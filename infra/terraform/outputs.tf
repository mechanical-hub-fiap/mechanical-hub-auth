output "api_base_url" {
  description = "URL base da API. E o unico endereco que os clientes devem conhecer."
  value       = aws_api_gateway_stage.this.invoke_url
}

output "login_url" {
  description = "Endpoint de login"
  value       = "${aws_api_gateway_stage.this.invoke_url}/auth/login"
}

output "webhook_url" {
  description = "URL de notificacao a configurar no painel do Mercado Pago. Muda a cada recriacao do API Gateway (reset do Lab): reconfigurar depois de todo apply que recriar a API."
  value       = "${aws_api_gateway_stage.this.invoke_url}/webhooks/payment"
}

output "routes" {
  description = "Rotas encaminhadas aos servicos (local.routes): caminho -> servico e se e publica."
  value       = { for path, route in local.routes : "${route.method} /${path}" => { service = route.service, public = route.public } }
}

output "authenticate_function_name" {
  value = aws_lambda_function.authenticate.function_name
}

output "authorize_function_name" {
  value = aws_lambda_function.authorize.function_name
}

output "rest_api_id" {
  value = aws_api_gateway_rest_api.this.id
}

output "lambda_security_group_id" {
  description = "Security group das funcoes, criado neste repositorio (ADR-0002)"
  value       = aws_security_group.lambda.id
}

output "vpc_link_id" {
  description = "VPC Link usado pelas integracoes privadas do API Gateway ate o NLB da aplicacao."
  value       = aws_api_gateway_vpc_link.app.id
}

# Ecoam o que foi efetivamente resolvido dos states remotos. Servem para
# conferir, no output do apply, se a pipeline leu o ambiente certo -- util
# depois de um reset do Lab, quando os ids mudam.
output "resolved_vpc_id" {
  description = "VPC em uso (do state de infra, ou do override)"
  value       = local.vpc_id
}

output "resolved_subnet_ids" {
  description = "Subnets privadas em uso (do state de infra, ou do override)"
  value       = local.subnet_ids
}

output "resolved_database_host" {
  description = "Endpoint do banco em uso (do state de database, ou do override)"
  value       = local.database_host
}

output "resolved_app_backend_urls" {
  description = "URLs base de cada servico no NLB interno (app_backend_base_urls), resolvidas do state de mechanical-hub-infra."
  value       = local.app_backend_base_urls
}

# --- Observabilidade (RFC-0004, etapa 3) --------------------------------------

output "telemetry_enabled" {
  description = <<-EOT
    Se as funcoes estao exportando telemetria. Falso significa que nao ha
    coletor alcancavel — as funcoes sobem e funcionam, apenas sem metricas nem
    rastros no Grafana. Vale conferir isto no resumo do apply antes de concluir
    que um painel vazio e problema de painel.
  EOT
  value       = local.telemetry_enabled
}

output "otlp_endpoint" {
  description = "Endereco OTLP/HTTP em uso pelas funcoes, resolvido do state de infra ou do override."
  value       = local.telemetry_enabled ? local.otlp_endpoint : null
}

output "authorizer_in_vpc" {
  description = <<-EOT
    Se o autorizador foi colocado na VPC. Fora dela ele nao alcanca o coletor e
    a serie mechanical_hub_auth_authorizer_total nao e publicada — o painel de
    decisoes do autorizador fica vazio, sem erro em lugar nenhum.
  EOT
  value       = local.authorizer_in_vpc
}

output "api_gateway_log_group" {
  description = "Log group com o log de acesso do API Gateway — o unico lugar onde aparece o que o Gateway recusou antes de chegar na funcao."
  value       = aws_cloudwatch_log_group.api_gateway.name
}
