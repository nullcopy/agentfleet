# A Morph-backed agent

[Morph](https://morphllm.com) serves open-weight models behind an
OpenAI-compatible API at `https://api.morphllm.com/v1`. Hermes reaches any
such endpoint through its `custom` provider, so a Morph agent is an ordinary
agent with three extra config keys and a key under a name of your choosing.

## Create one

```sh
sudo agentctl add scout \
    --model morph-glm53-744b \
    --description "research assistant" \
    --set model.provider=custom \
    --set model.base_url=https://api.morphllm.com/v1 \
    --set model.key_env=MORPH_API_KEY \
    --secret MORPH_API_KEY --no-prompt
```

You are asked for the Morph key with hidden input, then the file is written,
the host rebuilt, and the agent introduces itself on Matrix:

```
  MORPH_API_KEY: ********
wrote /etc/nixos/agents/scout.toml
git: staged (commit when you are happy with it)
wrote 1 secret(s) to /var/lib/agents/scout/secrets.env
==> nixos-rebuild switch --flake /etc/nixos
agent 'scout' is up and will introduce itself to @alice:example.com on Matrix.
```

`--no-prompt` skips the Anthropic, OpenRouter and OpenAI prompts, which this
agent does not need. The registry file that results:

```toml
model = "morph-glm53-744b"
description = "research assistant"

[settings.model]
provider = "custom"
base_url = "https://api.morphllm.com/v1"
key_env = "MORPH_API_KEY"
```

To switch an existing agent to Morph, add that `[settings.model]` table to
its file, run `sudo agentctl secrets set <name> MORPH_API_KEY`, delete
`/srv/agents/<name>/.hermes/config.yaml` (it is seeded once and Hermes owns
it afterwards), and rebuild.

## Which model

Hermes passes the id through unchanged, so use Morph's ids exactly. The
general-purpose chat models, all with tool calling, which Hermes needs:

| id | based on | notes |
| --- | --- | --- |
| `morph-glm53-744b` | GLM-5.3 744B | reasoning, structured output; the default pick for an agent |
| `morph-glm52-744b` | GLM-5.2 744B | previous generation of the above, cheaper input |
| `morph-glm53flash` | GLM-5.3-Flash | fast and cheap, vision, reasoning |
| `morph-dsv41flash` | DeepSeek V4.1 Flash | cheapest, vision, reasoning |
| `morph-dsv4flash` | DeepSeek V4 Flash | small MoE, reasoning |
| `morph-kimik3` | Kimi K3 | large multimodal MoE, strongest and most expensive |
| `morph-kimik3-fast` | Kimi K3 | same model on a faster tier |

All have a one million token context. Do not use `morph-v3-fast`,
`morph-v3-large`, `morph-compactor` or `morph-warp-grep-*`: those are
code-edit, compaction and search models without a chat interface an agent
can drive. Prices change; the live list for your key is

```sh
curl -s https://api.morphllm.com/v1/models -H "Authorization: Bearer $MORPH_API_KEY" | jq -r '.data[].id'
```

and the catalog with context sizes and prices is at
<https://www.morphllm.com/models>.

## Checking that it works

```sh
agentctl logs scout -n 30      # the gateway logged in to Matrix and loaded the model
```

Then message the agent in its DM room. An authentication problem shows up in
the log as a 401 from `api.morphllm.com`; fix the key with
`sudo agentctl secrets set scout MORPH_API_KEY`, which restarts the agent.
