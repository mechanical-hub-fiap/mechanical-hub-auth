variable "project_name" {
  description = "Prefixo aplicado ao nome de todos os recursos"
  type        = string
  default     = "mechanical-hub"
}

variable "environment" {
  description = "Ambiente (stage do API Gateway e sufixo dos recursos)"
  type        = string
  default     = "prod"
}

variable "aws_region" {
  description = "Regiao AWS. O AWS Academy Lab so libera us-east-1"
  type        = string
  default     = "us-east-1"
}

# --- Identidade ---------------------------------------------------------------

variable "lambda_execution_role_arn" {
  description = <<-EOT
    ARN da role de execucao das funcoes.

    No AWS Academy Lab nao ha permissao para criar IAM roles: use a LabRole
    existente (arn:aws:iam::<conta>:role/LabRole). Em uma conta comum, aponte
    para uma role dedicada com o minimo necessario.
  EOT
  type        = string
}

# --- States remotos -----------------------------------------------------------
#
# ADR-0002: os valores de rede e de banco vem dos states dos repositorios
# aplicados antes deste (mechanical-hub-infra e mechanical-hub-database), e nao
# de secrets preenchidos a mao.

variable "infra_state_bucket" {
  description = "Bucket S3 com o state do mechanical-hub-infra"
  type        = string
}

variable "infra_state_key" {
  description = "Chave do state do mechanical-hub-infra dentro do bucket"
  type        = string
  default     = "mechanical-hub-infra/terraform.tfstate"
}

variable "database_state_bucket" {
  description = "Bucket S3 com o state do mechanical-hub-database"
  type        = string
}

variable "database_state_key" {
  description = "Chave do state do mechanical-hub-database dentro do bucket"
  type        = string
  default     = "mechanical-hub-database/terraform.tfstate"
}

variable "state_region" {
  description = "Regiao dos buckets de state. Vazio usa aws_region."
  type        = string
  default     = ""
}

# --- Rotas --------------------------------------------------------------------

variable "expose_orchestrator_transaction" {
  description = "Expoe GET /transaction/{orderId} do orchestrator no API Gateway (somente ADMINISTRATOR). Ligar apenas quando o endpoint opcional existir no servico."
  type        = bool
  default     = false
}

# --- Rede ---------------------------------------------------------------------
#
# Overrides opcionais. Vazio = resolve pelo state remoto (comportamento padrao).
# Preencher apenas para apontar para um ambiente avulso ou para destravar um
# deploy caso algum state esteja indisponivel.

variable "vpc_id" {
  description = "Override do vpc_id. Vazio le do state do mechanical-hub-infra."
  type        = string
  default     = ""
}

variable "vpc_subnet_ids" {
  description = "Override das subnets privadas. Vazio le private_subnet_ids do state do mechanical-hub-infra."
  type        = list(string)
  default     = []
}

variable "database_egress_cidrs" {
  description = "Override dos CIDRs de egress do security group. Vazio usa o CIDR da propria VPC."
  type        = list(string)
  default     = []
}

variable "allow_https_egress" {
  description = "Libera 443 no security group. Necessario apenas ao migrar SECRET_PROVIDER para aws-secrets-manager via VPC endpoint."
  type        = bool
  default     = false
}

# --- Banco --------------------------------------------------------------------
#
# Mesmo padrao: vazio/null resolve pelo state do mechanical-hub-database.

variable "database_host" {
  description = "Override do endpoint do banco. Vazio le auth_database.endpoint do state do mechanical-hub-database (RDS do orders). Sem RDS Proxy no lab; a conexao e direta."
  type        = string
  default     = ""
}

variable "database_port" {
  description = "Override da porta do banco. null le auth_database.port do state do mechanical-hub-database."
  type        = number
  default     = null
}

variable "database_name" {
  description = "Override do nome do banco. Vazio le auth_database.db_name do state do mechanical-hub-database."
  type        = string
  default     = ""
}

variable "database_user" {
  description = "Usuario de banco dedicado a autenticacao, somente leitura. A role (LOGIN + CONNECT) e criada pelo mechanical-hub-database (sql/auth-database-role.sql); o GRANT SELECT em users/profiles vem das migrations do orders."
  type        = string
  default     = "mechanical_hub_auth"
}

# Continua vindo de secret, e nao de output de state: valores sensiveis nao
# trafegam por output de Terraform, que fica gravado em claro no arquivo de
# state. Precisa ser a mesma senha usada no AUTH_DB_PASSWORD do
# mechanical-hub-database, que cria a role.
variable "database_password" {
  description = "Senha do usuario de banco. Injetada pelo pipeline a partir de um secret do repositorio."
  type        = string
  sensitive   = true
}

variable "database_ssl" {
  description = "Habilita TLS na conexao com o banco"
  type        = bool
  default     = true
}

# --- Token --------------------------------------------------------------------

variable "token_signing_key" {
  description = "Chave HS256 usada para assinar e verificar o token. Minimo de 32 caracteres."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.token_signing_key) >= 32
    error_message = "A chave de assinatura precisa ter ao menos 32 caracteres."
  }
}

variable "token_issuer" {
  description = "Claim iss do token"
  type        = string
  default     = "mechanical-hub-auth"
}

variable "token_audience" {
  description = "Claim aud do token"
  type        = string
  default     = "mechanical-hub-api"
}

variable "token_ttl_seconds" {
  description = "Validade do token em segundos"
  type        = number
  default     = 7200
}

# --- Ajustes de execucao ------------------------------------------------------

variable "lambda_memory_mb" {
  description = "Memoria das funcoes. Mais memoria tambem significa mais CPU, o que reduz o cold start."
  type        = number
  default     = 512
}

variable "lambda_timeout_seconds" {
  description = "Timeout das funcoes"
  type        = number
  default     = 15
}

variable "authorizer_cache_ttl_seconds" {
  description = <<-EOT
    Cache da decisao do autorizador, por token.

    Reduz invocacoes e latencia, mas atrasa o efeito de uma desativacao de
    funcionario. 0 desliga o cache.
  EOT
  type        = number
  default     = 300
}

variable "log_retention_days" {
  description = "Retencao dos logs no CloudWatch"
  type        = number
  default     = 14
}

variable "login_throttle_rate" {
  description = "Requisicoes por segundo permitidas na rota de login"
  type        = number
  default     = 20
}

variable "login_throttle_burst" {
  description = "Pico de requisicoes permitido na rota de login"
  type        = number
  default     = 40
}

# --- Observabilidade (RFC-0004, etapa 3) --------------------------------------

variable "otlp_endpoint" {
  description = <<-EOT
    Override do endereco OTLP/HTTP do coletor OpenTelemetry.

    Vazio resolve pelo output `otlp_vpc_endpoint` do state do
    mechanical-hub-infra -- um listener no NLB interno, alcancavel de dentro da
    VPC. As funcoes rodam na VPC mas fora do Kubernetes, entao nao podem usar o
    DNS do cluster.

    Se nem o override nem o output existirem, a telemetria fica desligada: as
    funcoes sobem normalmente e apenas nao exportam nada.
  EOT
  type        = string
  default     = ""
}

variable "otlp_export_timeout_ms" {
  description = <<-EOT
    Prazo do envio de telemetria ao coletor.

    Entra no tempo de resposta da requisicao, porque a Lambda congela a execucao
    assim que responde e o envio precisa terminar antes disso. Curto de
    proposito: vale perder a telemetria de uma invocacao, nao atrasar o login.
  EOT
  type        = number
  default     = 1500
}

variable "authorizer_in_vpc" {
  description = <<-EOT
    Coloca o autorizador dentro da VPC para que ele alcance o coletor.

    Ele ficava fora por causa de cold start. Esse custo caiu muito desde as ENIs
    Hyperplane (a AWS mediu ~14,8s para ~933ms no anuncio de 2019), o que torna
    a troca aceitavel em troca das metricas de autorizacao -- que sao invocadas
    em toda requisicao protegida e hoje nao aparecem em painel nenhum.

    O caso de borda que sobra: a AWS documenta que funcoes ociosas por semanas
    podem ter os recursos Hyperplane recuperados e voltar a sofrer cold start
    mais longo -- plausivel num laboratorio parado entre sessoes. Com false, o
    autorizador volta para fora da VPC e perde so a exportacao; o log continua
    indo para o CloudWatch.

    Sem efeito quando nao ha coletor configurado.
  EOT
  type        = bool
  default     = true
}
