# Install

agentfleet is added to a NixOS host you already run and administer with a
flake. If you want to see a complete host flake, see
[nixos-core](https://github.com/nullcopy/nixos-core).

Nix owns the platform: the Hermes package and the agents' toolset, the
sandbox, the Matrix server and the `agentctl` tool. Agents themselves are
runtime state that `agentctl` creates and destroys in seconds, without a
rebuild, so an unrelated system change never touches a running agent and a
rebuild never happens behind your back.

Installation has two phases. First you stand up the Matrix server and prove
that the internet can reach it (steps 1 to 6). Only then do you create agents
(the [end-to-end example](e2e-example.md)). An agent created before the
server is reachable comes up fine but cannot deliver its introduction to you.

## What you need

Two machines, or one machine playing both roles:

- **The fleet host.** NixOS with flakes enabled and `git`. Runs the agents and
  the Matrix server (Synapse). It needs no public address.
- **The proxy host.** Has a public, static IP address and runs your reverse
  proxy with TLS. It must be able to reach the fleet host over some private
  network (a VPN, a LAN, a cloud VPC: anything where plain HTTP between the
  two is acceptable). If the fleet host itself has a public address, it can
  be the proxy host too.

Plus:

- a domain you control, for the fleet's Matrix server
- your own Matrix user id on an existing homeserver
- an API key for the model provider the agents will use (Anthropic, OpenRouter or OpenAI)

Names used below are placeholders, substitute your own everywhere:

| placeholder          | meaning                                                      |
| -------------------- | ------------------------------------------------------------ |
| `matrix.example.org` | the fleet's Matrix server name and public DNS name           |
| `@alice:example.com` | you, on your existing homeserver                             |
| `myhost`             | the fleet host, as named in the flake's `nixosConfigurations` |
| `10.0.0.2`           | the fleet host's address on the private network               |
| `203.0.113.5`        | the proxy host's public address                               |

## 1. DNS and the public side

Your account on `example.com` reaches the agents through Matrix federation,
which needs `https://matrix.example.org` to be reachable from the internet.
That is the proxy host's job.

- **DNS.** An `A` (and/or `AAAA`) record `matrix.example.org` pointing at the
  proxy host's public address, `203.0.113.5`. No `SRV` record is needed.
- **Ports on the proxy host.** Inbound TCP 80 (certificate challenge) and
  TCP 443 (all Matrix traffic). Port 8448, the historical federation port, is
  not needed because `.well-known` delegation below tells other servers to
  use 443.
- **Ports on the fleet host.** TCP 8008 open to the proxy host only, nothing
  else. Outbound HTTPS must be allowed (federation to `example.com`, model
  providers, certificate checks).
- **Server name.** In the basic setup `matrix.example.org` is both the DNS
  name and the Matrix server name, so user ids look like
  `@scout:matrix.example.org`. For the shorter `@scout:example.org` see
  [Short user ids](#short-user-ids) below before you rebuild. Either way the
  choice is permanent: it is baked into every user id and into the database,
  and changing it later means [starting the server over](#starting-the-server-over).

## 2. Add the flake input and import the module

In the fleet host's `flake.nix`:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    agentfleet.url = "github:nullcopy/agentfleet";
  };

  outputs = { nixpkgs, agentfleet, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        agentfleet.nixosModules.default   # <- this line
        ./configuration.nix
      ];
    };
  };
}
```

`myhost` must match the host's own `networking.hostName`, as it does for any
flake-based NixOS system; agents mention that name when they introduce
themselves.

## 3. Configure the fleet host

Add this to `configuration.nix`. Every value you must change is marked
`CHANGE`; the rest can stay as written.

```nix
services.agentfleet = {
  enable = true;

  matrix = {
    serverName = "matrix.example.org";                # CHANGE: permanent, see step 1
    operator = "@alice:example.com";                  # CHANGE: your own Matrix id
    listenAddresses = [ "10.0.0.2" ];                 # CHANGE: this host's address as the proxy sees it
  };

  # Optional: tools every agent gets on its PATH, besides git, curl, jq,
  # ripgrep and ssh which are always there.
  # extraPackages = [ pkgs.python3 pkgs.nodejs ];
};
```

And this, as a separate top-level setting, not inside the
`services.agentfleet` block:

```nix
# NixOS blocks inbound connections by default; this opens port 8008, but
# only on the network interface that carries the private address above, so
# the proxy host can reach Synapse and the internet cannot.
networking.firewall.interfaces."eth1".allowedTCPPorts = [ 8008 ];  # CHANGE: interface name, see below
```

To find the interface name, run `ip addr` on the fleet host and look for the
interface that holds the `listenAddresses` address: `tailscale0` or `wg0` for
a VPN, `eth1` or similar for a second network card. Do not use the plain
`networking.firewall.allowedTCPPorts` form here: it would open the port on
every interface.

What each value does:

| value                    | meaning                                                                                                                   |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------- |
| `matrix.serverName`      | The part after the colon in every agent's user id. Cannot change later.                                                   |
| `matrix.operator`        | The one Matrix user the agents accept messages and invites from, and DM when they come up. Must be on another homeserver. |
| `matrix.listenAddresses` | Private addresses Synapse listens on, in addition to loopback. Leave it out when the proxy runs on the fleet host itself.  |
| `matrix.publicBaseUrl`   | Only if the public URL is not `https://<serverName>`, as with [short user ids](#short-user-ids).                          |
| `matrix.listenPort`      | Only if 8008 clashes with something; default 8008.                                                                        |
| `extraPackages`          | Extra tools on every agent's PATH.                                                                                        |

Synapse speaks plain, unauthenticated HTTP on `listenAddresses`, and that
listener includes the admin API. Never expose it beyond the proxy host.

## 4. Configure the reverse proxy

On the proxy host, the proxy must do four things for `matrix.example.org`,
whatever software it is:

1. Terminate TLS with a valid certificate (Let's Encrypt is fine).
2. Forward `/_matrix/*` and `/_synapse/client/*` to `http://10.0.0.2:8008`,
   passing the `Host` header and `X-Forwarded-For` through. Synapse is
   configured to trust those headers. Do not forward `/_synapse/admin`.
3. Serve `/.well-known/matrix/server` with body
   `{"m.server": "matrix.example.org:443"}` so other homeservers federate
   over 443, and `/.well-known/matrix/client` with body
   `{"m.homeserver": {"base_url": "https://matrix.example.org"}}` for clients.
   Both as `application/json`; the client one needs
   `Access-Control-Allow-Origin: *`.
4. Allow request bodies of at least 50 MB (file uploads) and not cut off
   responses that take 30 s or more (`/sync` long-polls).

With [Caddy](https://caddyserver.com/), which handles TLS, `Host` and
`X-Forwarded-For` by itself and has no body or response limits by default,
that is this Caddyfile. The domain appears once, on the site line, and the
`.well-known` bodies take it from the request through the `{host}`
placeholder; the fleet host's address appears once in `reverse_proxy`:

```caddyfile
matrix.example.org {
    @synapse path /_matrix/* /_synapse/client/*
    handle @synapse {
        reverse_proxy 10.0.0.2:8008
    }

    handle /.well-known/matrix/server {
        header Content-Type application/json
        respond `{"m.server": "{host}:443"}` 200
    }

    handle /.well-known/matrix/client {
        header Content-Type application/json
        header Access-Control-Allow-Origin *
        respond `{"m.homeserver": {"base_url": "https://{host}"}}` 200
    }

    handle {
        respond 404
    }
}
```

If the proxy host is itself NixOS, the same thing as
`services.caddy.virtualHosts."matrix.example.org".extraConfig` with the
outer braces removed, plus `networking.firewall.allowedTCPPorts = [ 80 443 ];`.

If the proxy runs on the fleet host, leave `listenAddresses` and the firewall
line out of step 3 and use `127.0.0.1:8008` here.

## 5. Stand up the server: rebuild

On the fleet host:

```sh
sudo nixos-rebuild switch --flake /etc/nixos
```

The first rebuild builds Hermes and Synapse, which takes a while. When it is
done, Synapse runs on the host, the reconciler has created its admin account,
and `agentctl` is on your PATH with tab completion. No agents exist yet.

## 6. Verify that the world can reach the server

On the fleet host:

```sh
agentctl matrix check
```

It checks, in order: Synapse answers locally, DNS for the public name, HTTPS
and the `/_matrix` route through the proxy, that the proxy really forwards
to *this* Synapse, both `.well-known` documents, outbound federation to your
own homeserver, and finally asks the
[Matrix Federation Tester](https://federationtester.matrix.org/) for the view
from the internet. Each line is `OK` or `FAIL` with a hint:

```
Checking matrix.example.org (public URL https://matrix.example.org) from this host

  OK    Synapse answers on the host: http://127.0.0.1:8008
  OK    DNS for matrix.example.org: 203.0.113.5
  OK    HTTPS and the /_matrix route through the proxy: https://matrix.example.org/_matrix/client/versions
  OK    the proxy reaches this Synapse: server_name matrix.example.org
  OK    .well-known/matrix/server: m.server matrix.example.org:443
  OK    federation endpoint behind m.server: https://matrix.example.org:443/_matrix/key/v2/server
  OK    .well-known/matrix/client: base_url https://matrix.example.org
  OK    outbound federation to example.com: https://matrix.example.com:443
  OK    Matrix Federation Tester (from the internet): FederationOK

All good: other homeservers can reach this one. Agents will be able to reach the operator.
```

Do not continue until every line is `OK`. Typical failures and what they
mean:

| failing line | usual cause |
| --- | --- |
| Synapse answers on the host | the server is down; `sudo agentctl matrix logs -n 50` |
| DNS | the record is missing or still propagating, or points at the wrong address |
| HTTPS / `/_matrix` route | port 443 closed on the proxy host, Caddy not running, or the proxy host cannot reach the fleet host on 8008 (firewall, wrong `listenAddresses`) |
| the proxy reaches this Synapse | the proxy forwards somewhere else, or `serverName` was changed after the first start |
| .well-known | the two `handle` blocks are missing from the Caddyfile |
| outbound federation | the fleet host has no outbound HTTPS, or your homeserver is down |
| Federation Tester | anything above, as seen from outside; its web page has the full report |

For reference, `sudo agentctl matrix status` shows the server, the admin
account and the agents' accounts; with no agents yet it ends with
`no matrix agents`, and `agentctl list` says `no agents`.

Now continue with the [end-to-end example](e2e-example.md) to create your
first agent.

## Short user ids

To have agents called `@scout:example.org` while the server itself keeps
living at `matrix.example.org`, the Matrix server name becomes the bare
domain and the public URL stays as it is:

```nix
services.agentfleet.matrix = {
  serverName = "example.org";                       # the part after the colon in user ids
  publicBaseUrl = "https://matrix.example.org";     # where the server actually is
  # operator, listenAddresses as before
};
```

Decide this before the first rebuild (step 5). Other homeservers then look up
`https://example.org/.well-known/matrix/server`, so the two `.well-known`
documents must be served from the bare domain, with the names spelled out
rather than taken from the request:

```caddyfile
example.org {
    handle /.well-known/matrix/server {
        header Content-Type application/json
        respond `{"m.server": "matrix.example.org:443"}` 200
    }

    handle /.well-known/matrix/client {
        header Content-Type application/json
        header Access-Control-Allow-Origin *
        respond `{"m.homeserver": {"base_url": "https://matrix.example.org"}}` 200
    }

    # whatever else example.org serves goes here
}
```

The `matrix.example.org` block from step 4 stays as it is; its own
`.well-known` handlers are harmless. If anything in front of the proxy
routes by host name (a DNS record, a load balancer, an SNI map), the bare
domain needs the same treatment as `matrix.example.org`, with a certificate
of its own. `agentctl matrix check` knows the difference: it fetches
`.well-known` from the server name and everything else from the public URL,
and checks that the federation endpoint reports `example.org`.

## Starting the server over

The server name cannot be changed in place. If you need a different one, or
want a clean Synapse for any other reason, wipe the Matrix side; agents
created before are best purged first, since Hermes keeps state tied to their
old ids:

```sh
sudo agentctl purge <name> --yes                    # for each existing agent
sudo systemctl stop agentfleet-matrix matrix-synapse
sudo -u postgres dropdb matrix-synapse
sudo rm -rf /var/lib/matrix-synapse /var/lib/agentfleet/matrix
sudo systemctl restart agentfleet-matrix-secret agentfleet-matrix-db
# now change serverName / publicBaseUrl in configuration.nix, then:
sudo nixos-rebuild switch --flake /etc/nixos
sudo systemctl start matrix-synapse agentfleet-matrix
agentctl matrix check
```

This deletes every account, room and message on the fleet's server and the
record of purged names; nothing outside `/var/lib/matrix-synapse`,
`/var/lib/agentfleet/matrix` and that database is touched.

## Variations

- **Several hosts.** One `nixosConfigurations` entry per host, each with its
  own Matrix server and domain. Agents are created on each host with its own
  `agentctl`.
- **Updating Hermes.** It comes from the `hermes-agent` input inside
  agentfleet: `nix flake update agentfleet/hermes-agent`, then rebuild. That
  rebuild restarts every agent, since the template unit changed; agents are
  otherwise untouched by rebuilds. Synapse and everything else follow your
  `nixpkgs`.
- **Backups.** Everything about the fleet lives in `/var/lib/agents`,
  `/srv/agents`, `/var/lib/agentfleet` and the `matrix-synapse` Postgres
  database. Your flake is the platform, not the fleet.
