# Install

agentfleet is added to a NixOS host you already run and administer with a
flake. If you want to see a complete host flake, see
[nixos-core](https://github.com/nullcopy/nixos-core).

The host's flake checkout, `/etc/nixos` below, becomes the source of truth for
the fleet: each agent is a small TOML file inside it, `agentctl` edits those
files and runs `nixos-rebuild` for you, and the NixOS module turns them into
users, services and Matrix accounts.

You need:

- a NixOS host with flakes enabled and `git`
- a domain you control for the fleet's Matrix server
- your own Matrix user id on any homeserver
- an API key for the model provider the agents will use

Names used in this guide are placeholders, substitute your own everywhere:
`matrix.example.org` (the fleet's Matrix server), `example.com` (where your
own account lives), `myhost` (the NixOS host), `alice` (you).

## 1. Add the flake input and import the module

In the host's `flake.nix`:

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

## 2. Configure the fleet

In `configuration.nix`:

```nix
services.agentfleet = {
  # Where this flake is checked out ON THE HOST. agentctl writes new agent
  # files here and runs `nixos-rebuild switch --flake <flakeDir>`.
  flakeDir = "/etc/nixos";

  # The directory of per-agent TOML files, as a Nix path relative to this
  # file. It must be inside the flake so Nix can read it at build time.
  registry.dir = ./agents;

  matrix = {
    enable = true;
    serverName = "matrix.example.org";   # user ids become @<agent>:matrix.example.org; permanent
    operator = "@alice:example.com";   # you: allowed to talk to every agent, receives the intros
  };
};
```

`flakeDir` and `registry.dir` describe the same directory from two sides: Nix
needs a path it can read at evaluation time, agentctl needs the location on
disk to write to. If your registry is not named `agents`, also set
`registry.hostPath`.

`serverName` cannot be changed later without starting the Matrix server over;
pick it now.

## 3. Make the Matrix server reachable

Synapse listens on `127.0.0.1:8008` only, and the agents talk to it there.
Everything else, in particular your account on `example.com` talking to the
agents, goes through Matrix federation, which needs `https://matrix.example.org`
to be reachable from the internet. agentfleet does not manage any of this;
here is what has to be true.

**Address.** The host needs a public IP address that other homeservers can
connect to, IPv4 or IPv6, ideally both. A static address is best. A dynamic
one works with a DNS updater, but federation breaks each time the address
changes until DNS catches up. Behind a home router, forward TCP 80 and 443 to
the host.

**DNS.** An `A` (and/or `AAAA`) record for `matrix.example.org` pointing at that
address. No `SRV` record is needed because the `.well-known` document below
does the job. The record must resolve before the first rebuild, or the
certificate request fails; NixOS keeps retrying, so this is recoverable.

**Ports.** Inbound TCP 80 (for the ACME certificate challenge and redirects)
and TCP 443 (Matrix client and federation traffic). Port 8448, the historical
federation port, is not needed: `.well-known/matrix/server` tells other
servers to use 443. Outbound HTTPS must be allowed so your server can reach
`example.com` and friends. Port 8008 stays on loopback and is never exposed.

**Server name.** `serverName = "matrix.example.org"` keeps everything on one
host: the server name, the DNS name and the reverse proxy are the same thing,
and user ids look like `@scout:matrix.example.org`. If you would rather have
`@scout:example.org`, set `serverName = "example.org"` and serve
`https://example.org/.well-known/matrix/server` with
`{"m.server": "matrix.example.org:443"}` from whatever hosts `example.org`;
the rest of this guide stays the same.

**TLS and the reverse proxy.** A certificate for `matrix.example.org` and a
proxy that forwards the two Matrix path prefixes to port 8008 and answers the
two `.well-known` documents. With nginx and Let's Encrypt on the same host:

```nix
services.nginx = {
  enable = true;
  virtualHosts."matrix.example.org" = {
    enableACME = true;
    forceSSL = true;
    locations."/_matrix".proxyPass = "http://127.0.0.1:8008";
    locations."/_synapse/client".proxyPass = "http://127.0.0.1:8008";
    locations."= /.well-known/matrix/server".extraConfig = ''
      default_type application/json;
      return 200 '{"m.server": "matrix.example.org:443"}';
    '';
    locations."= /.well-known/matrix/client".extraConfig = ''
      default_type application/json;
      add_header Access-Control-Allow-Origin *;
      return 200 '{"m.homeserver": {"base_url": "https://matrix.example.org"}}';
    '';
    extraConfig = "client_max_body_size 50M;";
  };
};
security.acme = { acceptTerms = true; defaults.email = "admin@example.org"; };
networking.firewall.allowedTCPPorts = [ 80 443 ];
```

Any other proxy (Caddy, Traefik, a proxy on another machine) works the same
way: TLS on 443, `/_matrix` and `/_synapse/client` to `127.0.0.1:8008`, the two
`.well-known` documents. Set `matrix.publicBaseUrl` if the public URL is not
`https://<serverName>`.

## 4. Create the registry directory and rebuild

```sh
cd /etc/nixos
mkdir -p agents && touch agents/.keep
git add agents flake.nix configuration.nix   # flakes ignore untracked files
sudo nixos-rebuild switch --flake .
```

The first rebuild builds Hermes and Synapse, which takes a while.

## 5. Check it works

```sh
agentctl harnesses              # hermes and the secrets it understands
agentctl list                   # "no agents defined"
sudo agentctl matrix status     # homeserver up, admin @agentfleet:matrix.example.org
```

Then confirm federation from outside with the
[Matrix Federation Tester](https://federationtester.matrix.org/) by entering
`matrix.example.org`. It checks DNS, the certificate, the `.well-known`
document and the federation API in one go and says which one is wrong.
Until it passes, agents will come up fine but their introduction DMs cannot
reach you; they are retried on every rebuild and by `agentctl matrix introduce`.

Continue with the [end-to-end example](e2e-example.md).

## Variations

- **Your account on the agents' server instead of federation.**
  `sudo agentctl matrix register-user alice` prints a password and token;
  log in to Element with them and set `operator = "@alice:matrix.example.org"`.
  The reverse proxy is then only needed to use that account from the internet.
- **Agents in Nix instead of TOML.** Skip `registry.dir` and write
  `services.agentfleet.agents.<name> = { harness = "hermes"; ... };`. Both
  styles can be mixed.
- **Not rebuilding with `nixos-rebuild` on the host** (colmena, deploy-rs, a
  wrapper)? Set `services.agentfleet.rebuildCommand` to what `agentctl add`/`rm`
  should run; `{action}` is replaced with `switch`.
- **Bringing your own Hermes package.** Import `agentfleet.nixosModules.core`
  instead of `default` and set `services.agentfleet.harnesses.hermes.package`.
- **A Synapse you already run.** `matrix.manageSynapse = false`, `matrix.clientUrl`
  pointing at it, and its `registration_shared_secret: "..."` line in
  `/var/lib/agentfleet/matrix/synapse-secrets.yaml`. See the reference.
- **No Matrix at all.** Leave `matrix.enable` off; agents then only have the
  chat platforms you configure in their settings yourself.
