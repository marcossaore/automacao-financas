#!/bin/sh
#
# financas.sh — recebe uma notificação de receita/despesa e lança no Firefly III.
#
# Entrada (stdin ou 1 parâmetro), texto simples, um item por linha:
#   App
#   Corpo da mensagem   (pode ter várias linhas)
#   Data (ISO 8601)
#   Categoria           (opcional: pode vir vazia)
#
# Bancos suportados: Inter (compra no débito, Pix enviado).
# Qualquer outra coisa só é salva em financas-pendentes.log (na pasta do script) para análise.
#
# Configuração em .env na pasta do script (ou ~/.financas.env):
#   FIREFLY_URL=http://localhost:8080
#   FIREFLY_TOKEN=eyJ0eXAiOi...
#   FIREFLY_CONTA_INTER=Inter          # opcional: nome da conta de ativo no Firefly
#
# Logs ficam na pasta do script (financas.log e financas-pendentes.log).
#
# Teste sem enviar:  FIREFLY_DRY_RUN=1 ./financas.sh < exemplo.txt
# Requer: curl, jq

set -eu

# Configuração: usa o primeiro que existir
#   1) $FINANCAS_ENV   2) .env na pasta do script   3) ~/.financas.env
DIR_SCRIPT=$(cd "$(dirname "$0")" && pwd)
for env in "${FINANCAS_ENV:-}" "$DIR_SCRIPT/.env" "$HOME/.financas.env"; do
    if [ -n "$env" ] && [ -f "$env" ]; then
        . "$env"
        break
    fi
done

LOG="${FINANCAS_LOG:-$DIR_SCRIPT/financas.log}"
PENDENTES="${FINANCAS_PENDENTES:-$DIR_SCRIPT/financas-pendentes.log}"
CONTA_INTER="${FIREFLY_CONTA_INTER:-Inter}"

# Categorias para o Atalhos escolher:  ./financas.sh --categorias
CATEGORIAS="Mercado
Alimentação
Transporte
Combustível
Moradia
Contas da casa
Saúde
Educação
Lazer
Compras
Assinaturas
Transferências
Outros"

if [ "${1:-}" = "--categorias" ]; then
    printf '%s\n' "$CATEGORIAS"
    exit 0
fi

agora() { date '+%Y-%m-%d %H:%M:%S'; }
log()   { printf '%s %s\n' "$(agora)" "$*" >> "$LOG"; }
falha() { log "ERRO: $*"; echo "ERRO: $*" >&2; exit 1; }

# Guarda a notificação crua para criarmos regras depois, sem lançar nada.
pendente() {
    { echo "=== $(agora) | $1 ==="; printf '%s\n' "$ENTRADA"; } >> "$PENDENTES"
    log "PENDENTE ($1): $APP"
    echo "Salvo para análise: $1"
    exit 0
}

# "R$ 1.234,56." -> "1234.56"
normaliza_valor() {
    printf '%s' "$1" | sed 's/[^0-9,]//g; s/,/./'
}

# Remove espaços e ponto final das pontas
limpa() {
    printf '%s' "$1" | sed 's/^ *//; s/[ .]*$//'
}

# --- 1. Lê a entrada -------------------------------------------------------
if [ "$#" -ge 1 ]; then ENTRADA=$1; else ENTRADA=$(cat); fi
ENTRADA=$(printf '%s\n' "$ENTRADA" | tr -d '\r' | sed '/./,$!d')

TOTAL=$(printf '%s\n' "$ENTRADA" | wc -l)
APP=$(printf '%s\n' "$ENTRADA" | sed -n 1p)
[ "$TOTAL" -ge 3 ] || pendente "esperava ao menos 3 linhas, recebi $TOTAL"

linha() { printf '%s\n' "$ENTRADA" | sed -n "$1"; }

# Categoria é opcional: se a última linha já é a data ISO, não veio categoria
if linha "${TOTAL}p" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}'; then
    FIM_CORPO=$((TOTAL - 1)); DATA=$(linha "${TOTAL}p"); CATEGORIA=""
else
    FIM_CORPO=$((TOTAL - 2)); DATA=$(linha "$((TOTAL - 1))p"); CATEGORIA=$(linha "${TOTAL}p")
fi
CORPO=$(linha "2,${FIM_CORPO}p" | tr '\n' ' ' | sed 's/ *$//')
# --- 2. Interpreta por banco -----------------------------------------------
# Cada parser preenche: TIPO, VALOR, LOCAL, ORIGEM, DESTINO
parse_inter() {
    # "Olá <nome>, você acaba de comprar no débito no(a) <local> o valor de <valor>"
    LOCAL=$(printf '%s' "$CORPO" | sed -n 's/.*comprar no d[^ ]*bito no(a) \(.*\) o valor de .*/\1/p')
    if [ -n "$LOCAL" ]; then
        VALOR=$(printf '%s' "$CORPO" | sed -n 's/.* o valor de \(.*\)/\1/p')
        TIPO=withdrawal
        ORIGEM=$CONTA_INTER; DESTINO=$(limpa "$LOCAL")
        return 0
    fi

    # "Você fez um Pix no valor de <valor> para <local>"
    LOCAL=$(printf '%s' "$CORPO" | sed -n 's/.*fez um Pix no valor de .* para \(.*\)/\1/p')
    if [ -n "$LOCAL" ]; then
        VALOR=$(printf '%s' "$CORPO" | sed -n 's/.*fez um Pix no valor de \(.*\) para .*/\1/p')
        TIPO=withdrawal
        ORIGEM=$CONTA_INTER; DESTINO=$(limpa "$LOCAL")
        return 0
    fi

    return 1
}

case "$(printf '%s' "$APP" | tr '[:upper:]' '[:lower:]')" in
    *inter*) parse_inter || pendente "Inter: formato não reconhecido" ;;
    *)       pendente "app ainda não suportado" ;;
esac

VALOR=$(normaliza_valor "$VALOR")
[ -n "$VALOR" ] || pendente "valor não encontrado"
DESCRICAO=$DESTINO

# --- 3. Monta o JSON --------------------------------------------------------
# category_name só vai se veio preenchida; senão, as Regras do Firefly decidem.
JSON=$(jq -n \
    --arg tipo "$TIPO" --arg data "$DATA" --arg valor "$VALOR" \
    --arg desc "$DESCRICAO" --arg origem "$ORIGEM" --arg destino "$DESTINO" \
    --arg cat "$CATEGORIA" --arg app "$APP" --arg corpo "$CORPO" '{
      error_if_duplicate_hash: true,
      apply_rules: true,
      transactions: [({
        type: $tipo,
        date: $data,
        amount: $valor,
        description: $desc,
        source_name: $origem,
        destination_name: $destino,
        notes: $corpo,
        tags: ["notificacao", $app]
      } + (if $cat != "" then {category_name: $cat} else {} end))]
    }')

if [ "${FIREFLY_DRY_RUN:-0}" = 1 ]; then
    printf '%s\n' "$JSON"
    exit 0
fi

# --- 4. Envia para o Firefly III -------------------------------------------
: "${FIREFLY_URL:?defina FIREFLY_URL em ~/.financas.env}"
: "${FIREFLY_TOKEN:?defina FIREFLY_TOKEN em ~/.financas.env}"

RESPOSTA=$(curl -sS -w '\n%{http_code}' -X POST "$FIREFLY_URL/api/v1/transactions" \
    -H "Authorization: Bearer $FIREFLY_TOKEN" \
    -H 'Accept: application/vnd.api+json' \
    -H 'Content-Type: application/json' \
    --data "$JSON") || falha "curl falhou ao chamar $FIREFLY_URL"

STATUS=$(printf '%s' "$RESPOSTA" | tail -n1)
CORPO_RESP=$(printf '%s' "$RESPOSTA" | sed '$d')

case "$STATUS" in
    200|201) log "OK: $TIPO R\$ $VALOR -> $DESTINO"; echo "Lançado: R\$ $VALOR em $DESTINO" ;;
    422)     log "IGNORADO ($STATUS): $CORPO_RESP"; echo "Não lançado (duplicada ou dado inválido)" ;;
    *)       falha "HTTP $STATUS: $CORPO_RESP" ;;
esac
