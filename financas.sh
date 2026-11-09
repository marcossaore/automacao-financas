#!/bin/sh
#
# financas.sh — recebe notificações de bancos (via Atalhos do iOS) e lança no Firefly III.
#
# Comandos:
#   financas.sh analisar      valida a notificação e diz ao Atalhos o que fazer (JSON)
#   financas.sh lancar        lança a transação (com categoria e parcelas)
#   financas.sh --categorias  lista as categorias, uma por linha
#   (sem comando = lancar, para compatibilidade)
#
# Entrada (stdin ou 1 parâmetro), um item por linha:
#   App
#   Corpo da notificação   (pode ter várias linhas)
#   Data (ISO 8601)
#   Categoria              (só no "lancar"; pode ficar vazia)
#   Parcelas               (só no "lancar"; 1 a 18, "Recorrente" ou vazio = 1)
#   Conta                  (só no "lancar" com categoria Contas: nome da conta/bill)
#
# Mensagens suportadas:
#   Inter  compra no débito  -> despesa da conta Inter
#   Inter  Pix enviado       -> se o valor bater com uma recorrência ativa, não lança
#                               (o Firefly já lança sozinho); senão, despesa da conta Inter
#   C6     compra no cartão  -> despesa do cartão C6, à vista, parcelada (1 a 18x) ou
#                               recorrente (cria uma transação recorrente mensal no Firefly)
#   Categoria "Contas" ou "Contas da casa": vincula a transação à conta (bill) com o
#   nome enviado na 6ª linha; se a conta não existir, ela é criada.
# Qualquer outra coisa vai para financas-pendentes.log para análise.
#
# Configuração em .env na pasta do script (ou ~/.financas.env):
#   FIREFLY_URL, FIREFLY_TOKEN                     obrigatórios
#   FIREFLY_CONTA_INTER="Inter"                    opcional
#   FIREFLY_CONTA_C6="C6 Cartão"                   opcional
#
# Teste sem enviar:  FIREFLY_DRY_RUN=1 ./financas.sh lancar < exemplo.txt
# Requer: curl, jq

set -eu

# --- Configuração ------------------------------------------------------------
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
CONTA_C6="${FIREFLY_CONTA_C6:-C6 Cartão}"
DRY_RUN="${FIREFLY_DRY_RUN:-0}"
MAX_PARCELAS=18

# Categorias oferecidas no Atalhos
CATEGORIAS="Mercado
Alimentação
Transporte
Combustível
Moradia
Contas
Contas da casa
Saúde
Educação
Lazer
Compras
Assinaturas
Transferências
Outros"

# --- Comando -----------------------------------------------------------------
case "${1:-}" in
    --categorias) printf '%s\n' "$CATEGORIAS"; exit 0 ;;
    analisar|lancar) MODO=$1; shift ;;
    *) MODO=lancar ;;
esac

# --- Utilitários -------------------------------------------------------------
RESP=$(mktemp)
trap 'rm -f "$RESP"' EXIT

agora() { date '+%Y-%m-%d %H:%M:%S'; }
log()   { printf '%s %s\n' "$(agora)" "$*" >> "$LOG"; }
falha() { log "ERRO: $*"; echo "ERRO: $*"; exit 1; }

# "R$ 1.234,56." -> "1234.56"
normaliza_valor() { printf '%s' "$1" | sed 's/[^0-9,]//g; s/,/./'; }
# "1234.56" -> "R$ 1234,56"
valor_br() { printf 'R$ %s' "$(printf '%s' "$1" | sed 's/\./,/')"; }
# Remove espaços e ponto final das pontas
limpa() { printf '%s' "$1" | sed 's/^ *//; s/[ .]*$//'; }
# Centavos <-> decimal, para dividir parcelas sem erro de arredondamento
centavos() { printf '%s' "$1" | awk '{ printf "%d", $1 * 100 + 0.5 }'; }
decimal()  { printf '%s' "$1" | awk '{ printf "%.2f", $1 / 100 }'; }

# soma_meses AAAA-MM-DD N — soma N meses limitando ao último dia do mês
# (31/01 + 1 mês = 28/02, e não 03/03 como faria o "date -d +1 month").
soma_meses() {
    printf '%s' "$1" | awk -F- -v n="$2" '{
        y = $1 + 0; m = $2 + n; d = $3 + 0
        y += int((m - 1) / 12); m = (m - 1) % 12 + 1
        dias = (m == 2) ? ((y % 4 == 0 && y % 100 != 0) || y % 400 == 0 ? 29 : 28) \
             : (m == 4 || m == 6 || m == 9 || m == 11) ? 30 : 31
        if (d > dias) d = dias
        printf "%04d-%02d-%02d", y, m, d
    }'
}

# Chamada à API: api MÉTODO CAMINHO [JSON]. Define HTTP_STATUS; corpo em $RESP.
api() {
    if [ -n "${3:-}" ]; then
        HTTP_STATUS=$(curl -sS -o "$RESP" -w '%{http_code}' -X "$1" "$FIREFLY_URL$2" \
            -H "Authorization: Bearer $FIREFLY_TOKEN" \
            -H 'Accept: application/vnd.api+json' \
            -H 'Content-Type: application/json' \
            --data "$3") || HTTP_STATUS=000
    else
        HTTP_STATUS=$(curl -sS -o "$RESP" -w '%{http_code}' -X "$1" "$FIREFLY_URL$2" \
            -H "Authorization: Bearer $FIREFLY_TOKEN" \
            -H 'Accept: application/vnd.api+json') || HTTP_STATUS=000
    fi
}

requer_firefly() {
    : "${FIREFLY_URL:?defina FIREFLY_URL no .env (pasta do script)}"
    : "${FIREFLY_TOKEN:?defina FIREFLY_TOKEN no .env (pasta do script)}"
}

# Mensagem não reconhecida: guarda crua para criarmos regras depois.
nao_reconhecido() {
    { echo "=== $(agora) | $1 ==="; printf '%s\n' "$ENTRADA"; } >> "$PENDENTES"
    log "PENDENTE ($1): ${APP:-?}"
    if [ "$MODO" = analisar ]; then
        jq -n --arg m "Notificação não reconhecida: $1" '{acao: "ignorar", mensagem: $m}'
    else
        echo "Não lançado: $1"
    fi
    exit 0
}

# --- 1. Lê a entrada ---------------------------------------------------------
if [ "$#" -ge 1 ]; then ENTRADA=$1; else ENTRADA=$(cat); fi
ENTRADA=$(printf '%s\n' "$ENTRADA" | tr -d '\r' | sed '/./,$!d')
APP=$(printf '%s\n' "$ENTRADA" | sed -n 1p)

linha() { printf '%s\n' "$ENTRADA" | sed -n "$1"; }

# A linha da data (ISO 8601) separa o corpo da categoria e das parcelas
IDX_DATA=$(printf '%s\n' "$ENTRADA" | grep -nE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' | tail -n1 | cut -d: -f1 || true)
[ -n "$IDX_DATA" ] && [ "$IDX_DATA" -ge 3 ] \
    || nao_reconhecido "formato inválido: esperava App, Corpo e Data em linhas separadas"

# Junta as linhas do corpo e normaliza espaços (quebras do Atalhos/cópia viram um espaço)
CORPO=$(linha "2,$((IDX_DATA - 1))p" | tr '\n\t' '  ' | tr -s ' ' | sed 's/^ //; s/ $//')
DATA=$(linha "${IDX_DATA}p")
CATEGORIA=$(linha "$((IDX_DATA + 1))p")
PARCELAS=$(linha "$((IDX_DATA + 2))p")
CONTA_NOME=$(linha "$((IDX_DATA + 3))p")

# --- 2. Interpreta por banco -------------------------------------------------
# Cada parser preenche: MSG (compra|pix), VALOR, ORIGEM, DESTINO, PERMITE_PARCELAS
parse_inter() {
    PERMITE_PARCELAS=nao; ORIGEM=$CONTA_INTER

    # "Olá <nome>, você acaba de comprar no débito no(a) <local> o valor de <valor>"
    # (o Inter também escreve "no", "na" ou "em" no lugar de "no(a)")
    LOCAL=$(printf '%s' "$CORPO" | sed -En 's/.*comprar no d[^ ]*bito (no\(a\)|no|na|em) (.*) o valor de .*/\2/p')
    if [ -n "$LOCAL" ]; then
        MSG=compra
        VALOR=$(printf '%s' "$CORPO" | sed -n 's/.* o valor de \(.*\)/\1/p')
        DESTINO=$(limpa "$LOCAL")
        return 0
    fi

    # "Você fez um Pix no valor de <valor> para <local>"
    LOCAL=$(printf '%s' "$CORPO" | sed -n 's/.*fez um Pix no valor de .* para \(.*\)/\1/p')
    if [ -n "$LOCAL" ]; then
        MSG=pix
        VALOR=$(printf '%s' "$CORPO" | sed -n 's/.*fez um Pix no valor de \(.*\) para .*/\1/p')
        DESTINO=$(limpa "$LOCAL")
        return 0
    fi

    return 1
}

parse_c6() {
    # "Sua compra no cartão final <final> no valor de R$ <valor>, dia <dd/mm/aaaa> às <hh:mm>,
    #  em <local>, foi aprovada."
    LINHA_C6=$(printf '%s' "$CORPO" | sed -n \
        's/.*compra no cart[^ ]* final \([0-9]*\) *no valor de \(R[$] *[0-9.]*,[0-9][0-9]\), dia .*, em \(.*\), foi aprovada.*/\1|\2|\3/p')
    [ -n "$LINHA_C6" ] || return 1

    MSG=compra
    PERMITE_PARCELAS=sim   # todas as compras do C6 são no crédito
    ORIGEM=$CONTA_C6
    FINAL_CARTAO=$(printf '%s' "$LINHA_C6" | cut -d'|' -f1)
    VALOR=$(printf '%s' "$LINHA_C6" | cut -d'|' -f2)
    DESTINO=$(limpa "$(printf '%s' "$LINHA_C6" | cut -d'|' -f3-)")
    return 0
}

FINAL_CARTAO=""
case "$(printf '%s' "$APP" | tr '[:upper:]' '[:lower:]')" in
    *inter*) parse_inter || nao_reconhecido "Inter: formato não reconhecido" ;;
    *c6*)    parse_c6    || nao_reconhecido "C6: formato não reconhecido" ;;
    *)       nao_reconhecido "app ainda não suportado" ;;
esac

VALOR=$(normaliza_valor "$VALOR")
[ -n "$VALOR" ] || nao_reconhecido "valor não encontrado"

# --- 3. analisar: decide o que o Atalhos deve fazer --------------------------

# Nome da recorrência ativa (despesa) com exatamente este valor, ou vazio.
recorrencia_com_valor() {
    api GET "/api/v1/recurrences?limit=100"
    if [ "$HTTP_STATUS" != 200 ]; then
        log "AVISO: não consegui consultar recorrências (HTTP $HTTP_STATUS)"
        return 0
    fi
    jq -r --arg v "$1" '
        [ .data[].attributes
          | select(.active != false and .type == "withdrawal")
          | select(any(.transactions[]?; (.amount | tonumber) == ($v | tonumber)))
          | .title ] | first // empty' "$RESP"
}

# --- Contas (bills) do Firefly ----------------------------------------------
# Versões novas da API usam /subscriptions; as antigas, /bills.
NOVA_CONTA="+ Nova conta"
EP_CONTAS=""
lista_contas() {   # lista em $RESP; retorna 1 se a API falhar
    if [ -z "$EP_CONTAS" ]; then
        EP_CONTAS=/api/v1/subscriptions
        api GET "$EP_CONTAS?limit=100"
        if [ "$HTTP_STATUS" = 404 ]; then EP_CONTAS=/api/v1/bills; api GET "$EP_CONTAS?limit=100"; fi
    else
        api GET "$EP_CONTAS?limit=100"
    fi
    [ "$HTTP_STATUS" = 200 ] || { log "AVISO: não consegui consultar as contas (HTTP $HTTP_STATUS)"; return 1; }
}

# Nomes das contas ativas, um por linha
nomes_contas() {
    lista_contas || return 0
    jq -r '.data[] | select(.attributes.active != false) | .attributes.name' "$RESP"
}

# busca_conta NOME — define CONTA_ID (vazio se não existe); retorna 1 se a API falhar
busca_conta() {
    CONTA_ID=""
    lista_contas || return 1
    ACHADA=$(jq -r --arg n "$1" '[ .data[]
        | select((.attributes.name | ascii_downcase) == ($n | ascii_downcase))
        | "\(.id)|\(.attributes.name)" ] | first // empty' "$RESP")
    if [ -n "$ACHADA" ]; then
        CONTA_ID=${ACHADA%%|*}; CONTA_NOME=${ACHADA#*|}   # grafia como está no Firefly
    fi
}

# cria_conta NOME VALOR DATA — conta mensal com faixa de ±30% do valor; define CONTA_ID
cria_conta() {
    MIN=$(printf '%s' "$2" | awk '{ printf "%.2f", $1 * 0.7 }')
    MAX=$(printf '%s' "$2" | awk '{ printf "%.2f", $1 * 1.3 }')
    BODY=$(jq -n --arg n "$1" --arg min "$MIN" --arg max "$MAX" --arg d "$3" '{
        name: $n, amount_min: $min, amount_max: $max, date: $d,
        repeat_freq: "monthly", skip: 0, active: true }')
    api POST "$EP_CONTAS" "$BODY"
    case "$HTTP_STATUS" in
        200|201) CONTA_ID=$(jq -r '.data.id' "$RESP")
                 log "CONTA criada: $1 (faixa $(valor_br "$MIN") a $(valor_br "$MAX"))" ;;
        *)       falha "não consegui criar a conta '$1' (HTTP $HTTP_STATUS): $(cat "$RESP")" ;;
    esac
}

if [ "$MODO" = analisar ]; then
    if [ "$MSG" = pix ] && [ "$DRY_RUN" != 1 ]; then
        requer_firefly
        RECORRENTE=$(recorrencia_com_valor "$VALOR")
        if [ -n "$RECORRENTE" ]; then
            log "RECORRENTE: Pix $(valor_br "$VALOR") -> $DESTINO bate com '$RECORRENTE'; não lançado"
            jq -n --arg m "Pix de $(valor_br "$VALOR") para $DESTINO corresponde à recorrência \"$RECORRENTE\". O Firefly já lança essa despesa; nada a fazer." \
                '{acao: "recorrente", mensagem: $m}'
            exit 0
        fi
    fi

    if [ "$MSG" = pix ]; then DESC_MSG="Pix de $(valor_br "$VALOR") para $DESTINO"
    else DESC_MSG="Compra de $(valor_br "$VALOR") em $DESTINO"; fi

    CONTAS=""
    if [ "$DRY_RUN" != 1 ]; then requer_firefly; CONTAS=$(nomes_contas); fi

    jq -n --arg m "$DESC_MSG" --arg pp "$PERMITE_PARCELAS" --arg cats "$CATEGORIAS" \
          --arg contas "$CONTAS" --arg nova "$NOVA_CONTA" --argjson max "$MAX_PARCELAS" '{
        acao: "escolher",
        mensagem: $m,
        pedir_parcelas: $pp,
        categorias: ($cats | split("\n")),
        parcelas: ([range(1; $max + 1) | tostring] + ["Recorrente"]),
        contas: (($contas | split("\n") | map(select(. != ""))) + [$nova])
    }'
    exit 0
fi

# --- 4. lancar ---------------------------------------------------------------

# Interpreta as parcelas: N (1..18) ou "recorrente"
case "$(printf '%s' "$PARCELAS" | tr '[:upper:]' '[:lower:]')" in
    ""|1)        N=1 ;;
    recorrente*) N=recorrente ;;
    *[!0-9]*)    falha "parcelas inválidas: '$PARCELAS' (use 1 a $MAX_PARCELAS ou Recorrente)" ;;
    *)           N=$PARCELAS
                 [ "$N" -ge 1 ] && [ "$N" -le "$MAX_PARCELAS" ] \
                     || falha "parcelas fora do intervalo: $N (use 1 a $MAX_PARCELAS)" ;;
esac
if [ "$PERMITE_PARCELAS" = nao ] && [ "$N" != 1 ]; then
    log "AVISO: '$PARCELAS' ignorado; $APP $MSG não aceita parcelas"
    N=1
fi

# Categoria Contas: vincula à conta (bill) com o nome enviado; cria se não existir
BILL_ID=""; BILL_NOME=""; CONTA_CRIADA=""
case "$CATEGORIA" in
    [Cc]ontas|[Cc]ontas\ da\ casa)
        # grafia padrão, para não criar categoria duplicada no Firefly
        case "$CATEGORIA" in [Cc]ontas) CATEGORIA="Contas" ;; *) CATEGORIA="Contas da casa" ;; esac
        [ "$CONTA_NOME" != "$NOVA_CONTA" ] || falha "informe o nome da nova conta (veio '$NOVA_CONTA')"
        if [ -z "$CONTA_NOME" ]; then
            log "AVISO: categoria $CATEGORIA sem nome de conta; lançado sem vínculo"
        elif [ "$N" != 1 ]; then
            log "AVISO: categoria $CATEGORIA com parcelas/recorrente; não vinculado à conta $CONTA_NOME"
        elif [ "$DRY_RUN" = 1 ]; then
            log "dry-run: vínculo com a conta '$CONTA_NOME' pulado"
        else
            requer_firefly
            busca_conta "$CONTA_NOME" || falha "não consegui consultar as contas no Firefly"
            if [ -z "$CONTA_ID" ]; then
                cria_conta "$CONTA_NOME" "$VALOR" "$(printf '%s' "$DATA" | cut -c1-10)"
                CONTA_CRIADA=" (criada agora)"
            fi
            BILL_ID=$CONTA_ID; BILL_NOME=$CONTA_NOME
        fi ;;
esac

TAGS_BASE=$(jq -nc --arg app "$APP" --arg f "$FINAL_CARTAO" \
    '["notificacao", $app] + (if $f != "" then ["final-" + $f] else [] end)')

# lanca_transacao DATA VALOR DESCRICAO TAGS_JSON — POST de uma despesa
lanca_transacao() {
    JSON=$(jq -n \
        --arg data "$1" --arg valor "$2" --arg desc "$3" --argjson tags "$4" \
        --arg origem "$ORIGEM" --arg destino "$DESTINO" \
        --arg cat "$CATEGORIA" --arg corpo "$CORPO" --arg bill "$BILL_ID" '{
          error_if_duplicate_hash: true,
          apply_rules: true,
          transactions: [({
            type: "withdrawal",
            date: $data,
            amount: $valor,
            description: $desc,
            source_name: $origem,
            destination_name: $destino,
            notes: $corpo,
            tags: $tags
          } + (if $cat != "" then {category_name: $cat} else {} end)
            + (if $bill != "" then {bill_id: $bill} else {} end))]
        }')

    if [ "$DRY_RUN" = 1 ]; then
        printf '%s\n' "$JSON"
        return 0
    fi

    api POST /api/v1/transactions "$JSON"
    case "$HTTP_STATUS" in
        200|201) log "OK: $(valor_br "$2") -> $3 ($1)" ;;
        422)     if grep -qi duplicate "$RESP"; then
                     DUPLICADAS=$((DUPLICADAS + 1))
                     log "DUPLICADA (ignorada): $(valor_br "$2") -> $3 ($1)"
                 else
                     falha "Firefly recusou $3: $(cat "$RESP")"
                 fi ;;
        *)       falha "HTTP $HTTP_STATUS ao lançar $3: $(cat "$RESP")" ;;
    esac
}

# recorrencia_existe TITULO — 0 se já existe recorrência com esse título
recorrencia_existe() {
    api GET "/api/v1/recurrences?limit=100"
    [ "$HTTP_STATUS" = 200 ] || return 1
    jq -e --arg t "$1" 'any(.data[]; (.attributes.title | ascii_downcase) == ($t | ascii_downcase))' "$RESP" >/dev/null
}

# conta_id NOME origem|destino — id da conta do Firefly com esse nome, ou vazio
conta_id() {
    api GET "/api/v1/autocomplete/accounts?limit=50&query=$(jq -rn --arg v "$1" '$v | @uri')"
    [ "$HTTP_STATUS" = 200 ] || return 0
    jq -r --arg n "$1" --arg k "$2" '[ .[]
        | select((.name | ascii_downcase) == ($n | ascii_downcase))
        | select(if $k == "destino" then (.type | test("expense|despesa"; "i"))
                 else (.type | test("expense|revenue|despesa|receita"; "i") | not) end)
        | .id ] | first // empty' "$RESP"
}

# cria_recorrencia [SRC_ID DST_ID] — recorrência mensal sem fim a partir do mês que vem.
# A API exige IDs: usa os passados (da transação recém-criada) ou procura pelo nome.
# Não cria se já existir recorrência com o mesmo título (define REC_JA=1).
cria_recorrencia() {
    REC_JA=""
    if [ "$DRY_RUN" = 1 ]; then
        echo "(dry-run) criaria recorrência mensal: $DESTINO $(valor_br "$VALOR") a partir de $PROXIMA"
        return 0
    fi
    if recorrencia_existe "$DESTINO"; then
        REC_JA=1; log "RECORRÊNCIA já existia: $DESTINO"; return 0
    fi
    SRC_ID=${1:-$(conta_id "$ORIGEM" origem)}
    DST_ID=${2:-$(conta_id "$DESTINO" destino)}
    [ -n "$SRC_ID" ] && [ -n "$DST_ID" ] \
        || falha "não encontrei as contas '$ORIGEM' / '$DESTINO' para criar a recorrência"

    # O Firefly exige número de repetições OU data de término; "sem fim" = data distante
    REC=$(jq -n --arg t "$DESTINO" --arg d "$PROXIMA" --arg dia "$DIA" \
        --arg valor "$VALOR" --arg src "$SRC_ID" --arg dst "$DST_ID" --arg cat "$CATEGORIA" \
        --arg ate "${FIREFLY_RECORRENCIA_ATE:-2099-12-31}" '{
          type: "withdrawal",
          title: $t,
          first_date: $d,
          repeat_until: $ate,
          apply_rules: true,
          active: true,
          repetitions: [{ type: "monthly", moment: $dia, skip: 0, weekend: 1 }],
          transactions: [({
            description: $t,
            amount: $valor,
            source_id: $src,
            destination_id: $dst
          } + (if $cat != "" then {category_name: $cat} else {} end))]
        }')
    api POST /api/v1/recurrences "$REC"
    case "$HTTP_STATUS" in
        200|201) log "RECORRÊNCIA criada: $DESTINO $(valor_br "$VALOR") todo dia $DIA a partir de $PROXIMA" ;;
        *)       falha "transação lançada, mas a recorrência falhou (HTTP $HTTP_STATUS): $(cat "$RESP")" ;;
    esac
}

[ "$DRY_RUN" = 1 ] || requer_firefly
BASE=$(printf '%s' "$DATA" | cut -c1-10)
DUPLICADAS=0
JA_EXISTIA="Já lançado anteriormente: $(valor_br "$VALOR") em $DESTINO (nada foi duplicado)"

if [ "$N" = 1 ]; then
    lanca_transacao "$DATA" "$VALOR" "$DESTINO" "$TAGS_BASE"
    if [ "$DUPLICADAS" -gt 0 ]; then echo "$JA_EXISTIA"; exit 0; fi
    echo "Lançado: $(valor_br "$VALOR") em $DESTINO${CATEGORIA:+ [$CATEGORIA]}${BILL_NOME:+ -> conta \"$BILL_NOME\"$CONTA_CRIADA}"

elif [ "$N" = recorrente ]; then
    PROXIMA=$(soma_meses "$BASE" 1)
    DIA=$(printf '%s' "$BASE" | cut -c9-10 | sed 's/^0//')
    lanca_transacao "$DATA" "$VALOR" "$DESTINO" "$(printf '%s' "$TAGS_BASE" | jq -c '. + ["recorrente"]')"
    if [ "$DUPLICADAS" -gt 0 ]; then
        # já lançada antes; garante a recorrência (pode ter falhado na vez anterior)
        cria_recorrencia
        if [ -z "$REC_JA" ] && [ "$DRY_RUN" != 1 ]; then
            echo "Já lançado anteriormente: $(valor_br "$VALOR") em $DESTINO; recorrência mensal criada agora (todo dia $DIA)"
        else
            echo "$JA_EXISTIA"
        fi
        exit 0
    fi
    T_SRC=$(jq -r '.data.attributes.transactions[0].source_id // empty' "$RESP" 2>/dev/null || true)
    T_DST=$(jq -r '.data.attributes.transactions[0].destination_id // empty' "$RESP" 2>/dev/null || true)
    cria_recorrencia "$T_SRC" "$T_DST"
    if [ -n "$REC_JA" ]; then
        echo "Lançado: $(valor_br "$VALOR") em $DESTINO (a recorrência mensal já existia)"
    else
        echo "Lançado: $(valor_br "$VALOR") em $DESTINO, e recorrência mensal criada (todo dia $DIA)"
    fi

else
    # Parcelado: valor da notificação = total. Uma transação por mês;
    # a última parcela absorve a diferença de arredondamento.
    TOTAL_C=$(centavos "$VALOR")
    PARC_C=$((TOTAL_C / N))
    TAGS_PARC=$(printf '%s' "$TAGS_BASE" | jq -c '. + ["parcelado"]')
    k=1
    while [ "$k" -le "$N" ]; do
        if [ "$k" -eq "$N" ]; then V_C=$((TOTAL_C - PARC_C * (N - 1))); else V_C=$PARC_C; fi
        if [ "$k" -eq 1 ]; then D=$DATA; else D=$(soma_meses "$BASE" $((k - 1))); fi
        lanca_transacao "$D" "$(decimal "$V_C")" "$DESTINO ($k/$N)" "$TAGS_PARC"
        k=$((k + 1))
    done
    if [ "$DUPLICADAS" -eq "$N" ]; then echo "$JA_EXISTIA"; exit 0; fi
    echo "Lançado: $(valor_br "$VALOR") em $DESTINO, ${N}x de $(valor_br "$(decimal "$PARC_C")")"
fi
