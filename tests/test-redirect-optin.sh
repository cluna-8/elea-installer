#!/usr/bin/env bash
# Pruebas de la activación OPT-IN de la extensión de redirección de modelos (ELEA_REDIRECT=1), sin
# levantar nada: ./activar-redirect.sh, docker-compose.redirect.yml y su cableado en install.sh, con el
# Docker y el curl de mentira de tests/fake-docker. El compose se lee con tests/render-compose.py
# (expande las variables como compose; no usa Docker).
#   T100: sin ELEA_REDIRECT nada cambia; con ELEA_REDIRECT=1 se eligen las imágenes -ext, se escribe el
#         entorno de la extensión (modo 600, fuera del repo), se siembra y se apaga sacando la variable.
#   T101: el proxy y INTERNAL_ALLOWED_CIDRS=auto de la base siguen y /api/v1/internal/* sigue cerrado
#         desde afuera con la extensión.
# Correr:  bash tests/test-redirect-optin.sh
set -uo pipefail
AQUI="$(cd "$(dirname "$0")/.." && pwd)"
FALLOS=0
ok()   { echo "  ok   $1"; }
falla() { echo "  FALLA $1"; FALLOS=$((FALLOS + 1)); }
salta() { echo "  salta $1"; }
chequear() { local desc="$1"; shift; if "$@"; then ok "$desc"; else falla "$desc"; fi; }
chequear_no() { local desc="$1"; shift; if "$@"; then falla "$desc"; else ok "$desc"; fi; }

RENDER="$AQUI/tests/render-compose.py"
VERSION=2026-11-01       # versión «publicada» de prueba
MINIMA=2026-10-20        # tag mínimo que trae S15, fijado para las pruebas (el real lo fija el release)
chequear "hay python3 con PyYAML" python3 -c 'import yaml'

# Variables que exige el compose para renderizar (valores de relleno).
export POSTGRES_PASSWORD=pw ENGINE_MASTER_KEY=sk-x FERNET_SECRET_KEY=f JWT_SECRET_KEY=j
export AZURE_OPENAI_API_KEY=a AZURE_OPENAI_ENDPOINT=https://x AZURE_API_VERSION=v

# Carpeta de trabajo descartable: el «repo» con copias de los scripts y archivos, un HOME propio (el
# entorno de la extensión va fuera del repo) y los dobles de docker y curl.
nuevo_entorno() {
  T=$(mktemp -d); R="$T/repo"; mkdir -p "$R/proxy" "$T/home"
  cp "$AQUI"/{install.sh,activar-redirect.sh,base-motor.lib.sh,docker-compose.yml,docker-compose.redirect.yml,.env.example} "$R"/ 2>/dev/null
  cp "$AQUI/proxy/Caddyfile" "$R/proxy/"
  # respaldo.sh de mentira: anota el orden de las llamadas (el de verdad lo cubre test-base-motor.sh).
  printf '#!/usr/bin/env bash\necho respaldo >> "%s/orden"\nexit "${RESPALDO_RC:-0}"\n' "$T" > "$R/respaldo.sh"; chmod +x "$R/respaldo.sh"
  printf 'POSTGRES_PASSWORD=pw\nADMIN_PASSWORD=admin-pw\nENGINE_MASTER_KEY=sk-x\n' > "$R/.env"
  export HOME="$T/home"; unset XDG_CONFIG_HOME ELEA_REDIRECT_ENV_FILE ELEA_SIN_RESPALDO
  export FAKE_LOG="$T/docker.log"; : > "$FAKE_LOG"; export FAKE_CURL=1
  export PATH="$AQUI/tests/fake-docker:$PATH_ORIG"
  unset FAKE_HTTP_INTERNAL FAKE_HTTP_REDIRECT FAKE_HTTP_HEALTH FAKE_SEED_MISSING FAKE_CATALOG_RC FAKE_PULL_RC RESPALDO_RC
  export ELEA_EXT_MIN_VERSION="$MINIMA" ELEA_ESPERA_INTENTOS=2 ELEA_ESPERA_PAUSA=0
  # La salida de `docker compose config --format json` con la extensión: el compose real fusionado.
  COMPOSE_OK="$T/compose-ok.json"
  ELEA_EXT_VERSION=$VERSION python3 "$RENDER" --redirect > "$COMPOSE_OK"
  export FAKE_COMPOSE_JSON="$COMPOSE_OK"
}
PATH_ORIG="$PATH"
# Corre ./activar-redirect.sh en el repo de prueba con el entorno dado (VAR=valor …). Deja la salida en $out.
activar() { out=$(cd "$R" && env "$@" ./activar-redirect.sh 2>&1); rc=$?; }
ACTIVA=(ELEA_REDIRECT=1 "ELEA_EXT_VERSION=$VERSION")
ENVF() { echo "$T/home/.config/elea/redirect.env"; }
llamadas() { grep -c -- "$1" "$FAKE_LOG" || true; }
sin_secretos() { # ningún valor de las llaves generadas en la salida, el log de docker ni el repo
  local k v
  for k in REDIRECT_INTERNAL_KEY MASKING_NONCE_KEY; do
    v=$(grep "^$k=" "$(ENVF)" | cut -d= -f2-)
    [ -n "$v" ] || return 1
    grep -qF -- "$v" <<<"$out" && return 1
    grep -rqF -- "$v" "$FAKE_LOG"* "$R" 2>/dev/null && return 1
  done
  return 0
}

echo "— sintaxis y permisos"
for f in activar-redirect.sh install.sh tests/test-redirect-optin.sh tests/fake-docker/docker tests/fake-docker/curl; do
  chequear "bash -n $f" bash -n "$AQUI/$f"
done
chequear "activar-redirect.sh es ejecutable" [ -x "$AQUI/activar-redirect.sh" ]
chequear "el override del compose existe" [ -s "$AQUI/docker-compose.redirect.yml" ]

# ───────────────────────────────────────────────────────────────────────────────────────────────
echo "— T100 sin ELEA_REDIRECT: nada cambia (el compose de la instalación ya corregida queda idéntico)"
chequear "docker-compose.yml no menciona la extensión (imágenes -ext, entorno extra, redirect)" \
  bash -c '! grep -Eiq "elea_redirect|elea_ext|extra_env_file|redirect|[0-9]-ext|sentinel\.(redirect|catalog)" "$1"' _ "$AQUI/docker-compose.yml"
# Mismo render del compose con el entorno de una corrida SIN la variable que con una corrida CON ella pero sin
# aplicar el override (lo que ve compose cuando COMPOSE_FILE no está): por hash.
h_base=$(python3 "$RENDER" --hash)
h_sin=$(env -u ELEA_REDIRECT -u ELEA_EXT_VERSION python3 "$RENDER" --hash)
h_con_var=$(ELEA_REDIRECT=1 ELEA_EXT_VERSION=$VERSION python3 "$RENDER" --hash)
chequear "el compose renderizado da el mismo hash con y sin las variables de la extensión (sin override)" \
  bash -c '[ -n "$1" ] && [ "$1" = "$2" ] && [ "$1" = "$3" ]' _ "$h_base" "$h_sin" "$h_con_var"
chequear "…y con el override el hash es OTRO (la extensión sí cambia algo)" \
  bash -c '[ "$(ELEA_EXT_VERSION=$1 python3 "$2" --redirect --hash)" != "$3" ]' _ "$VERSION" "$RENDER" "$h_base"

nuevo_entorno
cp "$R/.env" "$T/.env.antes"
activar
chequear "sin la variable termina bien y en silencio" bash -c '[ "$1" = 0 ] && [ -z "$2" ]' _ "$rc" "$out"
chequear "no llama a docker ni a curl" bash -c '[ ! -s "$1" ] && [ ! -e "$1.curl" ]' _ "$FAKE_LOG"
chequear "no toca el .env" cmp -s "$R/.env" "$T/.env.antes"
chequear "no crea el archivo de entorno de la extensión" [ ! -e "$(ENVF)" ]
chequear "no pide respaldo" [ ! -e "$T/orden" ]
activar ELEA_REDIRECT=0
chequear "ELEA_REDIRECT=0 es lo mismo que no tenerla" bash -c '[ "$1" = 0 ] && [ -z "$2" ] && [ ! -s "$3" ]' _ "$rc" "$out" "$FAKE_LOG"
activar ELEA_REDIRECT=si
chequear "un valor que no es 1 se rechaza (no se activa por error)" bash -c '[ "$1" != 0 ] && [ ! -s "$2" ]' _ "$rc" "$FAKE_LOG"

echo "— T100 con ELEA_REDIRECT=1: las imágenes -ext, por su tag propio"
env_ext=(ELEA_EXT_VERSION="$VERSION")
imagen() { env "${env_ext[@]}" "$@" python3 "$RENDER" --redirect | python3 -c 'import json,sys;print(json.load(sys.stdin)["services"][sys.argv[1]]["image"])' "$S"; }
for S in backend frontend engine; do
  img=$(imagen)
  chequear "$S usa la imagen -ext de la versión ($img)" bash -c '[ "$1" = "ghcr.io/cluna-8/elea-guardian-$2:$3-ext" ]' _ "$img" "$S" "$VERSION"
  chequear "$S no usa latest ni el tag sin sufijo" bash -c '! grep -Eq ":latest$|:[0-9-]+$|@sha256" <<<"$1"' _ "$img"
done
S=backend; img=$(imagen BACKEND_EXT_IMAGE=ghcr.io/cluna-8/elea-guardian-backend@sha256:abc)
chequear "BACKEND_EXT_IMAGE reemplaza la imagen (p. ej. por digest)" [ "$img" = "ghcr.io/cluna-8/elea-guardian-backend@sha256:abc" ]
S=engine; img=$(imagen ENGINE_IMAGE=ghcr.io/cluna-8/elea-guardian-engine@sha256:base)
chequear "ENGINE_IMAGE (el digest de la base) no pisa la -ext del motor" [ "$img" = "ghcr.io/cluna-8/elea-guardian-engine:$VERSION-ext" ]
chequear "sin ELEA_EXT_VERSION el compose con la extensión no se puede renderizar (no hay default flotante)" \
  bash -c '! env -u ELEA_EXT_VERSION python3 "$1" --redirect >/dev/null 2>&1' _ "$RENDER"
chequear "otras imágenes (nlp, client, tabular, presenton…) no cambian" bash -c '
  a=$(python3 "$1" | python3 -c "import json,sys;d=json.load(sys.stdin)[\"services\"];print({k:v.get(\"image\") for k,v in d.items() if k not in (\"backend\",\"frontend\",\"engine\")})")
  b=$(ELEA_EXT_VERSION=$2 python3 "$1" --redirect | python3 -c "import json,sys;d=json.load(sys.stdin)[\"services\"];print({k:v.get(\"image\") for k,v in d.items() if k not in (\"backend\",\"frontend\",\"engine\")})")
  [ -n "$a" ] && [ "$a" = "$b" ]' _ "$RENDER" "$VERSION"
chequear "el backend arranca con «upgrade heads» (con dos ramas, «head» fallaría)" bash -c '
  ELEA_EXT_VERSION=$2 python3 "$1" --redirect | python3 -c "import json,sys;c=\" \".join(json.load(sys.stdin)[\"services\"][\"backend\"][\"command\"]);sys.exit(0 if \"alembic upgrade heads &&\" in c and \"uvicorn src.main:app\" in c else 1)"' _ "$RENDER" "$VERSION"
chequear "backend y motor reciben EXTRA_ENV_FILE (opcional, sintaxis larga)" bash -c '
  ELEA_EXT_VERSION=$2 EXTRA_ENV_FILE=/x/redirect.env python3 "$1" --redirect | python3 -c "
import json,sys
d=json.load(sys.stdin)[\"services\"]
for s in (\"backend\",\"engine\"):
    assert {\"path\":\"/x/redirect.env\",\"required\":False} in d[s][\"env_file\"], s
for s in (\"frontend\",\"api-proxy\",\"client\",\"db\"):
    assert not d[s].get(\"env_file\"), s"' _ "$RENDER" "$VERSION"
chequear "sin EXTRA_ENV_FILE apunta a /dev/null (no cambia el entorno)" bash -c '
  ELEA_EXT_VERSION=$2 python3 "$1" --redirect > "$3/r.json"; grep -q "\"/dev/null\"" "$3/r.json"' _ "$RENDER" "$VERSION" "$(mktemp -d)"
chequear "con la extensión, fuera de imágenes, env_file y comando el compose es el mismo (solo cambia eso)" bash -c '
  python3 "$1" > "$3/a.json"; ELEA_EXT_VERSION=$2 python3 "$1" --redirect > "$3/b.json"
  python3 - "$3/a.json" "$3/b.json" <<PY
import json, sys
a, b = (json.load(open(p)) for p in sys.argv[1:3])
for s in ("backend", "engine", "frontend"):
    a["services"][s].pop("image"); b["services"][s].pop("image")
for s in ("backend", "engine"):
    b["services"][s].pop("env_file")
a["services"]["backend"].pop("command"); b["services"]["backend"].pop("command")
assert a == b, [k for k in a if a[k] != b[k]]
PY' _ "$RENDER" "$VERSION" "$T"

# Si hay `docker compose` de verdad, solo se VALIDA (config -q: no levanta ni toca nada).
DOCKER_REAL=$(PATH="$PATH_ORIG" command -v docker || true)
if [ -n "$DOCKER_REAL" ] && "$DOCKER_REAL" compose version >/dev/null 2>&1; then
  chequear "docker compose config -q valida el compose base" bash -c 'cd "$1" && "$2" compose -f docker-compose.yml config -q' _ "$AQUI" "$DOCKER_REAL"
  chequear "docker compose config -q valida base + override con la extensión" bash -c 'cd "$1" && ELEA_EXT_VERSION=$3 "$2" compose -f docker-compose.yml -f docker-compose.redirect.yml config -q' _ "$AQUI" "$DOCKER_REAL" "$VERSION"
  chequear "…y sin ELEA_EXT_VERSION la validación con el override FALLA (variable obligatoria)" bash -c 'cd "$1" && ! env -u ELEA_EXT_VERSION "$2" compose -f docker-compose.yml -f docker-compose.redirect.yml config -q >/dev/null 2>&1' _ "$AQUI" "$DOCKER_REAL"
else
  salta "no hay docker compose real: no se validó con config -q (el render de arriba cubre el contenido)"
fi

# ───────────────────────────────────────────────────────────────────────────────────────────────
echo "— T100 con ELEA_REDIRECT=1: activación completa"
nuevo_entorno
activar "${ACTIVA[@]}"
chequear "termina bien" bash -c '[ "$1" = 0 ] || { echo "$2" >&2; exit 1; }' _ "$rc" "$out"
chequear "el entorno de la extensión se crea FUERA del repo" bash -c '[ -f "$1" ] && case "$1" in "$2"/*) exit 1;; *) exit 0;; esac' _ "$(ENVF)" "$R"
chequear "el archivo tiene modo 600" bash -c '[ "$(stat -c %a "$1")" = 600 ]' _ "$(ENVF)"
chequear "su carpeta tiene modo 700" bash -c '[ "$(stat -c %a "$(dirname "$1")")" = 700 ]' _ "$(ENVF)"
# Lista COMPLETA que activa la extensión (nada se activa por estar en la imagen): si falta una, falla.
declare -A ESPERADO=(
  [GATEWAY_PLUGINS]=sentinel.redirect.plugin
  [PLUGIN_PACKAGES]=sentinel.redirect.api,sentinel.catalog.api
  [ALEMBIC_EXTRA_VERSION_LOCATIONS]=/opt/sentinel-ext/sentinel/migrations
  [SENTINEL_ENTITY_REGION]=latam_ar
  [REDIRECT_SEED_FILES]=/opt/sentinel-ext/seeds/regions.americas.yaml,/opt/sentinel-ext/seeds/habilitacion-explicita.yaml
  [REDIRECT_CACHE_TTL_S]=5
)
for k in "${!ESPERADO[@]}"; do
  chequear "el entorno trae $k=${ESPERADO[$k]}" grep -qxF "$k=${ESPERADO[$k]}" "$(ENVF)"
done
for k in REDIRECT_INTERNAL_KEY MASKING_NONCE_KEY; do
  chequear "$k está generada (≥ 32 caracteres, no un marcador)" bash -c 'v=$(grep "^$1=" "$2" | cut -d= -f2-); [ "${#v}" -ge 32 ] && ! grep -q "<" <<<"$v"' _ "$k" "$(ENVF)"
done
for k in REDIRECT_OPERATOR_TENANT INTERNAL_ALLOWED_CIDRS CATALOG_DIRECT_ENABLED; do
  chequear_no "el entorno NO define $k" grep -q "^$k=" "$(ENVF)"
done
chequear "ninguna llave del entorno quedó vacía" bash -c '! grep -Eq "^[A-Z_]+=$" "$1"' _ "$(ENVF)"
chequear "ninguna llave generada ni su valor aparecen en la salida, el log de docker ni el repo" sin_secretos
chequear "el .env del instalador recuerda ELEA_REDIRECT=1" grep -qx 'ELEA_REDIRECT=1' "$R/.env"
chequear "el .env fija COMPOSE_FILE con el override (todo `docker compose` de la carpeta lo ve)" grep -qx 'COMPOSE_FILE=docker-compose.yml:docker-compose.redirect.yml' "$R/.env"
chequear "el .env recuerda ELEA_EXT_VERSION (con COMPOSE_FILE puesto, todo docker compose la necesita)" grep -qx "ELEA_EXT_VERSION=$VERSION" "$R/.env"
chequear "el .env apunta EXTRA_ENV_FILE al archivo de entorno" grep -qxF "EXTRA_ENV_FILE=$(ENVF)" "$R/.env"
chequear "el .env marca la activación (ELEA_REDIRECT_ACTIVADA=1)" grep -qx 'ELEA_REDIRECT_ACTIVADA=1' "$R/.env"
chequear_no "el .env NO guarda las llaves generadas" grep -Eq '^(REDIRECT_INTERNAL_KEY|MASKING_NONCE_KEY)=' "$R/.env"
chequear "docker corre con el override y el entorno de la extensión" bash -c 'grep -q "COMPOSE_FILE=docker-compose.yml:docker-compose.redirect.yml EXTRA_ENV_FILE=$2" "$1.env"' _ "$FAKE_LOG" "$(ENVF)"
chequear "baja las imágenes -ext antes de recrear" bash -c '[ "$(grep -n "compose pull" "$1" | head -1 | cut -d: -f1)" -lt "$(grep -n "compose up" "$1" | head -1 | cut -d: -f1)" ]' _ "$FAKE_LOG"
chequear "recrea el motor, el backend, el proxy y el panel" bash -c 'grep -q "compose up -d engine" "$1" && grep -Eq "compose up -d .*backend" "$1" && grep -Eq "compose up -d .*frontend" "$1"' _ "$FAKE_LOG"
chequear "el respaldo se toma ANTES de recrear nada" bash -c '[ "$(cat "$1/orden")" = respaldo ] && [ "$(grep -n "compose up" "$2" | head -1 | cut -d: -f1)" -gt 0 ]' _ "$T" "$FAKE_LOG"
chequear "verifica el 404 del plano interno por el puerto publicado ANTES de activar" bash -c '
  grep -n "" "$1.curl" | grep -q "/api/v1/internal/" && [ "$(grep -n "internal" "$1.curl" | head -1 | cut -d: -f1)" -lt "$(grep -n "redirect/health" "$1.curl" | head -1 | cut -d: -f1)" ]' _ "$FAKE_LOG"
chequear "consulta /api/v1/redirect/health por el puerto publicado (8091)" grep -q 'http://localhost:8091/api/v1/redirect/health' "$FAKE_LOG.curl"
chequear "siembra el catálogo de ejemplo de Azure" grep -q 'exec -T backend python -m sentinel.catalog.seed /opt/sentinel-ext/seeds/catalog-seed.azure-demo.yaml' "$FAKE_LOG"
chequear "las regiones y la habilitación se cargan al arrancar por REDIRECT_SEED_FILES (no con otro comando)" bash -c '! grep -Eq "regions_seed|catalog.habilitacion" "$1"' _ "$FAKE_LOG"
chequear "comprueba que los archivos de seeds existen en la imagen" bash -c 'grep -q "test -f /opt/sentinel-ext/seeds/regions.americas.yaml" "$1" && grep -q "test -f /opt/sentinel-ext/seeds/habilitacion-explicita.yaml" "$1"' _ "$FAKE_LOG"
chequear "dice dónde quedó el entorno y no su contenido" bash -c 'grep -qF "$2" <<<"$1" && ! grep -Eq "^(GATEWAY_PLUGINS|REDIRECT_INTERNAL_KEY)=" <<<"$1"' _ "$out" "$(ENVF)"

echo "— T100: una segunda corrida es idempotente y no cambia las llaves"
k1=$(grep '^REDIRECT_INTERNAL_KEY=' "$(ENVF)"); n1=$(grep '^MASKING_NONCE_KEY=' "$(ENVF)")
: > "$T/orden"; : > "$FAKE_LOG"; : > "$FAKE_LOG.curl"
echo 'REDIRECT_CRED_PRUEBA=del-operador' >> "$(ENVF)"
activar "${ACTIVA[@]}"
chequear "termina bien" [ "$rc" = 0 ]
chequear "conserva REDIRECT_INTERNAL_KEY y MASKING_NONCE_KEY (cambiarla rompe el enmascarado de las conversaciones en curso)" \
  bash -c 'grep -qxF "$1" "$3" && grep -qxF "$2" "$3"' _ "$k1" "$n1" "$(ENVF)"
chequear "conserva lo que el operador agregó al entorno (credenciales de destinos)" grep -qx 'REDIRECT_CRED_PRUEBA=del-operador' "$(ENVF)"
chequear "no repite el respaldo (la activación ya se hizo)" bash -c '[ ! -s "$1/orden" ]' _ "$T"
chequear "no vuelve a sembrar el catálogo (podría pisar lo que el administrador completó)" bash -c '! grep -q "catalog.seed" "$1"' _ "$FAKE_LOG"
chequear "vuelve a verificar la salud de la extensión" grep -q 'redirect/health' "$FAKE_LOG.curl"
chequear "el .env no duplica líneas" bash -c '[ "$(grep -c "^COMPOSE_FILE=" "$1")" = 1 ] && [ "$(grep -c "^ELEA_REDIRECT=" "$1")" = 1 ]' _ "$R/.env"
chmod 644 "$(ENVF)"; activar "${ACTIVA[@]}"
chequear "si el archivo de entorno quedó con otro modo, lo deja en 600" bash -c '[ "$(stat -c %a "$1")" = 600 ]' _ "$(ENVF)"

echo "— T100: otra ruta para el entorno (ELEA_REDIRECT_ENV_FILE)"
nuevo_entorno; mkdir -p "$T/otro"
activar "${ACTIVA[@]}" "ELEA_REDIRECT_ENV_FILE=$T/otro/ext.env"
chequear "usa esa ruta, en modo 600" bash -c '[ "$1" = 0 ] && [ "$(stat -c %a "$2/otro/ext.env")" = 600 ]' _ "$rc" "$T"
chequear "y la recuerda en el .env" grep -qx "EXTRA_ENV_FILE=$T/otro/ext.env" "$R/.env"
nuevo_entorno
activar "${ACTIVA[@]}" "ELEA_REDIRECT_ENV_FILE=$R/ext.env"
chequear "una ruta DENTRO del repo se rechaza (el repo se versiona)" bash -c '[ "$1" != 0 ] && [ ! -e "$2/ext.env" ] && [ ! -s "$3" ]' _ "$rc" "$R" "$FAKE_LOG"

# ───────────────────────────────────────────────────────────────────────────────────────────────
echo "— T103: variables de enmascarado que agregó la 057 (MASKING_*): llegan al motor y al backend, o rige su default seguro"
# Lista de .env.example de la rama de integración de la 057 (repo elea). Son OPCIONALES salvo MASKING_NONCE_KEY (la genera
# el instalador): el motor las lee del entorno en cada pedido y con un valor ausente o inválido rige el default de la línea.
# S14_EXEMPT_POSITIONS NO es una variable: es una tabla del código del motor (posiciones del pedido que no se reescriben);
# lo único que se enciende por entorno son las exenciones opcionales MASKING_EXEMPT_* (apagadas por defecto).
OPCIONALES=(MASKING_ANALYSIS_CACHE_ENABLED MASKING_ANALYSIS_CACHE_MAX_ENTRIES MASKING_ANALYSIS_CACHE_TTL_S MASKING_ANALYSIS_CACHE_SALT
  MASKING_PDF_MAX_PAGES MASKING_PDF_MAX_BYTES MASKING_PDF_MAX_MEMORY_MB MASKING_PDF_TIMEOUT_S MASKING_PDF_MAX_CONCURRENCY
  MASKING_PDF_MAX_STREAM_BYTES MASKING_PDF_MAX_TEXT_CHARS MASKING_PDF_MAX_PER_REQUEST MASKING_PDF_REQUEST_DEADLINE_S
  MASKING_PDF_CACHE_ENTRIES MASKING_EXEMPT_SYSTEM_PROMPT MASKING_EXEMPT_TOOL_DEFINITIONS)
nuevo_entorno
activar "${ACTIVA[@]}"
chequear "termina bien" [ "$rc" = 0 ]
for k in "${OPCIONALES[@]}"; do
  chequear_no "el instalador no escribe $k en el entorno (rige el default seguro del motor; el operador lo agrega si lo necesita)" grep -q "^$k=" "$(ENVF)"
done
chequear_no "ninguna exención opcional queda encendida (MASKING_EXEMPT_*=1|true|yes|on): todo se analiza" grep -Eiq '^MASKING_EXEMPT_[A-Z_]*=(1|true|yes|on)$' "$(ENVF)"
chequear "MASKING_NONCE_KEY es distinta de REDIRECT_INTERNAL_KEY (la clave de los marcadores no se reutiliza)" bash -c '
  a=$(grep "^MASKING_NONCE_KEY=" "$1" | cut -d= -f2-); b=$(grep "^REDIRECT_INTERNAL_KEY=" "$1" | cut -d= -f2-)
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" != "$b" ]' _ "$(ENVF)"
# Lo que ve cada servicio: el entorno del archivo de la extensión + `environment:` del compose (este último GANA). Si el
# compose definiera alguna de estas variables, pisaría la del operador; no tiene que definir ninguna.
efectivo() { # $1 = servicio, $2 = archivo de entorno; imprime KEY=VALOR del entorno que vería el contenedor
  ELEA_EXT_VERSION=$VERSION EXTRA_ENV_FILE="$2" python3 "$RENDER" --redirect | python3 -c '
import json, sys
svc = json.load(sys.stdin)["services"][sys.argv[1]]
env = {}
for e in svc.get("env_file", []):
    path = e["path"] if isinstance(e, dict) else e
    try:
        for ln in open(path):
            if "=" in ln and not ln.lstrip().startswith("#"):
                k, v = ln.rstrip("\n").split("=", 1); env[k] = v
    except OSError:
        pass
e = svc.get("environment", [])
for it in (e if isinstance(e, list) else [f"{k}={v}" for k, v in e.items()]):
    k, _, v = it.partition("="); env[k] = v
for k, v in sorted(env.items()):
    print(f"{k}={v}")' "$1"
}
cp "$(ENVF)" "$T/operador.env"
printf 'MASKING_PDF_MAX_PAGES=50\nMASKING_ANALYSIS_CACHE_ENABLED=false\nMASKING_EXEMPT_SYSTEM_PROMPT=true\nMASKING_ANALYSIS_CACHE_SALT=sal-de-prueba\n' >> "$T/operador.env"
for S in engine backend; do
  ef=$(efectivo "$S" "$T/operador.env")
  for k in MASKING_PDF_MAX_PAGES=50 MASKING_ANALYSIS_CACHE_ENABLED=false MASKING_EXEMPT_SYSTEM_PROMPT=true MASKING_ANALYSIS_CACHE_SALT=sal-de-prueba; do
    chequear "lo que el operador agrega a la extensión llega al $S tal cual ($k)" grep -qxF "$k" <<<"$ef"
  done
  chequear "MASKING_NONCE_KEY y REDIRECT_INTERNAL_KEY llegan al $S (el motor y el backend las derivan por separado)" \
    bash -c 'grep -q "^MASKING_NONCE_KEY=." <<<"$1" && grep -q "^REDIRECT_INTERNAL_KEY=." <<<"$1"' _ "$(efectivo "$S" "$(ENVF)")"
  for k in "${OPCIONALES[@]}"; do
    chequear_no "el compose no define $k en el $S (pisaría la del operador)" bash -c 'grep -q "^$1=" <<<"$2" && ! grep -q "^$1=" "$3"' _ "$k" "$(efectivo "$S" "$(ENVF)")" "$(ENVF)"
  done
done
chequear "SENTINEL_ENTITY_REGION del compose y de la extensión coinciden (latam_ar): ninguna pisa a la otra con otro valor" bash -c '
  [ "$(grep "^SENTINEL_ENTITY_REGION=" "$1" | cut -d= -f2-)" = latam_ar ] && [ "$(grep -c "SENTINEL_ENTITY_REGION=\${ENTITY_REGION:-latam_ar}" "$2")" = 2 ]' _ "$(ENVF)" "$AQUI/docker-compose.yml"
echo "REDIRECT_CRED_PRUEBA=del-operador" >> "$T/operador.env"
cp "$T/operador.env" "$(ENVF)"
activar "${ACTIVA[@]}"
chequear "una segunda activación conserva lo que el operador puso (MASKING_PDF_*, MASKING_ANALYSIS_CACHE_*, MASKING_EXEMPT_*)" bash -c '
  [ "$1" = 0 ] && for k in MASKING_PDF_MAX_PAGES=50 MASKING_ANALYSIS_CACHE_ENABLED=false MASKING_EXEMPT_SYSTEM_PROMPT=true MASKING_ANALYSIS_CACHE_SALT=sal-de-prueba; do grep -qxF "$k" "$2" || exit 1; done' _ "$rc" "$(ENVF)"
chequear "…y no duplica MASKING_NONCE_KEY" bash -c '[ "$(grep -c "^MASKING_NONCE_KEY=" "$1")" = 1 ]' _ "$(ENVF)"
chequear "la exención opcional puesta por el operador no la apaga ni la repite el instalador" bash -c '[ "$(grep -c "^MASKING_EXEMPT_SYSTEM_PROMPT=" "$1")" = 1 ]' _ "$(ENVF)"

# ───────────────────────────────────────────────────────────────────────────────────────────────
echo "— T100 gate de la dependencia (proxy y S15 de la vuelta 2): no se activa si falta alguna condición"
verifica_sin_activar() { # $1 = descripción; esperado: error, nada escrito, nada recreado, sin respaldo
  chequear "$1: termina con error" [ "$rc" != 0 ]
  chequear "$1: el mensaje lo explica" bash -c '[ -n "$1" ]' _ "$out"
  chequear "$1: no crea el entorno de la extensión" [ ! -e "$(ENVF)" ]
  chequear "$1: no toca el .env (sin COMPOSE_FILE, sin marca)" bash -c '! grep -Eq "^(COMPOSE_FILE|EXTRA_ENV_FILE|ELEA_REDIRECT_ACTIVADA)=" "$1/.env"' _ "$R"
  chequear "$1: no recrea contenedores" bash -c '! grep -Eq "compose (up|down|stop|restart)" "$1"' _ "$FAKE_LOG"
  chequear "$1: no toma respaldo ni siembra" bash -c '[ ! -e "$1/orden" ] && ! grep -q catalog.seed "$2"' _ "$T" "$FAKE_LOG"
}
# (1) el compose del instalador no tiene el servicio de proxy
nuevo_entorno
python3 - "$COMPOSE_OK" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); del d["services"]["api-proxy"]; json.dump(d, open(p, "w"))
PY
activar "${ACTIVA[@]}"
verifica_sin_activar "sin el servicio de proxy"
chequear "sin proxy: el mensaje nombra el proxy" grep -qi 'proxy' <<<"$out"
# (1b) el backend publica puertos
nuevo_entorno
python3 - "$COMPOSE_OK" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p)); d["services"]["backend"]["ports"] = ["8091:8000"]; json.dump(d, open(p, "w"))
PY
activar "${ACTIVA[@]}"
verifica_sin_activar "con el backend publicando puertos"
chequear "backend con puertos: el mensaje lo dice" grep -qi 'puerto' <<<"$out"
# (2) la imagen base del backend es anterior al tag mínimo que trae S15
nuevo_entorno
activar ELEA_REDIRECT=1 ELEA_EXT_VERSION=2026-10-19
verifica_sin_activar "con una versión anterior al mínimo que trae S15"
chequear "versión anterior: el mensaje da la versión mínima" grep -q "$MINIMA" <<<"$out"
nuevo_entorno
activar ELEA_REDIRECT=1 ELEA_EXT_VERSION=$MINIMA
chequear "la versión igual al mínimo SÍ se acepta" [ "$rc" = 0 ]
# (2b) mínimo sin fijar (el valor que entrega este repo hasta el release): falla cerrado
nuevo_entorno
activar "${ACTIVA[@]}" ELEA_EXT_MIN_VERSION=PENDIENTE-PRIMER-RELEASE
verifica_sin_activar "con el mínimo sin fijar (PENDIENTE-PRIMER-RELEASE)"
chequear "mínimo sin fijar: el mensaje explica que lo fija el release" grep -qi 'release' <<<"$out"
nuevo_entorno; unset ELEA_EXT_MIN_VERSION
activar "${ACTIVA[@]}"
verifica_sin_activar "sin constante de mínimo en el entorno"
nuevo_entorno; echo 'ELEA_EXT_MIN_VERSION=2000-01-01' >> "$R/.env"
activar "${ACTIVA[@]}" ELEA_EXT_MIN_VERSION=PENDIENTE-PRIMER-RELEASE
chequear "el mínimo no se puede bajar desde el .env" [ "$rc" != 0 ]
# (2c) versión faltante o mal formada
nuevo_entorno
activar ELEA_REDIRECT=1
verifica_sin_activar "sin ELEA_EXT_VERSION"
chequear "sin versión: el mensaje nombra ELEA_EXT_VERSION" grep -q 'ELEA_EXT_VERSION' <<<"$out"
nuevo_entorno
activar ELEA_REDIRECT=1 ELEA_EXT_VERSION=latest
verifica_sin_activar "con ELEA_EXT_VERSION=latest"
# (3) /api/v1/internal/* no da 404 por el puerto publicado antes de activar
for cod in 200 401 000; do
  nuevo_entorno; export FAKE_HTTP_INTERNAL=$cod
  activar "${ACTIVA[@]}"
  verifica_sin_activar "con /api/v1/internal/* respondiendo $cod por el puerto publicado"
  chequear "internal $cod: el mensaje nombra /api/v1/internal" grep -q '/api/v1/internal' <<<"$out"
done
# docker o compose viejo
nuevo_entorno; export FAKE_COMPOSE_JSON=/nonexistent
activar "${ACTIVA[@]}"
verifica_sin_activar "si docker compose no entrega la configuración"
# imágenes -ext que no existen: no se activa nada
nuevo_entorno; export FAKE_PULL_RC=1
activar "${ACTIVA[@]}"
verifica_sin_activar "si no se pueden bajar las imágenes -ext"
chequear "sin imágenes: el mensaje nombra la versión" grep -q "$VERSION" <<<"$out"

echo "— T100: respaldo previo obligatorio"
nuevo_entorno; export RESPALDO_RC=1
activar "${ACTIVA[@]}"
chequear "si el respaldo falla, no se activa (error y nada recreado)" bash -c '[ "$1" != 0 ] && ! grep -Eq "compose up" "$2" && [ ! -e "$3" ]' _ "$rc" "$FAKE_LOG" "$(ENVF)"
unset RESPALDO_RC
nuevo_entorno
activar "${ACTIVA[@]}" ELEA_SIN_RESPALDO=1
chequear "ELEA_SIN_RESPALDO=1 lo omite (bajo responsabilidad) y lo avisa" bash -c '[ "$1" = 0 ] && [ ! -e "$2/orden" ] && grep -qi "respaldo" <<<"$3"' _ "$rc" "$T" "$out"

echo "— T100: el instalador falla visible ante CUALQUIER respuesta de salud que no sea 200"
for cod in 503 404 500 000; do
  nuevo_entorno; export FAKE_HTTP_REDIRECT=$cod
  activar "${ACTIVA[@]}"
  chequear "salud $cod: termina con error" [ "$rc" != 0 ]
  chequear "salud $cod: dice el código recibido" grep -q "$cod" <<<"$out"
done
nuevo_entorno; export FAKE_HTTP_REDIRECT=503
activar "${ACTIVA[@]}"
chequear "503 del respaldo: muestra el motivo (region_unresolved)" grep -q 'region_unresolved' <<<"$out"
nuevo_entorno; export FAKE_HTTP_REDIRECT=404
activar "${ACTIVA[@]}"
chequear "404 de una imagen -ext inerte: explica que la extensión no está montada" grep -qi 'no está activa\|inerte\|no respondió' <<<"$out"
chequear "salud no 200: no siembra el catálogo" bash -c '! grep -q catalog.seed "$1"' _ "$FAKE_LOG"
nuevo_entorno; export FAKE_HTTP_HEALTH=000
activar "${ACTIVA[@]}"
chequear "si el backend no arranca tras recrearlo, falla y lo explica (arranque abortado por migración)" bash -c '[ "$1" != 0 ] && grep -qi "migraci" <<<"$2"' _ "$rc" "$out"
nuevo_entorno; export FAKE_SEED_MISSING=regions.americas.yaml
activar "${ACTIVA[@]}"
chequear "si falta un archivo de seeds en la imagen, falla con un mensaje claro que nombra el archivo" bash -c '[ "$1" != 0 ] && grep -q "regions.americas.yaml" <<<"$2"' _ "$rc" "$out"
nuevo_entorno; export FAKE_CATALOG_RC=1
activar "${ACTIVA[@]}"
chequear "si falla el catálogo de ejemplo, la activación sigue (no es fatal) y dice cómo reintentar" bash -c '[ "$1" = 0 ] && grep -q "catalog.seed" <<<"$2"' _ "$rc" "$out"
chequear "…y no marca el catálogo como sembrado (la próxima corrida lo reintenta)" bash -c '! grep -q "^ELEA_REDIRECT_CATALOGO=1" "$1/.env"' _ "$R"

# ───────────────────────────────────────────────────────────────────────────────────────────────
echo "— T100: se apaga sacando la variable"
nuevo_entorno
activar "${ACTIVA[@]}"
sed -i '/^ELEA_REDIRECT=/d' "$R/.env"
: > "$T/orden"; : > "$FAKE_LOG"; : > "$FAKE_LOG.curl"; : > "$FAKE_LOG.env"
activar
chequear "termina bien" bash -c '[ "$1" = 0 ] || { echo "$2" >&2; exit 1; }' _ "$rc" "$out"
chequear_no "el entorno ya no tiene GATEWAY_PLUGINS" grep -q '^GATEWAY_PLUGINS=' "$(ENVF)"
chequear_no "el entorno ya no tiene PLUGIN_PACKAGES" grep -q '^PLUGIN_PACKAGES=' "$(ENVF)"
chequear "conserva ALEMBIC_EXTRA_VERSION_LOCATIONS (con las migraciones aplicadas la imagen base no arranca)" grep -q '^ALEMBIC_EXTRA_VERSION_LOCATIONS=' "$(ENVF)"
chequear "conserva las llaves generadas" bash -c 'grep -q "^REDIRECT_INTERNAL_KEY=" "$1" && grep -q "^MASKING_NONCE_KEY=" "$1"' _ "$(ENVF)"
chequear "conserva las imágenes -ext (COMPOSE_FILE sigue)" grep -qx 'COMPOSE_FILE=docker-compose.yml:docker-compose.redirect.yml' "$R/.env"
chequear "recrea backend y motor para que apliquen el cambio" bash -c 'grep -q "compose up -d" "$1"' _ "$FAKE_LOG"
chequear "no toma respaldo ni siembra nada al apagar" bash -c '[ ! -s "$1/orden" ] && ! grep -q catalog.seed "$2"' _ "$T" "$FAKE_LOG"
chequear "explica que volver a las imágenes base es solo con el respaldo" grep -qi 'respaldo' <<<"$out"
chequear "no puede salir verde ni exige /redirect/health (la ruta ya no existe)" bash -c '! grep -q "redirect/health" "$1.curl"' _ "$FAKE_LOG"
activar
chequear "apagar dos veces es idempotente" [ "$rc" = 0 ]
chequear "volver a poner ELEA_REDIRECT=1 vuelve a encender (GATEWAY_PLUGINS y PLUGIN_PACKAGES de nuevo)" bash -c '
  f=$2; cd "$1" && env "${@:3}" ./activar-redirect.sh >/dev/null 2>&1 && grep -q "^GATEWAY_PLUGINS=sentinel.redirect.plugin" "$f" && grep -q "^PLUGIN_PACKAGES=" "$f"' _ "$R" "$(ENVF)" "${ACTIVA[@]}"
nuevo_entorno
echo 'ELEA_REDIRECT_ACTIVADA=1' >> "$R/.env"
activar
chequear "marca de activación pero sin archivo de entorno: no inventa nada y lo dice" bash -c '[ "$1" != 0 ] && grep -qi "entorno" <<<"$2"' _ "$rc" "$out"

# ───────────────────────────────────────────────────────────────────────────────────────────────
echo "— T101 el proxy y el canal interno siguen cerrados con la extensión"
M=$(ELEA_EXT_VERSION=$VERSION python3 "$RENDER" --redirect); B=$(python3 "$RENDER")
dato() { python3 -c 'import json,sys;d=json.load(sys.stdin)["services"];print(json.dumps(eval(sys.argv[1]),sort_keys=True))' "$1"; }
chequear "el proxy de la base sigue (servicio api-proxy publica 8091)" bash -c '[ "$1" = "[\"8091:8091\"]" ]' _ "$(dato 'd["api-proxy"]["ports"]' <<<"$M")"
chequear "el proxy no cambia con la extensión" bash -c '[ "$1" = "$2" ]' _ "$(dato 'd["api-proxy"]' <<<"$M")" "$(dato 'd["api-proxy"]' <<<"$B")"
chequear "el backend -ext no publica puertos propios" bash -c '[ "$1" = null ] || [ "$1" = "[]" ]' _ "$(dato 'd["backend"].get("ports")' <<<"$M")"
chequear "nadie más publica el 8000 del backend con la extensión" bash -c '! grep -Eq "\"[0-9]+:8000\"" <<<"$1"' _ "$M"
chequear "el puerto del panel, del Hub y del proxy son los de siempre" bash -c '[ "$1" = "$2" ]' _ \
  "$(dato '[d["frontend"]["ports"], d["client"]["ports"], d["api-proxy"]["ports"]]' <<<"$M")" "$(dato '[d["frontend"]["ports"], d["client"]["ports"], d["api-proxy"]["ports"]]' <<<"$B")"
chequear "el backend sigue con INTERNAL_ALLOWED_CIDRS=auto con la extensión" bash -c 'grep -q "INTERNAL_ALLOWED_CIDRS=auto" <<<"$1"' _ "$(dato 'd["backend"]["environment"]' <<<"$M")"
chequear "el motor sigue pidiendo identidad y auditoría al backend por la red interna" bash -c 'grep -q "http://backend:8000/api/v1/internal/identity" <<<"$1"' _ "$(dato 'd["engine"]["environment"]' <<<"$M")"
chequear "ni el override ni el instalador definen INTERNAL_ALLOWED_CIDRS (la fija el compose base; solo hay comentarios)" bash -c '! grep -v "^[[:space:]]*#" "$1" "$2" | grep -q "INTERNAL_ALLOWED_CIDRS"' _ "$AQUI/docker-compose.redirect.yml" "$AQUI/activar-redirect.sh"
chequear "el override no toca el entorno ni los puertos de ningún servicio" bash -c '
  python3 - "$1" <<PY
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))["services"]
for s, v in d.items():
    assert set(v) <= {"image", "command", "env_file"}, (s, sorted(v))
PY' _ "$AQUI/docker-compose.redirect.yml"
# Las reglas del proxy (proxy/Caddyfile) no cambian con la extensión: el plano interno 404; la pasarela, la
# salud de la extensión, la API de redirección y el catálogo pasan (el panel «Modelos» y el chequeo de salud).
REGEXP=$(sed -n 's/^[[:space:]]*@interno path_regexp "\(.*\)"$/\1/p' "$AQUI/proxy/Caddyfile")
chequear "el proxy tiene la regla del plano interno" [ -n "$REGEXP" ]
interno() { python3 -c 'import re,sys;sys.exit(0 if re.search(sys.argv[1], sys.argv[2]) else 1)' "$REGEXP" "$1"; }
for p in /api/v1/internal/identity /api/v1/internal/audit /api/v1/internal/model-credential /api/v1/internal /api/v1/Internal/x //api//v1///INTERNAL//x; do
  chequear "el proxy niega $p" interno "$p"
done
for p in /api/v1/gw /api/v1/gw/v1/models /api/v1/gw/v1/chat/completions /api/v1/redirect/health /api/v1/redirect/policy /api/v1/redirect/destinations /api/v1/catalog/models /api/v1/catalog/models/abc /health /docs; do
  chequear_no "el proxy deja pasar $p" interno "$p"
done
chequear "el instalador no cambia el proxy para la extensión (el Caddyfile no nombra rutas de la extensión)" bash -c '! grep -Eiq "redirect|catalog|gw" "$1"' _ "$AQUI/proxy/Caddyfile"
chequear "antes de activar se verifica /api/v1/internal/identity por el puerto publicado (8091 por defecto)" bash -c 'grep -q "ELEA_API_URL:-http://localhost:8091" "$1" && grep -q "\$API/api/v1/internal/identity" "$1"' _ "$AQUI/activar-redirect.sh"

# ───────────────────────────────────────────────────────────────────────────────────────────────
echo "— install.sh: cableado"
n_hub=$(grep -n '^docker compose up -d --remove-orphans tabular presenton client' "$AQUI/install.sh" | head -n1 | cut -d: -f1)
n_act=$(grep -n '^ *\./activar-redirect.sh' "$AQUI/install.sh" | head -n1 | cut -d: -f1)
n_fin=$(grep -n '^echo "  Listo. Todo corriendo."' "$AQUI/install.sh" | head -n1 | cut -d: -f1)
n_src=$(grep -n '^set -a; source .env; set +a' "$AQUI/install.sh" | head -n1 | cut -d: -f1)
n_min=$(grep -n '^ELEA_EXT_MIN_VERSION=' "$AQUI/install.sh" | head -n1 | cut -d: -f1)
chequear "install.sh llama a ./activar-redirect.sh" [ -n "$n_act" ]
chequear "lo llama DESPUÉS de levantar todo y ANTES del cierre" bash -c '[ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ] && [ "$1" -lt "$2" ] && [ "$2" -lt "$3" ]' _ "$n_hub" "$n_act" "$n_fin"
chequear "si activar falla, el instalador termina con error visible (no sigue como si nada)" bash -c 'sed -n "$1p" "$2" | grep -q "|| die"' _ "$n_act" "$AQUI/install.sh"
chequear "install.sh fija ELEA_EXT_MIN_VERSION DESPUÉS de leer el .env (el .env no puede bajarla)" bash -c '[ -n "$1" ] && [ -n "$2" ] && [ "$1" -gt "$2" ]' _ "$n_min" "$n_src"
chequear "la exporta para ./activar-redirect.sh" grep -Eq '^export ELEA_EXT_MIN_VERSION' "$AQUI/install.sh"
chequear "el valor entregado falla cerrado (centinela) o es una fecha AAAA-MM-DD" bash -c 'grep -Eq "^ELEA_EXT_MIN_VERSION=\"(PENDIENTE-PRIMER-RELEASE|[0-9]{4}-[0-9]{2}-[0-9]{2})\"" "$1"' _ "$AQUI/install.sh"
chequear "con ELEA_REDIRECT sin definir, install.sh no cambia ninguno de los comandos de compose (sin -f ni COMPOSE_FILE)" \
  bash -c '! grep -Eq "docker compose (-f|--file)|COMPOSE_FILE" "$1"' _ "$AQUI/install.sh"
chequear ".env.example documenta ELEA_REDIRECT y ELEA_EXT_VERSION, comentadas (apagado por defecto)" bash -c 'grep -Eq "^# ELEA_REDIRECT=1" "$1" && grep -Eq "^# ELEA_EXT_VERSION=" "$1" && ! grep -Eq "^(ELEA_REDIRECT|ELEA_EXT_VERSION)=" "$1"' _ "$AQUI/.env.example"

echo "— white-label y secretos"
chequear "los archivos nuevos no nombran los internals prohibidos (litellm, berriai, presidio)" bash -c '! grep -Eiq "litellm|berriai|presidio" "$@"' _ \
  "$AQUI/activar-redirect.sh" "$AQUI/docker-compose.redirect.yml"
chequear "ningún archivo versionado trae un valor de REDIRECT_INTERNAL_KEY ni MASKING_NONCE_KEY" \
  bash -c '! git -C "$1" grep -Eq "(REDIRECT_INTERNAL_KEY|MASKING_NONCE_KEY)=[A-Za-z0-9+/]{16,}" -- . ":!tests"' _ "$AQUI"
chequear "el entorno de la extensión no está dentro del repo ni lo ignora .gitignore por casualidad" bash -c '! git -C "$1" ls-files | grep -Eq "redirect\.env|extensions\.env"' _ "$AQUI"

echo
if [ "$FALLOS" = 0 ]; then echo "TODO OK"; else echo "$FALLOS FALLO(S)"; exit 1; fi
