# agentfleet

A fleet of [Hermes](https://github.com/NousResearch/hermes-agent) agents on
one NixOS host, each its own locked-down Unix user, each with an account on
the fleet's own Matrix server. You talk to them from your existing Matrix
account; a new agent opens a DM with you as soon as it is up.

```
$ sudo agentctl add scout --model anthropic/claude-sonnet-5.5 --description "research assistant"
  ANTHROPIC_API_KEY (Anthropic API key) [enter to skip]: ********
  ...
created agent 'scout' (agent-scout, /srv/agents/scout)
agent 'scout' is up and has invited @alice:example.com to !kGh...:matrix.example.org.
```

> **scout**: Hello! I'm scout, a Hermes agent running on `myhost`
> (anthropic/claude-sonnet-5.5). Research assistant. This room is our direct
> line: message me here any time.

```
$ sudo agentctl rm scout --purge
```

What agentfleet is, in five points:

1. It runs on a NixOS host you already have.
2. It gives that host a Matrix server, for which you set up a domain.
3. It gives you `agentctl` to create, manage and destroy agents on that server, in seconds and without rebuilding anything.
4. Every agent is a Hermes agent connected to that Matrix server.
5. You are expected to have your own Matrix id on another, pre-existing server.

- [Install](docs/install.md): DNS, flake input, what to set in `configuration.nix`, the reverse proxy (Caddy), the one rebuild, `agentctl matrix check`.
- [End-to-end example](docs/e2e-example.md): create an agent, receive its introduction, chat, remove it.
- [agentctl](docs/agentctl.md): every command, including the Matrix ones.
- [A Morph-backed agent](docs/morph.md): using an OpenAI-compatible provider, and Morph's models.
- [A Prime Intellect-backed agent](docs/primeintellect.md): the same recipe for Prime Inference and its catalog.
- [Reference](docs/reference.md): what an agent is on disk, what it gets, secrets, the sandbox, how the Matrix side works, what Nix owns.

```
agentctl list                      agents, state, Matrix id, model
agentctl add <name> [--model M]    create an agent and start it; the same name after `rm` resumes it
agentctl edit <name> [--model M]   change model, description, limits, environment or Hermes settings in place
agentctl rm <name> [--purge]       stop and remove it; --purge also deletes everything and retires the name
agentctl purge <name>              same as rm --purge, also for an agent removed earlier
agentctl start|stop|restart <name> | --all
agentctl status [name]             one agent: Matrix connection, config check, service; or the table
agentctl reset-config <name>       reseed config.yaml and move stray Hermes profiles aside: repairs a silent agent
agentctl logs <name> [-f] [-n N]
agentctl secrets set|edit|list <name>
agentctl matrix [status|check|introduce|rotate-token|start|stop|restart|logs]
```

## License

This project is licensed under the [GNU Affero General Public License v3.0 or later](LICENSE) (`AGPL-3.0-or-later`).
