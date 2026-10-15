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
- a hardened systemd service (or none, for on-demand harnesses like Claude Code)
- a root-owned secrets file at `/var/lib/agents/<name>/secrets.env`, injected into the
  service and into `agentctl shell`/`run`, never readable by the agent's user directly
- optional outbound-network policy: open, loopback only, or an IP/CIDR allowlist
- optional `MemoryMax` / `CPUQuota`

Removing an agent from the registry and rebuilding removes the user and units.
`--purge` also deletes its home and state.

## Install

### Fresh host

```sh
sudo mkdir -p /etc/nixos && cd /etc/nixos
sudo nix flake init -t github:nullcopy/agentfleet
sudo nixos-generate-config --show-hardware-config | sudo tee hardware-configuration.nix
# edit configuration.nix: hostname, your SSH key; rename agenthost in flake.nix
sudo git init && sudo git add -A
sudo nixos-rebuild switch --flake /etc/nixos
```

### Existing NixOS flake

```nix
# flake.nix
inputs.agentfleet.url = "github:nullcopy/agentfleet";

# in your nixosConfigurations.<host>.modules:
agentfleet.nixosModules.default
```

```nix
# configuration.nix
services.agents = {
  flakeDir = "/etc/nixos";          # where this flake is checked out on the host
  registry.dir = ./agents;          # one TOML per agent; agentctl manages these
  # or, without a registry, declare agents inline:
  agents.reviewer = { harness = "claude-code"; model = "claude-opus-5-5"; };
};
networking.firewall.enable = true;  # needed only for egress policies
```

Then `git add agents/` (create it, even empty, with a `.keep`) and rebuild.
`agentctl` is installed system-wide by the module.

Not using `nixos-rebuild` locally? Set `services.agents.rebuildCommand` to
whatever applies your config; `{action}` is replaced by `switch` or `dry-activate`.

`nixosModules.core` is the same module without the Hermes flake input wired in,
for people who want to bring their own `harnesses.hermes.package`.

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
agentctl shell <name>              login shell as the agent, secrets loaded
agentctl run <name> -- <cmd...>    one command as the agent, in its home
agentctl secrets set|edit|list <name>
```

`agentctl add` options worth knowing: `--set key=value` writes harness settings
(dotted keys allowed, e.g. `--set gateway.port=18790`), `--env K=V` adds
non-secret environment, `--package` adds nixpkgs packages to PATH,
`--allow-host IP|CIDR` or `--no-network` set the egress policy, and
`--no-apply` writes the registry entry without rebuilding.

Everything agentctl knows comes from `/etc/agents/state.json`, which the module
renders. It has no Nix logic of its own, so it works unchanged with any
registry location, rebuild command, or harness set.

## Registry format

`services.agents.registry.dir` points at a directory inside your flake. Each
`<name>.toml` becomes `services.agents.agents.<name>`; the two sources merge,
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
egress = "allowlist"                 # open | none | allowlist
egress_allow = ["100.64.0.0/10"]     # IPs/CIDRs; hostnames are not supported
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

### Writing a harness

A harness is a module that sets `services.agents.harnesses.<name>`:

```nix
{ pkgs, lib, ... }: {
  services.agents.harnesses.aider = {
    description = "aider; on demand";
    package = pkgs.aider-chat;
    secrets = [ { name = "OPENAI_API_KEY"; } ];
    environment = ag: { AIDER_CONFIG = "${ag.home}/.aider.conf.yml"; };
    # exec = ag: "${lib.getExe pkgs.aider-chat} --serve";   # omit for on-demand
    files = ag: { ".aider.conf.yml" = { text = "model: ${ag.model}\n"; }; };
  };
}
```

Each function receives the resolved agent: `name`, `user`, `group`, `home`,
`model`, `settings`, `envVars`, `packages`, `secretsFile`, `stateDir`, `harnessCfg`,
and `raw` (the submodule config).

## Secrets

The default secrets file is created empty, root-owned, mode 0400, and loaded via
`EnvironmentFile`. `agentctl secrets set NAME K=V` edits it and restarts a
running service. To manage secrets declaratively, point `secretsFile` at a
sops-nix or agenix path; agentctl then edits that path, so leave it read-only
and use your secrets tool instead.

## Egress

`egress = "none"` or `"allowlist"` installs owner-UID rules for the agent's user:
nftables when `networking.nftables.enable`, iptables via the NixOS firewall
otherwise. Loopback is always allowed, so a local Ollama or proxy keeps
working. Rules match IPs, not hostnames; allow your resolver and the API
subnet, or put an egress proxy on loopback. The rules apply to everything the
user runs, including `agentctl shell`.

## Several hosts

Keep one flake with one `nixosConfigurations` entry per host and one registry
per host: `registry.dir = ./hosts/${hostName}/agents;`. agentctl on each host
only ever touches its own directory. Nothing is shared between hosts; move an
agent by moving its TOML file and copying its home.

## Checks

```sh
nix flake check          # evaluates every recipe; builds agentctl; VM test needs KVM
nix build .#checks.x86_64-linux.vm
```

## Layout

```
flake.nix                 nixosModules.{default,core}, packages.agentctl, templates, checks
modules/default.nix       the services.agents module
modules/harnesses/        hermes, openclaw, claude-code, custom
pkgs/agentctl/            the CLI (python, stdlib only)
templates/fresh-host/     starter flake for a new machine
checks/                   example host used by `nix flake check`, NixOS VM test
```
