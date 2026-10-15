# agentfleet

Run a fleet of AI agents on one NixOS host. Each agent is its own locked-down
Unix user running [Hermes](https://github.com/NousResearch/hermes-agent), with
an account on the fleet's own Matrix server, and it introduces itself to you
on Matrix when it comes up. Agents are declared in Nix or as one TOML file
each, and `agentctl` handles the day to day.

```
$ sudo agentctl add scout --harness hermes --model anthropic/claude-sonnet-5.5
  ANTHROPIC_API_KEY (Anthropic API key) [enter to skip]: ********
  ...
wrote /etc/nixos/agents/scout.toml
==> nixos-rebuild switch --flake /etc/nixos
agent 'scout' is up. Next: agentctl status scout | agentctl shell scout
```

A minute later `@scout:matrix.example.org` opens a DM with you:

> Hello! I'm **scout**, a hermes agent running on `myhost`
> (anthropic/claude-sonnet-5.5). This room is our direct line: message me
> here any time.

```
$ sudo agentctl rm scout --purge
```

## Documentation

- [Install](docs/install.md): add agentfleet to a NixOS host you already run,
  including the Matrix server and the reverse proxy in front of it.
- [End-to-end example](docs/e2e-example.md): create a Hermes agent, receive
  its introduction, chat with it, remove it.
- [Reference](docs/reference.md): registry format, agent and harness options,
  secrets, the sandbox, how the Matrix server works, checks.

## agentctl

```
agentctl list                      agents, harness, state, Matrix id
agentctl harnesses                 recipes and the secrets they understand
agentctl add <name> --harness H    register + store secrets + rebuild
agentctl rm <name> [--purge]       unregister + rebuild [+ delete home, state, account]
agentctl start|stop|restart <name>
agentctl status [name]
agentctl logs <name> [-f] [-n N]
agentctl shell <name>              sandboxed login shell as the agent, secrets loaded
agentctl run <name> -- <cmd...>    one sandboxed command as the agent, in its home
agentctl secrets set|edit|list <name>
agentctl matrix [status|introduce|rotate-token|deactivate|register-user]
```

Everything agentctl knows comes from `/etc/agents/state.json`, rendered by
the NixOS module; it has no Nix logic of its own.
