# Example: a Hermes agent that messages you on Matrix

End to end: create a Hermes agent, let the fleet's Matrix server give it an
account, receive its introduction, chat with it, and remove it again.

What you need before starting:

- a host set up as in the README, with `services.agentfleet.matrix` enabled
  as described in [matrix-server.md](matrix-server.md), and federation
  working if your own account lives on another homeserver
- an Anthropic (or OpenRouter / OpenAI) API key

The agent is called `scout`; the host is `obelisk`, the server
`matrix.arx9.net`, and you are `@nullcopy:4d2.org`.

## 1. Create the agent

```
$ sudo agentctl add scout --harness hermes \
    --model anthropic/claude-sonnet-5.5 \
    --description "research assistant"
  ANTHROPIC_API_KEY (Anthropic API key) [enter to skip]: ********
  OPENROUTER_API_KEY (OpenRouter API key) [enter to skip]:
  OPENAI_API_KEY (OpenAI or OpenAI-compatible endpoint key) [enter to skip]:
  TELEGRAM_BOT_TOKEN (Telegram bot token, if the Telegram platform is enabled in settings) [enter to skip]:
  DISCORD_BOT_TOKEN (Discord bot token, if the Discord platform is enabled in settings) [enter to skip]:
  MATRIX_ACCESS_TOKEN (Matrix access token; only needed without the built-in Matrix server ...) [enter to skip]:
wrote /etc/nixos/agents/scout.toml
git: staged (commit when you are happy with it)
wrote 1 secret(s) to /var/lib/agents/scout/secrets.env
==> nixos-rebuild switch --flake /etc/nixos
agent 'scout' is up. Next: agentctl status scout | agentctl shell scout
```

Leave `MATRIX_ACCESS_TOKEN` empty: the Matrix server provisions it. The first
`add` of a Hermes agent builds Hermes, which takes a while.

During the rebuild the reconciler created `@scout:matrix.arx9.net`, wrote its
token where only root and the agent's units can read it, and started Hermes
after that:

```
$ agentctl list
NAME   HARNESS  SOURCE  STATE   USER         MATRIX                   DESCRIPTION
scout  hermes   toml    active  agent-scout  @scout:matrix.arx9.net   research assistant

$ agentctl matrix status
homeserver http://127.0.0.1:8008 (matrix.arx9.net): up
admin: @agentfleet:matrix.arx9.net
operator: @nullcopy:4d2.org
AGENT   USER                      STATE    INTRODUCED
scout   @scout:matrix.arx9.net    active   !kGh...:matrix.arx9.net

$ agentctl logs scout -n 20
... Matrix: logged in as @scout:matrix.arx9.net
... Matrix: initial sync complete, joined 1 rooms
```

## 2. The agent says hello

In your Matrix client there is a new invite from `@scout:matrix.arx9.net`.
Accept it. The room contains one message:

> Hello! I'm **scout**, a hermes agent running on `obelisk`
> (anthropic/claude-sonnet-5.5). Research assistant. This room is our direct
> line: message me here any time. In other rooms, invite me and mention
> `@scout` to get my attention.

That message was sent by the reconciler on the agent's behalf; everything
after it is Hermes. Reply in the same room:

> Summarise what you can do in three bullet points.

Hermes treats the two-person room as a DM and answers every message without
being mentioned. You are in its allow list because you are the operator.

**A room with several people, or several agents.** Create a room, invite
`@scout:matrix.arx9.net` (it accepts invites from allowed users), and mention
it when you want it:

> @scout: what is the capital of Mongolia, and what time is it there now?

For a room where it should answer everything, add the room id to the agent and
rebuild:

```toml
# /etc/nixos/agents/scout.toml
[environment]
MATRIX_FREE_RESPONSE_ROOMS = "!abc123:matrix.arx9.net"
```

```sh
sudo nixos-rebuild switch --flake /etc/nixos
```

Hermes commands work in chat too: `/model`, `/status`, `/new`. If your client
swallows `/`, use `!status`.

Everything the agent does, including any shell commands it runs for you, happens
as `agent-scout` inside `/srv/agents/scout`; it cannot read other agents' homes,
their tokens, or yours.

## 3. A local smoke test

Without Matrix, as the agent user inside its sandbox:

```sh
sudo agentctl run scout -- hermes chat --oneshot -q "Say hello in one line"
```

## 4. Remove the agent

```
$ sudo agentctl rm scout --purge
Remove agent 'scout' and PURGE its home, state and secrets? [y/N] y
removed /etc/nixos/agents/scout.toml
==> nixos-rebuild switch --flake /etc/nixos
agentfleet-matrix: scout: agent gone, locked @scout:matrix.arx9.net and logged out its devices
purged /srv/agents/scout
purged /var/lib/agents/scout
agentfleet-matrix: deactivated @scout:matrix.arx9.net (this id can never be registered again)
agent 'scout' removed
```

Without `--purge` the home, state and the Matrix account are kept, the
account merely locked; a later `agentctl add scout` unlocks it and the old DM
room is still there. With `--purge` the account is deactivated, which Synapse
makes permanent; a future `scout` needs `matrix.localpart = "scout2"`.
