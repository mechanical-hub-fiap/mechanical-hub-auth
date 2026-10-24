#!/usr/bin/env bash
#
# Smoke test pos-deploy (Fase 4). Roda no deploy.yml depois do apply e pode ser
# executado a mao contra qualquer ambiente:
#
#   API_BASE_URL="$(terraform -chdir=infra/terraform output -raw api_base_url)" \
#   SMOKE_CPF=... SMOKE_PASSWORD=... ./scripts/smoke-test.sh
#
# Cada verificacao prova um trecho do caminho gateway -> VPC Link -> NLB ->
# servico:
#
#   1. login com credencial invalida   -> 401/429  funcao no ar e alcancando o banco
#   2. login com credencial valida     -> 200+JWT  seeds do orders e role de leitura
#   3. GET /orders com token           -> 200      autorizador + roteamento ate o orders
#   4. GET /orders sem token           -> 401      autorizador barrando
#   5. POST /webhooks/payment sem      -> 401      vindo do billing: rota publica
#      assinatura                                  roteada ate o servico
#
# 2 e 3 dependem de SMOKE_CPF/SMOKE_PASSWORD (funcionario das seeds do orders).
# Sem eles, sao puladas com aviso -- as demais continuam valendo.

set -uo pipefail

API="${API_BASE_URL:?API_BASE_URL nao definido}"
SMOKE_CPF="${SMOKE_CPF:-}"
SMOKE_PASSWORD="${SMOKE_PASSWORD:-}"

falhas=0

# Corpo e status na mesma chamada: "corpo\nSTATUS".
chamada() {
  curl -s -w $'\n%{http_code}' --max-time 30 "$@"
}

status_de() { printf '%s' "${1##*$'\n'}"; }

chamada_estavel() {
  local limite=$((SECONDS + ${SMOKE_RETRY_SECONDS:-120})) r s
  while :; do
    r=$(chamada "$@")
    s="$(status_de "${r}")"
    case "${s}" in 5??|000) ;; *) break ;; esac
    [ "${SECONDS}" -ge "${limite}" ] && break
    echo "      ${s} transitorio, nova tentativa em 10 s..." >&2
    sleep 10
  done
  printf '%s' "${r}"
}
corpo_de() { printf '%s' "${1%$'\n'*}"; }

confere() {
  local nome="$1" recebido="$2"
  shift 2

  for esperado in "$@"; do
    if [ "${recebido}" = "${esperado}" ]; then
      echo "ok    ${nome}: ${recebido}"
      return 0
    fi
  done

  echo "FALHA ${nome}: esperado $*, recebido ${recebido}"
  # {"message":"Internal server error"} sozinho = erro do proprio gateway
  # (VPC Link/NLB/target); outro corpo = resposta do servico.
  echo "      corpo: $(corpo_de "${resposta:-}" | head -c 500)"
  falhas=$((falhas + 1))
  return 1
}

echo "API: ${API}"

# Logo apos o apply, o deployment novo e o caminho VPC Link -> NLB levam alguns
# minutos para estabilizar e respondem 500 transitorio (sem nenhum log nos
# servicos). Espera a rota publica do billing sair de 5xx antes de verificar.
aquecimento_limite=$((SECONDS + ${SMOKE_WARMUP_SECONDS:-300}))
while :; do
  status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -X POST "${API}/webhooks/payment" \
    -H 'Content-Type: application/json' -d '{"type":"order","data":{"id":"smoke-warmup"}}')
  case "${status}" in 5??|000) ;; *) echo "gateway estavel (webhook: ${status})"; break ;; esac
  if [ "${SECONDS}" -ge "${aquecimento_limite}" ]; then
    echo "gateway ainda respondendo ${status} apos o aquecimento; seguindo com as verificacoes"
    break
  fi
  echo "aguardando o gateway estabilizar (webhook: ${status})..."
  sleep 10
done

# 1) Credencial invalida. 500 aqui indicaria falha de conexao com o banco.
resposta=$(chamada -X POST "${API}/auth/login" \
  -H 'Content-Type: application/json' \
  -d '{"cpf":"52998224725","password":"senha-propositalmente-errada"}')
confere "login com credencial invalida" "$(status_de "${resposta}")" 401 429

# 2) e 3) Credencial valida e rota protegida com token.
if [ -n "${SMOKE_CPF}" ]; then
  resposta=$(chamada -X POST "${API}/auth/login" \
    -H 'Content-Type: application/json' \
    -d "{\"cpf\":\"${SMOKE_CPF}\",\"password\":\"${SMOKE_PASSWORD}\"}")
  token=$(corpo_de "${resposta}" | sed -n 's/.*"accessToken":"\([^"]*\)".*/\1/p')

  if confere "login com credencial valida" "$(status_de "${resposta}")" 200; then
    # JWT: tres partes base64url separadas por ponto.
    if [[ ! "${token}" =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]]; then
      echo "FALHA login com credencial valida: resposta sem accessToken no formato JWT"
      falhas=$((falhas + 1))
      token=""
    fi
  fi

  if [ -n "${token}" ]; then
    resposta=$(chamada_estavel -X GET "${API}/orders" -H "Authorization: Bearer ${token}")
    confere "GET /orders com token" "$(status_de "${resposta}")" 200
  else
    echo "FALHA GET /orders com token: sem token valido para testar"
    falhas=$((falhas + 1))
  fi
else
  echo "::warning::SMOKE_CPF nao configurado: login valido e GET /orders com token nao foram verificados"
fi

# 4) Rota protegida sem token: o autorizador barra antes de chegar ao orders.
resposta=$(chamada -X GET "${API}/orders")
confere "GET /orders sem token" "$(status_de "${resposta}")" 401

# 5) Webhook sem assinatura. A rota e publica no gateway, entao o 401 so pode
#    vir do billing -- prova o roteamento ate o servico. Um 403 seria o gateway
#    sem a rota; 5xx, o servico ou o VPC Link fora do ar.
resposta=$(chamada -X POST "${API}/webhooks/payment" \
  -H 'Content-Type: application/json' \
  -d '{"type":"order","data":{"id":"smoke-test"}}')
confere "POST /webhooks/payment sem assinatura" "$(status_de "${resposta}")" 401

if [ "${falhas}" -gt 0 ]; then
  echo "${falhas} verificacao(oes) falharam"
  exit 1
fi

echo "Smoke test concluido"
