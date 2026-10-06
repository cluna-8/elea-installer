#!/usr/bin/env bash
# Prueba del BRAND_NAME del backend (spec 057): el título de la consola del Guardian
# tiene que decir «Eleia GuardIAn» y no el default de fábrica «Sentinel Secure AI
# Gateway» (backend/src/main.py:78 lo lee con ese default). Sin Docker: lee
# docker-compose.yml con tests/render-compose.py (expande ${VAR} como compose).
#
#   T104: el entorno del backend trae BRAND_NAME=Eleia GuardIAn, también con la
#         extensión de redirección (el override solo cambia image, command y
#         env_file; el environment de la base se hereda).
# Correr:  bash tests/test-brand-name.sh
set -uo pipefail
AQUI="$(cd "$(dirname "$0")/.." && pwd)"
FALLOS=0
ok()   { echo "  ok   $1"; }
falla() { echo "  FALLA $1"; FALLOS=$((FALLOS + 1)); }
chequear() { local desc="$1"; shift; if "$@"; then ok "$desc"; else falla "$desc"; fi; }
chequear_no() { local desc="$1"; shift; if "$@"; then falla "$desc"; else ok "$desc"; fi; }

RENDER="$AQUI/tests/render-compose.py"
VERSION=2026-11-01       # versión «publicada» de prueba (igual que test-redirect-optin.sh)
chequear "hay python3 con PyYAML" python3 -c 'import yaml'

# Variables que exige el compose para renderizar (valores de relleno).
export POSTGRES_PASSWORD=pw ENGINE_MASTER_KEY=sk-x FERNET_SECRET_KEY=f JWT_SECRET_KEY=j
export AZURE_OPENAI_API_KEY=a AZURE_OPENAI_ENDPOINT=https://x AZURE_API_VERSION=v

# Imprime el environment expandido del servicio $1 (base o --redirect).
env_de() { # $1 = servicio, $2 = --redirect (opcional)
  local flag="${2:-}"
  python3 "$RENDER" $flag | python3 -c '
import json, sys
env = json.load(sys.stdin)["services"][sys.argv[1]].get("environment", [])
e = env if isinstance(env, list) else [f"{k}={v}" for k, v in env.items()]
print("\n".join(e))' "$1"
}

echo "— T104 el backend define BRAND_NAME=Eleia GuardIAn (no el default de fábrica)"
BE=$(env_de backend)
chequear "el backend trae BRAND_NAME=Eleia GuardIAn" grep -qxF "BRAND_NAME=Eleia GuardIAn" <<<"$BE"
chequear_no "el backend NO queda con el default de fábrica (Sentinel Secure AI Gateway)" grep -qi "Sentinel Secure AI Gateway" <<<"$BE"

echo "— T104 con la extensión de redirección el backend -ext hereda BRAND_NAME"
export ELEA_EXT_VERSION=$VERSION
BEXT=$(env_de backend --redirect)
chequear "el backend -ext (con --redirect) también trae BRAND_NAME=Eleia GuardIAn" grep -qxF "BRAND_NAME=Eleia GuardIAn" <<<"$BEXT"
chequear "el override NO redefine environment (lo hereda de la base: solo image, command, env_file)" bash -c '
  python3 -c "import yaml,sys; d=yaml.safe_load(open(sys.argv[1]))[\"services\"][\"backend\"]; sys.exit(0 if set(d) <= {\"image\",\"command\",\"env_file\"} else 1)" "$1"' _ "$AQUI/docker-compose.redirect.yml"

echo "— white-label: BRAND_NAME no nombra internals prohibidos"
chequear "BRAND_NAME no menciona litellm/berriai/presidio" bash -c '! grep -Eiq "litellm|berriai|presidio" <<<"$1"' _ "Eleia GuardIAn"

echo
if [ "$FALLOS" = 0 ]; then echo "TODO OK"; else echo "$FALLOS FALLO(S)"; exit 1; fi
