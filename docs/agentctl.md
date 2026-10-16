# agentctl

`agentctl` runs on the fleet host. It reads `/etc/agents/state.json`, which
the NixOS module renders, and otherwise only touches the registry directory,
the secrets files, systemd and the Matrix reconciler. Commands that change
anything need root. Tab completion for bash and zsh is installed with the
package; agent names complete.

```
agentctl list
agentctl add <name> [options]
agentctl rm <name> [--purge] [--yes] [--no-rebuild]
agentctl purge <name> [--yes]
agentctl start|stop|restart <name> | --all
agentctl status [<name>]
agentctl logs <name> [-f] [-n N]
agentctl secrets set|edit|list <name> ...
agentctl matrix [status|check|introduce <name>|rotate-token <name>|start|stop|restart|logs]
```

## Agents

**`list`** prints every agent with its service state, Matrix id, model and
description. Agents that were removed without `--purge` and still have files
on disk show up as `removed`.

**`add <name>`** writes `<registry>/<name>.toml`, stages it in git, stores
the provider key, runs `nixos-rebuild switch`, and the new agent introduces
itself to you on Matrix. After the rebuild it reports whether the agent runs
and whether the invitation reached you; if the invite could not be delivered
it points you at `matrix check`.

| option | effect |
| --- | --- |
| `--model M` | Hermes model id, e.g. `anthropic/claude-sonnet-5.5` |
| `--description TEXT` | shown by `list` and in the introduction DM |
| `--memory-max SIZE`, `--cpu-quota PCT` | systemd `MemoryMax` / `CPUQuota` |
| `--package PKG` | extra nixpkgs package on the agent's PATH, repeatable |
| `--env K=V` | non-secret environment variable, repeatable |
| `--set KEY=VAL` | Hermes `config.yaml` key, dotted; integers and `true`/`false` become literals. `--set-str` keeps a string |
| `--secret KEY[=VALUE]` | a secret to store; without `=VALUE` you are prompted with hidden input |
| `--no-prompt` | skip the prompts for the three well-known provider keys |
| `--no-rebuild` | write the file, do not rebuild |

**`rm <name>`** stops the agent, removes its registry file, rebuilds. The
Matrix account is locked and the home, state and secrets stay on disk, so a
later `add` with the same name resumes where it left off: same account, same
DM room, same memory. With `--purge` the files are deleted, the account
leaves every room, is logged out and locked, and the name is retired: no
agent of that name can ever be created again, on purpose. Nix-defined agents
cannot be removed here.

**`purge <name>`** does the `--purge` part for an agent that was removed
earlier without it. Refuses while the agent is still defined.

**`start`, `stop`, `restart`** act on one agent's service, or on every
enabled agent with `--all`.

**`status [<name>]`** is `systemctl status` for one agent, or the `list`
table.

**`logs <name>`** is `journalctl` for the agent's units; `-f` follows,
`-n` sets the number of lines.

## Secrets

Secrets live in `/var/lib/agents/<name>/secrets.env`, root-only, loaded into
the service by systemd. Any variable name is accepted.

- `secrets set <name> KEY [KEY2 ...]` prompts for each value. `KEY=VALUE`
  also works but leaves the value in your shell history.
- `secrets edit <name>` opens the file in `$EDITOR`.
- `secrets list <name>` prints the names only.

`set` and `edit` restart a running agent so the change takes effect.

## Matrix

The fleet's Matrix server is Synapse, run by `matrix-synapse.service`. After
every rebuild `agentfleet-matrix.service` (the reconciler) gives each agent
an account and a token and sends the one-time introduction. Every agent
service requires both, so stopping the server stops the agents.

| subcommand | what it does |
| --- | --- |
| `matrix check` | no root needed. Verifies from the host that the internet can reach the server: Synapse locally, DNS, HTTPS and the proxy routes, that the proxy forwards to this Synapse, both `.well-known` documents, outbound federation to the operator's homeserver, and the Matrix Federation Tester's view from outside. Prints `OK`/`FAIL` per item with a hint and exits non-zero on any failure. Run it before creating the first agent and whenever an introduction does not arrive |
| `matrix` or `matrix status` | is the homeserver up, which admin account bootstrapped it, who the operator is, and one row per agent account: `pending` (not yet provisioned), `active`, `locked` (removed with `rm`), `purged` (name retired), plus the id of the introduction room |
| `matrix introduce <name>` | send the introduction DM again, for example after federation started working |
| `matrix rotate-token <name>` | log the agent out of every session and issue a fresh token; the agent restarts with it. Use when a token may have leaked |
| `matrix stop` | stop Synapse. The reconciler and every agent stop with it |
| `matrix start` | start Synapse, the reconciler and every enabled agent |
| `matrix restart` | restart Synapse; systemd restarts the reconciler and the agents after it |
| `matrix logs [-f] [-n N]` | journal of Synapse and the reconciler |

Account records and the admin token live in `/var/lib/agentfleet/matrix/`.
The reconciler runs again on every rebuild and on
`systemctl restart agentfleet-matrix.service`, which is also how a failed
introduction is retried.
