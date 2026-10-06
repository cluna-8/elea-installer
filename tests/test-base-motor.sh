#!/usr/bin/env bash
# Pruebas de migrar-base-motor.sh y respaldo.sh con un Docker de mentira (tests/fake-docker):
# no levantan ni tocan ningún contenedor. Correr:  bash tests/test-base-motor.sh
set -uo pipefail
AQUI="$(cd "$(dirname "$0")/.." && pwd)"
FALLOS=0
ok()   { echo "  ok   $1"; }
falla() { echo "  FALLA $1"; FALLOS=$((FALLOS + 1)); }
chequear() { local desc="$1"; shift; if "$@"; then ok "$desc"; else falla "$desc"; fi; }

# Carpeta de trabajo descartable con una copia de los scripts, un .env de mentira y el Docker falso.
nuevo_entorno() {
  T=$(mktemp -d)
  cp "$AQUI"/{migrar-base-motor.sh,respaldo.sh,base-motor.lib.sh,docker-compose.yml} "$T"/
  printf 'POSTGRES_DB=elea_gateway\nPOSTGRES_USER=elea_admin\nPOSTGRES_PASSWORD=pw\nENGINE_DB=elea_engine\nTABULAR_ENGINE_VIRTUAL_KEY=sk-secreta-123\n' > "$T/.env"
  export FAKE_LOG="$T/docker.log"; : > "$FAKE_LOG"
  export PATH="$AQUI/tests/fake-docker:$PATH"
  export FAKE_DBS="postgres elea_gateway" FAKE_GW_MOTOR=66 FAKE_ENG_MOTOR=0 FAKE_CLIENTS="elea-rag-client elea-tabular"
  unset FAKE_MARKER FAKE_DUMP_RC FAKE_FOTO_DIFF FAKE_KEY_STATUS FAKE_ENGINE_LOG
}
linea() { grep -n "$1" "$FAKE_LOG" | head -n1 | cut -d: -f1; }
antes() { local a b; a=$(linea "$1"); b=$(linea "$2"); [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; }

echo "— sintaxis"
for f in install.sh migrar-base-motor.sh respaldo.sh base-motor.lib.sh tests/fake-docker/docker; do
  chequear "bash -n $f" bash -n "$AQUI/$f"
done

echo "— --dry-run no llama a Docker y muestra los pasos"
nuevo_entorno
out=$(cd "$T" && ./migrar-base-motor.sh --dry-run 2>&1); rc=$?
chequear "dry-run termina bien" [ "$rc" = 0 ]
chequear "no se llamó a docker" [ ! -s "$FAKE_LOG" ]
chequear "usa pg_dump -T (no -t)" grep -q 'pg_dump .* -T ' <<<"$out"
chequear "imprime la compuerta de integridad" grep -q 'COMPUERTA DE INTEGRIDAD' <<<"$out"
chequear "imprime la base nueva elea_engine" grep -q 'Base nueva motor  : elea_engine' <<<"$out"
chequear "imprime el digest fijado" grep -q 'elea-guardian-engine@sha256:1928af9d' <<<"$out"
chequear "no se tocó el .env" grep -q '^ENGINE_DB=elea_engine$' "$T/.env"
chequear "no se mostró la llave" bash -c '! grep -q sk-secreta-123 <<<"$0"' "$out"

echo "— --detectar"
detectar() { (cd "$T" && ./migrar-base-motor.sh --detectar >/dev/null 2>&1); echo $?; }
nuevo_entorno; export FAKE_GW_MOTOR=0
chequear "instalación nueva (sin tablas del motor) → 3" [ "$(detectar)" = 3 ]
nuevo_entorno
chequear "base compartida, sin base nueva → 0" [ "$(detectar)" = 0 ]
nuevo_entorno; export FAKE_DBS="postgres elea_gateway elea_engine"
chequear "base nueva existe pero vacía → 0" [ "$(detectar)" = 0 ]
nuevo_entorno; export FAKE_DBS="postgres elea_gateway elea_engine" FAKE_ENG_MOTOR=66
chequear "las dos con motor y sin marca → 4 (ambiguo)" [ "$(detectar)" = 4 ]
export FAKE_MARKER="separada-de:elea_gateway:2026-10-07"
chequear "las dos con motor y con marca → 3 (ya migrada)" [ "$(detectar)" = 3 ]
nuevo_entorno; sed -i 's/^ENGINE_DB=.*/ENGINE_DB=elea_gateway/' "$T/.env"
chequear "vuelta atrás activa (ENGINE_DB = POSTGRES_DB) → 3" [ "$(detectar)" = 3 ]

echo "— migración completa (--si --espera-gasto 0)"
nuevo_entorno
out=$(cd "$T" && ./migrar-base-motor.sh --si --espera-gasto 0 2>&1); rc=$?
chequear "termina bien" [ "$rc" = 0 ]
chequear "se paran los clientes antes que el motor" antes 'compose stop client' 'compose stop engine'
chequear "se crea la base antes de copiar" antes 'psql.*-d postgres' 'exec .*sh -c'
chequear "se copia antes de levantar el motor" antes 'exec .*sh -c' 'compose up -d engine'
chequear "el motor se levanta antes que los clientes" antes 'compose up -d engine' 'compose up -d client'
chequear "el respaldo se hace antes de parar nada" antes 'pg_dump' 'compose stop client'
chequear "la copia usa -T con tablas del Guardian" grep -q 'exec.*TLIST=alembic_version users audit_logs' "$FAKE_LOG"
chequear "no se borra ninguna tabla vieja" bash -c '! grep -qi "drop table" "$0.sql"' "$FAKE_LOG"
chequear "no se borra ninguna base" bash -c '! grep -qi "drop database" "$0.sql"' "$FAKE_LOG"
chequear "se anotó la imagen anterior" grep -q 'elea-guardian-engine@sha256:viejo' "$T/.migracion-motor/imagen-anterior"
chequear "se marcó la base nueva" grep -q "COMMENT ON DATABASE" "$FAKE_LOG.sql"
chequear "la llave de servicio no se imprime" bash -c '! grep -q sk-secreta-123 <<<"$0"' "$out"
chequear "la llave no viaja en la línea de comandos" bash -c '! grep -q sk-secreta-123 "$0"' "$FAKE_LOG"

echo "— falla la copia: vuelta atrás A"
nuevo_entorno; export FAKE_DUMP_RC=1
out=$(cd "$T" && ./migrar-base-motor.sh --si --espera-gasto 0 2>&1); rc=$?
chequear "termina con error" [ "$rc" != 0 ]
chequear "descarta la base nueva" grep -q 'DROP DATABASE IF EXISTS "elea_engine"' "$FAKE_LOG.sql"
chequear "arranca el contenedor viejo del motor" grep -q 'docker start elea-engine' "$FAKE_LOG"
chequear "arranca los clientes que paró" grep -q 'docker start .*elea-rag-client' "$FAKE_LOG"
chequear "NO recrea el motor con el compose nuevo" bash -c '! grep -q "compose up -d engine" "$0"' "$FAKE_LOG"

echo "— falla la compuerta de integridad: vuelta atrás A"
nuevo_entorno; export FAKE_FOTO_DIFF=1
out=$(cd "$T" && ./migrar-base-motor.sh --si --espera-gasto 0 2>&1); rc=$?
chequear "termina con error" [ "$rc" != 0 ]
chequear "descarta la base nueva" grep -q 'DROP DATABASE IF EXISTS "elea_engine"' "$FAKE_LOG.sql"
chequear "NO apunta el motor a la base nueva" bash -c '! grep -q "compose up -d engine" "$0"' "$FAKE_LOG"
chequear ".env sin tocar (ENGINE_DB sigue como estaba)" grep -q '^ENGINE_DB=elea_engine$' "$T/.env"

echo "— llave de servicio rechazada tras el corte"
nuevo_entorno; export FAKE_KEY_STATUS=401
out=$(cd "$T" && ./migrar-base-motor.sh --si --espera-gasto 0 2>&1); rc=$?
chequear "termina con error y sugiere la vuelta atrás B" bash -c '[ "$1" != 0 ] && grep -q -- "--vuelta-atras" <<<"$2"' _ "$rc" "$out"

echo "— vuelta atrás B"
nuevo_entorno; mkdir -p "$T/.migracion-motor"; echo "ghcr.io/cluna-8/elea-guardian-engine@sha256:viejo" > "$T/.migracion-motor/imagen-anterior"
out=$(cd "$T" && ./migrar-base-motor.sh --vuelta-atras --si 2>&1); rc=$?
chequear "termina bien" [ "$rc" = 0 ]
chequear ".env: ENGINE_DB=elea_gateway" grep -q '^ENGINE_DB=elea_gateway$' "$T/.env"
chequear ".env: identidad por SQL (URL vacía)" grep -q '^ENGINE_IDENTITY_URL=$' "$T/.env"
chequear ".env: auditoría por SQL (URL vacía)" grep -q '^ENGINE_AUDIT_URL=$' "$T/.env"
chequear ".env: imagen anterior restaurada" grep -q '^ENGINE_IMAGE=ghcr.io/cluna-8/elea-guardian-engine@sha256:viejo$' "$T/.env"
chequear "recrea el motor" grep -q 'compose up -d engine' "$FAKE_LOG"
nuevo_entorno; export FAKE_GW_MOTOR=0
out=$(cd "$T" && ./migrar-base-motor.sh --vuelta-atras --si 2>&1); rc=$?
chequear "sin tablas viejas no hay a dónde volver (vuelta C)" bash -c '[ "$1" != 0 ] && grep -q "Vuelta C" <<<"$2"' _ "$rc" "$out"

echo "— --mostrar-limpieza (solo imprime) y --gasto"
nuevo_entorno
out=$(cd "$T" && ./migrar-base-motor.sh --mostrar-limpieza 2>&1); rc=$?
chequear "sin motor en la base nueva se niega" bash -c '[ "$1" != 0 ]' _ "$rc"
nuevo_entorno; export FAKE_DBS="postgres elea_gateway elea_engine" FAKE_ENG_MOTOR=66
out=$(cd "$T" && ./migrar-base-motor.sh --mostrar-limpieza 2>&1); rc=$?
chequear "con la base nueva sana imprime un bloque BEGIN…COMMIT" bash -c '[ "$1" = 0 ] && grep -q "^BEGIN;" <<<"$2" && grep -q "^COMMIT;" <<<"$2"' _ "$rc" "$out"
chequear "advierte los 7 días" grep -q '7 días' <<<"$out"
(cd "$T" && ./migrar-base-motor.sh --gasto >/dev/null 2>&1); rc=$?
chequear "--gasto consulta la base del motor" bash -c '[ "$1" = 0 ] && grep -q "elea_engine" "$2"' _ "$rc" "$FAKE_LOG"

echo "— cableado de install.sh y del compose"
n_det=$(grep -n 'migrar-base-motor.sh --detectar' "$AQUI/install.sh" | head -n1 | cut -d: -f1)
n_up=$(grep -n 'docker compose up -d db redis' "$AQUI/install.sh" | head -n1 | cut -d: -f1)
chequear "install.sh detecta la base compartida ANTES de levantar con el compose nuevo" bash -c '[ -n "$1" ] && [ -n "$2" ] && [ "$1" -lt "$2" ]' _ "$n_det" "$n_up"
chequear "install.sh ya no baja el motor por :latest" bash -c '! grep -q "elea-guardian-engine:latest" "$1"' _ "$AQUI/install.sh"
chequear "el compose fija el motor por digest" grep -Eq 'image: \$\{ENGINE_IMAGE:-ghcr.io/cluna-8/elea-guardian-engine@sha256:[0-9a-f]{64}\}' "$AQUI/docker-compose.yml"
chequear "el compose no deja el motor en :latest" bash -c '! grep -q "elea-guardian-engine:latest" "$1"' _ "$AQUI/docker-compose.yml"
chequear ".env.example trae ENGINE_DB" grep -q '^ENGINE_DB=elea_engine$' "$AQUI/.env.example"
chequear "el motor depende de la creación de su base" grep -q 'db-engine-init: { condition: service_completed_successfully }' "$AQUI/docker-compose.yml"
chequear "el motor recibe identidad y auditoría por HTTP" bash -c 'grep -q "SENTINEL_IDENTITY_URL=" "$1" && grep -q "SENTINEL_AUDIT_URL=" "$1"' _ "$AQUI/docker-compose.yml"

echo "— respaldo"
nuevo_entorno; export FAKE_DBS="postgres elea_gateway elea_engine"
(cd "$T" && ./respaldo.sh >/dev/null 2>&1); rc=$?
d=$(ls -d "$T"/respaldos/20* 2>/dev/null | head -n1)
chequear "termina bien" [ "$rc" = 0 ]
chequear "respalda las DOS bases" bash -c '[ -s "$1/elea_gateway.dump" ] && [ -s "$1/elea_engine.dump" ]' _ "$d"
chequear "deja SHA256SUMS y MANIFEST" bash -c '[ -s "$1/SHA256SUMS" ] && [ -s "$1/MANIFEST.txt" ]' _ "$d"
chequear "permisos 700 en la carpeta" bash -c '[ "$(stat -c %a "$1")" = 700 ]' _ "$d"
nuevo_entorno; export FAKE_GW_TABLES=0
(cd "$T" && ./respaldo.sh >/dev/null 2>&1)
chequear "base vacía (instalación nueva): no crea carpeta" bash -c '[ ! -d "$1/respaldos" ]' _ "$T"
nuevo_entorno
(cd "$T" && ./respaldo.sh --dry-run >/dev/null 2>&1)
chequear "respaldo --dry-run no llama a docker" [ ! -s "$FAKE_LOG" ]

echo
if [ "$FALLOS" = 0 ]; then echo "TODO OK"; else echo "$FALLOS FALLO(S)"; exit 1; fi
