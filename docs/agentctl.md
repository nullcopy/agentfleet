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
agentctl rm <name> [--purge] [--yes]
agentctl purge <name> [--yes]
agentctl start|stop|restart <name> | --all
agentctl status [<name>]
agentctl logs <name> [-f] [-n N]
agentctl secrets set|edit|list <name> ...
agentctl matrix [status|check|introduce <name>|rotate-token <name>|start|stop|restart|logs]
```

## Agents

**`list`** prints every agent with its service state, Matrix id, model and
description. Agents removed with plain `rm` show as `removed`.

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

**`status [<name>]`** is `systemctl status` for one agent, or the `list`
table.

**`logs <name>`** is `journalctl` for the agent's unit; `-f` follows,
`-n` sets the number of lines.

## Changing an agent

Model, description and limits: `agentctl add <name> --model ... ` after a
plain `rm`, which resumes it with the new values. Environment variables the
same way with `--env`. Hermes settings after the first start live in
`/srv/agents/<name>/.hermes/config.yaml`, a YAML file Hermes owns; edit it as
that agent's user and `agentctl restart <name>`, or use Hermes's own chat
commands such as `/model`.

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
