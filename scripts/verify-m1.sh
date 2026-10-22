#!/usr/bin/env bash
# M1 verification: the AWS foundation (network, IAM, SSM secrets, budget).
# Covers N2 (partial), N4 (secrets, IAM roles), C5 and C9 from the requirements.
#
# Usage: scripts/verify-m1.sh                          # AWS_PROFILE defaults to admin
#        BEDROCK_MODEL= scripts/verify-m1.sh           # skip the Bedrock call
#
# Read-only, except for one tiny Bedrock call (a fraction of a cent). Never prints secret values.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF="$ROOT/terraform"
export AWS_PROFILE="${AWS_PROFILE:-admin}"
export AWS_REGION="${AWS_REGION:-eu-central-1}"
AZ="eu-central-1c"
CP_ROLE="llm-platform-control-plane"
GPU_ROLE="llm-platform-gpu-instance"
BUDGET="monthly-llm-platform-budget"
# The qwen-large fallback; must match the BedrockFallback statement in terraform/01-iam.tf.
BEDROCK_MODEL="${BEDROCK_MODEL-qwen.qwen3-coder-30b-a3b-v1:0}"
PARAMS=(
  /llm-platform/LITELLM_MASTER_KEY
  /llm-platform/LITELLM_SALT_KEY
  /llm-platform/POSTGRES_PASSWORD
  /llm-platform/GRAFANA_ADMIN_PASSWORD
  /llm-platform/gpu/VLLM_API_KEY
)

pass=0 fail=0 skip=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; fail=$((fail + 1)); }
skp()  { printf '  \033[33mSKIP\033[0m %s\n' "$1"; skip=$((skip + 1)); }
section() { printf '\n%s\n' "$1"; }

for bin in aws jq terraform git; do
  command -v "$bin" >/dev/null || {
    echo "missing dependency: $bin" >&2
    exit 2
  }
done
ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || {
  echo "no AWS session for profile $AWS_PROFILE; run: aws sso login --profile $AWS_PROFILE" >&2
  exit 2
}

# Secret values go into a private temp file and are matched with grep -f, so they never appear
# on a command line (visible in ps) or in the output.
SECRETS=$(mktemp)
chmod 600 "$SECRETS"
trap 'rm -f "$SECRETS"' EXIT

# --- terraform ---------------------------------------------------------------
section "Terraform"
plan=$(terraform -chdir="$TF" plan -detailed-exitcode -lock=false -input=false -no-color 2>&1)
case $? in
  0) ok "N2 AWS matches the Terraform code (plan: no changes)" ;;
  2) bad "N2 AWS matches the Terraform code" "$(grep -E '^Plan:' <<<"$plan")" ;;
  *) bad "N2 terraform plan runs" "$(tail -5 <<<"$plan")" ;;
esac

bucket=$(grep -oE 'bucket *= *"[^"]+"' "$TF/providers.tf" | cut -d'"' -f2)
versioning=$(aws s3api get-bucket-versioning --bucket "$bucket" --query Status --output text 2>/dev/null)
if [ "$versioning" = Enabled ]; then ok "state bucket is versioned"; else bad "state bucket is versioned" "status: ${versioning:-unknown}"; fi

state=$(terraform -chdir="$TF" state pull 2>/dev/null)

# --- secrets -----------------------------------------------------------------
section "Secrets"
for p in "${PARAMS[@]}"; do
  param=$(aws ssm get-parameter --name "$p" --with-decryption --output json 2>/dev/null)
  type=$(jq -r '.Parameter.Type // empty' <<<"$param")
  value=$(jq -r '.Parameter.Value // empty' <<<"$param")
  if [ "$type" = SecureString ] && [ -n "$value" ]; then
    ok "N4 $p exists and decrypts"
    printf '%s\n' "$value" >>"$SECRETS"
  else
    bad "N4 $p exists and decrypts" "type: ${type:-missing}"
  fi
  if [ "$p" = /llm-platform/LITELLM_MASTER_KEY ] && [ -n "$value" ]; then
    if [[ "$value" == sk-* ]]; then ok "LiteLLM master key starts with sk-"; else bad "LiteLLM master key starts with sk-"; fi
  fi
done
unset param value

if [ ! -s "$SECRETS" ]; then
  skp "N4 secrets are not in Terraform state (no secrets read)"
  skp "N4 secrets are not in Git (no secrets read)"
else
  if [ -z "$state" ]; then
    bad "N4 secrets are not in Terraform state" "could not read the state"
  elif grep -qF -f "$SECRETS" <<<"$state"; then
    bad "N4 secrets are not in Terraform state" "a secret value is in the state; is value_wo used everywhere?"
  else
    ok "N4 secrets are not in Terraform state"
  fi
  # --untracked also covers new files that aren't committed yet (ignored files are skipped)
  if git -C "$ROOT" grep -qF --untracked -f "$SECRETS"; then
    bad "N4 secrets are not in Git" "$(git -C "$ROOT" grep -lF --untracked -f "$SECRETS")"
  else
    ok "N4 secrets are not in Git"
  fi
fi

# --- iam ---------------------------------------------------------------------
section "IAM"
for role in "$CP_ROLE" "$GPU_ROLE"; do
  got=$(aws iam get-instance-profile --instance-profile-name "$role" --query 'InstanceProfile.Roles[0].RoleName' --output text 2>/dev/null)
  if [ "$got" = "$role" ]; then ok "instance profile $role has its role"; else bad "instance profile $role has its role" "got: ${got:-missing}"; fi
done

# simulate <role> <action> <resource arn> -> allowed | implicitDeny | explicitDeny
simulate() {
  aws iam simulate-principal-policy --policy-source-arn "arn:aws:iam::$ACCOUNT:role/$1" \
    --action-names "$2" --resource-arns "$3" \
    --query 'EvaluationResults[0].EvalDecision' --output text 2>/dev/null
}
expect() { # expect <label> <role> <action> <resource arn> <allowed|denied>
  local got
  got=$(simulate "$2" "$3" "$4")
  case "$5:$got" in
    allowed:allowed | denied:implicitDeny | denied:explicitDeny) ok "$1" ;;
    *) bad "$1" "decision: ${got:-error}" ;;
  esac
}
expect_param() { # expect_param <role> <parameter> <allowed|denied>
  expect "N4 $1 is $3 $2" "$1" ssm:GetParameter "arn:aws:ssm:$AWS_REGION:$ACCOUNT:parameter$2" "$3"
}
expect_param "$CP_ROLE" /llm-platform/LITELLM_MASTER_KEY allowed
expect_param "$CP_ROLE" /llm-platform/gpu/VLLM_API_KEY allowed
expect_param "$GPU_ROLE" /llm-platform/gpu/VLLM_API_KEY allowed
expect_param "$GPU_ROLE" /llm-platform/LITELLM_MASTER_KEY denied
# AmazonSSMManagedInstanceCore allows ssm:GetParameter on "*"; the roles' explicit denies must win.
expect_param "$CP_ROLE" /verify-m1/outside-llm-platform denied

if [ -n "$BEDROCK_MODEL" ]; then
  model_arn="arn:aws:bedrock:$AWS_REGION::foundation-model/$BEDROCK_MODEL"
  expect "$CP_ROLE may invoke $BEDROCK_MODEL" "$CP_ROLE" bedrock:InvokeModel "$model_arn" allowed
  expect "$GPU_ROLE may not invoke $BEDROCK_MODEL" "$GPU_ROLE" bedrock:InvokeModel "$model_arn" denied
fi

# --- network -----------------------------------------------------------------
section "Network"
subnets=$(aws ec2 describe-subnets --filters Name=tag:App,Values=llm-platform --query 'Subnets[].[SubnetId,AvailabilityZone]' --output text 2>/dev/null)
read -r subnet subnet_az <<<"$subnets"
if [ "$(wc -l <<<"$subnets" | tr -d ' ')" = 1 ] && [ "$subnet_az" = "$AZ" ]; then
  ok "one subnet, in $AZ ($subnet)"
else
  bad "one subnet, in $AZ" "found: $(tr '\n' ' ' <<<"${subnets:-none}")"
fi
gw=$(aws ec2 describe-route-tables --filters Name=association.subnet-id,Values="${subnet:-none}" \
  --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].GatewayId | [0]" --output text 2>/dev/null)
if [[ "$gw" == igw-* ]]; then ok "subnet routes 0.0.0.0/0 to the internet gateway ($gw)"; else bad "subnet routes 0.0.0.0/0 to the internet gateway" "default route target: ${gw:-none}"; fi

# --- cost --------------------------------------------------------------------
section "Cost"
nat=$(aws ec2 describe-nat-gateways --filter Name=state,Values=pending,available --query 'length(NatGateways)' --output text 2>/dev/null)
if [ "$nat" = 0 ]; then ok "C5 no NAT gateways in $AWS_REGION"; else bad "C5 no NAT gateways in $AWS_REGION" "found: ${nat:-error}"; fi
eips=$(aws ec2 describe-addresses --query 'length(Addresses)' --output text 2>/dev/null)
if [ "$eips" = 0 ]; then ok "C5 no Elastic IPs in $AWS_REGION"; else bad "C5 no Elastic IPs in $AWS_REGION" "found: ${eips:-error}"; fi

limit=$(aws budgets describe-budget --account-id "$ACCOUNT" --budget-name "$BUDGET" --query 'Budget.BudgetLimit.Amount' --output text 2>/dev/null)
alerts=$(aws budgets describe-notifications-for-budget --account-id "$ACCOUNT" --budget-name "$BUDGET" --query 'length(Notifications)' --output text 2>/dev/null)
if [ -n "$limit" ] && [ "${alerts:-0}" -gt 0 ]; then
  ok "N1 budget $BUDGET exists (\$$limit, $alerts alerts)"
else
  bad "N1 budget $BUDGET exists with alerts" "limit: ${limit:-missing}, alerts: ${alerts:-0}"
fi
tag=$(aws ce list-cost-allocation-tags --tag-keys App --query 'CostAllocationTags[0].Status' --output text 2>/dev/null)
if [ "$tag" = Active ]; then ok "N1 cost allocation tag App is active (the budget filters on it)"; else bad "N1 cost allocation tag App is active" "status: ${tag:-missing}"; fi

# --- bedrock -----------------------------------------------------------------
section "Bedrock"
if [ -z "${BEDROCK_MODEL:-}" ]; then
  skp "C9 Bedrock model access (BEDROCK_MODEL is empty)"
else
  if reply=$(aws bedrock-runtime converse --model-id "$BEDROCK_MODEL" \
    --messages '[{"role":"user","content":[{"text":"Reply with OK."}]}]' --inference-config maxTokens=5 \
    --query 'output.message.content[0].text' --output text 2>&1); then
    ok "C9 Bedrock answers with $BEDROCK_MODEL ($reply)"
  else
    bad "C9 Bedrock answers with $BEDROCK_MODEL" "$(tail -1 <<<"$reply")"
  fi
fi

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]
