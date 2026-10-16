# A Prime Intellect-backed agent

[Prime Inference](https://docs.primeintellect.ai/inference/overview) is
Prime Intellect's OpenAI-compatible API at
`https://api.pinference.ai/api/v1`. It serves a few open-weight models on its
own hardware and routes a long list of others, including the proprietary
ones, through a gateway, all under one key and one bill. Hermes reaches any
such endpoint through its `custom` provider, so a Prime agent is an ordinary
agent with three extra config keys and a key under a name of your choosing.

You need an API key with the **Inference** permission, created in the
[Prime Intellect dashboard](https://app.primeintellect.ai/dashboard/tokens).

## Create one

```sh
sudo agentctl add scout \
    --model z-ai/glm-5.3 \
    --description "research assistant" \
    --set model.provider=custom \
    --set model.base_url=https://api.pinference.ai/api/v1 \
    --set model.key_env=PRIME_API_KEY \
    --secret PRIME_API_KEY --no-prompt
```

You are asked for the key with hidden input, then the agent is created and
started, and it introduces itself on Matrix:

```
  PRIME_API_KEY: ********
wrote 1 secret(s) to /var/lib/agents/scout/secrets.env
seeded /srv/agents/scout/.hermes/config.yaml
created agent 'scout' (agent-scout, /srv/agents/scout)
agentfleet-matrix: created @scout:matrix.example.org
agentfleet-matrix: scout: introduced to @alice:example.com in !kGh...:matrix.example.org
agent 'scout' is up and has invited @alice:example.com to !kGh...:matrix.example.org. Accept the invite in your Matrix client.
```

`--no-prompt` skips the Anthropic, OpenRouter and OpenAI prompts, which this
agent does not need. The `--set` keys end up in the agent's seeded
`~/.hermes/config.yaml`:

```yaml
{"model": {"default": "z-ai/glm-5.3", "provider": "custom",
           "base_url": "https://api.pinference.ai/api/v1", "key_env": "PRIME_API_KEY"}}
```

To switch an existing agent to Prime: `sudo agentctl secrets set <name>
PRIME_API_KEY`, then edit `/srv/agents/<name>/.hermes/config.yaml` as that
agent's user (it is a YAML file Hermes owns after the first start) to set the
`model` keys above, and `sudo agentctl restart <name>`.

## Which model

Hermes passes the id through unchanged, so use Prime's ids exactly, with the
vendor prefix. The catalog is public:

```sh
curl -s https://api.pinference.ai/api/v1/models | jq -r '.data[] | [.id, .serving, .pricing.input_usd_per_mtok, .pricing.output_usd_per_mtok] | @tsv'
```

Each model is either `hosted`, served by Prime Intellect itself, or
`gateway`, forwarded to the model's own provider at that provider's price.
A reasonable selection for agents, which need tool calling and a long
context; prices are USD per million input / output tokens at the time of
writing and change often:

| id | serving | price in / out | notes |
| --- | --- | --- | --- |
| `z-ai/glm-5.3` | hosted | 1.40 / 4.40 | GLM-5.3, 1M context; the default pick for an agent |
| `z-ai/glm-5.3-flash` | gateway | 0.15 / 0.50 | same family, fast and cheap |
| `deepseek/deepseek-v4.1-flash` | hosted | 0.30 / 1.20 | DeepSeek V4.1 Flash, 1M context, cheap |
| `deepseek/deepseek-v4-pro` | gateway | 1.91 / 3.83 | DeepSeek V4 Pro, 1M context |
| `moonshotai/kimi-k3` | gateway | 3.45 / 17.25 | Kimi K3, the strongest open model here |
| `qwen/qwen3.5-397b-a17b` | gateway | 0.60 / 3.60 | large Qwen MoE, 262k context |
| `minimax/minimax-m3` | gateway | 0.30 / 1.20 | MiniMax M3, 1M context, cheap |
| `openai/gpt-oss-120b` | gateway | 0.35 / 0.75 | OpenAI's open-weight model, 131k context |
| `anthropic/claude-sonnet-5.5` | gateway | 2.00 / 10.00 | Claude through the gateway, same price as direct |
| `openai/gpt-5.5` | gateway | 5.00 / 30.00 | GPT through the gateway |

Skip the small `Qwen/Qwen3.5-0.8B` to `-9B` hosted models, `moondream`
(vision, 4k output), `cloudflare/clef*` and the `poolside/laguna*` code
models: they are not general chat models an agent can drive. The dashboard's
[model catalog](https://app.primeintellect.ai/dashboard/inference?tab=models)
shows context sizes and current prices.

## Checking that it works

```sh
agentctl logs scout -n 30      # the gateway logged in to Matrix and loaded the model
```

Then message the agent in its DM room. An authentication problem shows up in
the log as a 401 from `api.pinference.ai`; fix the key with
`sudo agentctl secrets set scout PRIME_API_KEY`, which restarts the agent. A
404 naming the model means the id is not in the catalog above, usually a
missing vendor prefix.
