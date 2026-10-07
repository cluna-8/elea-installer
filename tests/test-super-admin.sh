#!/usr/bin/env bash
# Pruebas del usuario de cumplimiento (super_admin): crear-super-admin.sh y su cableado en install.sh,
# con un Docker de mentira (tests/fake-docker): no levantan ni tocan ningún contenedor.
# Correr:  bash tests/test-super-admin.sh
set -uo pipefail
AQUI="$(cd "$(dirname "$0")/.." && pwd)"
FALLOS=0
ok()   { echo "  ok   $1"; }
falla() { echo "  FALLA $1"; FALLOS=$((FALLOS + 1)); }
chequear() { local desc="$1"; shift; if "$@"; then ok "$desc"; else falla "$desc"; fi; }

PASS_FALSA="Zk9-contrasena-de-mentira"
# Carpeta de trabajo descartable con una copia de los scripts, un .env de mentira y el Docker falso.
nuevo_entorno() {
  T=$(mktemp -d)
  cp "$AQUI"/{install.sh,crear-super-admin.sh,.env.example} "$T"/ 2>/dev/null
  printf 'POSTGRES_PASSWORD=pw\nADMIN_PASSWORD=admin-pw\n' > "$T/.env"
  export FAKE_LOG="$T/docker.log"; : > "$FAKE_LOG"
  export PATH="$AQUI/tests/fake-docker:$PATH"
  unset FAKE_SA FAKE_SA_PASSWORD
}
# Cuántas veces aparece $1 en lo que escribió el script (stdout+stderr juntos, $out).
veces() { grep -cF -- "$1" <<<"$out" || true; }

echo "— sintaxis"
for f in install.sh crear-super-admin.sh tests/test-super-admin.sh tests/fake-docker/docker; do
  chequear "bash -n $f" bash -n "$AQUI/$f"
done
chequear "crear-super-admin.sh es ejecutable" [ -x "$AQUI/crear-super-admin.sh" ]

echo "— crear-super-admin.sh: usuario creado"
nuevo_entorno
out=$(cd "$T" && ./crear-super-admin.sh 2>&1); rc=$?
chequear "termina bien" [ "$rc" = 0 ]
chequear "invoca el comando del backend con el contrato (-T, usuario y email fijos)" \
  grep -qxF 'docker compose exec -T backend python -m src.cli crear-super-admin --username cumplimiento --email cumplimiento@elea-internal.com' "$FAKE_LOG"
chequear "muestra la contraseña" [ "$(veces "$PASS_FALSA")" = 1 ]
chequear "la contraseña se muestra UNA sola vez" [ "$(veces "$PASS_FALSA")" -le 1 ]
chequear "avisa que se muestra una sola vez" grep -qi 'una sola vez' <<<"$out"
chequear "avisa que hay que cambiarla en el primer ingreso" grep -qi 'primer ingreso' <<<"$out"
chequear "muestra el usuario" grep -q 'cumplimiento' <<<"$out"
chequear "no repite el prefijo PASSWORD= del contrato" bash -c '! grep -q "PASSWORD=" <<<"$1"' _ "$out"
chequear "la contraseña no queda en el log de llamadas a docker" bash -c '! grep -rqF "$1" "$2"*' _ "$PASS_FALSA" "$FAKE_LOG"
chequear "la contraseña no queda en ningún archivo de la carpeta" bash -c '! grep -rqF "$1" "$2"' _ "$PASS_FALSA" "$T"
chequear "no toca el .env" bash -c '[ "$(cat "$1/.env")" = "$(printf "POSTGRES_PASSWORD=pw\nADMIN_PASSWORD=admin-pw")" ]' _ "$T"
chequear "no pasa la contraseña por argv de ningún comando" bash -c '! grep -qF "$1" "$2"' _ "$PASS_FALSA" "$FAKE_LOG"

echo "— crear-super-admin.sh: ya hay un super_admin"
nuevo_entorno; export FAKE_SA=existe
out=$(cd "$T" && ./crear-super-admin.sh 2>&1); rc=$?
chequear "termina bien (es informativo, no un error)" [ "$rc" = 0 ]
chequear "informa que ya hay un super_admin" grep -qi 'ya hay un super_admin' <<<"$out"
chequear "no muestra ninguna contraseña" bash -c '! grep -qiE "contraseña: |PASSWORD" <<<"$1"' _ "$out"
chequear "no avisa de un usuario creado" bash -c '! grep -qi "creado" <<<"$1"' _ "$out"
chequear "llamó al backend una sola vez (no reintenta)" bash -c '[ "$(grep -c crear-super-admin "$1")" = 1 ]' _ "$FAKE_LOG"

echo "— crear-super-admin.sh: errores"
nuevo_entorno; export FAKE_SA=error
out=$(cd "$T" && ./crear-super-admin.sh 2>&1); rc=$?
chequear "un error del comando termina distinto de 0" [ "$rc" != 0 ]
chequear "no muestra contraseña en un error" bash -c '! grep -qF "$1" <<<"$2"' _ "$PASS_FALSA" "$out"
chequear "dice cómo reintentar" grep -q 'crear-super-admin.sh' <<<"$out"
nuevo_entorno; export FAKE_SA=sin-comando
out=$(cd "$T" && ./crear-super-admin.sh 2>&1); rc=$?
chequear "backend sin el comando (imagen vieja) termina distinto de 0" [ "$rc" != 0 ]
chequear "sugiere actualizar la imagen del backend" grep -qi 'imagen' <<<"$out"
nuevo_entorno; export FAKE_SA=sin-linea
out=$(cd "$T" && ./crear-super-admin.sh 2>&1); rc=$?
chequear "exit 0 sin línea PASSWORD= es un error (contrato roto), no un éxito" [ "$rc" != 0 ]
nuevo_entorno
out=$(cd "$T" && ./crear-super-admin.sh --no-existe 2>&1); rc=$?
chequear "opción desconocida termina distinto de 0 y no llama a docker" bash -c '[ "$1" != 0 ] && ! grep -q crear-super-admin "$2"' _ "$rc" "$FAKE_LOG"
nuevo_entorno; mv "$T/.env" "$T/.env.no"
out=$(cd "$T" && ./crear-super-admin.sh 2>&1); rc=$?
chequear "no necesita .env (solo habla con el backend)" [ "$rc" = 0 ]

echo "— crear-super-admin.sh: usuario y email propios"
nuevo_entorno
out=$(cd "$T" && ./crear-super-admin.sh --usuario oficial.cumplimiento --email oficial@empresa.com 2>&1); rc=$?
chequear "termina bien" [ "$rc" = 0 ]
chequear "pasa el usuario y el email al comando" grep -q -- '--username oficial.cumplimiento --email oficial@empresa.com' "$FAKE_LOG"
nuevo_entorno
out=$(cd "$T" && ./crear-super-admin.sh --usuario admin 2>&1); rc=$?
chequear "no acepta el usuario del admin de la empresa" bash -c '[ "$1" != 0 ] && ! grep -q crear-super-admin "$2"' _ "$rc" "$FAKE_LOG"

echo "— install.sh: la marca de instalación nueva se pone al generar el .env"
nuevo_entorno; rm "$T/.env"
out=$(cd "$T" && ./install.sh 2>&1); rc=$?
chequear "primera corrida termina bien y deja el .env" bash -c '[ "$1" = 0 ] && [ -f "$2/.env" ]' _ "$rc" "$T"
chequear "el .env nuevo lleva ELEA_SUPER_ADMIN_PENDIENTE=1" grep -qx 'ELEA_SUPER_ADMIN_PENDIENTE=1' "$T/.env"
chequear "la primera corrida no crea el usuario todavía (el backend no existe aún)" bash -c '! grep -q crear-super-admin "$1"' _ "$FAKE_LOG"

echo "— install.sh: cableado"
n_health=$(grep -n 'curl -sf -o /dev/null http://localhost:8091/health' "$AQUI/install.sh" | head -n1 | cut -d: -f1)
n_sa=$(grep -n '^ *if \./crear-super-admin.sh' "$AQUI/install.sh" | head -n1 | cut -d: -f1)
n_key=$(grep -n '^# ── 5\.' "$AQUI/install.sh" | head -n1 | cut -d: -f1)
chequear "install.sh llama a ./crear-super-admin.sh" [ -n "$n_sa" ]
chequear "lo llama DESPUÉS de que el backend responde" bash -c '[ -n "$1" ] && [ -n "$2" ] && [ "$1" -lt "$2" ]' _ "$n_health" "$n_sa"
chequear "lo llama ANTES de generar las llaves de servicio" bash -c '[ -n "$1" ] && [ -n "$2" ] && [ "$1" -lt "$2" ]' _ "$n_sa" "$n_key"
chequear "install.sh no captura ni redirige la salida de crear-super-admin.sh (la contraseña no pasa por él)" bash -c '! grep -Eq "\\$\\(\\.?/?crear-super-admin|crear-super-admin\\.sh *[^ ]*(>|\\|)" <(grep -v "^ *#" "$1")' _ "$AQUI/install.sh"

# Corre SOLO el paso 4b de install.sh (entre «# ── 4b» y «# ── 5») con las funciones reales del encabezado y un
# ./crear-super-admin.sh de mentira que registra si lo llamaron y devuelve $SA_RC.
correr_paso_4b() {
  ( cd "$T" && set +e
    # shellcheck disable=SC1090
    eval "$(grep -E '^(log|die|set_env|del_env)\(\)' "$AQUI/install.sh")"
    printf '#!/usr/bin/env bash\necho llamado >> "%s/llamadas"\nexit "${SA_RC:-0}"\n' "$T" > "$T/crear-super-admin.sh"; chmod +x "$T/crear-super-admin.sh"
    set -a; source .env; set +a
    eval "$(sed -n '/^# ── 4b/,/^# ── 5\./p' "$AQUI/install.sh" | sed '$d')"
    echo "SALIDA_OK nota=${SUPER_ADMIN_NOTA:-}"
  ) 2>&1
}
echo "— install.sh: paso 4b (instalación nueva)"
nuevo_entorno; echo 'ELEA_SUPER_ADMIN_PENDIENTE=1' >> "$T/.env"
out=$(correr_paso_4b)
chequear "con la marca, llama a crear-super-admin.sh" [ "$(cat "$T/llamadas" 2>/dev/null)" = llamado ]
chequear "si salió bien, borra la marca del .env" bash -c '! grep -q ELEA_SUPER_ADMIN_PENDIENTE "$1/.env"' _ "$T"
chequear "no toca el resto del .env" grep -qx 'ADMIN_PASSWORD=admin-pw' "$T/.env"
chequear "el paso termina sin abortar el instalador" grep -q SALIDA_OK <<<"$out"
nuevo_entorno; echo 'ELEA_SUPER_ADMIN_PENDIENTE=1' >> "$T/.env"; export SA_RC=1
out=$(correr_paso_4b); unset SA_RC
chequear "si falla, la instalación sigue (no es fatal)" grep -q SALIDA_OK <<<"$out"
chequear "si falla, deja la marca para reintentar en la próxima corrida" grep -qx 'ELEA_SUPER_ADMIN_PENDIENTE=1' "$T/.env"
chequear "si falla, avisa cómo reintentar" grep -q './crear-super-admin.sh' <<<"$out"
echo "— install.sh: paso 4b (instalación existente)"
nuevo_entorno
out=$(correr_paso_4b)
chequear "sin la marca NO crea ningún usuario en una actualización" [ ! -e "$T/llamadas" ]
chequear "sin la marca deja una nota para el cierre del instalador" grep -q 'nota=.\+' <<<"$out"
chequear "la nota apunta a ./crear-super-admin.sh" grep -q 'nota=.*crear-super-admin.sh' <<<"$out"
chequear "el cierre del instalador imprime esa nota" grep -q 'SUPER_ADMIN_NOTA' "$AQUI/install.sh"

echo "— white-label y secretos"
chequear "los scripts no nombran componentes internos prohibidos" bash -c '! grep -Eiq "litellm|presenton|sentinel" "$@"' _ "$AQUI/crear-super-admin.sh"
chequear "ningún archivo versionado trae la contraseña de prueba" bash -c '! git -C "$1" grep -qF "$2" -- . ":!tests"' _ "$AQUI" "$PASS_FALSA"

echo
[ "$FALLOS" = 0 ] && echo "TODO OK" || { echo "$FALLOS fallo(s)"; exit 1; }
