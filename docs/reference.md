# Reference

## What Nix owns, what agentctl owns

The NixOS module (`services.agentfleet`) owns what should change on a
rebuild or a rollback: the Hermes package and the agents' toolset, the
sandbox as one template unit `agent@.service`, the Matrix server, the boot
starter and `agentctl` itself. Options: `enable`, `hermesPackage` (set from
the `hermes-agent` flake input by `nixosModules.default`), `extraPackages`,
and `matrix.*` (below).

`agentctl` owns the agents as runtime state under `/var/lib/agents/<name>/`
and `/srv/agents/<name>`. Creating or removing an agent never evaluates Nix
and never restarts another agent. A rebuild restarts agents only when the
template changed, which is what a Hermes upgrade does.

## What an agent is on disk

```
/srv/agents/<name>/                  home, agent-<name>:agent-<name> 0750
  .hermes/config.yaml                seeded once by agentctl from --model and --set; Hermes owns it afterwards
/var/lib/agents/<name>/              root 0700
  agent.json                         the definition (below)
  secrets.env                        provider keys, root 0400, from `agentctl add --secret` / `secrets set`
  environment.env                    non-secret variables from `--env`, root 0400
  matrix.env                         MATRIX_USER_ID, MATRIX_ACCESS_TOKEN, MATRIX_DEVICE_ID, root 0400, written by the reconciler
/var/lib/agentfleet/matrix/agents/<name>.json   the reconciler's account record
/etc/systemd/system.control/agent@<name>.service.d/   MemoryMax/CPUQuota drop-in, if set
```

`agent.json`:

```json
{
  "name": "scout",
  "state": "active",                 // or "removed" after `rm`
  "created": 1792000000,
  "localpart": "scout",              // Matrix id is @<localpart>:<serverName>
  "model": "anthropic/claude-sonnet-5.5",
  "description": "research assistant",
  "memory_max": "4G",
  "cpu_quota": "200%",
  "environment": { "TZ": "UTC" },
  "settings": { "model": { "provider": "anthropic" } }
}
```

`settings` and `model` are only used to seed `config.yaml`; after the first
start Hermes rewrites that file itself. A directory under `/var/lib/agents`
is an agent by virtue of existing; the reconciler and the boot starter read
these files, nothing else does.

## What an agent gets

- a system user `agent-<name>`, created with `useradd --system`, no login
  shell, left alone by NixOS because it is not declared
- `agent@<name>.service`, an instance of the template: `hermes gateway`,
  hardened, restarted on failure, requires Synapse (stopping the server stops
  the agents), ordered after the reconciler without requiring it
- on PATH: Hermes, git, curl, jq, ripgrep, ssh, plus `extraPackages`
- the environment `HOME`, `AGENT_NAME`, `HERMES_HOME`, `MATRIX_HOMESERVER`
  (loopback), `MATRIX_ALLOWED_USERS` (the operator), `MATRIX_E2EE_MODE=optional`,
  everything in `environment.env`, `secrets.env` and `matrix.env`
- a Matrix account `@<localpart>:<serverName>` and an introduction DM to the
  operator
- a start at boot, from `agentfleet-agents.service` (`agentctl start --all`)

## Secrets

`secrets.env` is root-owned, mode 0400, and loaded by systemd before the
service drops privileges. `agentctl secrets set NAME KEY` prompts for the
value with hidden input (`KEY=VALUE` also works, at the cost of your shell
history), writes the file in the `KEY="value"` dialect systemd reads and
restarts a running agent; `edit` opens it in `$EDITOR`; `list` prints key
names only. Hermes picks its provider from whichever of `ANTHROPIC_API_KEY`,
`OPENROUTER_API_KEY` or `OPENAI_API_KEY` is set. `agentctl add` refuses a
credential-looking name in `--env` or `--set`, so keys always end up here.

## Other model providers

Hermes talks to any OpenAI-compatible endpoint when `model.provider` is
`custom`, with `model.base_url` and `model.key_env` naming the endpoint and
the environment variable that holds its key. [A Morph-backed agent](morph.md)
walks through it; the same recipe works for any such provider.

## The sandbox

Every agent runs with: no capabilities, read-only system except its home,
private `/tmp` and `/dev`, invisible `/proc`, no new privileges, no
namespaces, native syscalls only, `AF_UNIX`/`AF_INET`/`AF_INET6`/`AF_NETLINK`
only, `ProtectHome`, umask 0077, optional `MemoryMax` and `CPUQuota`. The
definition is `sandbox` in `modules/default.nix`.

## The Matrix side

Options under `services.agentfleet.matrix`: `serverName` (permanent),
`operator`, `listenAddresses` (default `["127.0.0.1"]`, loopback is always
included), `listenPort` (8008), `publicBaseUrl` (default
`https://<serverName>`; set it when the server name is the bare domain and
the server lives on a subdomain, see [short user ids](install.md#short-user-ids)).

| unit | role |
|---|---|
| `matrix-synapse.service` | Synapse on `<listenAddresses>:<listenPort>`, plain HTTP, Postgres-backed, registration closed |
| `agentfleet-matrix-secret.service` | generates the registration shared secret Synapse and the reconciler share |
| `agentfleet-matrix-db.service` | creates the C-collated database Synapse insists on |
| `agentfleet-matrix.service` | runs `agentfleet-matrix reconcile` once at boot |
| `agentfleet-agents.service` | runs `agentctl start --all` at boot, after the reconciler |

The reconciler (`agentfleet-matrix`, reached as `agentctl matrix`) reads
`/etc/agents/matrix.json` for the homeserver and operator and
`/var/lib/agents/*/agent.json` for the agents, and keeps the homeserver in
step:

1. Creates an admin account `@agentfleet:<serverName>` on first run and keeps
   its token in `/var/lib/agentfleet/matrix/admin.json`.
2. For an agent (`provision <name>`, called by `agentctl add`; or all of
   them, `reconcile`, at boot): creates the account if missing, unlocks it if
   it was locked, lifts Synapse's message rate limit, sets a fresh password,
   logs in with the fixed device id `AGENTFLEET`, and writes `matrix.env`. A
   running agent is restarted when its token changed.
3. Sends the introduction once, in two halves. The local half, done
   immediately: a private room created by the agent, the greeting posted in
   it, and the room marked as a DM. The federated half: inviting the
   operator with an `m.room.member` event carrying `is_direct`, so their
   client files the room as a DM too. The invite makes Synapse contact the
   operator's homeserver and only works once federation works in both
   directions. Until then the invite is
   retried on every run and by `agentctl matrix introduce <name>`, always in
   the same room, so you never receive more than one invite per agent;
   `agentctl matrix check` finds out why it fails. A failure here, or
   anything else that goes wrong for one agent, is logged and does not fail
   the unit or affect other agents.
4. `lock <name>` (called by `agentctl rm`) locks the account and logs out its
   devices; `reconcile` does the same for any provisioned account whose agent
   no longer exists. `purge <name>` (called by `agentctl rm --purge`) makes
   the account leave every room, locks it and records the name as purged;
   such a name is refused by `provision` and by `agentctl add` forever. The
   locked account stays on the homeserver; Synapse's own deactivation is not
   used.

```
agentctl matrix status                 homeserver, admin, per-agent account state
agentctl matrix check                  DNS, TLS, proxy routes, .well-known, federation, from the host (no root)
agentctl matrix introduce <name>       resend the introduction DM
agentctl matrix rotate-token <name>    log out every session, issue a new token, restart the agent
agentctl matrix start|stop|restart     Synapse, and with it every agent
agentctl matrix logs [-f]              journal of Synapse and the reconciler
```

Each is described in [agentctl](agentctl.md). State lives in
`/var/lib/agentfleet/matrix/` (shared secret, admin token, one record per
agent account).

## Checks

```sh
nix flake check --no-build      # evaluates the module and the VM test
nix flake check                 # also builds the CLIs and runs the VM test (needs KVM)
nix build .#checks.x86_64-linux.vm
```

The VM test runs a real Synapse with a stub `hermes` binary and drives
`agentctl` end to end: add, environment and token wiring, the introduction,
secrets, a second agent not restarting the first, limits, rotation, `rm` and
resume, `purge`, fleet and server lifecycle, and a reboot.

## Layout

```
flake.nix                 nixosModules.default (sets hermesPackage from the hermes-agent input), packages, checks
modules/default.nix       the platform: agent@.service template, sandbox, boot starter, state.json
modules/matrix.nix        the fleet's Matrix server: Synapse, Postgres, reconciler unit
pkgs/agentctl/            the admin CLI (python, stdlib only) and its shell completions
pkgs/agentfleet-matrix/   the Matrix reconciler (python, stdlib only)
checks/                   example host, NixOS VM test
docs/                     install, end-to-end example, agentctl, Morph, this reference
```
