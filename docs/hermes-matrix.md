# Example: a Hermes agent you talk to over Matrix

End to end: create a Hermes agent, give it a Matrix account, chat with it from
your Matrix client, and remove it again. Everything below was checked against
the Hermes source pinned by this flake; the Nix build of Hermes includes the
Matrix client library, so nothing extra is installed.

What you need before starting:

- a host set up as in the README, with the `hermes` harness listed by
  `agentctl harnesses`
- an Anthropic (or OpenRouter / OpenAI) API key
- a Matrix homeserver you can create an account on, and your own Matrix user
  id (`@you:example.org`)

The agent is called `scout` throughout.

## 1. Create a Matrix account for the agent

The agent needs its own Matrix user. On your own Synapse:

```sh
register_new_matrix_user -c /etc/synapse/homeserver.yaml http://localhost:8008
# username: scout   -> @scout:example.org
```

On matrix.org or any other public homeserver, sign up through Element with a
username such as `scout-bot`. Either way, write down the user id and password.

Hermes authenticates with an access token. Get one once, with the password,
and keep it; the password itself is never given to the agent:

```sh
curl -s -X POST https://matrix.example.org/_matrix/client/v3/login \
  -H 'Content-Type: application/json' \
  -d '{"type":"m.login.password","identifier":{"type":"m.id.user","user":"scout"},
       "password":"<password>","initial_device_display_name":"hermes"}' | jq -r .access_token
```

## 2. Create the agent

Non-secret Matrix settings go in as environment variables; they end up in the
registry file, which is fine because none of them are secret. The token and
the API key are prompted for and stored in the root-only secrets file.

```
$ sudo agentctl add scout --harness hermes \
    --model anthropic/claude-sonnet-5.5 \
    --description "research assistant on Matrix" \
    --env MATRIX_HOMESERVER=https://matrix.example.org \
    --env MATRIX_ALLOWED_USERS=@you:example.org \
    --env MATRIX_SESSION_SCOPE=room
  ANTHROPIC_API_KEY (Anthropic API key) [enter to skip]: ********
  OPENROUTER_API_KEY (OpenRouter API key) [enter to skip]:
  OPENAI_API_KEY (OpenAI or OpenAI-compatible endpoint key) [enter to skip]:
  TELEGRAM_BOT_TOKEN (Telegram bot token, if the Telegram platform is enabled in settings) [enter to skip]:
  DISCORD_BOT_TOKEN (Discord bot token, if the Discord platform is enabled in settings) [enter to skip]:
  MATRIX_ACCESS_TOKEN (Matrix access token for the agent's own account (with MATRIX_HOMESERVER in environment)) [enter to skip]: ********
wrote /etc/nixos/agents/scout.toml
git: staged (commit when you are happy with it)
wrote 2 secret(s) to /var/lib/agents/scout/secrets.env
==> nixos-rebuild switch --flake /etc/nixos
agent 'scout' is up. Next: agentctl status scout | agentctl shell scout
```

The first `add` of a Hermes agent builds Hermes, which takes a while.

What the options mean:

- `MATRIX_ALLOWED_USERS` is who may talk to the agent and invite it to rooms.
  Several ids are comma-separated. Leave it out and Hermes falls back to
  pairing: an unknown user who DMs the agent gets a one-time code, which you
  approve with `sudo agentctl run scout -- hermes pairing approve matrix <code>`.
- `MATRIX_SESSION_SCOPE=room` gives each room one stable conversation instead
  of a new thread per message. Drop it if you prefer Hermes's default of
  auto-threading every reply.
- The model id uses Hermes's own naming; `anthropic/...` with `ANTHROPIC_API_KEY`
  talks to Anthropic directly.

Check that it connected:

```
$ agentctl status scout
$ agentctl logs scout -n 50
... Matrix: logged in as @scout:example.org
... Matrix: initial sync complete, joined 0 rooms
```

A local smoke test that does not touch Matrix at all, run as the agent user
inside its sandbox:

```sh
sudo agentctl run scout -- hermes chat --oneshot -q "Say hello in one line"
```

## 3. Talk to it

From your Matrix client, signed in as `@you:example.org`:

**Direct message.** Start a DM with `@scout:example.org` and write:

> Summarise what you can do in three bullet points.

The agent accepts the DM invite because you are an allowed user, and answers
every message in a DM without being mentioned.

**Room.** Create a room, invite `@scout:example.org`, then mention it:

> @scout: what is the capital of Mongolia, and what time is it there now?

In rooms Hermes only reacts when mentioned. For a room where it should answer
everything, add the room id to the agent and rebuild:

```sh
# /etc/nixos/agents/scout.toml, [environment] section
MATRIX_FREE_RESPONSE_ROOMS = "!abc123:example.org"
```

```sh
sudo nixos-rebuild switch --flake /etc/nixos
```

Hermes commands work in chat too: `/model`, `/status`, `/new`. If your client
swallows `/`, use `!status`.

Everything the agent does, including any shell commands it runs for you, happens
as `agent-scout` inside `/srv/agents/scout`; it cannot read other agents' homes
or your secrets.

## 4. Remove the agent

Log the Matrix session out first if you want the token dead; `--purge` deletes
the secrets file with everything else:

```sh
TOKEN=$(sudo awk -F'"' '/^MATRIX_ACCESS_TOKEN=/{print $2}' /var/lib/agents/scout/secrets.env)
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  https://matrix.example.org/_matrix/client/v3/logout/all
```

```
$ sudo agentctl rm scout --purge
Remove agent 'scout' and PURGE its home, state and secrets? [y/N] y
removed /etc/nixos/agents/scout.toml
==> nixos-rebuild switch --flake /etc/nixos
purged /srv/agents/scout
purged /var/lib/agents/scout
agent 'scout' removed
```

The Unix user, its service, home and secrets are gone. The Matrix account
still exists on the homeserver and stays in the rooms it joined; deactivate it
there, or keep it for the next agent.

## Several agents, several rooms

Each agent is its own Matrix user, so repeat the steps with a different account
per agent. Two or more agents can share a room; each only answers when it is
mentioned, and each keeps its own memory and session state in its own home.
