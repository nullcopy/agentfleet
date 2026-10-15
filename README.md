# agentfleet

Run several AI agents on one NixOS host, each as its own locked-down Unix user,
each with the harness of your choice (Hermes, OpenClaw, Claude Code, or any
command), declared in Nix and driven day to day by a small CLI.

```
$ sudo agentctl add research --harness hermes --model anthropic/claude-sonnet-5-5
  ANTHROPIC_API_KEY (Anthropic API key) [enter to skip]: ********
  ...
wrote /etc/nixos/agents/research.toml
git: staged (commit when you are happy with it)
wrote 1 secret(s) to /var/lib/agents/research/secrets.env
==> nixos-rebuild switch --flake /etc/nixos
agent 'research' is up. Next: agentctl status research | agentctl shell research

$ sudo agentctl rm research --purge
```

What you get per agent:

- a system user `agent-<name>` with home `/srv/agents/<name>`, nothing else writable
- a systemd sandbox (no capabilities, read-only system, private /tmp and /dev,
  no new privileges, no namespaces) that applies to the agent's service and
  equally to `agentctl shell`/`run`, which are transient services of the same shape
- a root-owned secrets file at `/var/lib/agents/<name>/secrets.env`, read by systemd
  into the service and into `agentctl shell`/`run`, never readable by the agent's
  user directly and never on a command line
- optional `MemoryMax` / `CPUQuota`

Removing an agent from the registry and rebuilding removes the user and units.
`--purge` also deletes its home and state.

## Install

agentfleet is added to a NixOS host you already run and administer with a
flake. The host's flake checkout (for example `/etc/nixos`) becomes the
source of truth for the fleet: each agent is a small TOML file inside it,
`agentctl` edits those files and runs `nixos-rebuild` for you, and the NixOS
module turns them into users and services.

If you want to see a complete host flake that this could be added to, see
[nixos-core](https://github.com/nullcopy/nixos-core).

### 1. Add the flake input and import the module

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

### 2. Tell the module where things live

In `configuration.nix`:

```nix
services.agentfleet = {
  # Where this flake is checked out ON THE HOST. agentctl writes new agent
  # files here and runs `nixos-rebuild switch --flake <flakeDir>`.
  flakeDir = "/etc/nixos";

  # The directory of per-agent TOML files, as a Nix path relative to this
  # file. It must be inside the flake so Nix can read it at build time.
  registry.dir = ./agents;
};
```

Both options describe the same directory from two points of view: Nix needs a
path it can read at evaluation time (`registry.dir`), and agentctl needs the
real location on disk to write to (`flakeDir` + `/agents`). If your registry is
not named `agents`, also set `registry.hostPath`.

### 3. Create the registry directory and rebuild

```sh
cd /etc/nixos
mkdir -p agents && touch agents/.keep
git add agents          # flakes ignore untracked files
sudo nixos-rebuild switch --flake .
```

### 4. Check it works

```sh
agentctl harnesses      # recipes available on this host
agentctl list           # "no agents defined"
sudo agentctl add scout --harness claude-code
```

### Optional

- **Claude Code** is unfree in nixpkgs. To use that harness, add
  `nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "claude-code" ];`
  to the host configuration.
- **Agents in Nix instead of TOML.** Skip `registry.dir` and write
  `services.agentfleet.agents.<name> = { harness = "hermes"; ... };` directly.
  Both styles can be mixed.
- **Not applying with `nixos-rebuild` on the host** (colmena, deploy-rs, a
  wrapper script)? Set `services.agentfleet.rebuildCommand`; `{action}` is replaced
  with `switch` or `dry-activate`.
- **Bringing your own Hermes package.** Import `agentfleet.nixosModules.core`
  instead of `default` and set `services.agentfleet.harnesses.hermes.package`.

## agentctl

```
agentctl list                      agents, harness, source, service state
agentctl harnesses                 recipes and the secrets they understand
agentctl add <name> --harness H    register + store secrets + rebuild
agentctl rm <name> [--purge]       unregister + rebuild [+ delete home/state]
agentctl apply [--dry-run]         rebuild from the current registry
agentctl start|stop|restart <name>
agentctl status [name]
agentctl logs <name> [-f] [-n N]
agentctl shell <name>              sandboxed login shell as the agent, secrets loaded
agentctl run <name> -- <cmd...>    one sandboxed command as the agent, in its home
agentctl secrets set|edit|list <name>
```

`agentctl add` options worth knowing: `--set key=value` writes harness settings
(dotted keys allowed, e.g. `--set gateway.port=18790`; integers and
`true`/`false` become TOML literals, `--set-str` keeps a string), `--env K=V`
adds non-secret environment, `--package` adds nixpkgs packages to PATH, and
`--no-apply` writes the registry entry without rebuilding.

`shell` and `run` start a transient systemd service as the agent's user
(`systemd-run --uid ... --pty`) carrying the same sandbox properties as the
agent's own units, so an on-demand harness like Claude Code is as confined as
a long-running one.

Everything agentctl knows comes from `/etc/agents/state.json`, which the module
renders. It has no Nix logic of its own, so it works unchanged with any
registry location, rebuild command, or harness set.

## Registry format

`services.agentfleet.registry.dir` points at a directory inside your flake. Each
`<name>.toml` becomes `services.agentfleet.agents.<name>`; the two sources merge,
and a name defined in both is an evaluation error.

```toml
harness = "hermes"                   # required: hermes | openclaw | claude-code | custom | yours
description = "research assistant"
model = "anthropic/claude-sonnet-5-5"
enable = true                        # false: keep the file, deploy nothing
autostart = true                     # start at boot (service harnesses only)
packages = ["python3", "nodejs"]     # nixpkgs attribute paths
memory_max = "4G"
cpu_quota = "200%"
secrets_file = "/run/secrets/research.env"   # e.g. sops-nix; default is under /var/lib/agents

[environment]
TZ = "UTC"

[settings]                           # harness-specific; merged into its config file
```

Flakes only see git-tracked files. `agentctl add` runs `git add` for you;
hand-written entries need it too.

## Harnesses

| name          | runs as            | config seeded at                 | notes |
|---------------|--------------------|----------------------------------|-------|
| `hermes`      | `hermes gateway`   | `~/.hermes/config.yaml`          | `settings` are Hermes config keys. Package comes from the hermes-agent flake input; first build compiles it. |
| `openclaw`    | `openclaw gateway` | `~/.openclaw/openclaw.json`      | `OPENCLAW_GATEWAY_TOKEN` required. Each agent is its own gateway: give the second one `--set gateway.port=18790`. nixpkgs flags the package insecure; the recipe clears that flag. |
| `claude-code` | on demand          | `~/.claude/settings.json`        | Unfree in nixpkgs: set `nixpkgs.config.allowUnfreePredicate`. Use `agentctl run name -- claude -p "..."`. |
| `custom`      | `settings.exec`    | nothing                          | Any command; `settings.init` runs once on first start. |

Seeded config files are written only if absent, because every one of these
harnesses edits its own config at runtime. Changing `model` or `settings` after
the first start therefore does not rewrite the file; edit it as the agent
(`agentctl shell`) or delete it and restart the init unit.

All agents share one systemd sandbox definition (see `sandboxOf` in
`modules/default.nix`). It forbids user namespaces, which breaks harnesses
that wrap their own tool calls in bubblewrap, such as Claude Code's optional
sandbox. Relax it per harness:
`services.agentfleet.harnesses.claude-code.sandbox = _: { RestrictNamespaces = false; };`.

### Writing a harness

A harness is a module that sets `services.agentfleet.harnesses.<name>`:

```nix
{ pkgs, lib, ... }: {
  services.agentfleet.harnesses.aider = {
    description = "aider; on demand";
    package = pkgs.aider-chat;
    secrets = [ { name = "OPENAI_API_KEY"; } ];
    environment = ag: { AIDER_CONFIG = "${ag.home}/.aider.conf.yml"; };
    # exec = ag: "${lib.getExe pkgs.aider-chat} --serve";   # omit for on-demand
    files = ag: { ".aider.conf.yml" = { text = "model: ${ag.model}\n"; }; };
    # sandbox = _: { RestrictNamespaces = false; };               # loosen the defaults
  };
}
```

Each function receives the resolved agent: `name`, `user`, `group`, `home`,
`model`, `settings`, `envVars`, `packages`, `secretsFile`, `stateDir`, `harnessCfg`,
and `raw` (the submodule config). Files are `seed` (a real file, written once)
or `managed` (a symlink into the store, refreshed on every activation).

## Secrets

The default secrets file is created empty, root-owned, mode 0400, and loaded via
`EnvironmentFile`; it must exist, so a typo in `secrets_file` fails the service
instead of starting it without credentials. `agentctl secrets set NAME K=V`
edits it and restarts a running service. To manage secrets declaratively, point
`secretsFile` at a sops-nix or agenix path; agentctl refuses to write there, so
use your secrets tool instead.

Everything else about an agent, including `[settings]` and the whole TOML
registry, is copied into the Nix store, which is world-readable. Tokens and
keys go in the secrets file, never in settings or environment.

## Several hosts

Keep one flake with one `nixosConfigurations` entry per host and one registry
per host: `registry.dir = ./hosts/${hostName}/agents;`. agentctl on each host
only ever touches its own directory. Nothing is shared between hosts; move an
agent by moving its TOML file and copying its home.

## Checks

```sh
nix flake check --no-build      # evaluates every recipe and the VM test
nix flake check                 # also builds agentctl and runs the VM test (needs KVM)
nix build .#checks.x86_64-linux.vm
```

## Layout

```
flake.nix                 nixosModules.{default,core}, packages.agentctl, checks
modules/default.nix       the services.agentfleet module
modules/harnesses/        hermes, openclaw, claude-code, custom
pkgs/agentctl/            the CLI (python, stdlib only)
checks/                   example host used by `nix flake check`, NixOS VM test
```
