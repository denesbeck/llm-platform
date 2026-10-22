ephemeral "random_password" "litellm_master_key" {
  length  = 48
  special = false
}

ephemeral "random_password" "litellm_salt_key" {
  length  = 48
  special = false
}

ephemeral "random_password" "postgres_pwd" {
  length  = 48
  special = false
}

ephemeral "random_password" "grafana_admin_pwd" {
  length  = 48
  special = false
}

ephemeral "random_password" "vllm_api_key" {
  length  = 48
  special = false
}

# master key must start with 'sk-': https://docs.litellm.ai/docs/proxy/virtual_keys#setup
resource "aws_ssm_parameter" "litellm_master_key" {
  name             = "/llm-platform/LITELLM_MASTER_KEY"
  type             = "SecureString"
  value_wo         = "sk-${ephemeral.random_password.litellm_master_key.result}"
  value_wo_version = 1
}

# never rotate: LiteLLM encrypts stored credentials with it
resource "aws_ssm_parameter" "litellm_salt_key" {
  name             = "/llm-platform/LITELLM_SALT_KEY"
  type             = "SecureString"
  value_wo         = ephemeral.random_password.litellm_salt_key.result
  value_wo_version = 1

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_ssm_parameter" "postgres_pwd" {
  name             = "/llm-platform/POSTGRES_PASSWORD"
  type             = "SecureString"
  value_wo         = ephemeral.random_password.postgres_pwd.result
  value_wo_version = 1
}

resource "aws_ssm_parameter" "grafana_admin_pwd" {
  name             = "/llm-platform/GRAFANA_ADMIN_PASSWORD"
  type             = "SecureString"
  value_wo         = ephemeral.random_password.grafana_admin_pwd.result
  value_wo_version = 1
}

resource "aws_ssm_parameter" "vllm_api_key" {
  name             = "/llm-platform/gpu/VLLM_API_KEY"
  type             = "SecureString"
  value_wo         = ephemeral.random_password.vllm_api_key.result
  value_wo_version = 1
}
