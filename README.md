# 🤖 llm-platform

A self-hosted, private LLM platform: an OpenAI-compatible gateway with per-user keys, budgets, spend tracking and metrics, in front of open-weight Qwen models. Terminal clients only (opencode, `llm`/`aichat`). No web UI.

```text
opencode / llm ──► LiteLLM gateway ──► Ollama on the Mac   (qwen-small, dev)
                     │                └► vLLM on a spot L4  (qwen-large, M3)
                     ├─ Postgres   keys, users, teams, spend logs
                     └─ Prometheus + Grafana
```

**Status:** M0 done, which means the whole stack runs locally on the Mac. Next up are the AWS control plane (EC2 + Tailscale, M1–M2) and the GPU backend (vLLM on spot, M3).

## Layout

```text
stack/            Docker Compose stack: LiteLLM, Postgres, Prometheus, Grafana (+ node-exporter, pgAdmin)
  litellm/        gateway config: model aliases, pricing, callbacks
  prometheus/     scrape config
  ollama/         Modelfile for the local model (context window)
clients/opencode/ opencode provider config (keys come from the environment)
scripts/          verify-mN.sh per milestone
terraform/        AWS (M1+)
gpu/              vLLM + DCGM on the GPU instance (M3)
users/            simulated users, teams and budgets (M4)
```

## Running it locally (M0)

Requirements: macOS with Apple Silicon, Docker Desktop, Homebrew, `jq`, opencode.

**1. Ollama, natively.** Docker on macOS can't use Metal, so the model runs outside Docker:

```bash
brew install ollama
OLLAMA_FLASH_ATTENTION=1 OLLAMA_KV_CACHE_TYPE=q8_0 OLLAMA_KEEP_ALIVE=30m ollama serve
```

Then, in another terminal:

```bash
ollama pull qwen3:8b
ollama create qwen3-8b-32k -f stack/ollama/Modelfile   # same model, 32k context
```

The Modelfile raises `num_ctx` to 32k, because the small default silently truncates agent prompts. Flash attention with the `q8_0` KV cache halves the cache's memory, which keeps a 16 GB Mac out of swap.

**2. The stack.**

```bash
cp stack/.env.example stack/.env          # fill in; secrets: openssl rand -hex 24
docker compose -f stack/compose.yaml up -d
```

| Service    | URL                                                             |
| ---------- | --------------------------------------------------------------- |
| LiteLLM    | http://localhost:4000 (UI at `/ui`, login `admin` / master key) |
| Grafana    | http://localhost:3000                                           |
| Prometheus | http://localhost:9090                                           |

All ports are bound to `127.0.0.1`. Optional profiles: `--profile debug` (pgAdmin on :5050) and `--profile linux` (node-exporter, only useful on a Linux host).

**3. A virtual key.** The master key is for admin calls only. Clients get virtual keys:

```bash
set -a; . stack/.env; set +a
curl -s localhost:4000/key/generate -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"models":["qwen-small"],"user_id":"me","key_alias":"me-opencode"}' | jq -r .key
```

The key is shown only once, because LiteLLM stores only a hash of it.

**4. opencode.**

```bash
export OPENCODE_CONFIG="$PWD/clients/opencode/opencode.example.json"   # absolute path
export LITELLM_API_KEY=sk-...                                           # the virtual key
opencode
```

**5. Verify.**

```bash
scripts/verify-m0.sh                  # ~2 min, mostly the opencode check
SKIP_OPENCODE=1 scripts/verify-m0.sh  # ~15 s
```

The script creates a temporary key (user `verify-m0`) and deletes it on exit. It checks that keys are enforced, that `/v1/models` lists the model, that streaming works, that a tool call comes back as `tool_calls`, that requests appear in the spend logs, that Prometheus is scraping LiteLLM, and that opencode can finish a small task.

## Configuration notes

- **Model aliases.** Clients only see `qwen-small` (and later `qwen-large`). The backend behind an alias can change without touching clients. Models live in `stack/litellm/config.yaml`, not in the database.
- **`ollama_chat/` provider** (not `ollama/`). It uses Ollama's chat endpoint, which is the one that returns proper tool calls.
- **`think: false`.** By default qwen3 writes 500+ "thinking" tokens before every reply. On the Mac that adds about a minute per agent turn.
- **Notional pricing.** Self-hosted models have a made-up per-token cost, so the spend tracking and budgets have numbers to work with.
- **Prompt logging off.** `turn_off_message_logging`: the spend logs keep metadata (user, model, tokens, cost, latency), not prompts.
- **Metrics.** The open-source LiteLLM exposes Prometheus metrics at `/metrics/`. Auth on that endpoint is turned off, because the port is localhost-only (and tailnet-only from M2 on).

## Performance on the Mac

On an M4 with an 8-core GPU and 16 GB of RAM, qwen3 8B (Q4_K_M) runs at about 80–110 tokens/s for prompt processing and 13–22 tokens/s for generation. opencode's first turn sends a prompt of about 10k tokens, so **the first reply of a session takes a few minutes**. Later turns reuse Ollama's prompt cache and start in seconds. The Mac backend is for development and wiring. Speed is the GPU backend's job (M3).
