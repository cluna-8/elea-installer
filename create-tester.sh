#!/usr/bin/env bash
# Crea un usuario para que alguien pruebe el cliente RAG, con presupuesto opcional.
# Uso: ./create-tester.sh <usuario> <email> [presupuesto_usd]
set -euo pipefail
cd "$(dirname "$0")"
[ $# -ge 2 ] || { echo "Uso: ./create-tester.sh <usuario> <email> [presupuesto_usd]"; exit 1; }

USERNAME="$1"; EMAIL="$2"; BUDGET="${3:-}"
source .env

ADMIN_TOKEN=$(curl -s -X POST http://localhost:8091/api/v1/users/login \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"admin\",\"password\":\"${ADMIN_PASSWORD}\"}" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')

PASSWORD=$(python3 -c 'import secrets;print(secrets.token_urlsafe(12))')
USER=$(curl -s -X POST http://localhost:8091/api/v1/users \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" -H 'Content-Type: application/json' \
  -d "{\"username\":\"${USERNAME}\",\"email\":\"${EMAIL}\",\"role\":\"client\",\"password\":\"${PASSWORD}\"}")

USER_ID=$(echo "$USER" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')
if [ -z "$USER_ID" ]; then
  echo "No se pudo crear el usuario. Respuesta del Guardian:"
  echo "$USER"
  exit 1
fi

if [ -n "$BUDGET" ]; then
  curl -s -X POST http://localhost:8091/api/v1/budgets \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" -H 'Content-Type: application/json' \
    -d "{\"user_id\":\"${USER_ID}\",\"max_spend_usd\":${BUDGET},\"max_tokens\":1000000,\"reset_period\":\"monthly\"}" \
    > /dev/null
fi

echo "================================================================"
echo "  Usuario creado: ${USERNAME}"
echo "  Contraseña:     ${PASSWORD}"
echo "  Entra en:       http://localhost:8095"
[ -n "$BUDGET" ] && echo "  Presupuesto:    \$${BUDGET} USD/mes"
echo "================================================================"
