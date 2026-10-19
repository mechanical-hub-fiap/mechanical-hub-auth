# =============================================================================
# API Gateway (REST v1)
#
# Desenho das rotas (Fase 4 -- um backend por servico, mesmo VPC Link):
#
#   POST /auth/login               -> funcao authenticate  (publica)
#   ANY  /mechanical-hub/{proxy+}  -> orders               (publica, token de aprovacao no servico)
#   POST /webhooks/payment         -> billing              (publica, assinatura validada no servico)
#   ANY  /orders, /orders/{proxy+} -> orders               (protegida)
#   GET  /services                 -> orders               (protegida)
#   ANY  /stock, /stock/{proxy+}   -> stock                (protegida)
#   GET  /transaction/{orderId}    -> orchestrator         (protegida, opcional)
#
# As rotas encaminhadas aos servicos sao geradas a partir de local.routes
# (main.tf). Nao ha mais /{proxy+} generico: caminho fora do mapa nao existe no
# gateway e recebe a resposta padrao dele -- negacao por padrao, como na matriz
# de acesso. /actuator, /swagger-ui e /v3 tambem nao passam mais por aqui: os
# quatro servicos teriam os mesmos caminhos. Health fica com o NLB; Swagger por
# port-forward.
#
# As rotas publicas nao ficam atras do autorizador por uma limitacao concreta
# do API Gateway: com cache ligado, um autorizador do tipo REQUEST nega a
# requisicao sem nem invocar a funcao quando o identity_source (o cabecalho
# Authorization) esta ausente. Como o cliente final e o Mercado Pago nunca
# mandam token, receberiam 401 antes de qualquer logica rodar.
# =============================================================================

resource "aws_api_gateway_rest_api" "this" {
  name        = local.name_prefix
  description = "Entrada unica da API do Mechanical Hub"

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = local.common_tags
}

# -----------------------------------------------------------------------------
# Autorizador
# -----------------------------------------------------------------------------

resource "aws_api_gateway_authorizer" "token" {
  name = "${local.name_prefix}-authorizer"
  type = "REQUEST"

  rest_api_id     = aws_api_gateway_rest_api.this.id
  authorizer_uri  = aws_lambda_function.authorize.invoke_arn
  identity_source = "method.request.header.Authorization"

  authorizer_result_ttl_in_seconds = var.authorizer_cache_ttl_seconds
}

# -----------------------------------------------------------------------------
# Conectividade privada ate a aplicacao principal
#
# Conectividade privada: o Service da aplicacao nao tem mais IP publico
# (ver mechanical-hub/src/main/resources/k8s/service-app.yaml). As integracoes
# HTTP_PROXY abaixo alcancam o NLB interno provisionado pelo
# mechanical-hub-infra atraves deste VPC Link, em vez de um hostname publico.
# -----------------------------------------------------------------------------

resource "aws_api_gateway_vpc_link" "app" {
  name        = "${local.name_prefix}-vpc-link"
  description = "Conectividade privada ate o NLB interno dos servicos (adendo da ADR-0003)."
  target_arns = [local.app_nlb_arn]
}

# =============================================================================
# /auth/login  (publica)
# =============================================================================

resource "aws_api_gateway_resource" "auth" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "auth"
}

resource "aws_api_gateway_resource" "auth_login" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.auth.id
  path_part   = "login"
}

resource "aws_api_gateway_method" "auth_login_post" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.auth_login.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "auth_login_post" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.auth_login.id
  http_method = aws_api_gateway_method.auth_login_post.http_method

  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.authenticate.invoke_arn
}

# =============================================================================
# Rotas encaminhadas aos servicos (geradas de local.routes)
#
# Todas as chaves de local.routes tem um ou dois segmentos. O primeiro segmento
# vira um recurso filho da raiz; o segundo, quando existe, um filho dele. Um
# prefixo com as duas formas (/orders e /orders/{proxy+}) compartilha o recurso
# do primeiro nivel.
# =============================================================================

locals {
  route_first_segments = toset([for path in keys(local.routes) : split("/", path)[0]])

  route_second_segments = {
    for path in keys(local.routes) : path => {
      parent    = split("/", path)[0]
      path_part = split("/", path)[1]
    } if length(split("/", path)) == 2
  }

  route_resource_ids = merge(
    { for segment, resource in aws_api_gateway_resource.route_first : segment => resource.id },
    { for path, resource in aws_api_gateway_resource.route_second : path => resource.id },
  )

  # Parametro de caminho da rota ({proxy+} -> proxy, {orderId} -> orderId) e o
  # caminho no servico com a sintaxe da integracao ({proxy+} vira {proxy}).
  route_specs = {
    for path, route in local.routes : path => merge(route, {
      path_param   = try(regex("\\{(\\w+)\\+?\\}", path)[0], null)
      backend_path = replace(path, "+}", "}")
    })
  }

  # A identidade resolvida pelo autorizador chega aos servicos como cabecalho.
  # E o que o filtro de gateway de cada servico consome -- assim nenhum deles
  # precisa reabrir o token.
  identity_headers = {
    "integration.request.header.x-user-id"   = "context.authorizer.userId"
    "integration.request.header.x-user-role" = "context.authorizer.role"
    "integration.request.header.x-user-name" = "context.authorizer.name"
  }
}

resource "aws_api_gateway_resource" "route_first" {
  for_each = local.route_first_segments

  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = each.value
}

resource "aws_api_gateway_resource" "route_second" {
  for_each = local.route_second_segments

  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.route_first[each.value.parent].id
  path_part   = each.value.path_part
}

resource "aws_api_gateway_method" "route" {
  for_each = local.route_specs

  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = local.route_resource_ids[each.key]
  http_method   = each.value.method
  authorization = each.value.public ? "NONE" : "CUSTOM"
  authorizer_id = each.value.public ? null : aws_api_gateway_authorizer.token.id

  # Cabecalhos repassados sao opcionais (false): presenca e conteudo sao
  # validados pelo servico -- o billing responde 401 a webhook sem x-signature.
  request_parameters = merge(
    each.value.path_param == null ? {} : { "method.request.path.${each.value.path_param}" = true },
    each.value.public ? {} : { "method.request.header.Authorization" = true },
    { for header in each.value.forward_headers : "method.request.header.${header}" => false },
  )
}

resource "aws_api_gateway_integration" "route" {
  for_each = local.route_specs

  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = local.route_resource_ids[each.key]
  http_method = aws_api_gateway_method.route[each.key].http_method

  # HTTP_PROXY repassa o corpo sem transformacao -- requisito do webhook, cuja
  # assinatura e conferida sobre a requisicao original.
  type                    = "HTTP_PROXY"
  integration_http_method = each.value.method
  uri                     = "${local.app_backend_base_urls[each.value.service]}/${each.value.backend_path}"

  connection_type = "VPC_LINK"
  connection_id   = aws_api_gateway_vpc_link.app.id

  request_parameters = merge(
    each.value.path_param == null ? {} : {
      "integration.request.path.${each.value.path_param}" = "method.request.path.${each.value.path_param}"
    },
    each.value.public ? {} : local.identity_headers,
    { for header in each.value.forward_headers : "integration.request.header.${header}" => "method.request.header.${header}" },
  )

  lifecycle {
    precondition {
      condition     = contains(keys(local.app_backend_base_urls), each.value.service)
      error_message = "O servico \"${each.value.service}\" da rota /${each.key} nao esta em app_backend_base_urls do state do mechanical-hub-infra."
    }
  }
}

# =============================================================================
# Permissoes de invocacao
# =============================================================================

resource "aws_lambda_permission" "authenticate" {
  statement_id  = "AllowApiGatewayInvokeAuthenticate"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.authenticate.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/*"
}

resource "aws_lambda_permission" "authorize" {
  statement_id  = "AllowApiGatewayInvokeAuthorize"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.authorize.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/authorizers/*"
}

# =============================================================================
# Deploy e stage
# =============================================================================

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  # Forca novo deploy quando qualquer parte do desenho da API muda.
  triggers = {
    redeploy = sha1(jsonencode([
      aws_api_gateway_resource.auth_login.id,
      aws_api_gateway_method.auth_login_post.id,
      aws_api_gateway_integration.auth_login_post.id,
      aws_api_gateway_authorizer.token.id,
      aws_api_gateway_vpc_link.app.id,
      # Objetos inteiros, e nao so ids: mudar a uri, os cabecalhos repassados ou
      # o autorizador de uma rota mantem o id e, sem isto, nao republicaria.
      aws_api_gateway_resource.route_first,
      aws_api_gateway_resource.route_second,
      aws_api_gateway_method.route,
      aws_api_gateway_integration.route,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_account" "this" {
  cloudwatch_role_arn = var.lambda_execution_role_arn
}

resource "aws_api_gateway_stage" "this" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  deployment_id = aws_api_gateway_deployment.this.id
  stage_name    = var.environment
  depends_on    = [aws_api_gateway_account.this]

  # `integrationLatency` separado de `responseLatency` responde a primeira
  # pergunta de toda reclamacao de lentidao: demorou no backend ou no Gateway?
  # `authorizerError` mostra a falha do autorizador, que de outro modo so
  # apareceria como um 500 sem explicacao.
  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway.arn

    format = jsonencode({
      requestId          = "$context.requestId"
      ip                 = "$context.identity.sourceIp"
      requestTime        = "$context.requestTime"
      httpMethod         = "$context.httpMethod"
      path               = "$context.path"
      status             = "$context.status"
      protocol           = "$context.protocol"
      responseLength     = "$context.responseLength"
      responseLatency    = "$context.responseLatency"
      integrationLatency = "$context.integration.latency"
      integrationStatus  = "$context.integration.status"
      authorizerError    = "$context.authorizer.error"
      error              = "$context.error.messageString"
      errorType          = "$context.error.responseType"
    })
  }

  tags = local.common_tags
}

# Throttling especifico da rota de login: primeira barreira contra forca bruta,
# antes do contador por documento que roda dentro da funcao.
resource "aws_api_gateway_method_settings" "login_throttle" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.this.stage_name
  method_path = "auth/login/POST"

  settings {
    throttling_rate_limit  = var.login_throttle_rate
    throttling_burst_limit = var.login_throttle_burst
    metrics_enabled        = true
  }
}

# =============================================================================
# Logs do API Gateway
#
# Preenche o unico trecho do caminho que nao tinha visibilidade nenhuma: o que
# acontece ANTES da requisicao chegar na funcao ou na aplicacao. Sem isto, um
# 500 gerado pelo proprio Gateway — integracao inalcancavel, autorizador que
# estourou — aparecia so como "Internal server error" no corpo da resposta, e o
# diagnostico dependia de reproduzir na mao pelo CLI. Foi exatamente o que
# aconteceu no incidente do VPC Link.
# =============================================================================

resource "aws_cloudwatch_log_group" "api_gateway" {
  name              = "/aws/apigateway/${local.name_prefix}"
  retention_in_days = var.log_retention_days
  tags              = local.common_tags
}