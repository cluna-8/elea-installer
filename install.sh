#!/usr/bin/env bash
# Instalador Elea — Guardian + cliente RAG + AnythingLLM.
# Un solo comando: ./install.sh
#
# Automatiza todo lo que en el desarrollo se hizo a mano (bootstrap del admin,
# generar la API key de AnythingLLM, crear las virtual keys de servicio, conectar
# AnythingLLM al motor) — no hace falta copiar/pegar ningún curl.
set -euo pipefail
cd "$(dirname "$0")"

log() { echo -e "\n\033[1;34m▶ $1\033[0m"; }
die() { echo -e "\033[1;31m✗ $1\033[0m" >&2; exit 1; }

command -v docker >/dev/null || die "Falta Docker. Instalalo antes de seguir: https://docs.docker.com/get-docker/"
docker compose version >/dev/null 2>&1 || die "Falta Docker Compose v2 (viene con Docker Desktop / docker-compose-plugin)."
command -v python3 >/dev/null || die "Falta python3 (lo usa este script para leer respuestas JSON)."

# ── 1. .env ──────────────────────────────────────────────────────────────────────────
if [ ! -f .env ]; then
  log "Primera vez: generando .env con secretos nuevos"
  cp .env.example .env
  python3 - <<'PY'
import secrets, re
with open('.env') as f:
    content = f.read()
content = content.replace('POSTGRES_PASSWORD=', f'POSTGRES_PASSWORD={secrets.token_urlsafe(24)}')
content = content.replace('ENGINE_MASTER_KEY=', f'ENGINE_MASTER_KEY=sk-{secrets.token_urlsafe(32)}')
content = content.replace('FERNET_SECRET_KEY=', 'FERNET_SECRET_KEY=' + __import__('base64').urlsafe_b64encode(secrets.token_bytes(32)).decode())
content = content.replace('JWT_SECRET_KEY=', f'JWT_SECRET_KEY={secrets.token_urlsafe(48)}')
content = content.replace('ADMIN_PASSWORD=', f'ADMIN_PASSWORD={secrets.token_urlsafe(16)}')
with open('.env', 'w') as f:
    f.write(content)
PY
  echo
  echo "  Se creó .env con secretos generados. FALTA que completes las credenciales"
  echo "  reales del modelo (Azure OpenAI / Gemini) — editá .env y volvé a correr:"
  echo
  echo "    nano .env    # completar AZURE_OPENAI_API_KEY, AZURE_OPENAI_ENDPOINT, AZURE_API_VERSION"
  echo "    ./install.sh"
  echo
  exit 0
fi

set -a; source .env; set +a
[ -n "${AZURE_OPENAI_API_KEY:-}" ] || die "Falta AZURE_OPENAI_API_KEY en .env — completalo y volvé a correr."

# ── 2. Login al registro de imágenes (privado) ──────────────────────────────────────
# Solo pide login si la imagen no está ya en la máquina (evita un login remoto
# innecesario cuando ya se descargó antes, o en dev con las imágenes construidas
# localmente con el mismo tag).
if ! docker image inspect ghcr.io/cluna-8/elea-guardian-backend:latest >/dev/null 2>&1; then
  log "Login al registro de imágenes"
  echo "Las imágenes son privadas. Pedí un token de lectura (read:packages) a quien te dio este instalador."
  read -rp "Usuario de GitHub: " GHCR_USER
  read -rsp "Token: " GHCR_TOKEN; echo
  echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin || die "No se pudo autenticar al registro."
fi

# ── 3. Levantar todo menos el cliente (necesita keys que generamos después) ─────────
log "Descargando y levantando el motor y AnythingLLM (sin depender de backend todavía)"
docker compose pull db redis nlp-analyzer engine anythingllm 2>&1 | grep -v "^ " || true
docker compose up -d db redis nlp-analyzer engine anythingllm

log "Esperando a que el motor termine de migrar su base (puede tardar varios minutos en el primer arranque con una base nueva)"
for i in $(seq 1 60); do
  status=$(docker inspect elea-engine --format '{{.State.Health.Status}}' 2>/dev/null || echo "starting")
  [ "$status" = "healthy" ] && break
  sleep 5
  [ "$i" -eq 60 ] && die "El motor no terminó de arrancar después de 5 minutos. Revisá: docker compose logs engine"
done

log "Levantando el Guardian (backend + panel)"
docker compose pull backend frontend 2>&1 | grep -v "^ " || true
docker compose up -d backend frontend

log "Esperando a que el Guardian esté listo (puede tardar el primer arranque)"
for i in $(seq 1 60); do
  curl -sf -o /dev/null http://localhost:8091/health && break
  sleep 3
  [ "$i" -eq 60 ] && die "El backend no respondió después de 3 minutos. Revisá: docker compose logs backend"
done

# ── 4. Bootstrap del admin (primer login lo crea) ───────────────────────────────────
log "Configurando el usuario administrador"
ADMIN_LOGIN=$(curl -s -X POST http://localhost:8091/api/v1/users/login \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"admin\",\"password\":\"${ADMIN_PASSWORD}\"}")
ADMIN_TOKEN=$(echo "$ADMIN_LOGIN" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("access_token",""))')
[ -n "$ADMIN_TOKEN" ] || die "No se pudo crear/autenticar el admin. Respuesta: $ADMIN_LOGIN"

# ── 5. API key de AnythingLLM (solo si no la generamos antes) ──────────────────────
if [ -z "${ANYTHINGLLM_API_KEY:-}" ]; then
  log "Esperando a AnythingLLM y generando su API key"
  for i in $(seq 1 30); do
    curl -sf -o /dev/null http://localhost:3001/ && break
    sleep 2
  done
  ANYTHINGLLM_API_KEY=$(docker exec elea-anythingllm node -e "
    const {PrismaClient} = require('/app/server/node_modules/@prisma/client');
    const p = new PrismaClient();
    p.api_keys.create({data:{name:'elea-rag-client', secret: require('crypto').randomBytes(32).toString('hex')}})
      .then(r => console.log(r.secret)).finally(() => process.exit());
  " | tail -1)
  [ -n "$ANYTHINGLLM_API_KEY" ] || die "No se pudo generar la API key de AnythingLLM."
  echo "ANYTHINGLLM_API_KEY=${ANYTHINGLLM_API_KEY}" >> .env
fi

# ── 6. Virtual keys de servicio (proveedor LLM de AnythingLLM + enmascarado) ────────
if [ -z "${MASKING_VIRTUAL_KEY:-}" ]; then
  log "Creando usuarios y llaves de servicio en el Guardian"
  # NO usar `die` adentro (corre en subshell vía `$(...)`, un exit ahí no frena al
  # script principal) — devuelve vacío en error y el caller lo chequea.
  create_service_key() {
    local username="$1" email="$2" name="$3"
    local password user_id
    password=$(python3 -c 'import secrets;print(secrets.token_urlsafe(24))')
    curl -s -X POST http://localhost:8091/api/v1/users \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" -H 'Content-Type: application/json' \
      -d "{\"username\":\"${username}\",\"email\":\"${email}\",\"role\":\"client\",\"password\":\"${password}\"}" \
      > /tmp/elea_svc_user.json
    user_id=$(python3 -c 'import json;d=json.load(open("/tmp/elea_svc_user.json"));print(d.get("id",""))')
    if [ -z "$user_id" ]; then
      echo "ERROR:usuario '${username}': $(cat /tmp/elea_svc_user.json)" >&2
      return 1
    fi
    curl -s -X POST http://localhost:8091/api/v1/keys \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" -H 'Content-Type: application/json' \
      -d "{\"name\":\"${name}\",\"user_id\":\"${user_id}\",\"tool_type\":\"chat-ui\",\"rpm_limit\":120,\"tpm_limit\":200000}" \
      > /tmp/elea_svc_key.json
    local plain_key
    plain_key=$(python3 -c 'import json;d=json.load(open("/tmp/elea_svc_key.json"));print(d.get("plain_key",""))')
    if [ -z "$plain_key" ]; then
      echo "ERROR:llave '${name}': $(cat /tmp/elea_svc_key.json)" >&2
      return 1
    fi
    echo "$plain_key"
  }
  # ".local" lo rechaza el validador de email (dominio reservado) — usar un dominio
  # con TLD real, aunque sea ficticio.
  PROVIDER_KEY=$(create_service_key "svc.anythingllm-provider" "svc.anythingllm-provider@elea-internal.com" "anythingllm-provider") \
    || die "No se pudo aprovisionar la llave del proveedor de AnythingLLM (ver error arriba)."
  MASKING_VIRTUAL_KEY=$(create_service_key "svc.rag-masking" "svc.rag-masking@elea-internal.com" "rag-masking") \
    || die "No se pudo aprovisionar la llave de enmascarado (ver error arriba)."
  echo "MASKING_VIRTUAL_KEY=${MASKING_VIRTUAL_KEY}" >> .env

  log "Conectando AnythingLLM al motor del Guardian"
  curl -s -X POST http://localhost:3001/api/v1/system/update-env \
    -H "Authorization: Bearer ${ANYTHINGLLM_API_KEY}" -H 'Content-Type: application/json' \
    -d "{\"LLMProvider\":\"generic-openai\",\"GenericOpenAiBasePath\":\"http://engine:4000/v1\",\"GenericOpenAiModelPref\":\"azure-gpt-4o-mini\",\"GenericOpenAiKey\":\"${PROVIDER_KEY}\"}" \
    > /dev/null
fi

# ── 7. Levantar el cliente (ya con las keys en .env) ────────────────────────────────
log "Levantando el cliente RAG"
docker compose up -d client

echo
echo "================================================================"
echo "  Listo. Todo corriendo."
echo
echo "  Panel del Guardian:  http://localhost:8090"
echo "  API del Guardian:    http://localhost:8091/docs"
echo "  Cliente RAG:         http://localhost:8095"
echo
echo "  Admin:  usuario 'admin', contraseña: ${ADMIN_PASSWORD}"
echo "  (guardada en .env — no se vuelve a mostrar)"
echo
echo "  Para cada persona que va a probar: crear su usuario en el Guardian"
echo "  (POST http://localhost:8091/api/v1/users con el token de admin, o pedime"
echo "  el script create-tester.sh) — todas entran a http://localhost:8095 con su"
echo "  propio usuario, sesiones aisladas por navegador."
echo "================================================================"
