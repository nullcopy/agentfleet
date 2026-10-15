# agents/

One TOML file per agent. `agentctl add` writes them, `agentctl rm` deletes
them, and you may edit them by hand followed by `agentctl apply`.

Only `*.toml` files are read; this README is ignored.

Flakes only see files tracked by git. `agentctl add` stages new files for you,
but if you create one by hand remember to `git add` it before rebuilding.

```toml
# agents/research.toml
harness = "hermes"
model = "anthropic/claude-sonnet-5-5"
description = "long-running research assistant"
memory_max = "4G"
packages = ["python3"]

[settings.gateway.platforms.telegram]
enabled = true
```
