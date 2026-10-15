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
- a domain you control, for the fleet's Matrix server
- your own Matrix user id on an existing homeserver
- an API key for the model provider the agents will use (Anthropic, OpenRouter or OpenAI)

Names used below are placeholders, substitute your own everywhere:
`matrix.example.org` (the fleet's Matrix server), `example.com` (where your
own account lives), `myhost` (the NixOS host), `alice` (you).

## 1. Point DNS at the host and open two ports

The agents talk to the Matrix server over loopback. Your account on
`example.com` talks to them through Matrix federation, which needs
`https://matrix.example.org` to be reachable from the internet.

- **Address.** The host needs a public IP address, IPv4 or IPv6, ideally both.
  A static address is best. A dynamic one works with a DNS updater, but
  federation breaks whenever the address changes until DNS catches up. Behind a
  home router, forward TCP 80 and 443 to the host.
- **DNS.** An `A` (and/or `AAAA`) record `matrix.example.org` pointing at that
  address. No `SRV` record is needed. The record must resolve before the first
  rebuild or the certificate request fails; NixOS keeps retrying, so this is
  recoverable.
- **Ports.** Inbound TCP 80 (certificate challenge, redirects) and TCP 443
  (Matrix traffic). Port 8448, the historical federation port, is not needed.
  Outbound HTTPS must be allowed. Port 8008 stays on loopback and is never
  exposed.
- **Server name.** `matrix.example.org` is both the DNS name and the Matrix
  server name, so user ids look like `@scout:matrix.example.org`. If you would
  rather have `@scout:example.org`, use `serverName = "example.org"` and serve
  `https://example.org/.well-known/matrix/server` containing
  `{"m.server": "matrix.example.org:443"}` from wherever `example.org` is
  hosted. Either way the choice is permanent: it is baked into every user id
  and into the database.

## 2. Add the flake input and import the module

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

## 3. Configure the fleet and the reverse proxy

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
    serverName = "matrix.example.org";   # permanent, see step 1
    operator = "@alice:example.com";     # you: allowed to talk to every agent, receives the intros
  };
};

# TLS and the reverse proxy in front of Synapse (127.0.0.1:8008). agentfleet
# does not manage this; any proxy works given the same four locations.
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

`flakeDir` and `registry.dir` describe the same directory from two sides: Nix
needs a path it can read at evaluation time, agentctl needs the location on
disk to write to. If your registry is not named `agents`, also set
`registry.hostPath`. If the public URL is not `https://<serverName>`, set
`matrix.publicBaseUrl`.

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
agentctl list                   # "no agents defined"
sudo agentctl matrix status     # homeserver up, admin @agentfleet:matrix.example.org
```

Then confirm federation from outside with the
[Matrix Federation Tester](https://federationtester.matrix.org/) by entering
`matrix.example.org`. It checks DNS, the certificate, the `.well-known`
document and the federation API in one go and says which one is wrong. Until
it passes, agents come up fine but their introduction DMs cannot reach you;
they are retried on every rebuild and by `agentctl matrix introduce <name>`.

Continue with the [end-to-end example](e2e-example.md).

## Variations

- **Agents in Nix instead of TOML.** Skip `registry.dir` and write
  `services.agentfleet.agents.<name> = { model = "..."; };`. Both styles mix;
  `agentctl rm` refuses to remove Nix-defined agents.
- **Several hosts.** One flake, one `nixosConfigurations` entry and one
  registry per host (`registry.dir = ./hosts/${hostName}/agents;`), each with
  its own Matrix server and domain.
- **Updating Hermes.** It comes from the `hermes-agent` input inside
  agentfleet: `nix flake update agentfleet/hermes-agent`, then rebuild.
  Synapse and everything else follow your `nixpkgs`.
