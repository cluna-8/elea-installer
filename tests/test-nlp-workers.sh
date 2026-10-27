#!/usr/bin/env bash
# Prueba del analizador (nlp-analyzer): NLP_WORKERS por defecto 2 y la imagen elegible con NLP_IMAGE.
# Sin Docker: lee docker-compose.yml con tests/render-compose.py (expande ${VAR} como compose).
# Correr:  bash tests/test-nlp-workers.sh
set -uo pipefail
AQUI="$(cd "$(dirname "$0")/.." && pwd)"
FALLOS=0
ok()   { echo "  ok   $1"; }
falla() { echo "  FALLA $1"; FALLOS=$((FALLOS + 1)); }
chequear() { local desc="$1"; shift; if "$@"; then ok "$desc"; else falla "$desc"; fi; }
chequear_no() { local desc="$1"; shift; if "$@"; then falla "$desc"; else ok "$desc"; fi; }

RENDER="$AQUI/tests/render-compose.py"
chequear "hay python3 con PyYAML" python3 -c 'import yaml'

export POSTGRES_PASSWORD=pw ENGINE_MASTER_KEY=sk-x FERNET_SECRET_KEY=f JWT_SECRET_KEY=j
export AZURE_OPENAI_API_KEY=a AZURE_OPENAI_ENDPOINT=https://x AZURE_API_VERSION=v

nlp() { # $1 = image | environment
  python3 "$RENDER" | python3 -c '
import json, sys
s = json.load(sys.stdin)["services"]["nlp-analyzer"]
v = s.get(sys.argv[1], [])
print("\n".join(v if isinstance(v, list) else [f"{k}={x}" for k, x in v.items()]) if not isinstance(v, str) else v)' "$1"
}

echo "— por defecto: imagen publicada y 2 procesos"
unset NLP_WORKERS NLP_IMAGE
chequear "la imagen por defecto es la publicada (latest)" grep -qxF "ghcr.io/cluna-8/elea-guardian-nlp:latest" <<<"$(nlp image)"
chequear "NLP_WORKERS=2 por defecto" grep -qxF "NLP_WORKERS=2" <<<"$(nlp environment)"

echo "— con .env: 4 procesos e imagen local"
export NLP_WORKERS=4 NLP_IMAGE=elea-guardian-nlp:local
chequear "NLP_WORKERS=4 se respeta" grep -qxF "NLP_WORKERS=4" <<<"$(nlp environment)"
chequear "NLP_IMAGE reemplaza la imagen" grep -qxF "elea-guardian-nlp:local" <<<"$(nlp image)"
unset NLP_WORKERS NLP_IMAGE

echo "— comentario corregido y documentación"
chequear_no "ya no dice ~330 chars/s" grep -q "330 chars/s" "$AQUI/docker-compose.yml"
chequear "dice ~49 000 caracteres/s" grep -q "49 000 caracteres/s" "$AQUI/docker-compose.yml"
chequear ".env.example documenta NLP_WORKERS y NLP_IMAGE" bash -c 'grep -q "^NLP_WORKERS=2" "$1" && grep -q "^# NLP_IMAGE=" "$1"' _ "$AQUI/.env.example"
chequear "el README documenta las cuatro imágenes locales" bash -c 'for v in BACKEND_EXT_IMAGE ENGINE_EXT_IMAGE FRONTEND_EXT_IMAGE NLP_IMAGE; do grep -q "\`$v\`" "$1" || exit 1; done' _ "$AQUI/README.md"

echo
if [ "$FALLOS" = 0 ]; then echo "TODO OK"; else echo "$FALLOS FALLO(S)"; exit 1; fi
