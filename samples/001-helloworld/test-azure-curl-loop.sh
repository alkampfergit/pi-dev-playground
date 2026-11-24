#!/bin/bash

set -e

# ==========================================
# VERIFICA VARIABILI AMBIENTE
# ==========================================
if [ -z "$AZURE_PI_TEST_ENDPOINT" ]; then
    echo "❌ ERRORE: AZURE_PI_TEST_ENDPOINT non impostato"
    echo "   Usa: source ./prepare.sh"
    exit 1
fi

if [ -z "$AZURE_PI_TEST_API_KEY" ]; then
    echo "❌ ERRORE: AZURE_PI_TEST_API_KEY non impostato"
    echo "   Usa: source ./prepare.sh"
    exit 1
fi

if [ -z "$AZURE_PI_TEST_DEPLOYMENT" ]; then
    echo "⚠️  WARN: AZURE_PI_TEST_DEPLOYMENT non impostato, uso default 'Kimi-K2.6'"
fi

# ==========================================
# CONFIGURAZIONE
# ==========================================
AZURE_BASE="$AZURE_PI_TEST_ENDPOINT"
API_KEY="$AZURE_PI_TEST_API_KEY"
MODEL="${PI_AZURE_LOOP_MODEL:-${AZURE_PI_TEST_DEPLOYMENT:-Kimi-K2.6}}"
MAX_RETRIES=3

# Costruzione endpoint corretta
if [[ "$AZURE_BASE" == */chat/completions ]]; then
    ENDPOINT="$AZURE_BASE"
else
    ENDPOINT="${AZURE_BASE%/}/chat/completions"
fi

echo "=========================================="
echo "Configurazione:"
echo "  Endpoint: ${ENDPOINT:0:60}..."
echo "  Model: $MODEL"
echo "  API Key: (configured)"
echo "=========================================="
echo ""

# ==========================================
# FUNZIONE: chiamata con retry
# ==========================================
call_azure() {
    local attempt=1
    local output
    local curl_code
    local http_code
    
    while [ $attempt -le $MAX_RETRIES ]; do
        set +e
        output=$(curl -s -w "\n%{http_code}\n%{time_total}" \
            "${ENDPOINT}" \
            -H "Content-Type: application/json" \
            -H "api-key: $API_KEY" \
            -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"scrivi un haiku\"}],\"max_tokens\":30}" \
            --max-time 30 2>&1)
        
        curl_code=$?
        set -e
        http_code=$(echo "$output" | tail -2 | head -1)
        
        # Successo
        if [ "$curl_code" -eq 0 ] && [ "$http_code" = "200" ]; then
            echo "$output"
            return 0
        fi
        
        # Retry su errori transienti (5xx, timeout, network)
        local should_retry=0
        
        if [ "$curl_code" -ne 0 ]; then
            # Errori di rete/transienti
            case $curl_code in
                6|7|28|35|56) should_retry=1 ;;  # DNS, Connection, Timeout, SSL, Network
            esac
        elif [[ "$http_code" == 5* ]] || [ "$http_code" = "429" ]; then
            # Server error o rate limit
            should_retry=1
        fi
        
        if [ $should_retry -eq 1 ] && [ $attempt -lt $MAX_RETRIES ]; then
            echo "        ↻ Retry $attempt/$MAX_RETRIES dopo 2s..." >&2
            sleep 2
            attempt=$((attempt + 1))
        else
            echo "$output"
            return 1
        fi
    done
    
    echo "$output"
    return 1
}

# ==========================================
# TEST INIZIALE
# ==========================================
echo "Test iniziale..."
set +e
TEST_OUTPUT=$(call_azure 2>&1)
TEST_RESULT=$?
set -e
TEST_HTTP=$(echo "$TEST_OUTPUT" | tail -2 | head -1)

if [ "$TEST_HTTP" = "200" ]; then
    echo "✅ Connessione OK"
else
    echo "❌ Test iniziale fallito:"
    echo "   HTTP: $TEST_HTTP"
    echo "   Response: $(echo "$TEST_OUTPUT" | sed '$d' | sed '$d' | head -c 200)"
    exit 1
fi
echo ""

# ==========================================
# LOOP PRINCIPALE
# ==========================================
echo "=========================================="
echo "Inizio 20 richieste con pausa 1s..."
echo "=========================================="

SUCCESS=0
FAILED=0
RETRIES_TOTAL=0

for i in {1..20}; do
    TS=$(date '+%H:%M:%S')
    
    # Chiama con retry
    set +e
    OUTPUT=$(call_azure 2>&1)
    RESULT=$?
    set -e
    
    # Conta retry dal stderr (se presente)
    RETRY_COUNT=$(echo "$OUTPUT" | grep -c "Retry" 2>/dev/null || true)
    RETRY_COUNT=${RETRY_COUNT:-0}
    RETRIES_TOTAL=$((RETRIES_TOTAL + RETRY_COUNT))
    
    # Estrai dati
    CURL_CODE=0  # call_azure gestisce internamente
    HTTP_CODE=$(echo "$OUTPUT" | tail -2 | head -1)
    TIME=$(echo "$OUTPUT" | tail -1)
    BODY=$(echo "$OUTPUT" | sed '$d' | sed '$d' | sed '/Retry/d')
    
    if [ "$RESULT" -eq 0 ]; then
        SUCCESS=$((SUCCESS + 1))
        CONTENT=$(echo "$BODY" | grep -o '"content":"[^"]*"' | head -1 | cut -d'"' -f4)
        [ -z "$CONTENT" ] && CONTENT=$(echo "$BODY" | grep -o '"reasoning_content":"[^"]*"' | head -1 | cut -d'"' -f4)
        
        RETRY_IND=""
        [ $RETRY_COUNT -gt 0 ] && RETRY_IND=" (↻$RETRY_COUNT)"
        
        echo "[${i}/20] ${TS} ✅ OK (${TIME}s)${RETRY_IND} | ${CONTENT:0:40}"
    else
        FAILED=$((FAILED + 1))
        echo "[${i}/20] ${TS} ❌ FAIL"
        echo "        HTTP: $HTTP_CODE | Time: ${TIME}s"
        
        # Decodifica errore
        if [[ "$BODY" == *"error"* ]]; then
            ERROR_MSG=$(echo "$BODY" | grep -o '"message":"[^"]*"' | head -1 | cut -d'"' -f4)
            [ -n "$ERROR_MSG" ] && echo "        → Errore: $ERROR_MSG"
        fi
        
        echo "        → Response: ${BODY:0:150}"
    fi
    
    sleep 1
done

echo "=========================================="
echo "Risultato: $SUCCESS success, $FAILED failed"
[ $RETRIES_TOTAL -gt 0 ] && echo "Retry totali: $RETRIES_TOTAL"
echo "=========================================="

[ $FAILED -eq 0 ] && exit 0 || exit 1
