# Mechanical Hub — Autenticação Serverless

Funções serverless de **autenticação** e **autorização** do Mechanical Hub, e o **API Gateway** que é a entrada única dos quatro serviços (Tech Challenge — Fase 4).

Repositório independente dos serviços (`orders`, `stock`, `billing`, `orchestrator`), com ciclo de deploy próprio.

- **Spec de referência:** `planning/mechanical-hub-auth-spec.md` (Fase 4) e `docs/specs/lambda-authorizer-spec.md` (Fase 3)
- **Decisões arquiteturais:** ADR-0001 — Autenticação de funcionários via CPF; ADR-0005 — Divisão em microsserviços; ADR-0006 — Comunicação híbrida

---

## O que este repositório faz

| Função | Papel |
|---|---|
| **`authenticate`** | Recebe CPF + senha, consulta o banco, verifica a senha e emite um JWT. Exposta em `POST /auth/login`. |
| **`authorize`** | Authorizer do API Gateway. Valida o token e o perfil contra a rota pedida, devolvendo Allow/Deny. |

Quem autentica são **funcionários da oficina** (mecânicos e administradores). O cliente final nunca faz login — as rotas dele (`/mechanical-hub/service-orders/**`) seguem públicas, e o token de aprovação é validado pelo `orders`.

---

## Rotas

O API Gateway encaminha cada prefixo ao serviço dono dele, todos pelo mesmo VPC Link até o NLB interno (um listener por serviço). As rotas são geradas a partir de `local.routes` (`infra/terraform/main.tf`); a matriz de acesso (`src/core/domain/access-policy.ts`) espelha a mesma tabela.

| Rota no API Gateway | Serviço | Acesso |
|---|---|---|
| `POST /auth/login` | Lambda `authenticate` | Público |
| `ANY /mechanical-hub/{proxy+}` | `orders` | Público (token de aprovação validado no serviço) |
| `POST /webhooks/payment` | `billing` | Público (assinatura `x-signature` validada no serviço) |
| `ANY /orders`, `ANY /orders/{proxy+}` | `orders` | `MECHANICAL`, `ADMINISTRATOR` |
| `GET /services` | `orders` | `MECHANICAL`, `ADMINISTRATOR` |
| `ANY /stock`, `ANY /stock/{proxy+}` | `stock` | `ADMINISTRATOR` |
| `GET /transaction/{orderId}` *(opcional, `expose_orchestrator_transaction = true`)* | `orchestrator` | `ADMINISTRATOR` |
| qualquer outra | — | **Negada** pelo próprio gateway (rota inexistente) |

- Rotas protegidas repassam `x-user-id`, `x-user-role` e `x-user-name` ao serviço.
- O webhook repassa `x-signature` e `x-request-id` e o corpo sem alteração (`HTTP_PROXY`).
- `/actuator`, `/swagger-ui` e `/v3` **não passam mais pelo gateway**: os quatro serviços teriam os mesmos caminhos. Health check fica com o NLB; Swagger por `kubectl port-forward`.

### URL do webhook do Mercado Pago

O output `webhook_url` (`<api_base_url>/webhooks/payment`) é a URL a cadastrar nas notificações do painel do Mercado Pago. Ela muda **a cada recriação do API Gateway** (reset do Lab): depois de um `apply` que recriar a API, atualize o painel. O `deploy.yml` publica o valor no resumo da execução.

---

## 🛠️ Tecnologias

| Camada | Tecnologia |
|---|---|
| Linguagem | TypeScript 5.5 |
| Runtime | Node.js 20.x (`nodejs20.x` na AWS Lambda) |
| Autenticação/hash | `jsonwebtoken` (JWT HS256) + `bcryptjs` |
| Banco de dados | `pg` (cliente PostgreSQL puro, sem ORM) |
| Segredos | Variável de ambiente (lab) ou `@aws-sdk/client-secrets-manager` (produção) |
| Bundler | esbuild |
| Testes | Vitest + `@vitest/coverage-v8` (mínimo 80% de cobertura) |
| IaC | Terraform >= 1.5, provider AWS ~> 5.0 |
| Nuvem | AWS Lambda + API Gateway (REST) |
| CI/CD | GitHub Actions |

---

## 🏗️ Arquitetura deste repositório

Recursos provisionados aqui (Terraform em `infra/terraform/`) e como eles se conectam ao que os outros repositórios provisionam:

```mermaid
flowchart LR
    CLI["Funcionário da oficina"]
    CLIENTE["Cliente final"]
    MP["Mercado Pago"]

    subgraph GW["API Gateway — recursos deste repositório"]
        LOGIN["POST /auth/login"]
        AUTHZ["REQUEST Authorizer"]
        PROT["/orders · /services · /stock<br/>/transaction (opcional)"]
        PUB["/mechanical-hub/{proxy+}<br/>POST /webhooks/payment"]
        LINK["VPC Link"]
    end

    LAUTH["Lambda authenticate"]
    LAZ["Lambda authorize"]
    SG["Security group deste repositório<br/>egress 5432 por CIDR"]
    RDS[("RDS do orders<br/>(auth_database, mechanical-hub-database)")]

    subgraph NLB["NLB interno — mechanical-hub-infra (um listener por serviço)"]
        ORD["orders :30080"]
        STK["stock :30081"]
        BIL["billing :30082"]
        ORC["orchestrator :30083"]
    end

    CLI -->|"POST /auth/login"| LOGIN --> LAUTH -->|"SELECT users, profiles"| SG --> RDS
    CLI -->|"Bearer"| PROT --> AUTHZ --> LAZ -->|"Allow/Deny + claims"| AUTHZ
    CLIENTE --> PUB
    MP --> PUB
    AUTHZ -->|"HTTP_PROXY + x-user-*"| LINK
    PUB -->|"HTTP_PROXY"| LINK
    LINK --> ORD & STK & BIL & ORC
```

Visão geral da plataforma na Fase 3 (antes da divisão em serviços), mantida como referência histórica:

![Diagrama da Arquitetura Alto Nível da Fase 3](mechanical-hub-diagram.png)

O desenho completo da plataforma (as quatro repositórios, nuvem, banco e observabilidade) está em `docs/ARCHITECTURE.md` no repositório `mechanical-hub`.

---

## Arquitetura do código

O código é dividido em três camadas, e a dependência aponta sempre para dentro:

```
src/
├── core/            ← regra de negócio. Não importa nada de AWS, HTTP ou banco.
│   ├── domain/         validação de CPF, erros, perfis, matriz de acesso
│   ├── ports/          interfaces (UserRepository, TokenService, SecretProvider, ...)
│   └── usecases/       authenticate-user, authorize-access
│
├── adapters/        ← implementações das portas
│   ├── persistence/    PostgreSQL via pg
│   ├── secrets/        variável de ambiente | AWS Secrets Manager | cache
│   ├── security/       JWT (HS256) e BCrypt
│   ├── ratelimit/      contador de tentativas
│   └── observability/  log JSON estruturado
│
├── entrypoints/
│   ├── http/           contrato HTTP neutro + controllers
│   └── aws-lambda/     ÚNICO lugar que conhece o formato de evento da AWS
│
└── composition/     ← raiz de composição (config + container)
```

**Migrar para outro provedor** (Azure Functions, Cloud Functions, Knative) significa escrever um novo diretório em `entrypoints/` e um novo `SecretProvider`. `core/`, `adapters/security`, `adapters/persistence` e os testes não mudam.

Nada em `core/` importa `aws-lambda`, `@aws-sdk` ou `process.env` — essa é a linha que não deve ser cruzada em nenhuma alteração futura.

---

## Restrições do AWS Academy Lab

O laboratório impõe limitações que moldaram decisões concretas:

| Limitação | Decisão |
|---|---|
| Não é possível criar IAM roles | O Terraform recebe o ARN da `LabRole` já existente via variável |
| Secrets Manager indisponível | `SECRET_PROVIDER=environment` — segredos em variável de ambiente da função. O adaptador de Secrets Manager já está implementado para produção; é trocar uma variável |
| RDS Proxy indisponível (exige role própria) | Conexão direta ao RDS, com pool limitado a **2 conexões por instância** |
| Sem concorrência provisionada | Cold start mitigado por bundle enxuto (esbuild), inicialização fora do handler e 512 MB de memória |
| Credenciais temporárias que expiram | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` e `AWS_SESSION_TOKEN` precisam ser atualizados a cada sessão do lab antes de rodar o deploy |

---

## Executando localmente

```bash
npm ci
cp .env.example .env      # preencha DATABASE_* e TOKEN_SIGNING_KEY

npm run typecheck
npm test
npm run test:coverage     # falha se a cobertura cair abaixo de 80%
npm run build             # bundles em dist/
npm run package           # zips em build/
```

---

## Contrato da API

### `POST /auth/login`

```json
{ "cpf": "529.982.247-25", "password": "senha-do-funcionario" }
```

**200**
```json
{ "accessToken": "eyJhbGciOiJIUzI1NiIs...", "tokenType": "Bearer", "expiresIn": 7200 }
```

**Erros** — corpo sempre no formato `{ error, message, traceId }`:

| Situação | HTTP | `error` |
|---|---|---|
| Corpo ausente ou campo faltando | 400 | `INVALID_REQUEST` |
| CPF com dígito verificador inválido | 400 | `INVALID_CPF` |
| CPF inexistente **ou** senha incorreta | 401 | `INVALID_CREDENTIALS` |
| Funcionário desativado | 403 | `USER_INACTIVE` |
| Tentativas excedidas | 429 | `TOO_MANY_ATTEMPTS` |
| Falha interna | 500 | `INTERNAL_ERROR` |

> CPF inexistente e senha errada devolvem a mesma resposta, e ambos passam pelo mesmo custo de tempo (comparação BCrypt descartável). Sem isso seria possível descobrir quais CPFs estão cadastrados medindo latência.

**Swagger/Postman:** este repositório não expõe uma API CRUD — apenas os dois contratos acima (`POST /auth/login` e o Authorizer). Não há Swagger próprio; cada serviço tem o seu, acessível por `kubectl port-forward` (não passa pelo gateway). Os exemplos de request/response desta seção podem ser colados diretamente em Postman/Insomnia.

### Claims do token

```json
{
  "iss": "mechanical-hub-auth",
  "sub": "<uuid do funcionário>",
  "aud": "mechanical-hub-api",
  "cpf": "52998224725",
  "name": "Maria Silva",
  "role": "ADMINISTRATOR",
  "iat": 1753600000,
  "exp": 1753607200,
  "jti": "<uuid>"
}
```

`role` ∈ `{ MECHANICAL, ADMINISTRATOR }` — o valor canônico de `profiles.name`.

---

## Matriz de acesso

Vive em `src/core/domain/access-policy.ts` e é coberta por teste unitário (cada rota × perfil). **Espelha as rotas do API Gateway (`local.routes`) — as duas mudam juntas.** A avaliação é por primeira regra que casa, com as mais específicas primeiro.

| Rota | Métodos | Acesso |
|---|---|---|
| `/auth/login` | `POST` | Público |
| `/mechanical-hub/service-orders/**` | todos | Público (cliente final) |
| `/webhooks/payment` | `POST` | Público (Mercado Pago) |
| `/transaction/*` | `GET` | `ADMINISTRATOR` |
| `/stock/**` (inclui `/stock`) | todos | `ADMINISTRATOR` |
| `/orders/**` (inclui `/orders`) | todos | `MECHANICAL` ou `ADMINISTRATOR` |
| `/services` | `GET` | `MECHANICAL` ou `ADMINISTRATOR` (antes só admin) |
| qualquer outra | — | **Negada** (default deny) |

As rotas do monolito (`/users`, `/customers`, `/vehicles`, `/materials`, `/reports`, `/service-orders`) e as de operação/documentação saíram da matriz.

---

## Contrato de banco

A função lê `users` e `profiles` no **banco do `orders`** (output `auth_database` do `mechanical-hub-database`), e **nunca escreve**. O dono do schema é o `mechanical-hub-orders` (migrations Flyway e seeds — sem cadastro de funcionários pela API, as seeds são a origem dos dados).

Colunas do contrato: `users.id`, `users.name`, `users.document_number`, `users.password_hash`, `users.deleted_at`, `users.profile_id`, `profiles.name` (`ADMINISTRATOR` ou `MECHANICAL`).

Antes do primeiro deploy:

1. Criar a role `mechanical_hub_auth` (só `LOGIN` e `CONNECT`) pelo `mechanical-hub-database` (`sql/auth-database-role.sql`), **antes** do primeiro deploy do `orders`.
2. Fazer o deploy do `orders`: as migrations dele criam `users`/`profiles`, as seeds e o `GRANT SELECT` para `mechanical_hub_auth`.

A senha usada ali (secret `AUTH_DB_PASSWORD` do `mechanical-hub-database`) precisa ser a mesma informada aqui em `TF_VAR_database_password`.

`deleted_at` é a única fonte de verdade sobre atividade do funcionário: `NULL` = ativo. Não existe coluna `status`.

---

## Deploy

```bash
npm run package

cd infra/terraform
cp terraform.tfvars.example terraform.tfvars   # preencha os buckets de state
export TF_VAR_database_password='...'
export TF_VAR_token_signing_key='...'

# bucket e região do backend não são versionados — vêm no init
terraform init \
  -backend-config="bucket=<bucket-de-state>" \
  -backend-config="region=us-east-1"

terraform plan
terraform apply
```

O workflow `.github/workflows/deploy.yml` faz o mesmo automaticamente no push para `main`, roda o smoke test (`scripts/smoke-test.sh`) e publica `api_base_url`, `login_url` e `webhook_url` no resumo da execução.

### Ordem de deploy

`infra` → `database` (apply + usuários/role) → **os 4 serviços** (`orders`, `stock`, `billing`, `orchestrator`) com targets saudáveis no NLB → **`auth`** → configurar `webhook_url` no Mercado Pago.

O `apply` deste repositório só depende dos states de `infra` e `database`, mas o smoke test passa pelos serviços:

| Verificação | Esperado | Prova |
|---|---|---|
| Login com credencial inválida | `401` (ou `429`) | Função no ar e alcançando o banco |
| Login com `SMOKE_TEST_CPF` | `200` + JWT | Seeds do `orders` e `GRANT SELECT` aplicados |
| `GET /orders` com token | `200` | Autorizador + roteamento até o `orders` |
| `GET /orders` sem token | `401` | Autorizador barrando |
| `POST /webhooks/payment` sem assinatura | `401` vindo do `billing` | Rota pública roteada até o serviço |

### Secrets do repositório

| Secret | Uso |
|---|---|
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` | Credenciais temporárias do lab |
| `LAB_ROLE_ARN` | ARN da LabRole |
| `TF_STATE_BUCKET` | Bucket S3 do state — usado no backend e na leitura dos states de `infra` e `database` |
| `DATABASE_PASSWORD` | Senha da role de banco (a mesma do `AUTH_DB_PASSWORD` no `mechanical-hub-database`) |
| `TOKEN_SIGNING_KEY` | Chave HS256 (mínimo 32 caracteres) |
| `SMOKE_TEST_CPF`, `SMOKE_TEST_PASSWORD` | Funcionário das seeds do `orders`, para o login e o `GET /orders` do smoke test (sem eles, essas duas verificações são puladas com aviso) |

> **`VPC_SUBNET_IDS`, `VPC_SECURITY_GROUP_IDS`, `DATABASE_HOST` e `APPLICATION_BASE_URL` não são mais necessários.** Podem ser removidos do repositório. Os endereços dos serviços são resolvidos do state do `mechanical-hub-infra` (`app_backend_base_urls`) — ver seção abaixo.

---

## Dependência entre repositórios

Este repositório **lê os states remotos** dos dois que vêm antes dele na ordem de provisionamento, conforme a ADR-0002 — nada de rede ou de endereço de banco é informado à mão:

| Origem | Outputs consumidos | Vira |
|---|---|---|
| `mechanical-hub-infra` | `vpc_id`, `private_subnet_ids` | VPC do security group e subnets das funções |
| `mechanical-hub-infra` | `app_nlb_arn` | Alvo do VPC Link (`aws_api_gateway_vpc_link`) — um só para os 4 serviços |
| `mechanical-hub-infra` | `app_backend_base_urls` (mapa por serviço) | `uri` das integrações `HTTP_PROXY` de cada rota |
| `mechanical-hub-infra` | `otlp_vpc_endpoint` (opcional) | Endereço do coletor OpenTelemetry |
| `mechanical-hub-database` | `auth_database` (`endpoint`, `port`, `db_name`) | `DATABASE_HOST`, `DATABASE_PORT`, `DATABASE_NAME` — RDS do `orders` |

Ordem de **dependência de state**: `infra` → `database` → **`auth`**.

**Sobre `app_nlb_arn`/`app_backend_base_urls`:** não dependem dos serviços já terem feito deploy — o NLB e os listeners são provisionados pelo `mechanical-hub-infra` (não pelo Kubernetes) e existem assim que `infra` aplica, ainda que sem alvos saudáveis até os serviços subirem. Por isso o `terraform apply` deste repositório nunca fica bloqueado esperando os serviços. Uma rota que aponte para um serviço ausente do mapa falha no `plan` (precondition da integração).

**Isso não muda a ordem para o smoke test**, que passa pelo NLB até `orders` e `billing` — ver [Ordem de deploy](#ordem-de-deploy).

**O que isso resolve no ciclo do Lab.** A cada reset do ambiente, subnets e endpoint do RDS mudam. Antes, era preciso reeditar três secrets no GitHub antes de qualquer deploy funcionar. Agora a pipeline lê os valores atuais sozinha.

**O que continua vindo de secret.** `database_password` e `token_signing_key`. Output de Terraform fica gravado em claro no arquivo de state — valor sensível não trafega por ali.

**Security group.** Criado *neste* repositório (`network.tf`), com egress apenas na porta do banco, restrito ao CIDR da VPC. A ADR-0002 rejeitou explicitamente criá-lo no `mechanical-hub-infra`: seria um recurso órfão, pertencente conceitualmente a `auth`. O banco libera acesso por CIDR das subnets privadas, então não precisa conhecer este SG — é o que evita a dependência circular, já que `database` é aplicado antes de `auth`.

### Overrides locais

Todas as variáveis de rede e de banco continuam existindo com default vazio. Preenchidas, têm precedência sobre o state — útil para apontar para um ambiente avulso ou destravar um deploy com state indisponível:

```bash
export TF_VAR_vpc_subnet_ids='["subnet-aaa","subnet-bbb"]'
export TF_VAR_database_host='meu-rds.us-east-1.rds.amazonaws.com'
```

Os outputs `resolved_vpc_id`, `resolved_subnet_ids`, `resolved_database_host` e `resolved_app_backend_urls` mostram o que foi efetivamente usado — vale conferir depois de um reset do Lab.

---

## Observabilidade

Uma linha JSON por evento em stdout, coletada pelo CloudWatch:

```json
{"timestamp":"2026-07-29T16:30:00.000Z","level":"warn","service":"mechanical-hub-auth",
 "event":"login.failed","reason":"INVALID_CREDENTIALS","cpfMasked":"***.***.247-25","traceId":"..."}
```

Eventos: `login.attempt`, `login.success`, `login.failed`, `login.blocked`, `login.error`, `authorizer.allow`, `authorizer.deny`, `authorizer.error`.

Senha nunca é registrada. CPF só aparece mascarado (`***.***.247-25`).

---

## Pontos de atenção conhecidos

- **Cache do authorizer (300s):** desativar um funcionário leva até 5 minutos + o tempo restante do token para surtir efeito. Aceito nesta fase; uma lista de revogação por `jti` resolveria.
- **Limitador de tentativas em memória:** o contador é por instância de execução, não global. A contenção real de volume é o throttling do API Gateway. Trocar por armazenamento distribuído é implementar a porta `AttemptLimiter`.
- **Os serviços confiam nos cabeçalhos do Gateway.** Eles precisam ser inalcançáveis fora do Gateway (NLB interno + Security Group restrito), senão qualquer um que chegue ao pod forja `x-user-role` e vira administrador.
- **`scripts/demo-auth.sh` ainda usa as rotas da Fase 3** (`/service-orders`, `/customers`) — o smoke test da Fase 4 é `scripts/smoke-test.sh`.
- **Chave HS256 compartilhada:** rotacionar exige janela de aceitação dupla, senão os tokens em circulação quebram.
