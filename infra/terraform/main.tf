terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Configuracao parcial: bucket e regiao vem do -backend-config no init, para
  # nao versionar o nome do bucket e permitir que cada ambiente use o seu.
  #
  #   terraform init \
  #     -backend-config="bucket=<bucket-de-state>" \
  #     -backend-config="region=us-east-1"
  backend "s3" {
    key     = "mechanical-hub-auth/terraform.tfstate"
    encrypt = true
  }
}

provider "aws" {
  region = var.aws_region
}

# =============================================================================
# States remotos dos repositorios anteriores na ordem de provisionamento
#
# ADR-0002: cada repositorio exporta outputs explicitos, e os consumidores leem
# esses valores via terraform_remote_state -- nunca por hardcode de IDs ou
# endpoints.
#
# Ganho concreto no ciclo do AWS Academy Lab: a cada reset do ambiente, subnets
# e endpoint do RDS mudam. Lendo do state, a pipeline pega os valores atuais
# sozinha, em vez de exigir que alguem reedite secrets no GitHub antes de
# qualquer deploy funcionar.
# =============================================================================

data "terraform_remote_state" "infra" {
  backend = "s3"

  config = {
    bucket = var.infra_state_bucket
    key    = var.infra_state_key
    region = var.state_region != "" ? var.state_region : var.aws_region
  }
}

data "terraform_remote_state" "database" {
  backend = "s3"

  config = {
    bucket = var.database_state_bucket
    key    = var.database_state_key
    region = var.state_region != "" ? var.state_region : var.aws_region
  }
}

locals {
  name_prefix = "${var.project_name}-auth-${var.environment}"

  common_tags = {
    Project     = var.project_name
    Component   = "auth"
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  # --- Valores resolvidos a partir dos states remotos ------------------------
  #
  # As variaveis correspondentes continuam existindo como override opcional
  # (default vazio). Servem para desenvolvimento local contra um ambiente
  # avulso e para destravar um deploy se algum state estiver indisponivel --
  # mesmo padrao de fallback adotado no mechanical-hub-database.

  vpc_id = var.vpc_id != "" ? var.vpc_id : data.terraform_remote_state.infra.outputs.vpc_id

  subnet_ids = length(var.vpc_subnet_ids) > 0 ? var.vpc_subnet_ids : data.terraform_remote_state.infra.outputs.private_subnet_ids

  # Fase 4: um RDS por servico. O login le users/profiles no banco do orders,
  # publicado pelo mechanical-hub-database como auth_database
  # ({ endpoint, port, db_name }), que substitui os antigos rds_*.
  auth_database = data.terraform_remote_state.database.outputs.auth_database

  # O endpoint e publicado so com o host, mas o split continua cobrindo o
  # formato "host:porta" (atributo `endpoint` do aws_db_instance): sem ele, o
  # driver do Postgres tentaria resolver "host:5432" como nome de maquina e a
  # conexao falharia.
  database_host = var.database_host != "" ? var.database_host : split(":", local.auth_database.endpoint)[0]

  database_port = var.database_port != null ? var.database_port : local.auth_database.port

  database_name = var.database_name != "" ? var.database_name : local.auth_database.db_name

  # NLB interno da aplicacao, provisionado pelo mechanical-hub-infra
  # (modules/app-lb) -- nao pelo Kubernetes. O AWS Load Balancer Controller
  # exigiria IRSA (IAM role nova via provedor OIDC), bloqueado no AWS Academy
  # Lab. Sem override aqui: ao contrario de rede/banco, este valor nao existia
  # antes da conectividade privada (era secret preenchido a mao) e sempre esta disponivel
  # assim que o mechanical-hub-infra aplica -- nao depende do deploy da
  # aplicacao ter rodado.
  #
  # Fase 4: o NLB continua um so (um VPC Link), mas com um listener por
  # servico. app_backend_base_urls e o mapa servico -> URL base
  # (orders, stock, billing, orchestrator), contrato da secao 3 da spec do infra.
  app_nlb_arn           = data.terraform_remote_state.infra.outputs.app_nlb_arn
  app_backend_base_urls = data.terraform_remote_state.infra.outputs.app_backend_base_urls

  # --- Rotas encaminhadas aos servicos (Fase 4) ------------------------------
  #
  # Chave: caminho no API Gateway, sem barra inicial e com no maximo dois
  # segmentos. Todos os recursos, metodos e integracoes do api-gateway.tf saem
  # deste mapa; rota fora dele nao existe no gateway e recebe a resposta padrao
  # dele (negacao por padrao, igual a matriz de acesso).
  #
  #   service         -> chave em app_backend_base_urls
  #   method          -> metodo HTTP no gateway (ANY para os {proxy+})
  #   public          -> true: sem autorizador; false: autorizador + x-user-*
  #   forward_headers -> cabecalhos repassados explicitamente a integracao
  #
  # /mechanical-hub e /webhooks sao publicos de proposito: o cliente final se
  # autentica pelo token de aprovacao (validado no orders) e o Mercado Pago pela
  # assinatura x-signature (validada no billing).
  routes = merge(
    {
      "mechanical-hub/{proxy+}" = { service = "orders", method = "ANY", public = true, forward_headers = [] }
      "orders"                  = { service = "orders", method = "ANY", public = false, forward_headers = [] }
      "orders/{proxy+}"         = { service = "orders", method = "ANY", public = false, forward_headers = [] }
      "services"                = { service = "orders", method = "GET", public = false, forward_headers = [] }
      "stock"                   = { service = "stock", method = "ANY", public = false, forward_headers = [] }
      "stock/{proxy+}"          = { service = "stock", method = "ANY", public = false, forward_headers = [] }
      "webhooks/payment"        = { service = "billing", method = "POST", public = true, forward_headers = ["x-signature", "x-request-id"] }
    },
    # Endpoint opcional do orquestrador (depuracao e demonstracao). So entra
    # no gateway quando o servico de fato o expoe.
    var.expose_orchestrator_transaction ? {
      "transaction/{orderId}" = { service = "orchestrator", method = "GET", public = false, forward_headers = [] }
    } : {},
  )

  # Configuracao comum as duas funcoes.
  #
  # SECRET_PROVIDER=environment porque o AWS Academy Lab nao libera o Secrets
  # Manager. Em uma conta comum, troque para "aws-secrets-manager" e informe
  # TOKEN_SIGNING_KEY_SECRET_ID / DATABASE_CREDENTIALS_SECRET_ID -- o codigo ja
  # suporta os dois modos atras da mesma porta (SecretProvider).
  token_environment = {
    SECRET_PROVIDER   = "environment"
    TOKEN_SIGNING_KEY = var.token_signing_key
    TOKEN_ISSUER      = var.token_issuer
    TOKEN_AUDIENCE    = var.token_audience
    TOKEN_TTL_SECONDS = tostring(var.token_ttl_seconds)
    SERVICE_NAME      = "${var.project_name}-auth"
    LOG_LEVEL         = "info"
  }

  # --- Telemetria (RFC-0004, etapa 3) ---------------------------------------
  #
  # O coletor OpenTelemetry roda no cluster; as funcoes rodam na VPC mas FORA do
  # Kubernetes, e nao resolvem o DNS interno nem alcancam um Service ClusterIP.
  # O mechanical-hub-infra publica no output abaixo um endereco que funciona de
  # dentro da VPC: um listener no mesmo NLB interno que ja atende a aplicacao,
  # apontando para o NodePort do coletor.
  #
  # `try` porque o output nao existe em states aplicados antes da etapa 1, e e
  # nulo quando a observabilidade esta desligada la. Nos dois casos a telemetria
  # apenas nao liga, em vez de quebrar o apply.
  otlp_endpoint_resolved = var.otlp_endpoint != "" ? var.otlp_endpoint : try(
    data.terraform_remote_state.infra.outputs.otlp_vpc_endpoint, ""
  )

  otlp_endpoint     = local.otlp_endpoint_resolved == null ? "" : local.otlp_endpoint_resolved
  telemetry_enabled = local.otlp_endpoint != ""

  # Sem coletor, o codigo trata endereco ausente como telemetria desligada e o
  # adaptador vira no-op -- nao tenta exportar para lugar nenhum.
  telemetry_environment = local.telemetry_enabled ? {
    OTEL_EXPORTER_OTLP_ENDPOINT = local.otlp_endpoint
    OTEL_ENABLED                = "true"
    OTEL_EXPORT_TIMEOUT_MS      = tostring(var.otlp_export_timeout_ms)
    ENVIRONMENT                 = var.environment
    } : {
    OTEL_ENABLED = "false"
    ENVIRONMENT  = var.environment
  }

  # O autorizador so entra na VPC quando precisa alcancar o coletor.
  #
  # Ele foi mantido fora dela de proposito ate aqui, e a justificativa era cold
  # start. Esse custo caiu muito desde as ENIs Hyperplane -- a propria AWS
  # mediu ~14,8s para ~933ms no anuncio de 2019 --, o que torna a troca
  # aceitavel em troca das metricas de autorizacao. O que sobra e um caso de
  # borda documentado pela AWS: funcoes ociosas por semanas podem ter os
  # recursos Hyperplane recuperados e voltar a sofrer cold start mais longo,
  # cenario plausivel num laboratorio que fica parado.
  #
  # Por isso e variavel, e nao decisao fixa: com var.authorizer_in_vpc = false
  # o autorizador volta a ficar fora da VPC e perde apenas a exportacao -- o
  # log continua indo para o CloudWatch.
  authorizer_in_vpc = local.telemetry_enabled && var.authorizer_in_vpc
}

# =============================================================================
# Funcoes
# =============================================================================

resource "aws_lambda_function" "authenticate" {
  function_name = "${local.name_prefix}-authenticate"
  description   = "Valida CPF e senha do funcionario e emite o token de acesso"

  role    = var.lambda_execution_role_arn
  runtime = "nodejs20.x"
  handler = "index.handler"

  filename         = "${path.module}/../../build/authenticate.zip"
  source_code_hash = filebase64sha256("${path.module}/../../build/authenticate.zip")

  memory_size = var.lambda_memory_mb
  timeout     = var.lambda_timeout_seconds

  # Precisa estar na VPC para alcancar o banco. Subnets e SG vem, respectivamente,
  # do state de infra e do recurso criado neste repositorio.
  vpc_config {
    subnet_ids         = local.subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = merge(local.token_environment, local.telemetry_environment, {
      DATABASE_HOST     = local.database_host
      DATABASE_PORT     = tostring(local.database_port)
      DATABASE_NAME     = local.database_name
      DATABASE_USER     = var.database_user
      DATABASE_PASSWORD = var.database_password
      DATABASE_SSL      = tostring(var.database_ssl)

      MAX_FAILED_ATTEMPTS            = "5"
      FAILED_ATTEMPTS_WINDOW_SECONDS = "900"
    })
  }

  tags = merge(local.common_tags, { Function = "authenticate" })

  depends_on = [aws_cloudwatch_log_group.authenticate]
}

resource "aws_lambda_function" "authorize" {
  function_name = "${local.name_prefix}-authorize"
  description   = "Autorizador do API Gateway: valida o token e o perfil contra a rota"

  role    = var.lambda_execution_role_arn
  runtime = "nodejs20.x"
  handler = "index.handler"

  filename         = "${path.module}/../../build/authorize.zip"
  source_code_hash = filebase64sha256("${path.module}/../../build/authorize.zip")

  memory_size = 256
  timeout     = 10

  # Historicamente ficava fora da VPC (nao fala com o banco). Passa a entrar
  # apenas quando ha coletor para alcancar -- ver o local authorizer_in_vpc,
  # que documenta o custo dessa troca e como reverte-la.
  dynamic "vpc_config" {
    for_each = local.authorizer_in_vpc ? [1] : []

    content {
      subnet_ids         = local.subnet_ids
      security_group_ids = [aws_security_group.lambda.id]
    }
  }

  environment {
    variables = merge(local.token_environment, local.telemetry_environment)
  }

  tags = merge(local.common_tags, { Function = "authorize" })

  depends_on = [aws_cloudwatch_log_group.authorize]
}

# =============================================================================
# Logs
# =============================================================================

resource "aws_cloudwatch_log_group" "authenticate" {
  name              = "/aws/lambda/${local.name_prefix}-authenticate"
  retention_in_days = var.log_retention_days
  tags              = local.common_tags
}

resource "aws_cloudwatch_log_group" "authorize" {
  name              = "/aws/lambda/${local.name_prefix}-authorize"
  retention_in_days = var.log_retention_days
  tags              = local.common_tags
}
