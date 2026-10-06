#!/usr/bin/env bash
# Separa la base del motor de la base del Guardian en una instalación EXISTENTE (base compartida).
#
# Por qué: el migrador del motor aplica un diff "base viva → schema del motor" que BORRA toda tabla
# que no conoce (users, audit_logs, alembic_version…). Compartiendo base, ese diff se dispara con una
# restauración parcial o con una imagen del motor sobre otra versión (ensayo del 06-oct-2026: 21 → 0
# tablas del Guardian en ~80 s, y el /health del backend sigue en 200). Con base propia el diff solo
# puede tocar tablas del motor.
#
# Qué hace (el procedimiento se ensayó A MANO con Docker el 06-oct-2026, con la corrección `pg_dump -T`,
# no `-t`; este script lo automatiza y se probó contra un Docker simulado: tests/test-base-motor.sh.
# Falta su ensayo de punta a punta contra contenedores reales):
#   Previa (sin corte)  baja la imagen fijada · anota la imagen en marcha · copia completa de las dos
#                       bases · comprueba que el libro de migraciones esté completo
#   Corte (≈ 1 min)    para clientes y motor · crea la base nueva · copia SOLO las tablas del motor
#                       (pg_dump -T de las del Guardian) · compuerta de integridad · apunta el motor a
#                       la base nueva y le da la identidad/auditoría por HTTP · verifica llaves y logs
#   Las tablas viejas del motor en la base compartida NO se borran (D8: a los 7 días o más, y a mano).
#
# Uso:
#   ./migrar-base-motor.sh                  migra (pide confirmación escrita si hay terminal)
#   ./migrar-base-motor.sh --dry-run        imprime los pasos con los nombres reales, sin tocar nada
#   ./migrar-base-motor.sh --detectar       ¿hace falta? código 0 = sí (base compartida), 3 = no, 4 = estado ambiguo
#   ./migrar-base-motor.sh --verificar      compuerta de integridad entre las dos bases + llaves (solo lectura)
#   ./migrar-base-motor.sh --vuelta-atras   opción B: el motor vuelve a leer la base compartida
#   ./migrar-base-motor.sh --inventario     imagen y versión del motor en marcha + tamaño de sus tablas (solo lectura)
#   ./migrar-base-motor.sh --gasto          alias y gasto acumulado de cada llave en la base del motor
#   ./migrar-base-motor.sh --mostrar-limpieza  IMPRIME (no ejecuta) el SQL para borrar las copias viejas (D8)
# Opciones: --si (sin confirmación) · --espera-gasto SEG (default 70; 0 = no esperar)
#
# Exige el docker-compose.yml nuevo (con db-engine-init): hacer `git pull` antes.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=base-motor.lib.sh
source ./base-motor.lib.sh

ACCION=migrar
SI=0
ESPERA_GASTO="${ELEA_ESPERA_GASTO:-70}"
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)      DRY=1 ;;
    --detectar)     ACCION=detectar ;;
    --verificar)    ACCION=verificar ;;
    --vuelta-atras) ACCION=vuelta ;;
    --inventario)   ACCION=inventario ;;
    --gasto)        ACCION=gasto ;;
    --mostrar-limpieza) ACCION=limpieza ;;
    --si)           SI=1 ;;
    --espera-gasto) ESPERA_GASTO="${2:?--espera-gasto necesita segundos}"; shift ;;
    -h|--help)      sed -n '2,30p' "$0"; exit 0 ;;
    *) die "Opción desconocida: $1 (ver --help)" ;;
  esac
  shift
done
[[ "$ESPERA_GASTO" =~ ^[0-9]+$ ]] || die "--espera-gasto tiene que ser un entero (segundos)."

ESTADO=.migracion-motor
CLIENTES=(client tabular presenton anythingllm)   # servicios que hablan con el motor; se paran durante el corte
FOTO_SQL=$(cat <<'SQL'
SELECT 'tabla|' || tablename || '|' || (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from public.%I', tablename), false, true, '')))[1]::text
  FROM pg_tables WHERE schemaname = 'public' AND (tablename LIKE 'LiteLLM\_%' OR tablename = '_prisma_migrations') ORDER BY tablename;
SELECT 'libro|' || count(*) || '|' || count(*) FILTER (WHERE finished_at IS NULL OR rolled_back_at IS NOT NULL) FROM _prisma_migrations;
SELECT 'llaves|' || count(*) || '|' || coalesce(md5(string_agg(token || '/' || coalesce(key_alias, '-') || '/' || coalesce(spend, 0)::text, ',' ORDER BY token)), '-') FROM "LiteLLM_VerificationToken";
SQL
)
# Fotografía de una base: conteo por tabla del motor, estado del libro y huella (md5, sin mostrar las
# llaves) de llaves+alias+gasto. Dos bases con la misma fotografía tienen el mismo motor.
foto() { psql_db "$1" <<<"$FOTO_SQL"; }

# ── Detección ───────────────────────────────────────────────────────────────────────────
# 0 = base compartida con el motor adentro → hay que migrar · 3 = no hace falta · 4 = ambiguo
detectar() {
  if [ "$ENGINE_DB" = "$GW_DB" ]; then
    aviso "ENGINE_DB = POSTGRES_DB (${GW_DB}): el motor está sobre la base compartida (vuelta atrás activa o .env viejo)."
    aviso "El borrado del migrador sigue siendo posible. Para volver a separar: ./migrar-base-motor.sh"
    return 3
  fi
  existe_db "$GW_DB" || return 3
  local gw eng=0
  gw=$(n_motor "$GW_DB")
  [ "$gw" -gt 0 ] || return 3
  if existe_db "$ENGINE_DB"; then eng=$(n_motor "$ENGINE_DB"); fi
  [ "$eng" -eq 0 ] && return 0
  local marca
  marca=$(psql_db postgres <<<"SELECT coalesce(shobj_description(oid, 'pg_database'), '') FROM pg_database WHERE datname = '${ENGINE_DB}'")
  if [[ "$marca" == separada-de:* ]]; then return 3; fi
  aviso "Las dos bases (${GW_DB} y ${ENGINE_DB}) tienen tablas del motor y ${ENGINE_DB} no fue creada por este script."
  aviso "Si alguien levantó el compose nuevo a mano sin ./install.sh, el motor arrancó vacío y las llaves del motor viejo siguen en ${GW_DB}."
  aviso "Ver README, «Estado ambiguo». No se migra nada solo."
  return 4
}

esperar_motor_sano() {
  local i st
  for i in $(seq 1 72); do
    st=$(docker inspect "$ENGINE_C" --format '{{.State.Health.Status}}' 2>/dev/null || echo starting)
    [ "$st" = healthy ] && return 0
    sleep 5
  done
  return 1
}

# El motor no debe haber pasado por el camino destructivo/lento del migrador (H3 del ensayo):
# «creating baseline migration», P3005 o la ristra «Resolving migration:». Un primer arranque sobre
# base vacía SÍ dice «diff applied»: eso es inocuo y no se mira.
log_motor_limpio() {
  local n
  n=$(docker logs "$ENGINE_C" 2>&1 | grep -Ec 'creating baseline migration|P3005|Resolving migration:' || true)
  if [ "$n" -gt 0 ]; then aviso "El log del motor tiene ${n} marcas del camino «baseline» (creating baseline / P3005 / Resolving migration)."; return 1; fi
}

# Cada llave de servicio del .env tiene que autenticar contra el motor (200 en /v1/models). Con la base
# separada eso prueba, de punta a punta, la identidad por HTTP motor → backend. La llave viaja por
# entorno, nunca en la línea de comandos ni en el log.
verificar_llaves() {
  local v k st fallo=0 probadas=0
  for v in ANYTHINGLLM_PROVIDER_VIRTUAL_KEY TABULAR_ENGINE_VIRTUAL_KEY PRESENTON_ENGINE_VIRTUAL_KEY; do
    k="${!v:-}"
    if [ -z "$k" ]; then echo "    ${v}: no está en .env (no se prueba)"; continue; fi
    st=$(K="$k" docker exec -e K "$ENGINE_C" python3 -c "
import os, urllib.request as u, urllib.error as e
r = u.Request('http://localhost:4000/v1/models', headers={'Authorization': 'Bearer ' + os.environ['K']})
try: print(u.urlopen(r, timeout=20).status)
except e.HTTPError as x: print(x.code)
except Exception: print('error')" 2>/dev/null || echo error)
    probadas=$((probadas + 1))
    echo "    ${v}: HTTP ${st}"
    [ "$st" = 200 ] || fallo=1
  done
  [ "$probadas" -gt 0 ] || aviso "No hay llaves de servicio en .env: no se pudo probar la identidad del motor."
  return "$fallo"
}

esta_creado() { [ -n "$(docker ps -a -q -f "name=^/$1\$")" ]; }
levantar_clientes() {
  local s
  for s in "${CLIENTES[@]}"; do
    esta_creado "elea-${s/client/rag-client}" && docker compose up -d "$s" >/dev/null
  done
  return 0
}

confirmar() {
  [ "$DRY" = 1 ] && return 0
  [ "$SI" = 1 ] && return 0
  [ -t 0 ] || die "Sin terminal no se pide confirmación: correr a mano (o con --si)."
  echo
  read -rp "  Escribí $1 para continuar: " resp
  [ "$resp" = "$1" ] || die "Cancelado: no se tocó nada."
}

# ── Migrar ──────────────────────────────────────────────────────────────────────────────
migrar() {
  grep -q 'db-engine-init' docker-compose.yml || die "Este docker-compose.yml no es el nuevo (falta db-engine-init): hacé git pull primero."
  local pin img_actual
  if [ "$DRY" = 1 ]; then
    # --dry-run no consulta Docker: la imagen fijada sale del compose y del .env.
    pin="${ENGINE_IMAGE:-$(grep -o 'ghcr.io/[a-z0-9/-]*elea-guardian-engine@sha256:[0-9a-f]*' docker-compose.yml | head -n1)}"
    img_actual='(no se consulta en --dry-run)'
    log "Separar la base del motor — DRY-RUN: no se ejecuta nada"
  else
    pin=$(docker compose config --images 2>/dev/null | grep elea-guardian-engine || echo '(no se pudo leer)')
    img_actual=$(docker inspect "$ENGINE_C" --format '{{.Config.Image}}' 2>/dev/null || echo '(no hay contenedor)')
    log "Separar la base del motor"
  fi
  echo "  Base del Guardian : ${GW_DB}   (usuario ${PGU}, contenedor ${DB_C})"
  echo "  Base nueva motor  : ${ENGINE_DB}"
  echo "  Motor en marcha   : ${img_actual}"
  echo "  Motor fijado      : ${pin}"
  echo "  Espera de gasto   : ${ESPERA_GASTO} s (el motor vuelca el gasto por lotes; ver README)"

  if [ "$DRY" != 1 ]; then
    asegurar_db
    local rc=0
    detectar || rc=$?
    case "$rc" in
      0) ;;
      3) echo "  No hace falta migrar: la base del motor ya está separada (o no hay motor que migrar)."; return 0 ;;
      *) die "Estado ambiguo (código ${rc}): no se migra solo. Ver README." ;;
    esac
    [ "${img_actual#*@sha256:}" != "$img_actual" ] || [ "$img_actual" = '(no hay contenedor)' ] \
      || aviso "El motor en marcha usa una etiqueta, no un digest: se cambia a la imagen fijada al levantarlo."
    echo
    echo "  Corte estimado: ~1 min de motor parado + ${ESPERA_GASTO} s de espera de gasto (Hub, planillas y presentaciones sin servicio)."
    confirmar MIGRAR
  fi

  log "PREVIA (sin corte)"
  paso "1. Bajar la imagen fijada del motor (para no descargar durante el corte)"
  ejec docker compose pull --quiet engine
  paso "2. Anotar la imagen del motor en marcha (la vuelta atrás B la necesita)"
  if [ "$DRY" = 1 ]; then
    echo "  \$ docker inspect ${ENGINE_C} → ${ESTADO}/imagen-anterior"
  else
    mkdir -p "$ESTADO"; chmod 700 "$ESTADO"
    local idimg ref
    idimg=$(docker inspect "$ENGINE_C" --format '{{.Image}}' 2>/dev/null || true)
    ref=$(docker image inspect "$idimg" --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{end}}' 2>/dev/null || true)
    [ -n "$ref" ] || ref="$img_actual"
    echo "$ref" > "${ESTADO}/imagen-anterior"
    echo "    ${ref}"
  fi
  paso "3. Copia completa de las bases (respaldo.sh) — se comprueba que se pueda leer"
  if [ "$DRY" = 1 ]; then ./respaldo.sh --dry-run | sed 's/^/    /'; else ./respaldo.sh || die "Sin copia previa no se migra."; fi
  paso "4. Libro de migraciones del motor completo en ${GW_DB} (0 pendientes o fallidas)"
  if [ "$DRY" = 1 ]; then
    echo "  \$ psql -d ${GW_DB} -c \"SELECT count(*) FROM _prisma_migrations WHERE finished_at IS NULL OR rolled_back_at IS NOT NULL\"   # debe dar 0"
  else
    local pend
    pend=$(psql_db "$GW_DB" <<<"SELECT count(*) FROM _prisma_migrations WHERE finished_at IS NULL OR rolled_back_at IS NOT NULL")
    [ "$pend" = 0 ] || die "El libro de migraciones tiene ${pend} filas pendientes o fallidas: no se migra. Revisar el motor primero."
  fi

  log "CORTE"
  local t0 PARADOS=() s
  t0=$(date +%s)
  [ "$DRY" = 1 ] || VERSION_ALEMBIC=$(psql_db "$GW_DB" <<<'SELECT version_num FROM alembic_version')
  paso "5. Parar los clientes del motor (congelan el gasto)"
  if [ "$DRY" = 1 ]; then
    echo "  \$ docker compose stop ${CLIENTES[*]}"
  else
    for s in "${CLIENTES[@]}"; do
      if [ -n "$(docker ps -q -f "name=^/elea-${s/client/rag-client}\$")" ]; then PARADOS+=("elea-${s/client/rag-client}"); fi
    done
    docker compose stop "${CLIENTES[@]}"
  fi
  paso "6. Esperar ${ESPERA_GASTO} s: el motor vuelca el gasto a su base por lotes"
  if [ "$DRY" = 1 ]; then echo "  \$ sleep ${ESPERA_GASTO}"; else sleep "$ESPERA_GASTO"; fi
  paso "7. Parar el motor (el contenedor viejo queda parado, no se borra: es la vuelta atrás A)"
  ejec docker compose stop engine
  paso "8. Fotografía previa del motor en ${GW_DB} (conteos, libro, huella de llaves+gasto)"
  if [ "$DRY" = 1 ]; then echo "  \$ psql -d ${GW_DB} <<SQL … SQL   → ${ESTADO}/foto-antes.txt"; else foto "$GW_DB" > "${ESTADO}/foto-antes.txt"; fi
  paso "9. Crear la base nueva ${ENGINE_DB} (solo si no existe; si existe tiene que estar sin tablas)"
  local creada=0
  if [ "$DRY" = 1 ]; then
    echo "  \$ psql -d postgres -c 'CREATE DATABASE \"${ENGINE_DB}\" OWNER \"${PGU}\"'"
  else
    if existe_db "$ENGINE_DB"; then
      [ "$(psql_db "$ENGINE_DB" <<<"SELECT count(*) FROM pg_tables WHERE schemaname = 'public'")" = 0 ] \
        || { vuelta_a "$creada" ${PARADOS[@]+"${PARADOS[@]}"}; die "${ENGINE_DB} ya existe y tiene tablas. Si es de un intento anterior: docker exec ${DB_C} psql -U ${PGU} -d postgres -c 'DROP DATABASE \"${ENGINE_DB}\"' y reintentar."; }
    else
      psql_db postgres <<<"CREATE DATABASE \"${ENGINE_DB}\" OWNER \"${PGU}\"" >/dev/null || { vuelta_a 0 ${PARADOS[@]+"${PARADOS[@]}"}; die "No se pudo crear ${ENGINE_DB}."; }
      creada=1
    fi
  fi
  paso "10. Copiar SOLO las tablas del motor: pg_dump -Fc -T <tablas del Guardian> | pg_restore --exit-on-error"
  if [ "$DRY" = 1 ]; then
    echo "  \$ (lista de tablas del Guardian armada del catálogo de ${GW_DB}: todo lo que no es del motor)"
    echo "  \$ docker exec ${DB_C} sh -c 'pg_dump -U ${PGU} -d ${GW_DB} -Fc -T public.\"<tabla>\" … -f /tmp/motor.dump && pg_restore -U ${PGU} -d ${ENGINE_DB} --no-owner --exit-on-error /tmp/motor.dump'"
    echo "    (-T y no -t: -t no arrastra los tipos ENUM y el restore aborta; ensayo 06-oct, hallazgo H1)"
  else
    local tablas
    tablas=$(psql_db "$GW_DB" <<<"SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND NOT ${SQL_ES_MOTOR} ORDER BY 1" | tr '\n' ' ')
    [[ "$tablas" =~ ^[a-z0-9_\ ]+$ ]] || { vuelta_a "$creada" ${PARADOS[@]+"${PARADOS[@]}"}; die "No se pudo armar la lista de tablas del Guardian (vacía o con nombres raros): ${tablas}"; }
    if ! docker exec -e TLIST="$tablas" -e PGU="$PGU" -e GW="$GW_DB" -e EN="$ENGINE_DB" "$DB_C" sh -c '
        set --
        for t in $TLIST; do set -- "$@" -T "public.\"$t\""; done
        pg_dump -U "$PGU" -d "$GW" -Fc "$@" -f /tmp/motor.dump && pg_restore -U "$PGU" -d "$EN" --no-owner --exit-on-error /tmp/motor.dump
        rc=$?; rm -f /tmp/motor.dump; exit $rc'; then
      vuelta_a "$creada" ${PARADOS[@]+"${PARADOS[@]}"}; die "La copia de las tablas del motor falló: se volvió al estado anterior (vuelta atrás A)."
    fi
  fi
  paso "11. COMPUERTA DE INTEGRIDAD: misma fotografía en las dos bases, sin tablas ajenas en ${ENGINE_DB}"
  if [ "$DRY" = 1 ]; then
    echo "  \$ diff ${ESTADO}/foto-antes.txt <(foto ${ENGINE_DB})   # conteo de cada tabla, libro y huella de llaves+gasto: 0 diferencias"
    echo "  \$ psql -d ${ENGINE_DB} -c \"SELECT count(*) FROM pg_tables … NOT motor\"   # debe dar 0"
  else
    foto "$ENGINE_DB" > "${ESTADO}/foto-despues.txt" || { vuelta_a "$creada" ${PARADOS[@]+"${PARADOS[@]}"}; die "No se pudo leer la copia."; }
    local ajenas
    ajenas=$(psql_db "$ENGINE_DB" <<<"SELECT count(*) FROM pg_tables WHERE schemaname = 'public' AND NOT ${SQL_ES_MOTOR}")
    if ! diff -u "${ESTADO}/foto-antes.txt" "${ESTADO}/foto-despues.txt" || [ "$ajenas" != 0 ] \
        || ! grep -q '^libro|[0-9]*|0$' "${ESTADO}/foto-despues.txt"; then
      vuelta_a "$creada" ${PARADOS[@]+"${PARADOS[@]}"}; die "La compuerta de integridad FALLÓ (arriba, las diferencias): se volvió al estado anterior."
    fi
    echo "    COMPUERTA OK: $(grep -c '^tabla|' "${ESTADO}/foto-despues.txt") tablas, mismas filas, mismas llaves y gasto, 0 tablas ajenas."
  fi
  paso "12. Apuntar el motor a ${ENGINE_DB} y darle identidad y auditoría por HTTP (las tres juntas o ninguna)"
  if [ "$DRY" = 1 ]; then
    echo "  \$ .env: ENGINE_DB=${ENGINE_DB}  (se borran ENGINE_IDENTITY_URL, ENGINE_AUDIT_URL, ENGINE_IMAGE si quedaron de una vuelta atrás)"
    echo "  \$ docker compose up -d engine"
  else
    set_env ENGINE_DB "$ENGINE_DB"; del_env ENGINE_IDENTITY_URL; del_env ENGINE_AUDIT_URL; del_env ENGINE_IMAGE
    docker compose up -d engine || die "No se pudo recrear el motor. Vuelta atrás B: ./migrar-base-motor.sh --vuelta-atras"
  fi
  paso "13. Esperar a que el motor esté sano (hasta 6 min)"
  if [ "$DRY" = 1 ]; then
    echo "  \$ docker inspect ${ENGINE_C} → healthy"
  else
    esperar_motor_sano || die "El motor no quedó sano. Vuelta atrás B: ./migrar-base-motor.sh --vuelta-atras   (log: ./elea-logs.sh engine)"
  fi
  paso "14. Verificar: log sin «baseline», llaves de servicio con 200, base del Guardian intacta"
  if [ "$DRY" = 1 ]; then
    echo "  \$ docker logs ${ENGINE_C} | grep -E 'creating baseline migration|P3005|Resolving migration:'   # 0 marcas"
    echo "  \$ GET /v1/models con cada llave svc.* del .env desde ${ENGINE_C}   # 200"
    echo "  \$ alembic_version de ${GW_DB} igual que antes; las tablas del motor viejas siguen en ${GW_DB}"
  else
    local mal=0
    log_motor_limpio || mal=1
    verificar_llaves || mal=1
    # La copia vieja (la vuelta atrás B) tiene que seguir idéntica a la fotografía de antes del corte.
    foto "$GW_DB" | diff -q - "${ESTADO}/foto-antes.txt" >/dev/null \
      || { aviso "Las tablas del motor que quedan en ${GW_DB} ya no coinciden con la fotografía previa al corte."; mal=1; }
    [ "$(psql_db "$GW_DB" <<<'SELECT version_num FROM alembic_version')" = "$VERSION_ALEMBIC" ] \
      || { aviso "alembic_version de ${GW_DB} cambió."; mal=1; }
    [ "$mal" = 0 ] || die "La verificación FALLÓ. Vuelta atrás B (el motor vuelve a la base compartida, copias viejas intactas): ./migrar-base-motor.sh --vuelta-atras"
  fi
  paso "15. Levantar de nuevo los clientes del motor"
  if [ "$DRY" = 1 ]; then echo "  \$ docker compose up -d ${CLIENTES[*]}"; else levantar_clientes; fi
  paso "16. Marcar ${ENGINE_DB} como separada de ${GW_DB} (lo lee --detectar)"
  if [ "$DRY" = 1 ]; then
    echo "  \$ psql -d postgres -c \"COMMENT ON DATABASE ${ENGINE_DB} IS 'separada-de:${GW_DB}:<fecha>'\""
  else
    psql_db postgres <<<"COMMENT ON DATABASE \"${ENGINE_DB}\" IS 'separada-de:${GW_DB}:$(date +%F)'" >/dev/null
  fi

  echo
  if [ "$DRY" = 1 ]; then
    echo "  DRY-RUN terminado: no se tocó nada."
    return 0
  fi
  echo "  Listo. Motor parado ~$(( $(date +%s) - t0 )) s en total (incluye la espera de gasto)."
  echo
  echo "  QUEDA POR HACER (a mano, ver README):"
  echo "   • Prueba funcional con una pregunta real: planillas, presentación, chat con documentos."
  echo "     Por cada una tiene que subir el gasto de su llave en ${ENGINE_DB} y aparecer una fila nueva en audit_logs."
  echo "   • Las tablas del motor siguen en ${GW_DB} (es la vuelta atrás B). NO se borran"
  echo "     antes de 7 días y sin una copia completa nueva: README, «Borrar las copias viejas»."
  echo "   • Vuelta atrás: ./migrar-base-motor.sh --vuelta-atras"
}

# Vuelta atrás A: fallo ANTES de apuntar el motor a la base nueva. Nada cambió para el motor viejo:
# se descarta la base nueva (solo si la creó esta corrida) y se arrancan los contenedores viejos tal
# cual estaban (docker start: no pasa por el compose nuevo, que ya apunta a la base nueva).
vuelta_a() {
  local creada="$1"; shift
  aviso "Vuelta atrás A: se descarta la base nueva y se arrancan los contenedores viejos."
  if [ "$creada" = 1 ]; then psql_db postgres <<<"DROP DATABASE IF EXISTS \"${ENGINE_DB}\"" >/dev/null || aviso "No se pudo borrar ${ENGINE_DB}: hacerlo a mano."; fi
  docker start "$ENGINE_C" >/dev/null || aviso "No arrancó ${ENGINE_C}: docker compose logs"
  [ $# -eq 0 ] || docker start "$@" >/dev/null || aviso "No arrancaron todos los clientes: docker compose ps"
  return 0
}

# ── Verificar (solo lectura) ────────────────────────────────────────────────────────────
verificar() {
  log "Verificación de las dos bases (solo lectura)"
  asegurar_db
  existe_db "$ENGINE_DB" || die "No existe ${ENGINE_DB}."
  local a b ajenas mal=0
  a=$(foto "$GW_DB") || die "No se pudo leer el motor de ${GW_DB}."
  b=$(foto "$ENGINE_DB") || die "No se pudo leer ${ENGINE_DB}."
  ajenas=$(psql_db "$ENGINE_DB" <<<"SELECT count(*) FROM pg_tables WHERE schemaname = 'public' AND NOT ${SQL_ES_MOTOR}")
  echo "  Tablas ajenas al motor en ${ENGINE_DB}: ${ajenas} (debe ser 0)"
  [ "$ajenas" = 0 ] || mal=1
  if [ "$a" = "$b" ]; then
    echo "  ${GW_DB} y ${ENGINE_DB} tienen la misma fotografía del motor (conteos, libro, llaves+gasto)."
  else
    echo "  Diferencias entre ${GW_DB} (-) y ${ENGINE_DB} (+) — esperable si el motor ya cuenta gasto en ${ENGINE_DB}:"
    diff -u <(echo "$a") <(echo "$b") || true
  fi
  echo "  alembic_version de ${GW_DB}: $(psql_db "$GW_DB" <<<'SELECT version_num FROM alembic_version')"
  echo "  Llaves de servicio contra el motor:"
  verificar_llaves || mal=1
  log_motor_limpio || mal=1
  [ "$mal" = 0 ] && echo "  OK" || die "Hay problemas (arriba)."
}

# ── Vuelta atrás B ──────────────────────────────────────────────────────────────────────
# El motor vuelve a leer sus tablas de la base compartida, que este procedimiento nunca borra.
# Pérdida acotada: el gasto que el motor contó en ENGINE_DB desde el corte. audit_logs no se afecta
# (vive en el backend).
vuelta() {
  log "Vuelta atrás B: el motor vuelve a la base compartida ${GW_DB}"
  asegurar_db
  [ "$(n_motor "$GW_DB")" -gt 0 ] || die "Las tablas del motor ya no están en ${GW_DB}: no hay a dónde volver. Vuelta C: restaurar la copia completa (README)."
  local anterior=""
  [ -f "${ESTADO}/imagen-anterior" ] && anterior=$(cat "${ESTADO}/imagen-anterior")
  echo "  Imagen del motor a restaurar: ${anterior:-(no hay registro: queda la fijada en el compose)}"
  echo "  Se pierde el gasto que el motor contó en ${ENGINE_DB} desde el corte."
  confirmar VOLVER
  paso "1. .env: ENGINE_DB=${GW_DB}; identidad y auditoría por SQL (URLs vacías)${anterior:+; imagen anterior}"
  set_env ENGINE_DB "$GW_DB"; set_env ENGINE_IDENTITY_URL ""; set_env ENGINE_AUDIT_URL ""
  [ -z "$anterior" ] || set_env ENGINE_IMAGE "$anterior"
  paso "2. Recrear el motor"
  docker compose up -d engine
  esperar_motor_sano || die "El motor no quedó sano. Revisá: ./elea-logs.sh engine"
  paso "3. Verificar"
  local mal=0
  log_motor_limpio || mal=1
  verificar_llaves || mal=1
  [ "$mal" = 0 ] || die "La verificación falló después de la vuelta atrás. Vuelta C: restaurar la copia completa (README)."
  levantar_clientes
  echo
  echo "  Vuelta atrás hecha. OJO: el motor otra vez comparte base con el Guardian (riesgo de borrado)."
  echo "  Mientras tanto no subir la imagen del motor. Para volver a separar: ./migrar-base-motor.sh"
  echo "  (si ${ENGINE_DB} quedó con tablas: DROP DATABASE antes, con una copia a mano si hace falta)."
}

# ── Inventario previo (solo lectura): qué motor corre y cuánto pesan sus tablas ─────────────────────
inventario() {
  asegurar_db
  echo "  Imagen del motor: $(docker inspect "$ENGINE_C" --format '{{.Config.Image}} {{.Image}}' 2>/dev/null || echo 'sin contenedor')"
  echo "  Versión (motor y su migrador): $(docker exec "$ENGINE_C" python3 -c "import importlib.metadata as m; print(m.version('litellm'), m.version('litellm-proxy-extras'))" 2>/dev/null || echo 'no se pudo leer')"
  echo "  El análisis del 06-oct-2026 se hizo sobre «1.92.0 0.4.74». Si es otra, parar y consultar."
  echo "  Tablas más grandes del motor en ${GW_DB}:"
  psql_db "$GW_DB" <<<"SELECT '    ' || relname || ' ' || pg_size_pretty(pg_total_relation_size(oid)) FROM pg_class WHERE relkind = 'r' AND relnamespace = 'public'::regnamespace AND (relname LIKE 'LiteLLM\\_%' OR relname = '_prisma_migrations') ORDER BY pg_total_relation_size(oid) DESC LIMIT 5"
}

# ── Gasto por llave (el motor lo vuelca por lotes: leerlo ≥ 70 s después del último pedido) ──────────
gasto() {
  asegurar_db
  echo "  alias | gasto acumulado (USD) | base ${ENGINE_DB}"
  psql_db "$ENGINE_DB" <<<'SELECT coalesce(key_alias, '"'"'(sin alias)'"'"') || '"'"' | '"'"' || coalesce(spend, 0)::text FROM "LiteLLM_VerificationToken" ORDER BY 1'
}

# ── Copias viejas (D8): SOLO imprime el SQL; borrarlas es una decisión de una persona ────────────────
limpieza() {
  asegurar_db
  [ "$ENGINE_DB" != "$GW_DB" ] || die "ENGINE_DB = POSTGRES_DB: el motor usa esas tablas, no hay copias viejas que borrar."
  existe_db "$ENGINE_DB" && [ "$(n_motor "$ENGINE_DB")" -gt 0 ] || die "La base ${ENGINE_DB} no tiene el motor: no se puede borrar la copia de ${GW_DB}."
  echo "-- Copias VIEJAS del motor en ${GW_DB}. Correr SOLO si pasaron ≥ 7 días con el motor sobre ${ENGINE_DB}, si"
  echo "-- ./migrar-base-motor.sh --verificar da OK y si hay una copia completa NUEVA (./respaldo.sh). Después de esto"
  echo "-- la vuelta atrás B ya no existe (queda la C: restaurar la copia). Revisar la lista antes de ejecutar."
  echo "\\connect ${GW_DB}"
  echo "BEGIN;"
  psql_db "$GW_DB" <<<"SELECT format('DROP TABLE public.%I CASCADE;', tablename) FROM pg_tables WHERE schemaname = 'public' AND ${SQL_ES_MOTOR} ORDER BY 1"
  # Tipos ENUM que solo usaban las tablas del motor (si algo del Guardian los usa, no se listan).
  psql_db "$GW_DB" <<<"SELECT format('DROP TYPE public.%I;', t.typname) FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE n.nspname = 'public' AND t.typtype = 'e' AND t.typname NOT IN (SELECT udt_name FROM information_schema.columns WHERE table_schema = 'public' AND NOT (table_name LIKE 'LiteLLM\\_%' OR table_name = '_prisma_migrations'))"
  echo "COMMIT;"
}

# ── Principal ───────────────────────────────────────────────────────────────────────────
cargar_env
if [ "$DRY" = 1 ] && [ "$ACCION" != migrar ]; then die "--dry-run solo vale para la migración."; fi
[ "$DRY" = 1 ] || requerir_docker
case "$ACCION" in
  detectar)  asegurar_db; rc=0; detectar || rc=$?; exit "$rc" ;;
  verificar) verificar ;;
  vuelta)    vuelta ;;
  inventario) inventario ;;
  gasto)     gasto ;;
  limpieza)  limpieza ;;
  migrar)    migrar ;;
esac
