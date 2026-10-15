# End-to-end example

Continues from [install](install.md): `myhost` runs agentfleet with the Matrix
server `matrix.example.org`, the federation tester passes, and you are
`@alice:example.com`. We create an agent called `scout`, receive its
introduction, chat with it, and remove it again. Nothing here requires
touching the agent on the command line; `agentctl` runs on the host, the
conversation happens in your Matrix client.

## 1. Create the agent

```
$ sudo agentctl add scout \
    --model anthropic/claude-sonnet-5.5 \
    --description "research assistant"
  ANTHROPIC_API_KEY (Anthropic API key) [enter to skip]: ********
  OPENROUTER_API_KEY (OpenRouter API key) [enter to skip]:
  OPENAI_API_KEY (OpenAI or OpenAI-compatible endpoint key) [enter to skip]:
wrote /etc/nixos/agents/scout.toml
git: staged (commit when you are happy with it)
wrote 1 secret(s) to /var/lib/agents/scout/secrets.env
==> nixos-rebuild switch --flake /etc/nixos
agent 'scout' is up and will introduce itself to @alice:example.com on Matrix.
Next: agentctl status scout | agentctl logs scout -f
```

One provider key is enough. During the rebuild the host created the user
`agent-scout`, the Matrix account `@scout:matrix.example.org`, wrote its token
where only root and the agent's service can read it, and started Hermes:

```
$ agentctl list
NAME   STATE   MATRIX                     MODEL                         DESCRIPTION
scout  active  @scout:matrix.example.org  anthropic/claude-sonnet-5.5   research assistant

$ sudo agentctl matrix status
homeserver http://127.0.0.1:8008 (matrix.example.org): up
admin: @agentfleet:matrix.example.org
operator: @alice:example.com
AGENT   USER                        STATE    INTRODUCED
scout   @scout:matrix.example.org   active   !kGh...:matrix.example.org

$ agentctl logs scout -n 20
... Matrix: logged in as @scout:matrix.example.org
... Matrix: initial sync complete, joined 1 rooms
```

## 2. The agent says hello

In your Matrix client there is a new invite from `@scout:matrix.example.org`.
Accept it. The room contains one message:

> Hello! I'm **scout**, a Hermes agent running on `myhost`
> (anthropic/claude-sonnet-5.5). Research assistant. This room is our direct
> line: message me here any time. In other rooms, invite me and mention
> `@scout` to get my attention.

That message was sent on the agent's behalf when its account was created;
everything after it is Hermes. Reply in the same room:

> Summarise what you can do in three bullet points.

Hermes treats the two-person room as a DM and answers every message without
being mentioned. You are in its allow list because you are the operator;
nobody else can talk to it.

## 3. Rooms with more people, or more agents

Create a room, invite `@scout:matrix.example.org` (it accepts invites from
you), and mention it when you want it:

> @scout: what is the capital of Mongolia, and what time is it there now?

Create a second agent and invite it to the same room; each answers when
mentioned and keeps its own memory in its own home. For a room where an agent
should answer everything, give it the room id and rebuild:

```toml
# /etc/nixos/agents/scout.toml
[environment]
MATRIX_FREE_RESPONSE_ROOMS = "!abc123:matrix.example.org"
```

```sh
sudo nixos-rebuild switch --flake /etc/nixos
```

Hermes chat commands work as usual: `/model`, `/status`, `/new`. If your
client swallows `/`, use `!status`.

Everything the agent does, including shell commands it runs for you, happens
as `agent-scout` inside `/srv/agents/scout`; it cannot read other agents'
homes, their tokens, or yours.

## 4. Remove the agent

```
$ sudo agentctl rm scout --purge
Remove agent 'scout' and PURGE its home, state and secrets? [y/N] y
removed /etc/nixos/agents/scout.toml
==> nixos-rebuild switch --flake /etc/nixos
agentfleet-matrix: scout: agent gone, locked @scout:matrix.example.org and logged out its devices
purged /srv/agents/scout
purged /var/lib/agents/scout
agentfleet-matrix: deactivated @scout:matrix.example.org (this id can never be registered again)
agent 'scout' removed
```

Without `--purge` the home, state and Matrix account are kept and the account
merely locked; a later `agentctl add scout` unlocks it and the old DM room is
still there. With `--purge` the account is deactivated, which Synapse makes
permanent; a future `scout` needs `[matrix] localpart = "scout2"` in its
registry file.
