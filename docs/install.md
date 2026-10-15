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
- a DNS name for the fleet's Matrix server pointing at the host, `matrix.arx9.net` below
- your own Matrix user id, on any homeserver, `@nullcopy:4d2.org` below
- an API key for the model provider the agents will use

## 1. Add the flake input and import the module

In the host's `flake.nix`:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    agentfleet.url = "github:nullcopy/agentfleet";
  };

  outputs = { nixpkgs, agentfleet, ... }: {
    nixosConfigurations.obelisk = nixpkgs.lib.nixosSystem {
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
    serverName = "matrix.arx9.net";   # user ids become @<agent>:matrix.arx9.net; permanent
    operator = "@nullcopy:4d2.org";   # you: allowed to talk to every agent, receives the intros
  };
};
```

`flakeDir` and `registry.dir` describe the same directory from two sides: Nix
needs a path it can read at evaluation time, agentctl needs the location on
disk to write to. If your registry is not named `agents`, also set
`registry.hostPath`.

`serverName` cannot be changed later without starting the Matrix server over;
pick it now.

## 3. Put a reverse proxy in front of the Matrix server

Synapse listens on `127.0.0.1:8008` only. Your account on `4d2.org` reaches
the agents through federation, which needs `https://matrix.arx9.net` to serve
the Matrix API and a `.well-known` answer. With nginx and ACME:

```nix
services.nginx = {
  enable = true;
  virtualHosts."matrix.arx9.net" = {
    enableACME = true;
    forceSSL = true;
    locations."/_matrix".proxyPass = "http://127.0.0.1:8008";
    locations."/_synapse/client".proxyPass = "http://127.0.0.1:8008";
    locations."= /.well-known/matrix/server".extraConfig = ''
      default_type application/json;
      return 200 '{"m.server": "matrix.arx9.net:443"}';
    '';
    locations."= /.well-known/matrix/client".extraConfig = ''
      default_type application/json;
      add_header Access-Control-Allow-Origin *;
      return 200 '{"m.homeserver": {"base_url": "https://matrix.arx9.net"}}';
    '';
    extraConfig = "client_max_body_size 50M;";
  };
};
security.acme = { acceptTerms = true; defaults.email = "you@example.org"; };
networking.firewall.allowedTCPPorts = [ 80 443 ];
```

Any other proxy works the same way: TLS on 443, the two path prefixes to
port 8008, the two `.well-known` documents. agentfleet does not manage this
part.

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
sudo agentctl matrix status     # homeserver up, admin @agentfleet:matrix.arx9.net
```

Then confirm federation from outside with the
[Matrix Federation Tester](https://federationtester.matrix.org/#matrix.arx9.net).
Until it passes, agents will come up fine but their introduction DMs cannot
reach you; they are retried on every rebuild and by `agentctl matrix introduce`.

Continue with the [end-to-end example](e2e-example.md).

## Variations

- **Your account on the agents' server instead of federation.**
  `sudo agentctl matrix register-user nullcopy` prints a password and token;
  log in to Element with them and set `operator = "@nullcopy:matrix.arx9.net"`.
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
