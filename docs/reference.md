# Reference

## Registry format

`services.agentfleet.registry.dir` points at a directory inside your flake.
Each `<name>.toml` is one agent; the registry and `services.agentfleet.agents`
(Nix) merge, and a name defined in both is an evaluation error. Flakes only
see git-tracked files: `agentctl add` runs `git add` for you, hand-written
entries need it too.

```toml
model = "anthropic/claude-sonnet-5.5"  # Hermes's own model naming
description = "research assistant"     # shown by agentctl list and in the introduction
enable = true                          # false: keep the file, deploy nothing
packages = ["python3", "nodejs"]       # nixpkgs attribute paths, on the agent's PATH for Hermes's tools
memory_max = "4G"
cpu_quota = "200%"

[environment]                          # non-secret environment variables
TZ = "UTC"
MATRIX_FREE_RESPONSE_ROOMS = "!abc123:matrix.example.org"

[settings]                             # Hermes config.yaml keys, seeded on first start

[matrix]
localpart = "scout2"                   # only if @scout was deactivated earlier
```

`agentctl add` writes this file from its flags: `--model`, `--description`,
`--memory-max`, `--cpu-quota`, `--package` (repeatable), `--env K=V`,
`--set key=value` (dotted keys; integers and `true`/`false` become TOML
literals, `--set-str` keeps a string), `--secret K=V` or the interactive
prompt, `--no-rebuild`.

Everything in the registry, including `[settings]` and `[environment]`, is
copied into the world-readable Nix store. Keys and tokens go in the secrets
file, never there.

## What an agent gets

- a system user `agent-<name>` with home `/srv/agents/<name>`, mode 0750,
  created by systemd-tmpfiles; no login shell
- `~/.hermes/config.yaml`, seeded once from `model` and `[settings]`. Hermes
  rewrites it at runtime, so later changes to those keys do not touch an
  existing file: delete it and restart the agent if you want them applied
- `agent-<name>.service` running `hermes gateway`, hardened, restarted on
  failure, started after the Matrix reconciler; and `agent-<name>-init.service`,
  a oneshot that marks the first start
- the environment `HERMES_HOME`, `MATRIX_HOMESERVER` (loopback),
  `MATRIX_USER_ID`, `MATRIX_ALLOWED_USERS` (the operator), `MATRIX_E2EE_MODE=optional`,
  plus `[environment]`
- two root-only files loaded by systemd into the service:
  `/var/lib/agents/<name>/secrets.env` (provider keys, yours) and
  `/var/lib/agents/<name>/matrix.env` (access token and device id, written by
  the reconciler)
- a Matrix account `@<localpart>:<serverName>` and an introduction DM to the
  operator

## Secrets

`secrets.env` is created empty, root-owned, mode 0400, and must exist; systemd
refuses to start the service without it. `agentctl secrets set NAME K=V`
writes it in the `KEY="value"` dialect systemd reads and restarts a running
agent; `edit` opens it in `$EDITOR`; `list` prints key names only. Hermes
picks its provider from whichever of `ANTHROPIC_API_KEY`, `OPENROUTER_API_KEY`
or `OPENAI_API_KEY` is set.

## The sandbox

Every agent service runs with: no capabilities, read-only system except its
home, private `/tmp` and `/dev`, invisible `/proc`, no new privileges, no
namespaces, native syscalls only, `AF_UNIX`/`AF_INET`/`AF_INET6`/`AF_NETLINK`
only, `ProtectHome`, umask 0077, optional `MemoryMax` and `CPUQuota`. The
definition is `sandbox` in `modules/default.nix`.

## The Matrix side

Options under `services.agentfleet.matrix`: `serverName` (permanent),
`operator`, `listenAddresses` (default `["127.0.0.1"]`, loopback is always
included), `listenPort` (8008), `publicBaseUrl` (default
`https://<serverName>`).

| unit | role |
|---|---|
| `matrix-synapse.service` | Synapse on `<listenAddresses>:<listenPort>`, plain HTTP, Postgres-backed, registration closed |
| `agentfleet-matrix-secret.service` | generates the registration shared secret Synapse and the reconciler share |
| `agentfleet-matrix-db.service` | creates the C-collated Postgres database Synapse insists on |
| `agentfleet-matrix.service` | the reconciler, run after every activation; agents start after it |

The reconciler (`agentfleet-matrix`, reached as `agentctl matrix`) reads
`/etc/agents/matrix.json`, rendered by the module, and keeps the homeserver in
step with it:

1. Creates an admin account `@agentfleet:<serverName>` on first run and keeps
   its token in `/var/lib/agentfleet/matrix/admin.json`.
2. For each agent: creates the account if missing, unlocks it if it was
   locked, lifts Synapse's message rate limit, sets a fresh password, logs in
   with the fixed device id `AGENTFLEET`, and writes the token to
   `matrix.env`. A running agent is restarted when its token changed.
3. Sends the introduction once: a private room created by the agent, the
   operator invited, one message naming the agent, its model and description.
   If the invite cannot be delivered yet (federation not working), it is
   retried on every run and by `agentctl matrix introduce <name>`.
4. Locks the account and logs out every device of any agent it provisioned
   earlier that is no longer declared.

Commands:

```
agentctl matrix status                 homeserver, admin, per-agent account state
agentctl matrix introduce <name>       resend the introduction DM
agentctl matrix rotate-token <name>    log out every session, issue a new token, restart the agent
agentctl matrix deactivate <name>      after `agentctl rm`: deactivate the account for good
```

Removal: `agentctl rm scout` locks `@scout:<serverName>` and logs it out;
adding `scout` again unlocks the same account. `agentctl rm scout --purge`
additionally deactivates it, which Synapse makes permanent, so a later
`scout` needs `[matrix] localpart = "scout2"`.

State lives in `/var/lib/agentfleet/matrix/` (shared secret, admin token, one
JSON record per agent) and is root-only.

## Checks

```sh
nix flake check --no-build      # evaluates the module and the VM test
nix flake check                 # also builds the CLIs and runs the VM test (needs KVM)
nix build .#checks.x86_64-linux.vm
```

The VM test runs a real Synapse with a stub `hermes` binary and checks users,
units, environment, token provisioning, the introduction, idempotent
reconciles, token rotation, and `agentctl add`/`rm`.

## Layout

```
flake.nix                 nixosModules.default (sets hermesPackage from the hermes-agent input), packages, checks
modules/default.nix       agents: users, units, sandbox, registry, state.json
modules/matrix.nix        the fleet's Matrix server: Synapse, Postgres, reconciler unit
pkgs/agentctl/            the admin CLI (python, stdlib only)
pkgs/agentfleet-matrix/   the Matrix reconciler (python, stdlib only)
checks/                   example host, NixOS VM test
docs/                     install, end-to-end example, this reference
```
