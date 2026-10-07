#!/usr/bin/env bash
# Pruebas del nombre del DESPLIEGUE de embeddings del ruteo semántico (ROUTER_EMBEDDINGS_DEPLOYMENT), sin
# Docker: el compose se lee con tests/render-compose.py (expande las variables como compose).
#   - el motor la recibe del .env, en la base y con la extensión (-ext), con el default de siempre;
#   - .env.example la documenta, vacía (sin valor propio: el nombre lo elige quien creó el recurso);
#   - el README explica cómo listar los despliegues con la llave del .env SIN imprimirla.
# Correr:  bash tests/test-embeddings-deployment.sh
set -uo pipefail
AQUI="$(cd "$(dirname "$0")/.." && pwd)"
FALLOS=0
ok()   { echo "  ok   $1"; }
falla() { echo "  FALLA $1"; FALLOS=$((FALLOS + 1)); }
chequear() { local desc="$1"; shift; if "$@"; then ok "$desc"; else falla "$desc"; fi; }

RENDER="$AQUI/tests/render-compose.py"
chequear "hay python3 con PyYAML" python3 -c 'import yaml'
export POSTGRES_PASSWORD=pw ENGINE_MASTER_KEY=sk-x FERNET_SECRET_KEY=f JWT_SECRET_KEY=j
export AZURE_OPENAI_API_KEY=a AZURE_OPENAI_ENDPOINT=https://x AZURE_API_VERSION=v
export ELEA_EXT_VERSION=2026-11-01

# Valor que recibe el motor ('<ausente>' si el compose no la pasa). Args: [--redirect]
valor() {
  python3 "$RENDER" "$@" | python3 -c '
import json, sys
env = json.load(sys.stdin)["services"]["engine"]["environment"]
vals = [e.split("=", 1)[1] for e in env if e.startswith("ROUTER_EMBEDDINGS_DEPLOYMENT=")]
print(vals[0] if vals else "<ausente>")'
}

echo "— el compose se la pasa al motor"
unset ROUTER_EMBEDDINGS_DEPLOYMENT
chequear "base, sin definir" test "$(valor)" = "text-embedding-3-large"
chequear "base, vacía (la deja así el .env.example)" test "$(ROUTER_EMBEDDINGS_DEPLOYMENT= valor)" = "text-embedding-3-large"
chequear "base, definida" test "$(ROUTER_EMBEDDINGS_DEPLOYMENT=text-embedding-3-large-azure-openai valor)" = "text-embedding-3-large-azure-openai"
chequear "-ext, sin definir" test "$(valor --redirect)" = "text-embedding-3-large"
chequear "-ext, definida" test "$(ROUTER_EMBEDDINGS_DEPLOYMENT=mi-despliegue valor --redirect)" = "mi-despliegue"

echo "— .env.example"
chequear "la documenta vacía" grep -qx 'ROUTER_EMBEDDINGS_DEPLOYMENT=' "$AQUI/.env.example"
chequear "sin un nombre de despliegue inventado" bash -c '! grep -E "^ROUTER_EMBEDDINGS_DEPLOYMENT=." "$1"' _ "$AQUI/.env.example"

echo "— README"
R="$AQUI/README.md"
chequear "nombra la variable" grep -q 'ROUTER_EMBEDDINGS_DEPLOYMENT' "$R"
chequear "el valor en Elea es text-embedding-3-large-azure-openai" grep -q 'ROUTER_EMBEDDINGS_DEPLOYMENT=text-embedding-3-large-azure-openai' "$R"
chequear "lista los despliegues con /openai/deployments?api-version=2022-12-01" grep -q 'openai/deployments?api-version=2022-12-01' "$R"
# La llave se lee del .env DENTRO del comando (header desde stdin), nunca se imprime ni queda en el historial.
chequear "el curl no imprime la llave (header por stdin, sin echo ni -v)" bash -c '
  bloque=$(grep -B8 -A8 "openai/deployments?api-version=2022-12-01" "$1")
  grep -q -- "-H @-" <<<"$bloque" && ! grep -qE "echo[^|]*AZURE_OPENAI_API_KEY|curl[^|]* -v( |$)" <<<"$bloque"' _ "$R"
chequear "'Si falla' del ruteo degradado" grep -q 'embed_error' "$R"
chequear "lista este test entre las pruebas del instalador" grep -q 'tests/test-embeddings-deployment.sh' "$R"

if [ "$FALLOS" = 0 ]; then echo "TODO OK"; else echo "$FALLOS FALLO(S)"; exit 1; fi
