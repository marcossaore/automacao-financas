#!/bin/sh
#
# importar.sh — importa uma lista de gastos (copiada da planilha) para o Firefly III.
#
# Entrada: arquivo ou stdin, uma despesa por linha, colunas separadas por TAB:
#   data (dd/mm/aaaa)  descrição  categoria  valor (R$ 1.234,56)  meio  tipo
#
#   meio: "débito", "crédito" ou vazio (dinheiro/outros)
#   tipo: recorrente|variável|parcelas  (ou vazio = despesa comum)
#     recorrente|nao              valor fixo: recorrência mensal sem fim
#     recorrente|nao|infinito     idem
#     recorrente|nao|8-12         8 de 12 já pagas (contando a do mês): lança a 8/12
#                                 e cria a recorrência com as 4 que faltam
#     recorrente|sim              valor variável: conta (bill) com o nome da descrição
#
# Regras (as mesmas do financas.sh):
#   - Variável, ou categoria "Contas"/"Contas da casa": a descrição é o nome da conta
#     (bill). A transação é vinculada a ela; se não existir, é criada (mensal, faixa
#     de ±30% do valor). Contas não viram recorrência.
#   - Recorrente de valor fixo: lança o mês e cria uma transação recorrente mensal no
#     Firefly a partir do mês seguinte, no mesmo dia (sem fim ou com N repetições).
#   - Demais linhas: despesa comum.
#   Reimportar o mesmo arquivo não duplica transações, contas nem recorrências.
#
# Uso:
#   ./importar.sh gastos.tsv
#   FIREFLY_DRY_RUN=1 ./importar.sh gastos.tsv     # só mostra, não envia
#
# Usa o mesmo .env do financas.sh. Variáveis extras (opcionais):
#   FIREFLY_CONTA_DEBITO="Inter"                # conta de ativo do débito
#   FIREFLY_CONTA_CREDITO="C6 Cartão"           # conta do cartão (padrão: FIREFLY_CONTA_C6)
#   FIREFLY_CONTA_OUTROS="Carteira"             # quando o meio vem vazio
#
# Requer: curl, jq, awk

set -eu

# --- Configuração ------------------------------------------------------------
DIR_SCRIPT=$(cd "$(dirname "$0")" && pwd)
for env in "${FINANCAS_ENV:-}" "$DIR_SCRIPT/.env" "$HOME/.financas.env"; do
    if [ -n "$env" ] && [ -f "$env" ]; then
        . "$env"
        break
    fi
done

LOG="${FINANCAS_IMPORT_LOG:-$DIR_SCRIPT/importacao.log}"
CONTA_DEBITO="${FIREFLY_CONTA_DEBITO:-${FIREFLY_CONTA_INTER:-Inter}}"
CONTA_CREDITO="${FIREFLY_CONTA_CREDITO:-${FIREFLY_CONTA_C6:-C6 Cartão}}"
CONTA_OUTROS="${FIREFLY_CONTA_OUTROS:-Carteira}"
DRY_RUN="${FIREFLY_DRY_RUN:-0}"

if [ "$DRY_RUN" != 1 ]; then
    : "${FIREFLY_URL:?defina FIREFLY_URL no .env (pasta do script)}"
    : "${FIREFLY_TOKEN:?defina FIREFLY_TOKEN no .env (pasta do script)}"
fi

# --- Utilitários -------------------------------------------------------------
RESP=$(mktemp)
LINHAS=$(mktemp)
trap 'rm -f "$RESP" "$LINHAS"' EXIT

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

# "R$ 1.234,56" -> "1234.56"
normaliza_valor() { printf '%s' "$1" | sed 's/[^0-9,]//g; s/,/./'; }
# "05/11/2026" -> "2026-11-05"
normaliza_data() { printf '%s' "$1" | sed -n 's|^ *\([0-9][0-9]\)/\([0-9][0-9]\)/\([0-9]\{4\}\) *$|\3-\2-\1|p'; }
# "1234.56" -> "R$ 1234,56"
valor_br() { printf 'R$ %s' "$(printf '%s' "$1" | sed 's/\./,/')"; }

# soma_meses AAAA-MM-DD N — limita ao último dia do mês (31/01 + 1 = 28/02)
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

conta_origem() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        *d*bito*)  printf '%s' "$CONTA_DEBITO" ;;
        *cr*dito*) printf '%s' "$CONTA_CREDITO" ;;
        *)         printf '%s' "$CONTA_OUTROS" ;;
    esac
}

# api MÉTODO CAMINHO [JSON] — define HTTP_STATUS; corpo em $RESP
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

# --- Contas (bills) ----------------------------------------------------------
# Versões novas da API usam /subscriptions; as antigas, /bills.
EP_CONTAS=""
lista_contas() {
    if [ -z "$EP_CONTAS" ]; then
        EP_CONTAS=/api/v1/subscriptions
        api GET "$EP_CONTAS?limit=100"
        if [ "$HTTP_STATUS" = 404 ]; then EP_CONTAS=/api/v1/bills; api GET "$EP_CONTAS?limit=100"; fi
    else
        api GET "$EP_CONTAS?limit=100"
    fi
    [ "$HTTP_STATUS" = 200 ]
}

# prepara_conta NOME VALOR DATA — define BILL_ID/BILL_NOME, criando a conta se preciso.
# Retorna 1 (com ERRO_MSG) se a API falhar.
prepara_conta() {
    BILL_ID=""; BILL_NOME=$1; CONTA_CRIADA=""
    lista_contas || { ERRO_MSG="não consegui consultar as contas (HTTP $HTTP_STATUS)"; return 1; }
    ACHADA=$(jq -r --arg n "$1" '[ .data[]
        | select((.attributes.name | ascii_downcase) == ($n | ascii_downcase))
        | "\(.id)|\(.attributes.name)" ] | first // empty' "$RESP")
    if [ -n "$ACHADA" ]; then
        BILL_ID=${ACHADA%%|*}; BILL_NOME=${ACHADA#*|}
        return 0
    fi
    MIN=$(printf '%s' "$2" | awk '{ printf "%.2f", $1 * 0.7 }')
    MAX=$(printf '%s' "$2" | awk '{ printf "%.2f", $1 * 1.3 }')
    BODY=$(jq -n --arg n "$1" --arg min "$MIN" --arg max "$MAX" --arg d "$3" '{
        name: $n, amount_min: $min, amount_max: $max, date: $d,
        repeat_freq: "monthly", skip: 0, active: true }')
    api POST "$EP_CONTAS" "$BODY"
    case "$HTTP_STATUS" in
        200|201) BILL_ID=$(jq -r '.data.id' "$RESP"); CONTA_CRIADA=1
                 log "CONTA criada: $1 (faixa $(valor_br "$MIN") a $(valor_br "$MAX"))" ;;
        *)       ERRO_MSG="não consegui criar a conta '$1' (HTTP $HTTP_STATUS): $(cat "$RESP")"; return 1 ;;
    esac
}

# --- Recorrência -------------------------------------------------------------
# O Firefly exige número de repetições OU data de término; "sem fim" usa esta data.
SEM_FIM="${FIREFLY_RECORRENCIA_ATE:-2099-12-31}"

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

# cria_recorrencia DESC VALOR DATA CATEGORIA REPETICOES SRC_ID DST_ID ORIGEM
# Sem REPETICOES = sem fim. Sem os IDs, procura as contas pelo nome.
# Não cria se já existir recorrência com o mesmo título (define REC_JA=1).
cria_recorrencia() {
    REC_JA=""
    if recorrencia_existe "$1"; then
        REC_JA=1; log "RECORRÊNCIA já existia: $1"; return 0
    fi
    SRC_ID=${6:-$(conta_id "$8" origem)}
    DST_ID=${7:-$(conta_id "$1" destino)}
    if [ -z "$SRC_ID" ] || [ -z "$DST_ID" ]; then
        ERRO_MSG="não encontrei as contas '$8' / '$1' para criar a recorrência"; return 1
    fi
    PROXIMA=$(soma_meses "$3" 1)
    DIA=$(printf '%s' "$3" | cut -c9-10 | sed 's/^0//')
    REC=$(jq -n --arg t "$1" --arg d "$PROXIMA" --arg dia "$DIA" --arg valor "$2" \
        --arg src "$SRC_ID" --arg dst "$DST_ID" --arg cat "$4" --arg reps "$5" --arg ate "$SEM_FIM" '{
          type: "withdrawal",
          title: $t,
          first_date: $d,
          apply_rules: true,
          active: true,
          repetitions: [{ type: "monthly", moment: $dia, skip: 0, weekend: 1 }],
          transactions: [({
            description: $t, amount: $valor, source_id: $src, destination_id: $dst
          } + (if $cat != "" then {category_name: $cat} else {} end))]
        } + (if $reps != "" then {nr_of_repetitions: ($reps | tonumber)} else {repeat_until: $ate} end)')
    api POST /api/v1/recurrences "$REC"
    case "$HTTP_STATUS" in
        200|201) log "RECORRÊNCIA criada: $1 $(valor_br "$2") todo dia $DIA a partir de $PROXIMA${5:+, $5 repetição(ões)}" ;;
        *)       ERRO_MSG="recorrência falhou (HTTP $HTTP_STATUS): $(cat "$RESP")"; return 1 ;;
    esac
}

# --- Leitura -----------------------------------------------------------------
# awk separa por TAB preservando colunas vazias (o "read" do shell juntaria
# TABs seguidos) e emite os campos separados pelo caractere US (\037).
SEP=$(printf '\037')
awk -F'\t' -v OFS="$SEP" '
    { sub(/\r$/, "") }
    $0 ~ /^[[:space:]]*$/ { next }
    { print NR, $1, $2, $3, $4, $5, $6 }
' "${1:--}" > "$LINHAS"

OK=0; DUP=0; ERRO=0; N=0; N_REC=0; N_CONTA=0

while IFS="$SEP" read -r NL DATA_BR DESC CAT VALOR_BR MEIO RECORR; do
    N=$((N + 1))
    DATA=$(normaliza_data "$DATA_BR")
    VALOR=$(normaliza_valor "$VALOR_BR")

    if [ -z "$DATA" ] || [ -z "$VALOR" ] || [ -z "$DESC" ]; then
        echo "✗ linha $NL: formato inválido (a lista está separada por TAB?) -> $DATA_BR | $DESC | $VALOR_BR"
        log "ERRO linha $NL: formato inválido: $DATA_BR|$DESC|$CAT|$VALOR_BR|$MEIO|$RECORR"
        ERRO=$((ERRO + 1))
        continue
    fi

    ORIGEM=$(conta_origem "$MEIO")

    # Última coluna: recorrente|variável|parcelas
    TIPO=$(printf '%s' "$RECORR" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
    F_REC=$(printf '%s' "$TIPO" | cut -d'|' -f1)
    F_VAR=$(printf '%s' "$TIPO" | cut -s -d'|' -f2)
    F_PARC=$(printf '%s' "$TIPO" | cut -s -d'|' -f3)

    E_CONTA=""; E_RECORRENTE=""; REPS=""; DESC_TX=$DESC; TAGS='["importacao"]'; EXTRA_PLANO=""
    case "$CAT" in
        [Cc]ontas)            CAT="Contas";         E_CONTA=1 ;;
        [Cc]ontas\ da\ casa)  CAT="Contas da casa"; E_CONTA=1 ;;
    esac

    if [ "$F_REC" = recorrente ]; then
        case "$F_VAR" in sim|s|variavel|variável) E_CONTA=1 ;; esac
        if [ -z "$E_CONTA" ]; then
            E_RECORRENTE=1
            TAGS='["importacao","recorrente"]'
            case "$F_PARC" in
                ""|infinito|inf|sempre) ;;
                *-*)
                    # pagas-total: "8-12" = esta é a 8ª de 12; faltam 4 nos próximos meses
                    PAGAS=${F_PARC%%-*}; TOTAL=${F_PARC#*-}
                    case "$PAGAS$TOTAL" in *[!0-9]*|"") PAGAS=x ;; esac
                    if [ "$PAGAS" = x ] || [ "$PAGAS" -lt 1 ] || [ "$PAGAS" -gt "$TOTAL" ]; then
                        echo "✗ linha $NL: parcelas inválidas '$F_PARC' (use pagas-total, ex.: 8-12)"
                        log "ERRO linha $NL: parcelas inválidas: $F_PARC"; ERRO=$((ERRO + 1)); continue
                    fi
                    DESC_TX="$DESC ($PAGAS/$TOTAL)"
                    TAGS='["importacao","recorrente","parcelado"]'
                    REPS=$((TOTAL - PAGAS))
                    if [ "$REPS" -eq 0 ]; then E_RECORRENTE=""; EXTRA_PLANO=" (última parcela)"; fi ;;
                *)
                    echo "✗ linha $NL: parcelas inválidas '$F_PARC' (use pagas-total ou infinito)"
                    log "ERRO linha $NL: parcelas inválidas: $F_PARC"; ERRO=$((ERRO + 1)); continue ;;
            esac
        fi
    elif [ -n "$F_REC" ]; then
        echo "✗ linha $NL: tipo inválido '$RECORR' (use recorrente|nao, recorrente|sim ou recorrente|nao|8-12)"
        log "ERRO linha $NL: tipo inválido: $RECORR"; ERRO=$((ERRO + 1)); continue
    fi

    RESUMO="$DATA  $(valor_br "$VALOR")  $DESC_TX  [$CAT]  ($ORIGEM)"

    if [ -n "$E_RECORRENTE" ]; then
        if [ -n "$REPS" ]; then
            PLANO_REC=" + recorrência mensal, mais $REPS vez(es) até $(soma_meses "$DATA" "$REPS")"
        else
            PLANO_REC=" + recorrência mensal sem fim a partir de $(soma_meses "$DATA" 1)"
        fi
    else
        PLANO_REC=$EXTRA_PLANO
    fi

    if [ "$DRY_RUN" = 1 ]; then
        if [ -n "$E_CONTA" ]; then echo "• $RESUMO -> conta \"$DESC\""; else echo "• $RESUMO$PLANO_REC"; fi
        continue
    fi

    # Conta (bill): vincula ou cria antes de lançar
    BILL_ID=""; BILL_NOME=""; CONTA_CRIADA=""
    if [ -n "$E_CONTA" ]; then
        if ! prepara_conta "$DESC" "$VALOR" "$DATA"; then
            echo "✗ $RESUMO -> $ERRO_MSG"; log "ERRO: $RESUMO -> $ERRO_MSG"; ERRO=$((ERRO + 1))
            continue
        fi
    fi

    JSON=$(jq -n \
        --arg data "$DATA" --arg valor "$VALOR" --arg desc "$DESC_TX" --arg destino "$DESC" \
        --arg cat "$CAT" --arg origem "$ORIGEM" --argjson tags "$TAGS" --arg bill "$BILL_ID" '{
          error_if_duplicate_hash: true,
          apply_rules: true,
          transactions: [({
            type: "withdrawal",
            date: $data,
            amount: $valor,
            description: $desc,
            source_name: $origem,
            destination_name: $destino,
            tags: $tags
          } + (if $cat != "" then {category_name: $cat} else {} end)
            + (if $bill != "" then {bill_id: $bill} else {} end))]
        }')

    api POST /api/v1/transactions "$JSON"
    case "$HTTP_STATUS" in
        200|201)
            # contas da transação criada (usadas pela recorrência)
            T_SRC=$(jq -r '.data.attributes.transactions[0].source_id // empty' "$RESP" 2>/dev/null || true)
            T_DST=$(jq -r '.data.attributes.transactions[0].destination_id // empty' "$RESP" 2>/dev/null || true)
            EXTRA=""
            if [ -n "$BILL_ID" ]; then
                N_CONTA=$((N_CONTA + 1))
                EXTRA=" -> conta \"$BILL_NOME\"${CONTA_CRIADA:+ (criada)}"
            fi
            if [ -n "$E_RECORRENTE" ]; then
                if cria_recorrencia "$DESC" "$VALOR" "$DATA" "$CAT" "$REPS" "$T_SRC" "$T_DST" "$ORIGEM"; then
                    N_REC=$((N_REC + 1)); EXTRA=$PLANO_REC
                    [ -z "$REC_JA" ] || EXTRA=" (recorrência já existia)"
                else
                    EXTRA=" (ATENÇÃO: $ERRO_MSG)"; ERRO=$((ERRO + 1))
                    log "ERRO: $RESUMO -> $ERRO_MSG"
                fi
            fi
            echo "✓ $RESUMO$EXTRA"; log "OK: $RESUMO$EXTRA"; OK=$((OK + 1)) ;;
        422)
            if grep -qi 'duplicate' "$RESP"; then
                # já importada antes; garante a recorrência (pode ter falhado na vez anterior)
                EXTRA=""
                if [ -n "$E_RECORRENTE" ]; then
                    if cria_recorrencia "$DESC" "$VALOR" "$DATA" "$CAT" "$REPS" "" "" "$ORIGEM"; then
                        if [ -z "$REC_JA" ]; then N_REC=$((N_REC + 1)); EXTRA=" (recorrência criada agora)"; fi
                    else
                        EXTRA=" (ATENÇÃO: $ERRO_MSG)"; ERRO=$((ERRO + 1)); log "ERRO: $RESUMO -> $ERRO_MSG"
                    fi
                fi
                echo "= já existia: $RESUMO$EXTRA"; log "DUPLICADA: $RESUMO$EXTRA"; DUP=$((DUP + 1))
            else
                echo "✗ $RESUMO -> $(cat "$RESP")"; log "ERRO 422: $RESUMO -> $(cat "$RESP")"; ERRO=$((ERRO + 1))
            fi ;;
        *)
            echo "✗ $RESUMO -> HTTP $HTTP_STATUS"; log "ERRO HTTP $HTTP_STATUS: $RESUMO -> $(cat "$RESP")"; ERRO=$((ERRO + 1)) ;;
    esac
done < "$LINHAS"

echo
if [ "$DRY_RUN" = 1 ]; then
    echo "Simulação: $N linha(s) lidas, nada foi enviado."
else
    echo "Resumo: $OK lançada(s) ($N_REC com recorrência, $N_CONTA vinculada(s) a conta), $DUP já existia(m), $ERRO com erro."
fi
[ "$ERRO" -eq 0 ]
