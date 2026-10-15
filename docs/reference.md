# Reference

## Registry format

`services.agentfleet.registry.dir` points at a directory inside your flake.
Each `<name>.toml` becomes an agent; the TOML registry and
`services.agentfleet.agents` (Nix) merge, and a name defined in both is an
evaluation error. Flakes only see git-tracked files: `agentctl add` runs
`git add` for you, hand-written entries need it too.

```toml
harness = "hermes"                   # required: hermes, or a harness you defined
description = "research assistant"
model = "anthropic/claude-sonnet-5.5" # Hermes's own model naming
enable = true                        # false: keep the file, deploy nothing
autostart = true                     # start at boot (service harnesses only)
packages = ["python3", "nodejs"]     # nixpkgs attribute paths, on the agent's PATH
memory_max = "4G"
cpu_quota = "200%"
secrets_file = "/run/secrets/research.env"   # e.g. sops-nix; default is under /var/lib/agents

[matrix]
enable = true                        # default: on when the Matrix server is enabled
localpart = "research"               # @<localpart>:<serverName>; change if the old id was deactivated
allowed_users = ["@friend:example.org"]   # besides the operator
introduce = true

[environment]                        # non-secret environment variables
TZ = "UTC"
MATRIX_FREE_RESPONSE_ROOMS = "!abc123:matrix.example.org"

[settings]                           # merged into the harness's own config file (Hermes config.yaml)
```

`agentctl add` writes this file from its flags: `--model`, `--description`,
`--no-autostart`, `--memory-max`, `--cpu-quota`, `--package` (repeatable),
`--env K=V`, `--set key=value` (dotted keys allowed; integers and
`true`/`false` become TOML literals, `--set-str` keeps a string), `--no-matrix`,
`--secret K=V` or an interactive prompt, `--no-rebuild`.

Everything in the registry, including `[settings]` and `[environment]`, is
copied into the world-readable Nix store. Tokens and keys go in the secrets
file, never there.

## What an agent gets

- a system user `agent-<name>` (prefix: `userPrefix`) with home
  `/srv/agents/<name>` (`homeBase`), mode 0750, created by systemd-tmpfiles
- `agent-<name>.service`, hardened, restarted on failure, and
  `agent-<name>-init.service`, a oneshot that runs the harness's `init` once
  (guarded by `~/.agentfleet/initialized`)
- files the harness seeds into the home: `seed` files are real files written
  only if absent, `managed` files are symlinks into the store refreshed on
  every activation
- `/etc/agents/<name>.sh`, the agent's environment for login shells, sourced
  by a managed `.bash_profile`
- a Matrix account, token and introduction when the Matrix server is on

Changing `model` or `settings` after the first start does not rewrite seeded
files, because Hermes edits its own config at runtime. Edit it as the agent
(`agentctl shell`) or delete it and restart the init unit.

## Secrets

The default secrets file `/var/lib/agents/<name>/secrets.env` is created
empty, root-owned, mode 0400, and loaded by systemd via `EnvironmentFile`; it
must exist, so a typo in `secrets_file` fails the service instead of starting
it without credentials. `agentctl secrets set NAME K=V` edits it in the
`KEY="value"` dialect systemd reads and restarts a running service. To manage
secrets declaratively, point `secretsFile` at a sops-nix or agenix path;
agentctl refuses to write there, use your secrets tool instead.

The Matrix token lives in a second file, `/var/lib/agents/<name>/matrix.env`,
written by the reconciler and loaded after the first.

## The sandbox

All agents share one systemd sandbox definition (`sandboxOf` in
`modules/default.nix`): no capabilities, read-only system except the home,
private `/tmp` and `/dev`, invisible `/proc`, no new privileges, no
namespaces, native syscalls only, `AF_UNIX`/`AF_INET`/`AF_INET6`/`AF_NETLINK`
only, umask 0077. `ProtectHome` is on unless `homeBase` is under `/home`.

`agentctl run` and `shell` start a transient service with `systemd-run` as the
agent's user carrying the same properties (they are rendered into state.json),
so an interactive session is as confined as the service. Secrets reach it
through `EnvironmentFile`, never a command line.

A harness relaxes the sandbox with its `sandbox` option, for example
`_: { RestrictNamespaces = false; }` for a harness that wraps its tool calls in
bubblewrap. Per agent, `extraServiceConfig` is merged last into the main
service only.

## Writing a harness

A harness is a module that sets `services.agentfleet.harnesses.<name>`:

```nix
{ pkgs, lib, ... }: {
  services.agentfleet.harnesses.aider = {
    description = "aider; on demand";
    package = pkgs.aider-chat;                       # on the agent's PATH
    secrets = [ { name = "OPENAI_API_KEY"; } ];      # prompted for by agentctl add
    environment = ag: { AIDER_CONFIG = "${ag.home}/.aider.conf.yml"; };
    # exec = ag: "${lib.getExe pkgs.aider-chat} --serve";   # omit for on-demand
    files = ag: { ".aider.conf.yml" = { text = "model: ${ag.model}\n"; }; };
    # init = ag: "...";                               # shell, once, as the agent
    # sandbox = _: { RestrictNamespaces = false; };
    # supportsMatrix = true;  # reads MATRIX_HOMESERVER/USER_ID/ALLOWED_USERS/ACCESS_TOKEN/DEVICE_ID
  };
}
```

Each function receives the resolved agent: `name`, `user`, `group`, `home`,
`model`, `settings`, `envVars`, `packages`, `secretsFile`, `stateDir`,
`harnessCfg`, `matrix` (`enable`, `userId`, `homeserver`, `allowedUsers`) and
`raw` (the submodule config). `agentctl harnesses` lists what is registered.

## The Matrix server

`services.agentfleet.matrix` options: `enable`, `serverName` (permanent),
`publicBaseUrl` (default `https://<serverName>`), `operator`,
`extraAllowedUsers`, `listenPort` (8008), `clientUrl`, `manageSynapse`,
`stateDir` (`/var/lib/agentfleet/matrix`), `adminLocalpart` (`agentfleet`).

What the host runs:

| unit | role |
|---|---|
| `matrix-synapse.service` | Synapse on `127.0.0.1:8008`, Postgres-backed, registration closed |
| `agentfleet-matrix-secret.service` | generates the registration shared secret Synapse and the reconciler share |
| `agentfleet-matrix-db.service` | creates the C-collated Postgres database Synapse insists on |
| `agentfleet-matrix.service` | the reconciler, run after every activation; agents start after it |

The reconciler (`agentfleet-matrix`, reached as `agentctl matrix`) reads
`/etc/agents/matrix.json`, rendered by the module, and keeps the homeserver in
step with it:

1. Creates an admin account `@agentfleet:<serverName>` on first run and keeps
   its token in `<stateDir>/admin.json`.
2. For each Matrix-enabled agent: creates the account if missing, unlocks it
   if it was locked, lifts Synapse's message rate limit, sets a fresh password,
   logs in with the fixed device id `AGENTFLEET`, and writes the token to
   `/var/lib/agents/<name>/matrix.env`. A running service is restarted when
   its token changed.
3. Sends the introduction: a private room created by the agent, the operator
   invited, one templated message naming the agent, its harness, model and
   description. If the invite cannot be delivered yet (federation not set up),
   it is retried on every run and by `agentctl matrix introduce <name>`.
4. Locks the account and logs out every device of any agent it provisioned
   earlier that is no longer declared.

The agent's environment carries `MATRIX_HOMESERVER`, `MATRIX_USER_ID` and
`MATRIX_ALLOWED_USERS` (operator, `extraAllowedUsers`, the agent's own list)
from Nix, and `MATRIX_ACCESS_TOKEN` and `MATRIX_DEVICE_ID` from the token file.
The Hermes recipe also sets `MATRIX_E2EE_MODE=optional`, so encrypted DMs
created from Element work and unencrypted rooms keep working if the crypto
store cannot initialise.

Commands:

```
agentctl matrix status                 homeserver, admin, per-agent account state
agentctl matrix introduce <name>       resend the introduction DM
agentctl matrix rotate-token <name>    log out every session, issue a new token, restart the agent
agentctl matrix deactivate <name>      after `agentctl rm`: deactivate the account for good
agentctl matrix register-user <local>  a human account on this server (prints its token)
```

Removal semantics: `agentctl rm scout` locks `@scout:<serverName>` and logs it
out; adding `scout` again unlocks the same account. `agentctl rm scout --purge`
additionally deactivates it, which Synapse makes permanent, so a later `scout`
needs `matrix.localpart = "scout2"` (the reconciler says so).

Using a Synapse you already run: `manageSynapse = false`, `clientUrl` pointing
at it, and its `registration_shared_secret: "..."` line in
`<stateDir>/synapse-secrets.yaml` (root, 0600). The reconciler needs the
Synapse admin API, so other homeservers are not supported.

## Several hosts

Keep one flake with one `nixosConfigurations` entry per host and one registry
per host: `registry.dir = ./hosts/${hostName}/agents;`. agentctl on each host
only ever touches its own directory. Each host runs its own Matrix server, or
all but one use `manageSynapse = false` against the first one's.

## Updates

Hermes comes from the `hermes-agent` input inside agentfleet
(`nix flake update agentfleet/hermes-agent`), Synapse and everything else from
your `nixpkgs`. A rebuild restarts the services whose definition changed;
`nixos-rebuild switch --rollback` restarts them on the previous versions.

## Checks

```sh
nix flake check --no-build      # evaluates every recipe and the VM test
nix flake check                 # also builds the CLIs and runs the VM test (needs KVM)
nix build .#checks.x86_64-linux.vm
```

## Layout

```
flake.nix                 nixosModules.{default,core}, packages, checks
modules/default.nix       the services.agentfleet module
modules/matrix.nix        the fleet's Matrix server (Synapse + reconciler)
modules/harnesses/        hermes
pkgs/agentctl/            the CLI (python, stdlib only)
pkgs/agentfleet-matrix/   the Matrix reconciler (python, stdlib only)
checks/                   example host used by `nix flake check`, NixOS VM test
docs/                     install, end-to-end example, this reference
```
