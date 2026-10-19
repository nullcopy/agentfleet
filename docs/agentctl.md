# agentctl

`agentctl` runs on the fleet host. It reads `/etc/agents/state.json`, which
the NixOS module renders with the host's fixed facts, and otherwise only
touches `/var/lib/agents`, `/srv/agents`, the system user database, systemd
and the Matrix reconciler. Nothing it does rebuilds the system. Commands that
change anything need root. Tab completion for bash and zsh is installed with
the package; agent names complete.

```
agentctl list
agentctl add <name> [options]
agentctl edit <name> [options]
agentctl rm <name> [--purge] [--yes]
agentctl purge <name> [--yes]
agentctl start|stop|restart <name> | --all
agentctl status [<name>]
agentctl reset-config <name> [--yes]
agentctl logs <name> [-f] [-n N]
agentctl secrets set|edit|list <name> ...
agentctl matrix [status|check|introduce <name>|rotate-token <name>|start|stop|restart|logs]
```

## Agents

**`list`** prints every agent with its state, Matrix id, model and
description. The state is the service's, refined by what Hermes itself
reports about its Matrix connection: a healthy agent is `active`; one whose
gateway is up but not connected shows `active, matrix retrying` (or
`connecting`, `startup_failed`, `degraded`), and one whose gateway enabled no
messaging platform at all, which is how an agent goes silent while its unit
looks fine, shows `active, matrix none` with a hint after the table. Agents
removed with plain `rm` show as `removed`.

**`add <name>`** creates the system user `agent-<name>`, the home
`/srv/agents/<name>`, the state directory `/var/lib/agents/<name>` with
`agent.json`, the secrets and environment files, seeds
`~/.hermes/config.yaml`, asks the reconciler for a Matrix account and token,
starts `agent@<name>.service` and reports whether the invitation reached
you. It takes a few seconds. Other agents are not touched.

| option | effect |
| --- | --- |
| `--model M` | Hermes model id, e.g. `anthropic/claude-sonnet-5.5` |
| `--description TEXT` | shown by `list` and in the introduction DM |
| `--memory-max SIZE`, `--cpu-quota PCT` | systemd `MemoryMax` / `CPUQuota`, stored as a drop-in for this instance |
| `--env K=V` | non-secret environment variable, repeatable |
| `--set KEY=VAL` | Hermes `config.yaml` key, dotted; integers and `true`/`false` become literals. `--set-str` keeps a string |
| `--secret KEY[=VALUE]` | a secret to store; without `=VALUE` you are prompted with hidden input |
| `--no-prompt` | skip the prompts for the three well-known provider keys |
| `--no-start` | create everything but do not start the agent |

Running `add` for a name that was removed with plain `rm` resumes that
agent: same user, same home and memory, same Matrix account and DM room.
Flags given on the resume override the stored values; secrets are kept.

**`rm <name>`** stops the agent and marks it removed. The home, state,
secrets and Matrix account are kept, the account is locked, so `add` with
the same name brings it back exactly as it was. With `--purge` everything on
the host is deleted, the system user removed, the Matrix account leaves and
forgets every room, is logged out and locked, and the name is retired: no
agent of that name can ever be created again, on purpose.

**`purge <name>`** is `rm --purge`, also for an agent that was removed
earlier without it.

**`start`, `stop`, `restart`** act on one agent's service, or on every agent
with `--all`. At boot, `agentfleet-agents.service` runs `start --all`.

**`status [<name>]`** without a name is the `list` table. With a name it
answers the questions that matter when an agent does not reply, then prints
`systemctl status`:

```
agent:     scout (agent-scout, /srv/agents/scout)
model:     anthropic/claude-sonnet-5.5
service:   active
matrix:    connected as @scout:matrix.example.org
config:    ok (hermes config check)
profiles:  locked (one agent, one profile)
```

`matrix` is the gateway's own view (`connected`, `retrying`, `none` when it
enabled no platform, `stale` when it stopped reporting). `config` runs
`hermes config check` as the agent; a file Hermes cannot parse shows
`BROKEN` with the parser's complaint, and Hermes is then running on default
settings. `profiles` says whether the agent could create a second Hermes
profile, which would silence it (see `reset-config`).

**`logs <name>`** is `journalctl` for the agent's unit; `-f` follows,
`-n` sets the number of lines.

## Changing an agent

**`edit <name>`** changes an agent in place. Each flag changes one thing;
with no flags, the editable part of its definition opens in `$EDITOR` as
JSON and is validated before anything is applied.

| option | effect |
| --- | --- |
| `--model M` | new Hermes model id, applied with `hermes config set model.default` |
| `--description TEXT` | shown by `list` |
| `--memory-max SIZE`, `--cpu-quota PCT` | new limits, applied live; an empty value removes the limit |
| `--env K=V`, `--unset-env K` | non-secret environment variables, repeatable |
| `--set KEY=VAL`, `--set-str KEY=VAL`, `--unset KEY` | Hermes `config.yaml` keys, applied with `hermes config set` / `unset`, repeatable |
| `--no-restart` | leave a running agent alone; the change applies at its next restart |

The definition in `agent.json` is updated either way, so a later
`reset-config` or resume reproduces the change. Model and settings are
written by Hermes's own `hermes config` command, run as the agent, so Hermes
stays the only writer of its file; if that file is broken, `edit` refuses
and nothing changes. Model, settings and environment changes restart a
running agent; description and limits do not need to. Secrets are
`agentctl secrets`, and `edit` refuses credential-looking names.

**`reset-config <name>`** repairs the Hermes side of an agent that went
wrong, typically one that stopped answering while `list` still said
`active`. It stops the agent, moves its `config.yaml` to
`~/.hermes/backups/agentctl/`, moves any extra profile under
`~/.hermes/profiles/` there too, locks that directory again, reseeds
`config.yaml` from the stored model and settings and starts the agent. Home,
memory, secrets and the Matrix account are untouched. It asks before doing
so unless `--yes`.

Why profiles matter: a Hermes home with two or more profiles makes the
gateway a multiplexer that takes each profile's credentials from its own
files and ignores the Matrix token the service provides; the agent comes up
with no messaging platform and never hears you again. An agent asked to
"spawn more agents" tends to try exactly that. So `add` makes
`~/.hermes/profiles` a root-owned, read-only directory, `status` reports
whether it still is, and `reset-config` restores it. More agents are
`agentctl add`.

Hermes's own chat commands such as `/model` still work; they change
`config.yaml` directly and `agent.json` does not learn about them.

## Secrets

Secrets live in `/var/lib/agents/<name>/secrets.env`, root-only, loaded into
the service by systemd. Any variable name is accepted.

- `secrets set <name> KEY [KEY2 ...]` prompts for each value. `KEY=VALUE`
  also works but leaves the value in your shell history.
- `secrets edit <name>` opens the file in `$EDITOR`.
- `secrets list <name>` prints the names only.

`set` and `edit` restart a running agent so the change takes effect.

## Matrix

The fleet's Matrix server is Synapse, run by `matrix-synapse.service`. The
reconciler, `agentfleet-matrix`, gives each agent an account and a token and
sends the one-time introduction; `agentctl add` calls it for the new agent,
and `agentfleet-matrix.service` runs it once at boot as a safety net. Every
agent service requires Synapse, so stopping the server stops the agents.

| subcommand | what it does |
| --- | --- |
| `matrix check` | no root needed. Verifies from the host that the internet can reach the server: Synapse locally, DNS, HTTPS and the proxy routes, that the proxy forwards to this Synapse, both `.well-known` documents, outbound federation to the operator's homeserver, and the Matrix Federation Tester's view from outside. Prints `OK`/`FAIL` per item with a hint and exits non-zero on any failure. Run it before creating the first agent and whenever an introduction does not arrive |
| `matrix` or `matrix status` | is the homeserver up, which admin account bootstrapped it, who the operator is, and one row per agent account: `pending` (not yet provisioned), `active`, `locked` (removed with `rm`), `purged` (name retired), plus the id of the introduction room |
| `matrix introduce <name>` | send the introduction DM again, for example after federation started working |
| `matrix rotate-token <name>` | log the agent out of every session and issue a fresh token; the agent restarts with it. Use when a token may have leaked |
| `matrix stop` | stop Synapse. Every agent stops with it |
| `matrix start` | start Synapse, the reconciler and every agent |
| `matrix restart` | restart Synapse; systemd restarts the agents after it |
| `matrix logs [-f] [-n N]` | journal of Synapse and the reconciler |

Account records and the admin token live in `/var/lib/agentfleet/matrix/`.
