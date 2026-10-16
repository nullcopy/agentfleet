# agentfleet

A fleet of [Hermes](https://github.com/NousResearch/hermes-agent) agents on
one NixOS host, each its own locked-down Unix user, each with an account on
the fleet's own Matrix server. You talk to them from your existing Matrix
account; a new agent opens a DM with you as soon as it is up.

```
$ sudo agentctl add scout --model anthropic/claude-sonnet-5.5 --description "research assistant"
  ANTHROPIC_API_KEY (Anthropic API key) [enter to skip]: ********
  ...
wrote /etc/nixos/agents/scout.toml
==> nixos-rebuild switch --flake /etc/nixos
agent 'scout' is up and will introduce itself to @alice:example.com on Matrix.
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
3. It gives you `agentctl` to create, manage and destroy agents on that server.
4. Every agent is a Hermes agent connected to that Matrix server.
5. You are expected to have your own Matrix id on another, pre-existing server.

- [Install](docs/install.md): DNS, flake input, what to set in `configuration.nix`, the reverse proxy (Caddy), first rebuild.
- [End-to-end example](docs/e2e-example.md): create an agent, receive its introduction, chat, remove it.
- [agentctl](docs/agentctl.md): every command, including the Matrix ones.
- [A Morph-backed agent](docs/morph.md): using an OpenAI-compatible provider, and Morph's models.
- [Reference](docs/reference.md): registry format, what an agent gets, secrets, the sandbox, how the Matrix side works.

```
agentctl list                      agents, state, Matrix id, model
agentctl add <name> [--model M]    create an agent: registry file, provider key, rebuild
agentctl rm <name> [--purge]       remove it; --purge also deletes home, state, secrets and the Matrix account
agentctl purge <name>              delete what an earlier rm left behind
agentctl start|stop|restart <name> | --all
agentctl status [name]
agentctl logs <name> [-f] [-n N]
agentctl secrets set|edit|list <name>
agentctl matrix [status|introduce|rotate-token|deactivate|start|stop|restart|logs]
```
