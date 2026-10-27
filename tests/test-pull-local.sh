#!/usr/bin/env bash
# Prueba del pull de imágenes con imágenes construidas en local (README, «Probar imágenes construidas en local»),
# sin Docker: ./activar-redirect.sh y la parte de ./install.sh que baja la imagen del motor, con el Docker y el
# curl de mentira de tests/fake-docker.
#   - activar-redirect.sh: si el pull falla pero backend, panel y motor existen en local, sigue; si falta alguna, muere
#     y la nombra (sin tocar nada).
#   - install.sh: si el pull del motor falla pero la imagen existe en local, NO pide usuario y token del registro;
#     si no existe, sí (comportamiento de siempre).
# Correr:  bash tests/test-pull-local.sh
set -uo pipefail
AQUI="$(cd "$(dirname "$0")/.." && pwd)"
FALLOS=0
ok()   { echo "  ok   $1"; }
falla() { echo "  FALLA $1"; FALLOS=$((FALLOS + 1)); }
chequear() { local desc="$1"; shift; if "$@"; then ok "$desc"; else falla "$desc"; fi; }
chequear_no() { local desc="$1"; shift; if "$@"; then falla "$desc"; else ok "$desc"; fi; }

RENDER="$AQUI/tests/render-compose.py"
VERSION=2026-11-01
MINIMA=2026-10-20
chequear "hay python3 con PyYAML" python3 -c 'import yaml'

export POSTGRES_PASSWORD=pw ENGINE_MASTER_KEY=sk-x FERNET_SECRET_KEY=f JWT_SECRET_KEY=j
export AZURE_OPENAI_API_KEY=a AZURE_OPENAI_ENDPOINT=https://x AZURE_API_VERSION=v

PATH_ORIG="$PATH"
nuevo_entorno() {
  T=$(mktemp -d); R="$T/repo"; mkdir -p "$R/proxy" "$T/home"
  cp "$AQUI"/{install.sh,activar-redirect.sh,base-motor.lib.sh,docker-compose.yml,docker-compose.redirect.yml,.env.example} "$R"/ 2>/dev/null
  cp "$AQUI/proxy/Caddyfile" "$AQUI/proxy/https.lib.sh" "$R/proxy/"
  printf '#!/usr/bin/env bash\necho respaldo >> "%s/orden"\nexit 0\n' "$T" > "$R/respaldo.sh"; chmod +x "$R/respaldo.sh"
  printf 'POSTGRES_PASSWORD=pw\nADMIN_PASSWORD=admin-pw\nENGINE_MASTER_KEY=sk-x\n' > "$R/.env"
  export HOME="$T/home"; unset XDG_CONFIG_HOME ELEA_REDIRECT_ENV_FILE ELEA_SIN_RESPALDO
  export FAKE_LOG="$T/docker.log"; : > "$FAKE_LOG"; export FAKE_CURL=1
  export PATH="$AQUI/tests/fake-docker:$PATH_ORIG"
  unset FAKE_HTTP_INTERNAL FAKE_HTTP_REDIRECT FAKE_HTTP_HEALTH FAKE_SEED_MISSING FAKE_CATALOG_RC FAKE_PULL_RC FAKE_IMAGES_MISSING FAKE_ENGINE_REF
  export ELEA_EXT_MIN_VERSION="$MINIMA" ELEA_ESPERA_INTENTOS=2 ELEA_ESPERA_PAUSA=0
  COMPOSE_OK="$T/compose-ok.json"
  ELEA_EXT_VERSION=$VERSION python3 "$RENDER" --redirect > "$COMPOSE_OK"
  export FAKE_COMPOSE_JSON="$COMPOSE_OK"
}
# Corre ./activar-redirect.sh con el entorno dado; el compose «efectivo» que devuelve el docker de mentira se vuelve a
# renderizar con ese mismo entorno (así las *_EXT_IMAGE llegan a la configuración, como en compose).
activar() {
  env ELEA_EXT_VERSION=$VERSION "$@" python3 "$RENDER" --redirect > "$COMPOSE_OK"
  out=$(cd "$R" && env ELEA_REDIRECT=1 "ELEA_EXT_VERSION=$VERSION" "$@" ./activar-redirect.sh 2>&1); rc=$?
}
sin_tocar() { # error, nada recreado, sin respaldo ni entorno de la extensión
  chequear "$1: termina con error" [ "$rc" != 0 ]
  chequear "$1: no recrea contenedores" bash -c '! grep -Eq "compose (up|down|stop|restart)" "$1"' _ "$FAKE_LOG"
  chequear "$1: no toma respaldo" bash -c '[ ! -e "$1/orden" ]' _ "$T"
  chequear "$1: no crea el entorno de la extensión" bash -c '[ ! -e "$1/home/.config/elea/redirect.env" ]' _ "$T"
}

echo "— activar-redirect.sh: pull fallido con las tres imágenes en local → sigue"
nuevo_entorno; export FAKE_PULL_RC=1
activar
chequear "termina bien" [ "$rc" = 0 ]
chequear "intentó el pull" grep -q "compose pull backend frontend engine" "$FAKE_LOG"
chequear "verificó en local la imagen del backend -ext" grep -q "image inspect ghcr.io/cluna-8/elea-guardian-backend:${VERSION}-ext" "$FAKE_LOG"
chequear "verificó en local la imagen del panel -ext" grep -q "image inspect ghcr.io/cluna-8/elea-guardian-frontend:${VERSION}-ext" "$FAKE_LOG"
chequear "verificó en local la imagen del motor -ext" grep -q "image inspect ghcr.io/cluna-8/elea-guardian-engine:${VERSION}-ext" "$FAKE_LOG"
chequear "avisa que usa las imágenes locales" grep -qi "locales\|en local" <<<"$out"
chequear "activó (recreó el backend)" grep -Eq "compose up -d .*backend" "$FAKE_LOG"

echo "— activar-redirect.sh: pull fallido con una imagen ausente → muere y la nombra"
for faltante in backend frontend engine; do
  nuevo_entorno; export FAKE_PULL_RC=1 FAKE_IMAGES_MISSING="elea-guardian-$faltante:"
  activar
  sin_tocar "falta $faltante"
  chequear "falta $faltante: nombra la imagen que falta" grep -q "elea-guardian-$faltante:${VERSION}-ext" <<<"$out"
  chequear "falta $faltante: nombra la versión" grep -q "$VERSION" <<<"$out"
done
nuevo_entorno; export FAKE_PULL_RC=1 FAKE_IMAGES_MISSING="-ext"
activar
sin_tocar "faltan todas"

echo "— activar-redirect.sh: imágenes locales por *_EXT_IMAGE"
nuevo_entorno; export FAKE_PULL_RC=1 FAKE_IMAGES_MISSING="no-existe"
activar BACKEND_EXT_IMAGE=elea-backend:local ENGINE_EXT_IMAGE=elea-engine:local FRONTEND_EXT_IMAGE=elea-frontend:local
chequear "con las tres presentes sigue" [ "$rc" = 0 ]
chequear "verificó la referencia local del backend" grep -q "image inspect elea-backend:local" "$FAKE_LOG"
nuevo_entorno; export FAKE_PULL_RC=1 FAKE_IMAGES_MISSING="elea-engine:local"
activar BACKEND_EXT_IMAGE=elea-backend:local ENGINE_EXT_IMAGE=elea-engine:local FRONTEND_EXT_IMAGE=elea-frontend:local
sin_tocar "motor local ausente"
chequear "nombra la referencia que falta" grep -q "elea-engine:local" <<<"$out"

echo "— activar-redirect.sh: imágenes del registro (pull que anda) → no cambia nada"
nuevo_entorno
activar
chequear "termina bien" [ "$rc" = 0 ]
chequear_no "no hace falta verificar en local lo recién bajado" grep -q "image inspect ghcr.io/cluna-8/elea-guardian-backend" "$FAKE_LOG"
chequear_no "no avisa de imágenes locales" grep -qi "usan las imágenes locales" <<<"$out"

# ───────────────────────────────────────────────────────────────────────────────────────────────
# install.sh: se corre SOLO el bloque «Registro de imágenes» (de `if ! docker compose pull --quiet engine` al `fi`).
echo "— install.sh: pull del motor fallido"
bloque() {
  awk '/^if ! docker compose pull --quiet engine/{p=1} p{print} p&&/^fi$/{exit}' "$AQUI/install.sh"
}
chequear "el bloque del pull del motor está en install.sh" bash -c '[ "$(echo "$1" | wc -l)" -gt 3 ]' _ "$(bloque)"
motor() { # entorno extra …  → corre el bloque con el docker de mentira; deja $out y $rc
  nuevo_entorno; export FAKE_PULL_RC=1
  { printf 'set -euo pipefail\nlog() { echo "▶ $1"; }\ndie() { echo "✗ $1" >&2; exit 1; }\n'; bloque; echo "echo SIGUE"; } > "$T/bloque.sh"
  out=$(env "$@" bash "$T/bloque.sh" </dev/null 2>&1); rc=$?
}
motor FAKE_X=1
chequear "imagen del motor presente en local: sigue sin pedir credenciales" bash -c '[ "$2" = 0 ] && grep -q SIGUE <<<"$1" && ! grep -q "Pedí un token" <<<"$1"' _ "$out" "$rc"
chequear "imagen presente: no llama a docker login" bash -c '! grep -q "docker login" "$1"' _ "$FAKE_LOG"
chequear "imagen presente: consulta la imagen del motor de compose" grep -q "compose config --images engine" "$FAKE_LOG"
motor FAKE_IMAGES_MISSING=elea-guardian-engine
chequear "imagen del motor ausente: pide usuario y token (como siempre)" grep -q "Pedí un token" <<<"$out"
motor FAKE_IMAGES_MISSING=elea-engine:local FAKE_ENGINE_REF=elea-engine:local
chequear "motor local ausente (ENGINE_IMAGE local): pide credenciales" grep -q "Pedí un token" <<<"$out"
motor FAKE_ENGINE_REF=elea-engine:local
chequear "motor local presente (ENGINE_IMAGE local): no pide credenciales" bash -c '[ "$2" = 0 ] && ! grep -q "Pedí un token" <<<"$1"' _ "$out" "$rc"
nuevo_entorno   # pull que anda: ni inspecciona ni pide nada
{ printf 'set -euo pipefail\nlog() { :; }\ndie() { exit 1; }\n'; bloque; echo "echo SIGUE"; } > "$T/bloque.sh"
out=$(bash "$T/bloque.sh" </dev/null 2>&1); rc=$?
chequear "pull que anda: sigue sin tocar nada más" bash -c '[ "$2" = 0 ] && grep -q SIGUE <<<"$1" && ! grep -q "image inspect\|docker login" "$3"' _ "$out" "$rc" "$FAKE_LOG"

echo
if [ "$FALLOS" = 0 ]; then echo "TODO OK"; else echo "$FALLOS FALLO(S)"; exit 1; fi
