COMPOSE         := docker compose -f stack/compose.yaml
OPENCODE_CONFIG := $(CURDIR)/clients/opencode/opencode.example.json
OLLAMA_MODEL    := qwen3-8b-32k
# Not USER: make imports the shell's $USER (the login name).
NAME            ?= $(shell whoami)

.PHONY: help stack-up stack-down stack-ps stack-logs model key oc verify verify-fast lint

help:
	@echo "stack-up      start the local stack (LiteLLM, Postgres, Prometheus, Grafana)"
	@echo "stack-down    stop it (volumes are kept)"
	@echo "stack-ps      show service status"
	@echo "stack-logs    follow LiteLLM's logs"
	@echo "model         create $(OLLAMA_MODEL) from stack/ollama/Modelfile (needs 'ollama serve')"
	@echo "key           create a virtual key for qwen-small: make key NAME=alice (default: your login)"
	@echo "oc            start opencode against the gateway (needs LITELLM_API_KEY)"
	@echo "verify        run scripts/verify-m0.sh (~2 min, includes an opencode task)"
	@echo "verify-fast   same, without the opencode task"
	@echo "lint          run the CI checks locally"

stack-up:
	$(COMPOSE) up -d

stack-down:
	$(COMPOSE) down

stack-ps:
	$(COMPOSE) ps

stack-logs:
	$(COMPOSE) logs -f litellm

model:
	ollama pull qwen3:8b
	ollama create $(OLLAMA_MODEL) -f stack/ollama/Modelfile

key:
	@set -a; . stack/.env; set +a; \
	curl -s localhost:4000/key/generate -H "Authorization: Bearer $$LITELLM_MASTER_KEY" \
		-H 'Content-Type: application/json' \
		-d '{"models":["qwen-small"],"user_id":"$(NAME)","key_alias":"$(NAME)-opencode"}' | jq -r '.key // .'

oc:
	@test -n "$$LITELLM_API_KEY" || { echo "LITELLM_API_KEY is not set (make key, then export it)"; exit 1; }
	OPENCODE_CONFIG=$(OPENCODE_CONFIG) opencode

verify:
	scripts/verify-m0.sh

verify-fast:
	SKIP_OPENCODE=1 scripts/verify-m0.sh

lint:
	$(COMPOSE) --profile linux --profile debug config -q
	pipx run yamllint --strict .
	shellcheck scripts/*.sh
	terraform -chdir=terraform fmt -check -recursive
