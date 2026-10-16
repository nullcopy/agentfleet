# End-to-end example

Continues from [install](install.md): `myhost` runs agentfleet with the Matrix
server `matrix.example.org`, `agentctl matrix check` reports all `OK`, and
you are `@alice:example.com`. We create an agent called `scout`, receive its
introduction, chat with it, and remove it again. Nothing here requires
touching the agent on the command line; `agentctl` runs on the host, the
conversation happens in your Matrix client.

If you skipped the check, run it now. An agent whose invitation cannot be
delivered says so at the end of `agentctl add`, and `sudo agentctl matrix
status` lists it with `-` in the INTRODUCED column.

## 1. Create the agent

```
$ sudo agentctl add scout \
    --model anthropic/claude-sonnet-5.5 \
    --description "research assistant"
  ANTHROPIC_API_KEY (Anthropic API key) [enter to skip]: ********
  OPENROUTER_API_KEY (OpenRouter API key) [enter to skip]:
  OPENAI_API_KEY (OpenAI or OpenAI-compatible endpoint key) [enter to skip]:
wrote 1 secret(s) to /var/lib/agents/scout/secrets.env
seeded /srv/agents/scout/.hermes/config.yaml
created agent 'scout' (agent-scout, /srv/agents/scout)
agentfleet-matrix: created @scout:matrix.example.org
agentfleet-matrix: scout: token written to /var/lib/agents/scout/matrix.env
agentfleet-matrix: scout: introduced to @alice:example.com in !kGh...:matrix.example.org
agent 'scout' is up and has invited @alice:example.com to !kGh...:matrix.example.org. Accept the invite in your Matrix client.
Next: agentctl logs scout -f
```

One provider key is enough. In those few seconds the host created the user
`agent-scout`, the Matrix account `@scout:matrix.example.org`, wrote its
token where only root and the agent's service can read it, and started
Hermes. Nothing was rebuilt and no other agent noticed:

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
should answer everything, give it the room id as an environment variable:

```sh
sudo agentctl rm scout --yes
sudo agentctl add scout --env MATRIX_FREE_RESPONSE_ROOMS='!abc123:matrix.example.org'
```

`rm` without `--purge` keeps everything, and `add` with the same name resumes
the agent with the new variable: same account, same memory, same DM room.

Hermes chat commands work as usual: `/model`, `/status`, `/new`. If your
client swallows `/`, use `!status`.

Everything the agent does, including shell commands it runs for you, happens
as `agent-scout` inside `/srv/agents/scout`; it cannot read other agents'
homes, their tokens, or yours.

## 4. Remove the agent

```
$ sudo agentctl rm scout --purge
Remove agent 'scout' and PURGE it: delete home, state and secrets, leave its rooms, and retire the name for good? [y/N] y
stopped agent@scout.service
deleted /srv/agents/scout
deleted /var/lib/agents/scout
agentfleet-matrix: purged @scout:matrix.example.org: left 1 room(s), logged out, locked; the name 'scout' can never be used again
agent 'scout' purged; the name can never be used again
```

Two kinds of removal, pick deliberately:

- **`rm scout`** keeps the home, the state and the Matrix account, merely
  locked. A later `agentctl add scout` brings the agent back with its memory
  and its old DM room.
- **`rm scout --purge`** deletes everything on the host, makes the account
  leave every room and retires the name: `scout` can never be created again.
  Use it for agents you are done with.
