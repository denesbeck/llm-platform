resource "aws_budgets_budget" "llm_platform_budget" {
  name         = "monthly-llm-platform-budget"
  budget_type  = "COST"
  limit_amount = "45"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_email]
  }

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:App$llm-platform"]
  }
}

# account-wide setting, never deactivate it from here
# INFO: run this when you apply the infra for the first time
# resource "aws_ce_cost_allocation_tag" "app" {
#   tag_key = "App"
#   status  = "Active"
#
#   lifecycle {
#     prevent_destroy = true
#   }
# }

# after creating the cost allocation tag, forget it, so it can stay active even after destroying the infra
removed {
  from = aws_se_cost_allocation_tag.app

  lifecycle {
    destroy = false
  }
}
