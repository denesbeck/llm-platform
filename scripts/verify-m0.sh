#!/usr/bin/env bash
# M0 verification: the local stack on the Mac (opencode → LiteLLM → Ollama/Qwen).
# Covers R3, R5, R6, R7, R8, R12 (local) and R20 from the requirements (R21 dropped, CR-004).
#
# Usage: scripts/verify-m0.sh              # full run (the opencode check takes a few minutes)
#        SKIP_OPENCODE=1 scripts/verify-m0.sh
#
# Creates a temporary virtual key (user_id "verify-m0") and deletes it on exit.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STACK="$ROOT/stack"
GATEWAY="${GATEWAY:-http://localhost:4000}"
PROMETHEUS="${PROMETHEUS:-http://localhost:9090}"
MODEL="qwen-small"
OPENCODE_TIMEOUT="${OPENCODE_TIMEOUT:-600}"

pass=0 fail=0 skip=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; fail=$((fail + 1)); }
skp()  { printf '  \033[33mSKIP\033[0m %s\n' "$1"; skip=$((skip + 1)); }
section() { printf '\n%s\n' "$1"; }

for bin in curl jq docker ollama; do
  command -v "$bin" >/dev/null || { echo "missing dependency: $bin" >&2; exit 2; }
done
[ -f "$STACK/.env" ] || { echo "missing $STACK/.env (copy .env.example)" >&2; exit 2; }
set -a
# shellcheck source=/dev/null
. "$STACK/.env"
set +a

admin() { curl -s -m 30 -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'Content-Type: application/json' "$@"; }

# --- stack -------------------------------------------------------------------
section "Stack"
for svc in postgres litellm prometheus grafana; do
  state=$(docker compose -f "$STACK/compose.yaml" ps --format '{{.Service}} {{.State}} {{.Health}}' 2>/dev/null | awk -v s="$svc" '$1 == s {print $2, $3}')
  case "$state" in
    "running healthy" | "running ") ok "$svc is ${state% }" ;;
    *) bad "$svc is running" "state: ${state:-not found}" ;;
  esac
done

ollama_model=$(grep -oE 'ollama_chat/[^ #]+' "$STACK/litellm/config.yaml" | head -1 | cut -d/ -f2)
if curl -s -m 5 localhost:11434/api/tags | jq -e --arg m "$ollama_model" '.models[].name | select(. == $m or . == ($m + ":latest"))' >/dev/null; then
  ok "R12 Ollama serves $ollama_model"
else
  bad "R12 Ollama serves $ollama_model" "is 'ollama serve' running and was the model created from stack/ollama/Modelfile?"
fi

# --- temporary key -----------------------------------------------------------
KEY=$(admin "$GATEWAY/key/generate" -d "{\"models\":[\"$MODEL\"],\"user_id\":\"verify-m0\",\"key_alias\":\"verify-m0-$$\",\"duration\":\"1h\"}" | jq -r '.key // empty')
if [ -z "$KEY" ]; then
  echo "could not create a virtual key with the master key; is LiteLLM up?" >&2
  exit 1
fi
trap 'admin "$GATEWAY/key/delete" -d "{\"keys\":[\"$KEY\"]}" >/dev/null' EXIT
user() { curl -s -m 300 -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' "$@"; }

# --- auth --------------------------------------------------------------------
section "Auth"
code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$GATEWAY/v1/models")
if [ "$code" = 401 ]; then ok "R3 request without a key is rejected (401)"; else bad "R3 request without a key is rejected (401)" "got $code"; fi
code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 -H 'Authorization: Bearer sk-not-a-real-key' "$GATEWAY/v1/models")
if [ "$code" = 401 ]; then ok "R3 request with an invalid key is rejected (401)"; else bad "R3 request with an invalid key is rejected (401)" "got $code"; fi
if grep -rqF "$LITELLM_MASTER_KEY" "$ROOT/clients" 2>/dev/null; then
  bad "R5 master key does not appear in client configs" "found in $ROOT/clients"
else
  ok "R5 master key does not appear in client configs"
fi

# --- OpenAI-compatible API ---------------------------------------------------
section "API"
if user "$GATEWAY/v1/models" | jq -e --arg m "$MODEL" '.data[].id | select(. == $m)' >/dev/null; then
  ok "R6/R8 /v1/models lists $MODEL"
else
  bad "R6/R8 /v1/models lists $MODEL"
fi

stream=$(user "$GATEWAY/v1/chat/completions" -N -d "{\"model\":\"$MODEL\",\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"Count from 1 to 5.\"}]}")
chunks=$(grep -c '^data: {' <<<"$stream")
if [ "$chunks" -gt 1 ] && grep -q '^data: \[DONE\]' <<<"$stream"; then
  ok "R6 chat completion streams ($chunks chunks)"
else
  bad "R6 chat completion streams" "$(head -c 300 <<<"$stream")"
fi

tool_req=$(jq -n --arg m "$MODEL" '{model: $m, messages: [{role: "user", content: "List the files in /tmp."}],
  tools: [{type: "function", function: {name: "list_files", description: "List files in a directory",
    parameters: {type: "object", properties: {path: {type: "string"}}, required: ["path"]}}}]}')
tool_resp=$(user "$GATEWAY/v1/chat/completions" -d "$tool_req")
if jq -e '.choices[0].message.tool_calls[0].function.name == "list_files"' <<<"$tool_resp" >/dev/null; then
  ok "R7 tool call returns tool_calls ($(jq -c '.choices[0].message.tool_calls[0].function.arguments' <<<"$tool_resp"))"
else
  bad "R7 tool call returns tool_calls" "$(jq -c '.choices[0].message // .' <<<"$tool_resp" | head -c 300)"
fi

# --- spend logs + metrics ----------------------------------------------------
section "Tracking"
# LiteLLM writes spend logs in batches, so poll for a while.
logged=0
for _ in $(seq 1 18); do
  logged=$(admin "$GATEWAY/spend/logs?user_id=verify-m0&summarize=false" | jq '[.[] | select(.status == "success" and .model_group == "qwen-small")] | length')
  [ "${logged:-0}" -gt 0 ] && break
  sleep 5
done
if [ "${logged:-0}" -gt 0 ]; then ok "requests show up in spend logs for user verify-m0 ($logged)"; else bad "requests show up in spend logs for user verify-m0" "nothing after 90s"; fi

health=$(curl -s -m 5 "$PROMETHEUS/api/v1/targets" | jq -r '.data.activeTargets[] | select(.labels.job == "litellm") | .health')
if [ "$health" = up ]; then ok "Prometheus scrapes LiteLLM"; else bad "Prometheus scrapes LiteLLM" "target health: ${health:-missing}"; fi

# --- clients -----------------------------------------------------------------
section "Clients"
if [ -n "${SKIP_OPENCODE:-}" ]; then
  skp "R20 opencode completes a task (SKIP_OPENCODE set)"
elif ! command -v opencode >/dev/null; then
  skp "R20 opencode completes a task (opencode not installed)"
else
  echo "  ...  R20 running opencode (the first turn processes a ~10k-token prompt; can take minutes)"
  out=$(cd "$ROOT" && OPENCODE_CONFIG="$ROOT/clients/opencode/opencode.example.json" LITELLM_API_KEY="$KEY" \
    perl -e 'alarm shift; exec @ARGV' "$OPENCODE_TIMEOUT" \
    opencode run -m "litellm/$MODEL" "List the files in the stack/litellm directory using your tools. Reply with only the file names." 2>&1)
  if grep -q 'config.yaml' <<<"$out"; then
    ok "R20 opencode completes a task (found stack/litellm/config.yaml)"
  else
    bad "R20 opencode completes a task" "$(tail -5 <<<"$out")"
  fi
fi

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]
