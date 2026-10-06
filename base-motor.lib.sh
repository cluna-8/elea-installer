#!/usr/bin/env bash
# shellcheck shell=bash
# Funciones comunes de migrar-base-motor.sh y respaldo.sh. Se carga con `source`; no se ejecuta.
#
# Contexto: el motor de gateway tiene su base PROPIA (ENGINE_DB, default elea_engine), separada de
# la del Guardian (POSTGRES_DB). Con la base compartida, el migrador del motor borraba las tablas
# del Guardian (users, audit_logs, alembic_version…): comprobado en el ensayo del 06-oct-2026.

log()   { echo -e "\n\033[1;34m▶ $1\033[0m"; }
paso()  { echo -e "\033[1;36m  ■ $1\033[0m"; }
aviso() { echo -e "\033[1;33m! $1\033[0m" >&2; }
die()   { echo -e "\033[1;31m✗ $1\033[0m" >&2; exit 1; }

DRY="${DRY:-0}"
# Muestra el comando y lo ejecuta, salvo con --dry-run (solo lo muestra).
ejec() { echo "  \$ $*"; [ "$DRY" = 1 ] || "$@"; }

# Mismo criterio que install.sh: KEY=VALUE en .env reemplazando la línea si ya existe.
# Además actualiza el entorno de ESTE proceso: `docker compose` da prioridad al entorno del shell sobre
# .env, así que un valor viejo exportado por `source .env` taparía el cambio recién escrito.
set_env() { if grep -q "^$1=" .env; then sed -i "s|^$1=.*|$1=$2|" .env; else echo "$1=$2" >> .env; fi; export "$1=$2"; }
del_env() { sed -i "/^$1=/d" .env; unset "$1"; }

# Predicado de "tabla del motor" (sus 65 tablas y su libro de migraciones). Todo lo demás de la base
# compartida es del Guardian.
SQL_ES_MOTOR="(tablename LIKE 'LiteLLM\\_%' OR tablename = '_prisma_migrations')"

cargar_env() {
  [ -f .env ] || die "No hay .env en $(pwd): este script se corre en la carpeta del instalador."
  set -a; source .env; set +a
  PGU="${POSTGRES_USER:-elea_admin}"
  GW_DB="${POSTGRES_DB:-elea_gateway}"
  ENGINE_DB="${ENGINE_DB:-elea_engine}"
  DB_C="${DB_CONTAINER:-elea-db}"
  ENGINE_C="${ENGINE_CONTAINER:-elea-engine}"
  local n
  for n in "$PGU" "$GW_DB" "$ENGINE_DB"; do
    [[ "$n" =~ ^[A-Za-z0-9_]+$ ]] || die "Nombre inválido en .env ('$n'): solo letras, números y _."
  done
}

requerir_docker() {
  command -v docker >/dev/null || die "Falta Docker."
  docker compose version >/dev/null 2>&1 || die "Falta Docker Compose v2."
}

# psql dentro del contenedor de la base (socket local, sin contraseña): SQL por stdin, salida sin adornos.
psql_db() { local db="$1"; shift; docker exec -i "$DB_C" psql -U "$PGU" -d "$db" -X -At -v ON_ERROR_STOP=1 "$@"; }

existe_db() { [ "$(psql_db postgres <<<"SELECT 1 FROM pg_database WHERE datname = '$1'")" = 1 ]; }

# Cantidad de tablas del motor que hay en la base $1.
n_motor() { psql_db "$1" <<<"SELECT count(*) FROM pg_tables WHERE schemaname = 'public' AND ${SQL_ES_MOTOR}"; }

# Levanta `db` si no está corriendo y espera a que esté sana (no recrea nada: su configuración no cambió).
asegurar_db() {
  if [ "$(docker inspect "$DB_C" --format '{{.State.Health.Status}}' 2>/dev/null || true)" != healthy ]; then
    log "Levantando la base ($DB_C)"
    docker compose up -d db >/dev/null
    local i
    for i in $(seq 1 30); do
      [ "$(docker inspect "$DB_C" --format '{{.State.Health.Status}}' 2>/dev/null || true)" = healthy ] && return 0
      sleep 2
    done
    die "La base no quedó sana en 1 minuto. Revisá: ./elea-logs.sh db"
  fi
}
