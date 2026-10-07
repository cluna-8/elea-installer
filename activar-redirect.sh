#!/usr/bin/env bash
# Extensión de redirección de modelos: activación OPT-IN (ELEA_REDIRECT=1) y su apagado. Lo llama ./install.sh al
# final; también se puede correr solo (con el Guardian ya levantado).
#
#   ELEA_REDIRECT=1 (en .env o en el entorno) + ELEA_EXT_VERSION=AAAA-MM-DD (la versión publicada con sus -ext)
#       → activa: comprueba las condiciones, toma el respaldo, escribe el entorno de la extensión, cambia
#         backend, panel y motor a las imágenes -ext, verifica /api/v1/redirect/health y siembra el catálogo.
#   sin ELEA_REDIRECT (o 0), en una instalación que NO la activó nunca → no hace nada (ni un byte distinto).
#   sin ELEA_REDIRECT (o 0), en una que la activó → «apagar» (nivel 1): quita GATEWAY_PLUGINS y PLUGIN_PACKAGES y
#         recrea; CONSERVA las imágenes -ext y ALEMBIC_EXTRA_VERSION_LOCATIONS (con las migraciones ya aplicadas la
#         imagen base no arranca). Volver a las imágenes base es solo con el respaldo: README.
#
# Condiciones para activar (gate; si falta una NO se toca nada y sale con error que la explica):
#   1) el compose del instalador tiene el proxy de la API y el backend no publica puertos;
#   2) ELEA_EXT_VERSION >= ELEA_EXT_MIN_VERSION (el tag mínimo del backend base que trae el chequeo de origen del
#      canal interno; lo fija install.sh, no se puede bajar desde .env);
#   3) /api/v1/internal/* da 404 por el puerto publicado (8091).
#
# El entorno de la extensión (secretos generados acá) vive FUERA del repo, con modo 600:
#   ${ELEA_REDIRECT_ENV_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/elea/redirect.env}
# Nunca se imprime su contenido. Lo que el operador agregue ahí (credenciales de destinos) se conserva.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=base-motor.lib.sh
source ./base-motor.lib.sh
# shellcheck source=proxy/https.lib.sh
source ./proxy/https.lib.sh

# El mínimo lo fija install.sh (o quien llama); un valor puesto en .env no lo puede bajar.
MINIMA_FIJADA="${ELEA_EXT_MIN_VERSION-}"
if [ -f .env ]; then set -a; source .env; set +a; fi
ELEA_EXT_MIN_VERSION="$MINIMA_FIJADA"

API="${ELEA_API_URL:-http://localhost:8091}"
OVERRIDE=docker-compose.redirect.yml
RE_FECHA='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
SEEDS_DIR=/opt/sentinel-ext/seeds
SEEDS_REGIONES="$SEEDS_DIR/regions.americas.yaml"
SEEDS_HABILITACION="$SEEDS_DIR/habilitacion-explicita.yaml"
SEED_CATALOGO="$SEEDS_DIR/catalog-seed.azure-demo.yaml"

# ── Entorno de la extensión: edición por clave, sin tocar lo que el operador puso ───────────────────
envx_set() { # archivo clave valor (los valores gestionados acá no llevan «|»)
  if grep -q "^$2=" "$1"; then sed -i "s|^$2=.*|$2=$3|" "$1"; else printf '%s=%s\n' "$2" "$3" >> "$1"; fi
}
envx_del() { sed -i "/^$2=/d" "$1"; }
envx_get() { grep "^$2=" "$1" | head -n1 | cut -d= -f2- || true; }
secreto() { python3 -c 'import base64,secrets;print(base64.b64encode(secrets.token_bytes(48)).decode())'; }

ruta_entorno() {
  ENV_EXT="${ELEA_REDIRECT_ENV_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/elea/redirect.env}"
  case "$ENV_EXT" in /*) ;; *) die "ELEA_REDIRECT_ENV_FILE tiene que ser una ruta absoluta (es: $ENV_EXT)." ;; esac
  case "$(realpath -m "$ENV_EXT")/" in
    "$(pwd -P)"/*) die "El entorno de la extensión (secretos) no puede estar dentro del repo del instalador, que se versiona: $ENV_EXT" ;;
  esac
}

# Intentos y pausa de las esperas (60 × 3 s el backend, 60 × 5 s el motor, como install.sh); las pruebas los acortan.
INTENTOS="${ELEA_ESPERA_INTENTOS:-60}"
esperar_backend() {
  local i
  for i in $(seq 1 "$INTENTOS"); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$API/health" || true)" = 200 ] && return 0
    sleep "${ELEA_ESPERA_PAUSA:-3}"
  done
  return 1
}

esperar_motor() {
  local i status
  for i in $(seq 1 "$INTENTOS"); do
    status=$(docker inspect elea-engine --format '{{.State.Health.Status}}' 2>/dev/null || echo starting)
    [ "$status" = healthy ] && return 0
    sleep "${ELEA_ESPERA_PAUSA:-5}"
  done
  return 1
}

# ── Apagar (nivel 1) ────────────────────────────────────────────────────────────────────────────────
apagar() {
  log "Extensión de redirección: apagando (nivel 1)"
  ruta_entorno
  [ -n "${EXTRA_ENV_FILE:-}" ] && ENV_EXT="$EXTRA_ENV_FILE"
  [ -f "$ENV_EXT" ] || die "Falta el archivo de entorno de la extensión ($ENV_EXT): sin él no se puede apagar con seguridad. Ver README, «vuelta atrás»."
  [[ "${ELEA_EXT_VERSION:-}" =~ $RE_FECHA ]] || die "Falta ELEA_EXT_VERSION en .env: las imágenes -ext se conservan al apagar y compose las necesita. Ver README."
  chmod 600 "$ENV_EXT"
  envx_del "$ENV_EXT" GATEWAY_PLUGINS
  envx_del "$ENV_EXT" PLUGIN_PACKAGES
  export COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml:$OVERRIDE}" EXTRA_ENV_FILE="$ENV_EXT"
  docker compose up -d engine backend api-proxy || die "No se pudieron recrear los servicios."
  esperar_backend || die "El backend no respondió después de apagar la extensión. Revisá: ./elea-logs.sh backend"
  echo "  Extensión apagada: la política deja de aplicarse y las rutas de la extensión desaparecen."
  echo "  Siguen las imágenes -ext y las migraciones de la extensión (la imagen base no arrancaría con ellas aplicadas)."
  echo "  Volver a las imágenes base es SOLO restaurando el respaldo previo a la activación: README, «Vuelta atrás»."
}

# ── Activar ─────────────────────────────────────────────────────────────────────────────────────────
activar() {
  log "Extensión de redirección: activando (ELEA_REDIRECT=1)"
  [[ "${ELEA_EXT_VERSION:-}" =~ $RE_FECHA ]] \
    || die "Falta ELEA_EXT_VERSION (AAAA-MM-DD, la versión publicada con sus imágenes -ext) en .env: sin ella no se elige ninguna imagen (no hay default: ni latest ni una fecha implícita)."
  [[ "$ELEA_EXT_MIN_VERSION" =~ $RE_FECHA ]] \
    || die "ELEA_REDIRECT=1 todavía no se puede activar: el tag mínimo del backend que trae el chequeo de origen del canal interno (ELEA_EXT_MIN_VERSION, install.sh) sigue sin fijar (${ELEA_EXT_MIN_VERSION:-vacío}). Lo fija el release que trae la extensión; hasta entonces no se activa."
  [[ ! "$ELEA_EXT_VERSION" < "$ELEA_EXT_MIN_VERSION" ]] \
    || die "ELEA_EXT_VERSION=${ELEA_EXT_VERSION} es anterior al mínimo ${ELEA_EXT_MIN_VERSION} (el primer backend con el chequeo de origen del canal interno): no se activa. Usá una versión >= ${ELEA_EXT_MIN_VERSION}."

  ruta_entorno
  # URL pública de la pasarela para los kits: si no hay una en .env, https://<primer nombre de PROXY_TLS_NAMES>:<puerto>/api/v1/gw
  # (el .env la pisa). Antes de recrear el backend, que es quien la lee.
  https_fijar_url_pasarela
  command -v docker >/dev/null || die "Falta Docker."
  local v
  v=$(docker compose version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
  [ "$(printf '%s\n2.24.0\n' "$v" | sort -V | head -n1)" = 2.24.0 ] || die "Docker Compose ${v:-?} es anterior a 2.24: no entiende env_file opcional. Actualizalo."

  export COMPOSE_FILE="docker-compose.yml:$OVERRIDE" EXTRA_ENV_FILE="$ENV_EXT"

  # Gate 1: proxy delante del backend y backend sin puertos, sobre la configuración EFECTIVA (base + override).
  local cfg
  cfg=$(docker compose config --format json 2>/dev/null) || cfg=""
  [ -n "$cfg" ] || die "No se pudo leer la configuración de docker compose (docker compose config)."
  printf '%s' "$cfg" | python3 -c '
import json, sys
s = json.load(sys.stdin).get("services", {})
if "api-proxy" not in s:
    sys.exit("falta el servicio de proxy de la API (api-proxy): la extensión no se activa sin el proxy que niega /api/v1/internal/*")
if s.get("backend", {}).get("ports"):
    sys.exit("el backend publica puertos: tiene que salir solo el proxy (el backend publicado dejaría abierto /api/v1/internal/*)")
' || die "Falta la dependencia de la vuelta 2 de la base propia del motor (proxy y canal interno cerrado). Actualizá este instalador. Ver README."

  # Gate 3: el plano interno da 404 por el puerto publicado, antes de activar.
  local cod
  cod=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$API/api/v1/internal/identity" || true)
  [ "$cod" = 404 ] || die "/api/v1/internal/identity dio ${cod:-sin respuesta} por el puerto publicado (se esperaba 404): el plano interno no está cerrado, o el Guardian no está levantado. No se activa la extensión."

  log "Bajando las imágenes -ext (${ELEA_EXT_VERSION})"
  docker compose pull backend frontend engine || die "No se pudieron bajar las imágenes -ext de la versión ${ELEA_EXT_VERSION} (¿se publicaron? ¿ELEA_EXT_VERSION correcta?). No se activa nada."

  # Respaldo ANTES de aplicar las migraciones de la extensión: volver a las imágenes base solo se puede con él.
  if [ "${ELEA_REDIRECT_ACTIVADA:-}" != 1 ]; then
    if [ "${ELEA_SIN_RESPALDO:-0}" = 1 ]; then
      aviso "ELEA_SIN_RESPALDO=1: se activa SIN respaldo previo. Sin él no hay vuelta atrás a las imágenes base."
    else
      log "Respaldo de las bases (antes de aplicar las migraciones de la extensión)"
      ./respaldo.sh || die "Sin respaldo previo no se activa la extensión (ELEA_SIN_RESPALDO=1 lo omite, bajo tu responsabilidad)."
    fi
  fi

  # Entorno de la extensión: fuera del repo, modo 600. Las llaves se generan UNA vez y no se pisan.
  # La carpeta se crea 700 solo si no existía (nunca se cambia el modo de una carpeta ajena).
  ( umask 077; [ -d "$(dirname "$ENV_EXT")" ] || mkdir -p "$(dirname "$ENV_EXT")"; [ -f "$ENV_EXT" ] || : > "$ENV_EXT" )
  chmod 600 "$ENV_EXT"
  if ! grep -q '^# Entorno de la extensión' "$ENV_EXT"; then
    { echo "# Entorno de la extensión de redirección (lo escribe ./activar-redirect.sh). SECRETOS: modo 600, fuera del repo, no versionar."
      echo "# Se pasa a backend y motor por EXTRA_ENV_FILE. Credenciales de destinos: REDIRECT_CRED_<NOMBRE>=…"; } | cat - "$ENV_EXT" > "$ENV_EXT.nuevo"
    mv "$ENV_EXT.nuevo" "$ENV_EXT"; chmod 600 "$ENV_EXT"
  fi
  envx_set "$ENV_EXT" GATEWAY_PLUGINS sentinel.redirect.plugin
  envx_set "$ENV_EXT" PLUGIN_PACKAGES sentinel.redirect.api,sentinel.catalog.api
  envx_set "$ENV_EXT" ALEMBIC_EXTRA_VERSION_LOCATIONS /opt/sentinel-ext/sentinel/migrations
  envx_set "$ENV_EXT" SENTINEL_ENTITY_REGION latam_ar
  envx_set "$ENV_EXT" REDIRECT_SEED_FILES "$SEEDS_REGIONES,$SEEDS_HABILITACION"
  envx_set "$ENV_EXT" REDIRECT_CACHE_TTL_S 5
  [ -n "$(envx_get "$ENV_EXT" REDIRECT_INTERNAL_KEY)" ] || printf 'REDIRECT_INTERNAL_KEY=%s\n' "$(secreto)" >> "$ENV_EXT"
  [ -n "$(envx_get "$ENV_EXT" MASKING_NONCE_KEY)" ]     || printf 'MASKING_NONCE_KEY=%s\n' "$(secreto)" >> "$ENV_EXT"
  paso "Entorno de la extensión: $ENV_EXT (modo 600, fuera del repo; no se muestra su contenido)"

  # Lo que recuerda el instalador (no hay secretos acá): así todo `docker compose` de esta carpeta ve las -ext.
  # ELEA_EXT_VERSION también: con COMPOSE_FILE puesto, todo `docker compose` de la carpeta la necesita.
  set_env ELEA_REDIRECT 1
  set_env ELEA_EXT_VERSION "$ELEA_EXT_VERSION"
  set_env COMPOSE_FILE "docker-compose.yml:$OVERRIDE"
  set_env EXTRA_ENV_FILE "$ENV_EXT"
  set_env ELEA_REDIRECT_ACTIVADA 1

  log "Recreando el motor, el backend y el panel con las imágenes -ext"
  docker compose up -d engine || die "No se pudo recrear el motor."
  esperar_motor || die "El motor no terminó de arrancar después de 5 minutos. Revisá: ./elea-logs.sh engine"
  docker compose up -d backend api-proxy frontend || die "No se pudieron recrear backend, proxy y panel."
  esperar_backend || die "El backend no respondió en 3 minutos. Con la extensión, una migración fallida ABORTA el arranque: revisá ./elea-logs.sh backend (¿migración de la extensión?). Vuelta atrás: README."

  local f
  for f in "$SEEDS_REGIONES" "$SEEDS_HABILITACION"; do
    docker compose exec -T backend test -f "$f" \
      || die "Falta ${f} dentro de la imagen del backend -ext (${ELEA_EXT_VERSION}): esa versión no trae todos los seeds. Usá una versión publicada que los incluya."
  done

  log "Verificando la salud de la extensión (${API}/api/v1/redirect/health)"
  local cuerpo; cuerpo=$(mktemp)
  cod=$(curl -s -o "$cuerpo" -w '%{http_code}' --max-time 10 "$API/api/v1/redirect/health" || true)
  if [ "$cod" != 200 ]; then
    local motivo; motivo=$(cat "$cuerpo" 2>/dev/null); rm -f "$cuerpo"
    case "$cod" in
      404) die "/api/v1/redirect/health dio 404: la extensión no está activa en el backend (¿imagen -ext inerte, sin GATEWAY_PLUGINS/PLUGIN_PACKAGES? ¿no llegó el entorno?). Revisá ./elea-logs.sh backend." ;;
      503) die "/api/v1/redirect/health dio 503 (${motivo:-sin detalle}): rige el respaldo en código (región sin resolver o sin fila de región; los seeds no se cargaron). Todo lo redirigido se rechaza hasta que se corrija. Revisá ./elea-logs.sh backend." ;;
      *)   die "/api/v1/redirect/health dio ${cod:-sin respuesta} (se esperaba 200). Revisá ./elea-logs.sh backend." ;;
    esac
  fi
  rm -f "$cuerpo"
  paso "Salud de la extensión: 200 (regiones y habilitación cargadas al arrancar)"

  # Catálogo de ejemplo de Azure: UNA vez (el administrador lo completa en «Modelos»; no se vuelve a pisar).
  if [ "${ELEA_REDIRECT_CATALOGO:-}" != 1 ]; then
    if docker compose exec -T backend python -m sentinel.catalog.seed "$SEED_CATALOGO"; then
      set_env ELEA_REDIRECT_CATALOGO 1
    else
      aviso "No se pudo sembrar el catálogo de ejemplo; la extensión sigue activa. Reintentá: docker compose exec -T backend python -m sentinel.catalog.seed $SEED_CATALOGO"
    fi
  fi

  echo
  echo "  Extensión activa. Pasarela para Claude Desktop y Claude Code: ${REDIRECT_GATEWAY_URL:-${API}/api/v1/gw}"
  [ -z "${REDIRECT_GATEWAY_URL:-}" ] || echo "  (Claude Desktop pide https: si el proxy usa su CA interna, ./exportar-ca.sh copia la raíz para las PC. README, «HTTPS para Claude Desktop».)"
  echo "  Falta (en el panel, «Modelos»): jurisdicción de inferencia y entidad responsable de cada destino, y una llave por persona."
  echo "  Vuelta atrás y verificaciones: README, «Extensión de redirección de modelos»."
}

case "${ELEA_REDIRECT:-}" in
  1) activar ;;
  ""|0) [ "${ELEA_REDIRECT_ACTIVADA:-}" != 1 ] || apagar ;;
  *) die "ELEA_REDIRECT=${ELEA_REDIRECT} no es válido: usá 1 para activar la extensión, o quitá la variable (o 0) para apagarla." ;;
esac
