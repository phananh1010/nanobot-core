# SSM Parameter Store — placeholder secrets for nanobot.
#
# IMPORTANT: Terraform state stores these values in plaintext.
# For a personal project this is acceptable, but you can also manage
# sensitive params outside Terraform and just reference them by path:
#   aws ssm put-parameter --name "/nanobot/anthropic_api_key" \
#     --value "sk-ant-..." --type SecureString --overwrite
#
# After running `terraform apply`, populate each parameter with the real value:
#   aws ssm put-parameter --name "<name>" --value "<value>" \
#     --type SecureString --overwrite --region <region>

locals {
  ssm_prefix = "/${var.project}"
}

# ── LLM provider keys (fill in the values you use) ───────────────────────────

resource "aws_ssm_parameter" "anthropic_api_key" {
  name        = "${local.ssm_prefix}/anthropic_api_key"
  description = "Anthropic API key → NANOBOT_PROVIDERS__ANTHROPIC__API_KEY"
  type        = "SecureString"
  value       = "REPLACE_ME"

  lifecycle { ignore_changes = [value] }
}

resource "aws_ssm_parameter" "openai_api_key" {
  name        = "${local.ssm_prefix}/openai_api_key"
  description = "OpenAI API key → NANOBOT_PROVIDERS__OPENAI__API_KEY"
  type        = "SecureString"
  value       = "REPLACE_ME"

  lifecycle { ignore_changes = [value] }
}

resource "aws_ssm_parameter" "openrouter_api_key" {
  name        = "${local.ssm_prefix}/openrouter_api_key"
  description = "OpenRouter API key → NANOBOT_PROVIDERS__OPENROUTER__API_KEY"
  type        = "SecureString"
  value       = "REPLACE_ME"

  lifecycle { ignore_changes = [value] }
}

resource "aws_ssm_parameter" "deepseek_api_key" {
  name        = "${local.ssm_prefix}/deepseek_api_key"
  description = "DeepSeek API key → NANOBOT_PROVIDERS__DEEPSEEK__API_KEY"
  type        = "SecureString"
  value       = "REPLACE_ME"

  lifecycle { ignore_changes = [value] }
}

resource "aws_ssm_parameter" "gemini_api_key" {
  name        = "${local.ssm_prefix}/gemini_api_key"
  description = "Gemini API key → NANOBOT_PROVIDERS__GEMINI__API_KEY"
  type        = "SecureString"
  value       = "REPLACE_ME"

  lifecycle { ignore_changes = [value] }
}

# ── Gateway ───────────────────────────────────────────────────────────────────

resource "aws_ssm_parameter" "gateway_http_api_key" {
  name        = "${local.ssm_prefix}/gateway_http_api_key"
  description = "Secret key protecting POST /v1/chat → NANOBOT_GATEWAY__HTTP_API_KEY"
  type        = "SecureString"
  value       = "REPLACE_ME"

  lifecycle { ignore_changes = [value] }
}

# ── Channel tokens ────────────────────────────────────────────────────────────

resource "aws_ssm_parameter" "telegram_bot_token" {
  name        = "${local.ssm_prefix}/telegram_bot_token"
  description = "Telegram bot token (from BotFather) — written to config.json by fetch-secrets.sh"
  type        = "SecureString"
  value       = "REPLACE_ME"

  lifecycle { ignore_changes = [value] }
}

resource "aws_ssm_parameter" "slack_bot_token" {
  name        = "${local.ssm_prefix}/slack_bot_token"
  description = "Slack bot OAuth token — written to config.json by fetch-secrets.sh"
  type        = "SecureString"
  value       = "REPLACE_ME"

  lifecycle { ignore_changes = [value] }
}

resource "aws_ssm_parameter" "discord_bot_token" {
  name        = "${local.ssm_prefix}/discord_bot_token"
  description = "Discord bot token — written to config.json by fetch-secrets.sh"
  type        = "SecureString"
  value       = "REPLACE_ME"

  lifecycle { ignore_changes = [value] }
}

# ── Web search ────────────────────────────────────────────────────────────────

resource "aws_ssm_parameter" "brave_search_api_key" {
  name        = "${local.ssm_prefix}/brave_search_api_key"
  description = "Brave Search API key → NANOBOT_TOOLS__WEB__SEARCH__API_KEY"
  type        = "SecureString"
  value       = "REPLACE_ME"

  lifecycle { ignore_changes = [value] }
}
