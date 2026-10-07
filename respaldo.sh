#!/usr/bin/env bash
# Respaldo de las DOS bases: la del Guardian (POSTGRES_DB) y la del motor (ENGINE_DB).
#
# Con la base del motor separada, un `pg_dump` de POSTGRES_DB ya no alcanza: las llaves virtuales
# y el gasto del motor viven en la otra (decisión D7, oct-2026). Cada corrida crea una carpeta
# fechada con un volcado `-Fc` por base, la verifica con `pg_restore -l` y registra su SHA-256.
#
#   ./respaldo.sh                      # respaldos/AAAA-MM-DD-HHMMSS/{<base>.dump,SHA256SUMS,MANIFEST.txt}
#   ./respaldo.sh --dry-run            # imprime los pasos, no toca nada
#   ./respaldo.sh --destino /ruta      # otra carpeta (por defecto ./respaldos o $ELEA_RESPALDO_DIR)
#   ./respaldo.sh --conservar 20       # cuántas carpetas dejar (por defecto 10)
#
# Los volcados traen datos reales (usuarios, auditoría): permisos 700/600. La carpeta está en el
# MISMO servidor que la base: copiarla a otro lado es parte del procedimiento (README).
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=base-motor.lib.sh
source ./base-motor.lib.sh

DESTINO="${ELEA_RESPALDO_DIR:-respaldos}"
CONSERVAR=10
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)   DRY=1 ;;
    --destino)   DESTINO="${2:?--destino necesita una ruta}"; shift ;;
    --conservar) CONSERVAR="${2:?--conservar necesita un número}"; shift ;;
    -h|--help)   sed -n '2,15p' "$0"; exit 0 ;;
    *) die "Opción desconocida: $1 (ver --help)" ;;
  esac
  shift
done
[[ "$CONSERVAR" =~ ^[0-9]+$ ]] && [ "$CONSERVAR" -ge 1 ] || die "--conservar tiene que ser un entero ≥ 1."

cargar_env
[ "$DRY" = 1 ] || requerir_docker

SELLO="$(date +%Y-%m-%d-%H%M%S)"
CARPETA="${DESTINO}/${SELLO}"

if [ "$DRY" = 1 ]; then
  log "Respaldo (--dry-run: no se ejecuta nada)"
  paso "Bases a respaldar: ${GW_DB}$([ "$ENGINE_DB" != "$GW_DB" ] && echo " y ${ENGINE_DB} (si ya existe)")"
  ejec mkdir -p -m 700 "$CARPETA"
  ejec docker exec "$DB_C" pg_dump -U "$PGU" -d "$GW_DB" -Fc "> ${CARPETA}/${GW_DB}.dump"
  [ "$ENGINE_DB" = "$GW_DB" ] || ejec docker exec "$DB_C" pg_dump -U "$PGU" -d "$ENGINE_DB" -Fc "> ${CARPETA}/${ENGINE_DB}.dump"
  ejec docker exec -i "$DB_C" pg_restore -l "< cada .dump   # verificación de que la copia se puede leer"
  ejec sha256sum "${CARPETA}"/*.dump "> ${CARPETA}/SHA256SUMS"
  ejec "# se conservan las últimas ${CONSERVAR} carpetas de ${DESTINO}"
  exit 0
fi

asegurar_db

if ! existe_db "$GW_DB"; then
  echo "  No existe la base '${GW_DB}': instalación nueva, no hay nada que respaldar."
  exit 0
fi
if [ "$(psql_db "$GW_DB" <<<"SELECT count(*) FROM pg_tables WHERE schemaname = 'public'")" = 0 ] \
   && { [ "$ENGINE_DB" = "$GW_DB" ] || ! existe_db "$ENGINE_DB" || [ "$(psql_db "$ENGINE_DB" <<<"SELECT count(*) FROM pg_tables WHERE schemaname = 'public'")" = 0 ]; }; then
  echo "  Las bases están vacías (instalación nueva): no hay nada que respaldar."
  exit 0
fi

log "Respaldo de las bases del Guardian y del motor → ${CARPETA}"
umask 077
mkdir -p "$CARPETA"
chmod 700 "$DESTINO" "$CARPETA" 2>/dev/null || true

BASES=("$GW_DB")
if [ "$ENGINE_DB" != "$GW_DB" ] && existe_db "$ENGINE_DB"; then
  BASES+=("$ENGINE_DB")
else
  echo "  (la base del motor '${ENGINE_DB}' todavía no existe o es la misma: se respalda solo '${GW_DB}')"
fi

for db in "${BASES[@]}"; do
  paso "pg_dump -Fc ${db}"
  # A un archivo temporal y recién después al nombre final: un corte a mitad no deja un .dump que parezca bueno.
  docker exec "$DB_C" pg_dump -U "$PGU" -d "$db" -Fc > "${CARPETA}/${db}.dump.parcial" \
    || { rm -f "${CARPETA}/${db}.dump.parcial"; die "pg_dump de ${db} falló: NO se actualizó nada."; }
  [ -s "${CARPETA}/${db}.dump.parcial" ] || die "El volcado de ${db} quedó vacío."
  # Verificación: pg_restore tiene que poder leer el índice de la copia y encontrar tablas en ella.
  entradas=$(docker exec -i "$DB_C" pg_restore -l < "${CARPETA}/${db}.dump.parcial" | grep -c ' TABLE ' || true)
  [ "$entradas" -gt 0 ] || die "La copia de ${db} no se puede leer o no trae tablas (pg_restore -l)."
  mv "${CARPETA}/${db}.dump.parcial" "${CARPETA}/${db}.dump"
  echo "    ${db}.dump: $(stat -c %s "${CARPETA}/${db}.dump") bytes, ${entradas} tablas"
done

( cd "$CARPETA" && sha256sum -- *.dump > SHA256SUMS )
{
  echo "fecha: $(date -Iseconds)"
  echo "bases: ${BASES[*]}"
  echo "imagen_motor_en_marcha: $(docker inspect "$ENGINE_C" --format '{{.Config.Image}} {{.Image}}' 2>/dev/null || echo 'sin contenedor')"
  echo "alembic_version: $(psql_db "$GW_DB" <<<'SELECT version_num FROM alembic_version' 2>/dev/null || echo '?')"
} > "${CARPETA}/MANIFEST.txt"

# Retención: se borran SOLO carpetas con nombre de fecha creadas por este script, de las más viejas.
mapfile -t VIEJAS < <(find "$DESTINO" -mindepth 1 -maxdepth 1 -type d -name '20??-??-??-??????' | sort | head -n "-${CONSERVAR}")
for d in "${VIEJAS[@]}"; do
  [ -n "$d" ] || continue
  echo "  (retención) se borra el respaldo viejo: $d"
  rm -rf -- "$d"
done

echo
echo "  Respaldo listo: ${CARPETA}"
echo "  Está en el mismo servidor que la base: copiarlo a otro lugar antes de cualquier cambio grande."
echo "${CARPETA}" > .ultimo-respaldo
