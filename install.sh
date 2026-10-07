#!/usr/bin/env bash
# Instalador Elea — Guardian + Eleia Hub + motores (documentos, planillas, presentaciones).
# Un solo comando: ./install.sh
#
# Automatiza todo lo que en el desarrollo se hizo a mano (bootstrap del admin,
# generar la API key de AnythingLLM, crear las virtual keys de servicio, conectar
# AnythingLLM al motor) — no hace falta copiar/pegar ningún curl.
set -euo pipefail
cd "$(dirname "$0")"

log() { echo -e "\n\033[1;34m▶ $1\033[0m"; }
die() { echo -e "\033[1;31m✗ $1\033[0m" >&2; exit 1; }
# Escribe KEY=VALUE en .env reemplazando la línea si ya existe (el .env.example trae las
# claves vacías; antes se agregaban al final y quedaban duplicadas).
set_env() { if grep -q "^$1=" .env; then sed -i "s|^$1=.*|$1=$2|" .env; else echo "$1=$2" >> .env; fi; }
del_env() { sed -i "/^$1=/d" .env; unset "$1"; }
# AnythingLLM NO publica su puerto al host (aislamiento, 08-sep): se le habla desde adentro
# de su propio contenedor (trae curl). Antes el instalador usaba localhost:3001 y fallaba.
allm_curl() { docker exec elea-anythingllm curl -s "$@"; }

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
  # Marca de instalación NUEVA: la segunda corrida (la que levanta todo) crea el usuario de cumplimiento
  # y la borra. Una instalación que ya existía no la tiene: ahí ese usuario es una decisión explícita
  # (./crear-super-admin.sh), no algo que aparece solo al actualizar.
  set_env ELEA_SUPER_ADMIN_PENDIENTE 1
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
# Extensión de redirección de modelos (opt-in, ELEA_REDIRECT=1; README, «Extensión de redirección de modelos»).
# Tag MÍNIMO (AAAA-MM-DD) del backend publicado que trae el chequeo de origen del canal interno: con una versión
# anterior ./activar-redirect.sh no activa la extensión. Se fija ACÁ, después de leer .env, para que un valor en
# .env no pueda bajarlo. 2026-10-07 = la fecha del primer juego de imágenes (base y -ext) construido desde la rama
# final de la 057 (prueba T102); una versión publicada anterior no trae ese chequeo. «PENDIENTE-PRIMER-RELEASE»
# (el valor anterior) hacía que ELEA_REDIRECT=1 no se pudiera activar nunca.
ELEA_EXT_MIN_VERSION="2026-10-08"
export ELEA_EXT_MIN_VERSION
[ -n "${AZURE_OPENAI_API_KEY:-}" ] || die "Falta AZURE_OPENAI_API_KEY en .env — completalo y volvé a correr."

# HTTPS del proxy (Claude Desktop exige https en la URL de la pasarela). Deja en .env los nombres del certificado
# (PROXY_TLS_NAMES: por defecto la IP del servidor y su hostname) y el puerto (PROXY_HTTPS_PORT, 8443), y valida
# el certificado de la empresa si se configuró (PROXY_TLS_CERT / PROXY_TLS_KEY). Antes de tocar Docker.
# shellcheck source=proxy/https.lib.sh
source ./proxy/https.lib.sh
https_preparar
# Con la extensión de redirección, la URL pública de la pasarela para los kits: https por defecto (el .env la pisa).
[ "${ELEA_REDIRECT:-}" != 1 ] || https_fijar_url_pasarela

# ── 2. Registro de imágenes ─────────────────────────────────────────────────────────
# Las imágenes son públicas (decisión del 14-sep-2026): no hace falta login. Solo si la
# descarga falla (imagen todavía privada, o red que exige credenciales) se pide un token.
# El motor va FIJADO POR DIGEST en docker-compose.yml (decisión D3, oct-2026): este script nunca lo
# cambia por su cuenta; subirlo es una tarea deliberada (README, "Subir la versión del motor").
if [ -n "${ENGINE_IMAGE:-}" ] && [ "${ENGINE_IMAGE#*@sha256:}" = "${ENGINE_IMAGE}" ]; then
  echo "  ! ENGINE_IMAGE (.env) no es un digest (…@sha256:…): el motor puede cambiar de versión sin aviso." >&2
fi
if ! docker compose pull --quiet engine >/dev/null 2>&1; then
  log "No se pudo descargar la imagen del Guardian sin credenciales — login al registro"
  echo "Pedí un token de lectura (read:packages) a quien te dio este instalador."
  read -rp "Usuario de GitHub: " GHCR_USER
  read -rsp "Token: " GHCR_TOKEN; echo
  echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin || die "No se pudo autenticar al registro."
fi

# ── 2b. Base propia del motor ───────────────────────────────────────────────────────
# El motor tiene su base (ENGINE_DB) separada de la del Guardian: con la base compartida su migrador
# borra las tablas del Guardian. Una instalación vieja la tiene compartida: se migra ANTES de
# levantar nada con el compose nuevo (que apuntaría el motor a una base vacía). Una instalación
# nueva no tiene nada que migrar. Detalle y vuelta atrás: README.
rc=0; ./migrar-base-motor.sh --detectar || rc=$?
case "$rc" in
  0) log "Esta instalación tiene la base del motor compartida con el Guardian: se separa (hay un corte de ~1-3 min)"
     ./migrar-base-motor.sh || die "La migración de la base del motor no terminó. Estado y vuelta atrás: README, «Separar la base del motor»." ;;
  3) # Nada que separar. Antes de actualizar una instalación con datos, copia de las dos bases.
     if [ "${ELEA_SIN_RESPALDO:-0}" != 1 ]; then
       log "Copia de seguridad de las bases (antes de tocar nada)"
       ./respaldo.sh || die "Sin copia previa no se actualiza (ELEA_SIN_RESPALDO=1 para omitirla bajo tu responsabilidad)."
     fi ;;
  *) die "Estado de las bases ambiguo (código ${rc}): no se actualiza nada. Ver README, «Estado ambiguo»." ;;
esac

# ── 3. Levantar todo menos el cliente (necesita keys que generamos después) ─────────
log "Descargando y levantando el motor y AnythingLLM (sin depender de backend todavía)"
docker compose pull db redis nlp-analyzer engine anythingllm 2>&1 | grep -v "^ " || true
docker compose up -d db redis nlp-analyzer engine anythingllm

log "Esperando a que el motor termine de migrar su base (puede tardar varios minutos en el primer arranque con una base nueva)"
for i in $(seq 1 60); do
  status=$(docker inspect elea-engine --format '{{.State.Health.Status}}' 2>/dev/null || echo "starting")
  [ "$status" = "healthy" ] && break
  sleep 5
  [ "$i" -eq 60 ] && die "El motor no terminó de arrancar después de 5 minutos. Revisá: ./elea-logs.sh engine"
done

# El puerto 8091 lo publica el proxy (api-proxy), no el backend: el proxy niega /api/v1/internal/*.
# Si OTRO proceso lo tiene ocupado el proxy no arranca: mejor decirlo antes que esperar 3 minutos.
# (Si ya corren el backend o el proxy de este instalador, el 8091 es nuestro: compose lo reasigna solo.)
if command -v ss >/dev/null && ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq '[:.]8091$' \
   && [ -z "$(docker ps -q -f name=^/elea-backend$ -f name=^/elea-api-proxy$)" ]; then
  die "El puerto 8091 ya lo usa otro proceso (no es este instalador): liberalo y volvé a correr. Ver: ss -ltnp | grep 8091"
fi

# Lo mismo para el puerto HTTPS del proxy.
if command -v ss >/dev/null && ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${PROXY_HTTPS_PORT}\$" \
   && [ -z "$(docker ps -q -f name=^/elea-api-proxy$)" ]; then
  die "El puerto HTTPS ${PROXY_HTTPS_PORT} ya lo usa otro proceso (no es este instalador): liberalo o poné otro en PROXY_HTTPS_PORT (.env) y volvé a correr. Ver: ss -ltnp | grep ${PROXY_HTTPS_PORT}"
fi

log "Levantando el Guardian (backend + proxy de la API + panel)"
docker compose pull backend api-proxy frontend 2>&1 | grep -v "^ " || true
# Juntos y en una sola orden: al actualizar una instalación vieja, el backend viejo todavía publica
# el 8091; compose lo recrea sin puerto ANTES de arrancar el proxy (que depende de él) y lo toma.
docker compose up -d backend api-proxy frontend

log "Esperando a que el Guardian esté listo (puede tardar el primer arranque)"
for i in $(seq 1 60); do
  curl -sf -o /dev/null http://localhost:8091/health && break
  sleep 3
  [ "$i" -eq 60 ] && die "El backend no respondió después de 3 minutos. Revisá: ./elea-logs.sh backend"
done

# HTTPS: el proxy habla TLS con el mismo enrutamiento que el 8091. Se prueba por el puerto publicado, con el
# primer nombre del certificado y sin validar la cadena (-k: esto comprueba el proxy, no la confianza de las PC),
# y se exige que el plano interno siga cerrado (404) también por acá: si no, se corta la instalación.
HTTPS_URL="https://${PROXY_TLS_NAMES%%,*}:${PROXY_HTTPS_PORT}"
log "Comprobando el HTTPS del proxy (${HTTPS_URL})"
for i in $(seq 1 20); do
  curl -sk -f -o /dev/null --connect-to "::127.0.0.1:" "${HTTPS_URL}/health" && break
  sleep 3
  [ "$i" -eq 20 ] && die "El HTTPS del proxy no respondió (${HTTPS_URL}/health). Revisá: ./elea-logs.sh api-proxy"
done
cod=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 --connect-to "::127.0.0.1:" "${HTTPS_URL}/api/v1/internal/identity" || true)
[ "$cod" = 404 ] || die "/api/v1/internal/identity dio ${cod:-sin respuesta} por el HTTPS (se esperaba 404): el plano interno no está cerrado por ese puerto. No se sigue."

# ── 4. Bootstrap del admin (primer login lo crea) ───────────────────────────────────
log "Configurando el usuario administrador"
ADMIN_LOGIN=$(curl -s -X POST http://localhost:8091/api/v1/users/login \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"admin\",\"password\":\"${ADMIN_PASSWORD}\"}")
ADMIN_TOKEN=$(echo "$ADMIN_LOGIN" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("access_token",""))')
[ -n "$ADMIN_TOKEN" ] || die "No se pudo crear/autenticar el admin. Respuesta: $ADMIN_LOGIN"

# ── 4b. Usuario de cumplimiento (super_admin) ───────────────────────────────────────
# Solo en una instalación nueva (marca puesta al generar el .env). Es otro usuario que el admin de la
# empresa: crea Auditores y relaja el enmascarado de la 057. Su contraseña la genera el backend, se
# muestra UNA vez (./crear-super-admin.sh) y no pasa por este script ni por ningún archivo. Si falla no
# se aborta la instalación: la marca queda y la próxima corrida (o el comando a mano) lo reintenta.
SUPER_ADMIN_NOTA=""
if [ "${ELEA_SUPER_ADMIN_PENDIENTE:-}" = 1 ]; then
  log "Creando el usuario de cumplimiento (super_admin)"
  if ./crear-super-admin.sh; then
    del_env ELEA_SUPER_ADMIN_PENDIENTE
  else
    echo "  ! No se pudo crear el usuario de cumplimiento; la instalación sigue. Reintentá más tarde: ./crear-super-admin.sh" >&2
    SUPER_ADMIN_NOTA="Falta crear el usuario de cumplimiento: ./crear-super-admin.sh"
  fi
else
  SUPER_ADMIN_NOTA="Usuario de cumplimiento (super_admin): ./crear-super-admin.sh lo crea una vez (si ya hay uno, no toca nada)"
fi

# ── 5. API key de AnythingLLM (solo si no la generamos antes) ──────────────────────
if [ -z "${ANYTHINGLLM_API_KEY:-}" ]; then
  log "Esperando a AnythingLLM y generando su API key"
  for i in $(seq 1 30); do
    allm_curl -f -o /dev/null http://localhost:3001/api/ping && break
    sleep 2
    [ "$i" -eq 30 ] && die "AnythingLLM no respondió después de 1 minuto. Revisá: ./elea-logs.sh anythingllm"
  done
  ANYTHINGLLM_API_KEY=$(docker exec elea-anythingllm node -e "
    const {PrismaClient} = require('/app/server/node_modules/@prisma/client');
    const p = new PrismaClient();
    p.api_keys.create({data:{name:'elea-rag-client', secret: require('crypto').randomBytes(32).toString('hex')}})
      .then(r => console.log(r.secret)).finally(() => process.exit());
  " | tail -1)
  [ -n "$ANYTHINGLLM_API_KEY" ] || die "No se pudo generar la API key de AnythingLLM."
  set_env ANYTHINGLLM_API_KEY "${ANYTHINGLLM_API_KEY}"
fi

# ── 6. Virtual keys de servicio (proveedor LLM de AnythingLLM + motores) ────────────
# Spec 050 (12-sep-2026): el Hub YA NO enmascara (Guardian no recibe archivos), así que la
# cuenta svc.rag-masking y MASKING_VIRTUAL_KEY dejaron de crearse. DB-GPT (svc.dbgpt-excel)
# se retiró: lo reemplaza el motor tabular propio. Cada motor tiene su propia llave `svc.*`.
if [ -z "${TABULAR_ENGINE_VIRTUAL_KEY:-}" ]; then
  log "Creando usuarios y llaves de servicio en el Guardian"
  # NO usar `die` adentro (corre en subshell vía `$(...)`, un exit ahí no frena al
  # script principal) — devuelve vacío en error y el caller lo chequea.
  create_service_key() {
    local username="$1" email="$2" name="$3" can_act_on_behalf="${4:-false}" rpm="${5:-120}" tpm="${6:-200000}"
    local password user_id
    password=$(python3 -c 'import secrets;print(secrets.token_urlsafe(24))')
    curl -s -X POST http://localhost:8091/api/v1/users \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" -H 'Content-Type: application/json' \
      -d "{\"username\":\"${username}\",\"email\":\"${email}\",\"role\":\"client\",\"password\":\"${password}\"}" \
      > /tmp/elea_svc_user.json
    user_id=$(python3 -c 'import json;d=json.load(open("/tmp/elea_svc_user.json"));print(d.get("id",""))')
    if [ -z "$user_id" ]; then
      # Actualización de una instalación existente: la cuenta ya está (la creó un instalador
      # anterior) → se reutiliza y se le emite una llave nueva; la vieja sigue válida.
      user_id=$(curl -s "http://localhost:8091/api/v1/users?include_service=true" -H "Authorization: Bearer ${ADMIN_TOKEN}" \
        | python3 -c 'import json,sys;u=sys.argv[1];print(next((x["id"] for x in json.load(sys.stdin) if x.get("username")==u),""))' "${username}")
      if [ -z "$user_id" ]; then
        echo "ERROR:usuario '${username}': $(cat /tmp/elea_svc_user.json)" >&2
        return 1
      fi
      echo "  (la cuenta ${username} ya existía: se revoca su llave anterior y se emite una nueva)" >&2
      # El motor exige alias únicos entre TODAS las llaves, incluso revocadas (visto en el
      # servidor de Elea, 14-sep): la nueva lleva sufijo de fecha.
      name="${name}-$(date +%Y%m%d%H%M)"
      # Guardian permite UNA llave activa por cuenta y herramienta: revocar la vieja primero.
      for kid in $(curl -s http://localhost:8091/api/v1/keys -H "Authorization: Bearer ${ADMIN_TOKEN}" \
          | python3 -c 'import json,sys;u=sys.argv[1];print(" ".join(k["id"] for k in json.load(sys.stdin) if k.get("user_id")==u and k.get("tool_type")=="servicio"))' "${user_id}"); do
        curl -s -o /dev/null -X DELETE "http://localhost:8091/api/v1/keys/${kid}" -H "Authorization: Bearer ${ADMIN_TOKEN}"
      done
    fi
    # Spec 043 (US2/US4, T032): tool_type="servicio" (ya no "chat-ui" — esas dos llaves
    # se auditaban bajo la superficie del chat interno, diagnostico.md §3/§4 de la 043) +
    # can_act_on_behalf explícito por llave (solo la de enmascarado lo necesita, contrato 2).
    curl -s -X POST http://localhost:8091/api/v1/keys \
      -H "Authorization: Bearer ${ADMIN_TOKEN}" -H 'Content-Type: application/json' \
      -d "{\"name\":\"${name}\",\"user_id\":\"${user_id}\",\"tool_type\":\"servicio\",\"can_act_on_behalf\":${can_act_on_behalf},\"rpm_limit\":${rpm},\"tpm_limit\":${tpm}}" \
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
  ANYTHINGLLM_PROVIDER_VIRTUAL_KEY=$(create_service_key "svc.anythingllm-provider" "svc.anythingllm-provider@elea-internal.com" "anythingllm-provider" "false") \
    || die "No se pudo aprovisionar la llave del proveedor de AnythingLLM (ver error arriba)."
  set_env ANYTHINGLLM_PROVIDER_VIRTUAL_KEY "${ANYTHINGLLM_PROVIDER_VIRTUAL_KEY}"
  # Motor tabular (planillas, spec 050 FR-031): can_act_on_behalf=true → manda
  # X-Guardian-Acting-User con la persona que preguntó.
  TABULAR_ENGINE_VIRTUAL_KEY=$(create_service_key "svc.tabular" "svc.tabular@elea-internal.com" "tabular" "true") \
    || die "No se pudo aprovisionar la llave del motor de planillas (ver error arriba)."
  set_env TABULAR_ENGINE_VIRTUAL_KEY "${TABULAR_ENGINE_VIRTUAL_KEY}"
  # Motor de presentaciones (Presenton): no permite cabeceras extra → sin acting-user.
  # Presenton manda varias diapositivas en paralelo, con imagen (plantillas): cupo alto de
  # tokens por minuto, si no el motor devuelve 429 a mitad de la creación de una plantilla.
  PRESENTON_ENGINE_VIRTUAL_KEY=$(create_service_key "svc.presenton" "svc.presenton@elea-internal.com" "presenton" "false" 300 2000000) \
    || die "No se pudo aprovisionar la llave del motor de presentaciones (ver error arriba)."
  set_env PRESENTON_ENGINE_VIRTUAL_KEY "${PRESENTON_ENGINE_VIRTUAL_KEY}"
  # Token interno Hub → tabular (no es de Guardian; solo viaja por la red interna).
  TABULAR_INTERNAL_TOKEN=$(python3 -c 'import secrets;print(secrets.token_hex(32))')
  set_env TABULAR_INTERNAL_TOKEN "${TABULAR_INTERNAL_TOKEN}"
fi

# Siempre (idempotente): antes vivía dentro del bloque de arriba y, si la primera corrida se
# cortaba justo después de crear las llaves, la segunda ya no conectaba AnythingLLM al motor.
log "Conectando AnythingLLM al motor del Guardian"
[ -n "${ANYTHINGLLM_PROVIDER_VIRTUAL_KEY:-}" ] || die "Falta ANYTHINGLLM_PROVIDER_VIRTUAL_KEY en .env (instalación a medias: borrá TABULAR_ENGINE_VIRTUAL_KEY del .env y volvé a correr)."
ALLM_RESP=$(allm_curl -X POST http://localhost:3001/api/v1/system/update-env \
  -H "Authorization: Bearer ${ANYTHINGLLM_API_KEY}" -H 'Content-Type: application/json' \
  -d "{\"LLMProvider\":\"generic-openai\",\"GenericOpenAiBasePath\":\"http://engine:4000/v1\",\"GenericOpenAiModelPref\":\"${ANYTHINGLLM_MODEL:-azure-gpt-4o-mini}\",\"GenericOpenAiKey\":\"${ANYTHINGLLM_PROVIDER_VIRTUAL_KEY}\"}")
echo "$ALLM_RESP" | grep -q '"error":false' || die "AnythingLLM no aceptó la configuración del motor: ${ALLM_RESP}"

# ── 7. Levantar los motores y el Hub (ya con las keys en .env) ─────────────────────
log "Levantando el motor de planillas, el de presentaciones y Eleia Hub"
docker compose pull tabular presenton client 2>&1 | grep -v "^ " || true
# --remove-orphans: al actualizar desde una instalación anterior borra el contenedor de DB-GPT
# (exact-analysis-engine), que ya no está en este compose.
docker compose up -d --remove-orphans tabular presenton client

# ── 8. Extensión de redirección de modelos (opt-in) ─────────────────────────────────
# Sin ELEA_REDIRECT no hace nada (ni escribe ni recrea nada). Con ELEA_REDIRECT=1 comprueba las condiciones, toma
# el respaldo y cambia backend, panel y motor a las imágenes -ext. Si se la saca de .env, la apaga (nivel 1).
./activar-redirect.sh || die "La extensión de redirección no quedó activa (el resto de la instalación está listo). Ver el mensaje de arriba y README, «Extensión de redirección de modelos»."

echo
echo "================================================================"
echo "  Listo. Todo corriendo."
echo
echo "  Panel del Guardian:  http://localhost:8090"
echo "  API del Guardian:    http://localhost:8091/docs"
echo "  Eleia Hub:           http://localhost:8095   (chat con documentos, planillas, presentaciones)"
echo "  Plantillas (admin):  http://localhost:8097/templates   (cargar la plantilla corporativa)"
echo "  API por HTTPS:       ${HTTPS_URL}/api/v1/gw   (Claude Desktop; nombres del certificado: ${PROXY_TLS_NAMES})"
if [ -n "${PROXY_TLS_CERT:-}" ]; then
  echo "                       con el certificado de la empresa (las PC ya confían en él)"
else
  echo "                       con la CA interna del proxy: ./exportar-ca.sh copia su raíz pública para instalarla en las PC (README, «HTTPS para Claude Desktop»)"
fi
echo
echo "  Admin:  usuario 'admin', contraseña: ${ADMIN_PASSWORD}"
echo "  (guardada en .env — no se vuelve a mostrar)"
echo
[ -z "${SUPER_ADMIN_NOTA}" ] || { echo "  ${SUPER_ADMIN_NOTA}"; echo; }
echo "  Para cada persona que va a probar: crear su usuario en el Guardian"
echo "  (POST http://localhost:8091/api/v1/users con el token de admin, o pedime"
echo "  el script create-tester.sh) — todas entran a http://localhost:8095 con su"
echo "  propio usuario, sesiones aisladas por navegador."
echo "================================================================"
