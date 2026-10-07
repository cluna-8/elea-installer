#!/usr/bin/env bash
# Pruebas del runbook consolidado «Actualizar el servidor de Elea (057 + bases separadas)» (README.md, T103): que sea UN
# orden ejecutable (pasos 0 a 9, cada uno con su verificación y su «si falla»), que cada comando exista en este repo
# (scripts, opciones, contenedores, servicios), que tenga sintaxis válida, que deje un marcador explícito en vez de inventar
# el tag de las imágenes -ext, que nombre los dos niveles de vuelta atrás, que el Paso 9 (modelos y Claude Desktop) traiga los puntos clave y que no traiga secretos. No usa Docker.
# Correr:  bash tests/test-runbook-actualizar.sh
set -uo pipefail
AQUI="$(cd "$(dirname "$0")/.." && pwd)"
README="$AQUI/README.md"
FALLOS=0
ok()   { echo "  ok   $1"; }
falla() { echo "  FALLA $1"; FALLOS=$((FALLOS + 1)); }
chequear() { local desc="$1"; shift; if "$@"; then ok "$desc"; else falla "$desc"; fi; }
chequear_no() { local desc="$1"; shift; if "$@"; then falla "$desc"; else ok "$desc"; fi; }

chequear "bash -n tests/test-runbook-actualizar.sh" bash -n "$AQUI/tests/test-runbook-actualizar.sh"
chequear "hay python3 con PyYAML" python3 -c 'import yaml'

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# La sección: desde su título hasta el siguiente «## » (los «### Paso N» son subsecciones y no la cortan).
SEC="$T/seccion"
awk '/^## Actualizar el servidor de Elea \(057 \+ bases separadas\)/{d=1;print;next} d&&/^## /{exit} d' "$README" > "$SEC"
chequear "el README tiene la sección «Actualizar el servidor de Elea (057 + bases separadas)»" [ -s "$SEC" ]
EXT="$T/extension"
awk '/^## Extensión de redirección de modelos/{d=1;print;next} d&&/^## /{exit} d' "$README" > "$EXT"
tiene() { grep -qF -- "$1" "$SEC"; }

# Un archivo por paso: $T/paso0 … $T/paso9 (todo lo que va hasta el siguiente «### Paso»).
awk -v dir="$T" '/^### Paso [0-9]+ /{n=$3; f=dir "/paso" n} f{print > f}' "$SEC"
# Bloques de comandos (```bash) de cada paso: $T/paso<N>.bloques
for n in 0 1 2 3 4 5 6 7 8 9; do
  [ -f "$T/paso$n" ] && awk '/^```bash$/{b=1;next} /^```$/{b=0;next} b' "$T/paso$n" > "$T/paso$n.bloques"
done

echo "— un orden: pasos 0 a 9, cada uno con su verificación y su «si falla»"
prev=0
for n in 0 1 2 3 4 5 6 7 8 9; do
  chequear "existe el «Paso $n»" [ -s "$T/paso$n" ]
  l=$(grep -nE "^### Paso $n " "$SEC" | head -n1 | cut -d: -f1)
  chequear "el «Paso $n» viene después del anterior" bash -c '[ -n "$1" ] && [ "$1" -gt "$2" ]' _ "$l" "$prev"
  prev=${l:-$prev}
  chequear "el «Paso $n» trae comandos copiables (bloque bash)" [ -s "$T/paso$n.bloques" ]
  chequear "el «Paso $n» dice cómo se verifica (**Verificar**)" grep -q '^\*\*Verificar' "$T/paso$n"
  chequear "el «Paso $n» dice qué hacer si falla (**Si falla**)" grep -q '^\*\*Si falla' "$T/paso$n"
done
for par in "0:[Pp]recondicion" "1:[Rr]espaldo" "2:[Ii]nstalador" "3:[Ss]eparar la base del motor" "4:super_admin" "5:sin redirecci" "6:[Aa]ctivar" "7:[Vv]erificar" "8:[Vv]uelta atr" "9:[Mm]odelos y Claude Desktop"; do
  chequear "el título del «Paso ${par%%:*}» nombra lo que hace (${par#*:})" grep -Eq "^### Paso ${par%%:*} .*${par#*:}" "$SEC"
done
chequear "no hay un «Paso 10»: son diez pasos, 0 a 9" bash -c '! grep -Eq "^### Paso 10 " "$1"' _ "$SEC"

echo "— el orden de los comandos importa"
chequear "Paso 0: anota imagen y versión del motor (--inventario), imágenes en marcha, disco y revisión de la base" bash -c '
  grep -q "migrar-base-motor.sh --inventario" "$1" && grep -q "docker compose images" "$1" && grep -q "df -h" "$1" && grep -q "alembic_version" "$1"' _ "$T/paso0.bloques"
chequear "Paso 0: comprueba que el respaldo M2 existe y se puede leer (sha256sum -c / pg_restore -l)" bash -c '
  grep -q "M2" "$1" && grep -q "sha256sum -c" "$1" && grep -q "pg_restore -l" "$1"' _ "$T/paso0.bloques"
chequear "Paso 0: comprueba que ELEA_REDIRECT no está puesto todavía (install.sh lo activaría en los pasos 3 y 4)" grep -q 'ELEA_REDIRECT' "$T/paso0.bloques"
chequear "Paso 1: ./respaldo.sh y verificación de la copia (SHA256SUMS, .ultimo-respaldo)" bash -c 'grep -q "^./respaldo.sh" "$1" && grep -q "sha256sum -c" "$1" && grep -q ".ultimo-respaldo" "$1"' _ "$T/paso1.bloques"
chequear "Paso 1: avisa que la copia es del mismo servidor y la retención de respaldo.sh (guardarla fuera de respaldos/)" bash -c 'grep -qi "fuera del servidor" "$1" && grep -qi "retenci" "$1"' _ "$T/paso1"
chequear "Paso 2: git pull y valida el compose nuevo (docker compose config -q)" bash -c 'grep -q "git pull" "$1" && grep -q "docker compose config -q" "$1"' _ "$T/paso2.bloques"
chequear "Paso 2: mira ELEA_EXT_MIN_VERSION en install.sh" grep -q 'ELEA_EXT_MIN_VERSION' "$T/paso2.bloques"
chequear "Paso 3: ./migrar-base-motor.sh --detectar, --dry-run y la migración (pide MIGRAR), y recién después ./install.sh" bash -c '
  b="$1"; grep -q "migrar-base-motor.sh --detectar" "$b" && grep -q "migrar-base-motor.sh --dry-run" "$b" && grep -q "^./migrar-base-motor.sh *\(#.*\)\?$" "$b" &&
  [ "$(grep -n "^./migrar-base-motor.sh *\(#.*\)\?$" "$b" | head -1 | cut -d: -f1)" -lt "$(grep -n "^./install.sh" "$b" | head -1 | cut -d: -f1)" ]' _ "$T/paso3.bloques"
chequear "Paso 3: nombra MIGRAR y la ventana (30 minutos)" bash -c 'grep -q "MIGRAR" "$1" && grep -q "30 min" "$1"' _ "$T/paso3"
chequear "Paso 3: verifica con --verificar" grep -q 'migrar-base-motor.sh --verificar' "$T/paso3.bloques"
chequear "Paso 3: vuelta atrás de la separación (--vuelta-atras, escalones A/B/C)" bash -c 'grep -q -- "--vuelta-atras" "$1" && grep -q "VOLVER" "$1"' _ "$T/paso3"
chequear "Paso 4: ./crear-super-admin.sh y lo repite para verificar (idempotente)" bash -c '[ "$(grep -c "^./crear-super-admin.sh" "$1")" -ge 2 ]' _ "$T/paso4.bloques"
chequear "Paso 4: avisa que la contraseña se muestra una sola vez y que se limpia la pantalla" bash -c 'grep -qi "una sola vez" "$1" && grep -q "clear" "$1"' _ "$T/paso4"
for n in 3 4 5; do
  chequear_no "Paso $n: ningún comando activa la extensión (ELEA_REDIRECT=1 todavía no)" grep -Eq '^[^#]*ELEA_REDIRECT=1' "$T/paso$n.bloques"
done
chequear "Paso 5: verifica sin redirección: salud, /docs, internal 404 y que /api/v1/redirect/health todavía da 404 (esperado)" bash -c '
  grep -q "/health" "$1" && grep -q "/docs" "$1" && grep -q "/api/v1/internal/" "$1" && grep -q "/api/v1/redirect/health" "$1" && grep -q "404" "$1"' _ "$T/paso5"
chequear "Paso 5: dice que es un punto donde se puede parar (la instalación queda completa sin redirección)" bash -c 'grep -qi "punto.*parar\|parar acá\|podés parar" "$1"' _ "$T/paso5"
chequear "Paso 6: respaldo antes de activar y anotar cuál es el previo a la activación" bash -c 'grep -q "^./respaldo.sh" "$1" && grep -q ".ultimo-respaldo" "$1"' _ "$T/paso6.bloques"
MIN=$(sed -n 's/^ELEA_EXT_MIN_VERSION="\([0-9-]*\)".*/\1/p' "$AQUI/install.sh" | head -n1)
chequear "install.sh trae una fecha AAAA-MM-DD como mínimo (ya no el centinela)" bash -c '[[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]' _ "$MIN"
chequear "Paso 6: el tag es el del juego de imágenes probado en T102 y coincide con el mínimo de install.sh" grep -q "^ELEA_EXT_VERSION='$MIN'" "$T/paso6.bloques"
chequear_no "no queda ningún marcador sin completar (<TAG-A-COMPLETAR-TRAS-T102> / [COMPLETAR-TRAS-T102] / PENDIENTE-PRIMER-RELEASE)" grep -Eq "TAG-A-COMPLETAR|COMPLETAR-TRAS-T102|PENDIENTE-PRIMER-RELEASE" "$SEC"
chequear "Paso 6: no activa con el marcador puesto (valida AAAA-MM-DD antes de escribir ELEA_REDIRECT=1 en .env)" bash -c '
  b="$1"; grep -q "=~" "$b" && [ "$(grep -n "=~" "$b" | head -1 | cut -d: -f1)" -lt "$(grep -n "ELEA_REDIRECT=1" "$b" | head -1 | cut -d: -f1)" ] && grep -q "^if " "$b" && grep -q "^fi" "$b"' _ "$T/paso6.bloques"
chequear "Paso 6: activa con ./install.sh (activar-redirect.sh solo no conoce el tag mínimo)" bash -c 'grep -q "./install.sh" "$1" && ! grep -q "^ *./activar-redirect.sh" "$1"' _ "$T/paso6.bloques"
chequear "Paso 6: explica el tag mínimo (ELEA_EXT_MIN_VERSION) y que falla cerrado sin tocar nada" bash -c 'grep -q "ELEA_EXT_MIN_VERSION" "$1" && grep -qi "falla cerrado" "$1"' _ "$T/paso6"
chequear "Paso 6: imágenes -ext (docker inspect) y modo 600 del entorno de la extensión" bash -c 'grep -q "\-ext" "$1" && grep -q "redirect.env" "$1" && grep -q "600" "$1"' _ "$T/paso6"
chequear "Paso 6: las variables opcionales del enmascarado (no hace falta tocarlas) y cómo cambiarlas" bash -c 'grep -q "force-recreate" "$1" && grep -q "redirect.env" "$1"' _ "$T/paso6"
chequear "Paso 7: /api/v1/redirect/health 200" bash -c 'grep -q "/api/v1/redirect/health" "$1" && grep -q "200" "$1"' _ "$T/paso7.bloques"
chequear "Paso 7: /api/v1/internal/ da 404 desde otra máquina de la LAN" bash -c 'grep -q "/api/v1/internal/" "$1" && grep -q "404" "$1"' _ "$T/paso7"
chequear "Paso 7: ...y dice que tiene que ser desde otra máquina, no el servidor" grep -qiE 'otra máquina|otra PC' "$T/paso7"
chequear "Paso 7: una conversación de Claude Code con un dato personal de prueba (ANTHROPIC_BASE_URL y ANTHROPIC_AUTH_TOKEN)" bash -c 'grep -q "ANTHROPIC_BASE_URL=http://<servidor>:8091/api/v1/gw" "$1" && grep -q "ANTHROPIC_AUTH_TOKEN=" "$1"' _ "$T/paso7.bloques"
chequear "Paso 7: dice cómo se ve el enmascarado: sale enmascarado hacia el modelo, vuelve restaurado y la auditoría (solo metadatos) lo registra" bash -c '
  grep -qi "enmascarad" "$1" && grep -qi "restaurad" "$1" && grep -qi "metadatos" "$1" && grep -q "masking_scope" "$1"' _ "$T/paso7"
chequear "Paso 7: usa un dato de prueba inventado, nunca el de una persona real" grep -qi 'inventad' "$T/paso7"
chequear "Paso 7: verifica el libro de migraciones del motor (--verificar)" grep -q 'migrar-base-motor.sh --verificar' "$T/paso7.bloques"

echo "— vuelta atrás (Paso 8): dos niveles"
chequear "nombra el nivel 1 (apagar) y el nivel 2 (volver a las imágenes base)" bash -c 'grep -Eq "^#### Nivel 1.*apagar" "$1" && grep -Eq "^#### Nivel 2.*volver a las imágenes base" "$1"' _ "$T/paso8"
chequear "nivel 1: sacar ELEA_REDIRECT y ./install.sh; quita GATEWAY_PLUGINS y PLUGIN_PACKAGES y conserva la imagen -ext y ALEMBIC_EXTRA_VERSION_LOCATIONS" bash -c '
  grep -q "sed -i .*ELEA_REDIRECT" "$1" && grep -q "./install.sh" "$1" && grep -q "GATEWAY_PLUGINS" "$1" && grep -q "PLUGIN_PACKAGES" "$1" &&
  grep -q "ALEMBIC_EXTRA_VERSION_LOCATIONS" "$1" && grep -qi "conserva" "$1"' _ "$T/paso8"
chequear "nivel 1: explica por qué (con las migraciones aplicadas la imagen base no arranca)" grep -qiE 'imagen base.*no arranca|revisiones desconocidas' "$T/paso8"
chequear "nivel 2: solo restaurando el respaldo previo (pg_restore, renombrar la base, sacar las variables del instalador)" bash -c '
  grep -q "pg_restore" "$1" && grep -q "RENAME TO" "$1" && grep -q "COMPOSE_FILE" "$1" && grep -q "ELEA_REDIRECT_ACTIVADA" "$1"' _ "$T/paso8.bloques"
chequear "nivel 2: dice que es SOLO restaurando el respaldo previo" grep -qE '\*\*Solo\*\* restaurando' "$T/paso8"
chequear "nivel 2: un respaldo del estado ACTUAL antes de restaurar" bash -c 'grep -q "^./respaldo.sh" "$1"' _ "$T/paso8.bloques"
chequear "nivel 2: sin respaldo previo no hay nivel 2 (rollback con migraciones aplicadas no soportado)" bash -c 'grep -qiE "sin (el )?respaldo" "$1" && grep -qiE "no est[aá] soportad" "$1"' _ "$T/paso8"
chequear "nivel 2: no borra nada (la base con la extensión se renombra; DROP DATABASE es decisión de una persona)" bash -c 'grep -q "elea_gateway_con_extension" "$1" && grep -q "DROP DATABASE" "$1"' _ "$T/paso8"
chequear "el comando que saca las variables del instalador (nivel 2) es EL MISMO que el de la sección «Extensión de redirección»" bash -c '
  a=$(grep -E "^sed -i -E .*ELEA_REDIRECT_ACTIVADA" "$1"); b=$(grep -E "^sed -i -E .*ELEA_REDIRECT_ACTIVADA" "$2"); [ -n "$a" ] && [ "$a" = "$b" ]' _ "$T/paso8.bloques" "$EXT"
chequear "...y el unset de esas variables también" bash -c '
  a=$(grep -E "^unset .*ELEA_REDIRECT_ACTIVADA" "$1"); b=$(grep -E "^unset .*ELEA_REDIRECT_ACTIVADA" "$2"); [ -n "$a" ] && [ "$a" = "$b" ]' _ "$T/paso8.bloques" "$EXT"

echo "— los comandos existen en este repo"
cat "$T"/paso?.bloques > "$T/todos.sh"
chequear "hay bloques de comandos en todos los pasos" bash -c '[ "$(ls "$1"/paso?.bloques | wc -l)" = 10 ]' _ "$T"
for n in 0 1 2 3 4 5 6 7 8 9; do chequear "bash -n del Paso $n" bash -n "$T/paso$n.bloques"; done
chequear "todo ./script.sh del runbook existe y es ejecutable" bash -c 'for s in $(grep -ohE "\./[a-z-]+\.sh" "$1" | sort -u); do [ -x "$2/${s#./}" ] || { echo "falta $s" >&2; exit 1; }; done' _ "$SEC" "$AQUI"
# Cada opción --xxx que el runbook le pasa a un script del repo está en el código de ese script.
opciones_ok() {
  local s o falta=0
  for s in migrar-base-motor.sh respaldo.sh crear-super-admin.sh; do
    for o in $(grep -E "^ *\./${s//./\\.}( |\$)" "$T/todos.sh" | sed 's/#.*//' | grep -oE -- ' --[a-z-]+' | sort -u); do
      grep -qE -- "^ *${o# }\)|^ *[a-z|-]*\|?${o# }[|)]" "$AQUI/$s" || { echo "  $s no tiene la opción ${o# }" >&2; falta=1; }
    done
  done
  return $falta
}
chequear "cada opción --xxx que el runbook usa existe en su script (migrar-base-motor.sh, respaldo.sh, crear-super-admin.sh)" opciones_ok
chequear "los contenedores que nombra (elea-*) existen en docker-compose.yml" bash -c '
  for c in $(grep -ohE "\belea-[a-z-]+\b" "$1" | sort -u | grep -Ev "^elea-(logs|installer|guardian-[a-z]+)$"); do
    grep -q "container_name: $c\$" "$2/docker-compose.yml" || { echo "falta container $c" >&2; exit 1; }; done' _ "$T/todos.sh" "$AQUI"
chequear "los servicios que nombra (docker compose … <servicio>) existen en el compose (base + override)" python3 - "$T/todos.sh" "$AQUI" <<'PY'
import re, sys, yaml
todos, aqui = sys.argv[1:3]
servicios = set()
for f in ("docker-compose.yml", "docker-compose.redirect.yml"):
    servicios |= set(yaml.safe_load(open(f"{aqui}/{f}"))["services"])
mal = []
for ln in open(todos):
    ln = re.split(r"[|;&<>]", ln.split("#")[0])[0]
    m = re.search(r"docker compose (?:up|stop|restart|pull|logs|ps|exec)\b(.*)", ln)
    if not m:
        continue
    for tok in m.group(1).split():
        if tok.startswith("-"):
            continue
        if re.fullmatch(r"[a-z][a-z-]*", tok) and tok not in ("python", "sh", "test", "alembic", "current", "heads", "head", "d", "T"):
            if tok not in servicios:
                mal.append((tok, ln.strip()))
for tok, ln in mal:
    print(f"  servicio desconocido {tok!r} en: {ln}", file=sys.stderr)
sys.exit(1 if mal else 0)
PY
chequear "no usa el 8000 del backend (los puertos publicados son 8090 panel, 8091 proxy de la API)" bash -c '! grep -Eq ":8000\b" "$1"' _ "$T/todos.sh"
chequear "no usa comandos destructivos del volumen (down -v, volume rm, prune, rm -rf respaldos)" bash -c '! grep -Eq "down -v|volume rm|system prune|rm -rf +respaldos|docker volume" "$1"' _ "$T/todos.sh"
chequear "DROP DATABASE no es un comando del runbook: solo aparece en prosa, como decisión de una persona" bash -c '! grep -q "DROP DATABASE" "$1"' _ "$T/todos.sh"

echo "— variables del enmascarado que agregó la 057"
for k in MASKING_NONCE_KEY MASKING_ANALYSIS_CACHE_ENABLED MASKING_ANALYSIS_CACHE_MAX_ENTRIES MASKING_ANALYSIS_CACHE_TTL_S MASKING_ANALYSIS_CACHE_SALT \
  MASKING_PDF_MAX_PAGES MASKING_PDF_MAX_BYTES MASKING_PDF_MAX_MEMORY_MB MASKING_PDF_TIMEOUT_S MASKING_PDF_MAX_CONCURRENCY MASKING_PDF_MAX_STREAM_BYTES \
  MASKING_PDF_MAX_TEXT_CHARS MASKING_PDF_MAX_PER_REQUEST MASKING_PDF_REQUEST_DEADLINE_S MASKING_PDF_CACHE_ENTRIES MASKING_EXEMPT_SYSTEM_PROMPT \
  MASKING_EXEMPT_TOOL_DEFINITIONS; do
  chequear "el runbook nombra $k" tiene "$k"
done
chequear "aclara que S14_EXEMPT_POSITIONS no es una variable (es una tabla del código) y que las exenciones opcionales están apagadas por defecto" bash -c '
  grep -q "S14_EXEMPT_POSITIONS" "$1" && grep -qiE "no es una variable|tabla del c[oó]digo" "$1" && grep -qiE "apagadas? por defecto" "$1"' _ "$SEC"

echo "— Paso 9: modelos y Claude Desktop (lo hace el admin; cumplimiento solo lo suyo)"
p9() { grep -qF -- "$1" "$T/paso9"; }
chequear "Paso 9: lo hace el admin de la empresa y cumplimiento solo la residencia de la ficha" bash -c 'grep -q "administrador de la empresa" "$1" && grep -q "cumplimiento" "$1" && grep -qi "lo que es suyo" "$1"' _ "$T/paso9"
chequear "Paso 9: las credenciales no se editan (se crea otra y se reasigna) y el endpoint va en cada modelo (Dirección base)" bash -c 'grep -q "no se editan" "$1" && grep -q "reasign" "$1" && grep -q "Dirección base" "$1"' _ "$T/paso9"
chequear "Paso 9: credencial de Azure con la versión de API 2025-04-01-preview" p9 '2025-04-01-preview'
chequear "Paso 9: modelos de Azure por nombre de despliegue (gpt-5.6-luna, gpt-5.1-chat, gpt-5.4-mini, gpt-4o-mini) y archivar los 4 sembrados" bash -c '
  for m in gpt-5.6-luna gpt-5.1-chat gpt-5.4-mini gpt-4o-mini; do grep -q -- "$m" "$1" || exit 1; done; grep -qi "archivar" "$1" && grep -qi "nombre del despliegue" "$1"' _ "$T/paso9"
chequear "Paso 9: ficha (Microsoft Corporation, Entrena con datos No, Retención cero No, DPA) y resultado «Dentro de AMERICAS» / Estándar" bash -c '
  grep -q "Microsoft Corporation" "$1" && grep -q "Entrena con datos" "$1" && grep -q "Retención cero" "$1" && grep -q "DPA" "$1" && grep -q "Dentro de AMERICAS" "$1" && grep -q "Estándar" "$1"' _ "$T/paso9"
chequear "Paso 9: la región real del recurso es un dato a confirmar (US en Elea), no una afirmación" bash -c 'grep -q "región real del recurso" "$1" && grep -qi "a confirmar" "$1"' _ "$T/paso9"
chequear "Paso 9: ids publicados claude-opus-5-5, claude-sonnet-5-5, claude-haiku-4-5 con etiqueta «id pedido»" bash -c '
  grep -q "claude-opus-5-5" "$1" && grep -q "claude-sonnet-5-5" "$1" && grep -q "claude-haiku-4-5" "$1" && grep -q "id pedido" "$1"' _ "$T/paso9"
chequear "Paso 9: reglas tier → destino (opus→gpt-5.6-luna, sonnet→gpt-5.1-chat, haiku→gpt-5.4-mini) y política encendida" bash -c '
  grep -q "claude-opus-5-5. → .gpt-5.6-luna" "$1" && grep -q "claude-sonnet-5-5. → .gpt-5.1-chat" "$1" && grep -q "claude-haiku-4-5. → .gpt-5.4-mini" "$1" && grep -qi "política.*encendida\|encendida.*política" "$1"' _ "$T/paso9"
chequear "Paso 9: cambiar el destino de un tier (a OpenRouter, con su credencial) sin tocar a los clientes" bash -c 'grep -q "OpenRouter" "$1" && grep -qi "credencial de OpenRouter" "$1" && grep -qi "sin tocar a los clientes" "$1"' _ "$T/paso9"
chequear "Paso 9: grupos «Todos» y «Solo Azure» (alcance de grupo y perfil de acceso por proveedor)" bash -c 'grep -q "Todos" "$1" && grep -q "Solo Azure" "$1" && grep -qi "perfil de acceso" "$1" && grep -qi "alcance de grupo" "$1"' _ "$T/paso9"
chequear "Paso 9: llave por persona con 1.000.000 tpm y 120 rpm, Editar límites y el kit que ya nace así" bash -c 'grep -q "1.000.000 tpm" "$1" && grep -q "120 rpm" "$1" && grep -q "Editar límites" "$1" && grep -qi "kit" "$1"' _ "$T/paso9"
chequear "Paso 9: Claude Desktop: Gateway, URL sin /v1, Clave de API estática, bearer, descubrimiento" bash -c '
  grep -q "Configure Third-Party Inference" "$1" && grep -q "Gateway" "$1" && grep -q "8091/api/v1/gw" "$1" && grep -q "sin .\/v1." "$1" && grep -q "Clave de API estática" "$1" && grep -q "bearer" "$1" && grep -qi "descubrimiento" "$1"' _ "$T/paso9"
chequear "Paso 9: espacio de trabajo: «* Permitir todo», Omitir verificación de dominio de WebFetch, Análisis avanzado de archivos" bash -c '
  grep -q "Permitir todo" "$1" && grep -q "Omitir verificación de dominio de WebFetch" "$1" && grep -q "Análisis avanzado de archivos" "$1"' _ "$T/paso9"
chequear "Paso 9: Cowork con carpeta de trabajo (y el síntoma FileNotFoundError sin ella)" bash -c 'grep -q "carpeta de trabajo" "$1" && grep -q "FileNotFoundError" "$1"' _ "$T/paso9"
chequear "Paso 9: el kit (managed-settings.json): inferenceGatewayBaseUrl del servidor, no http://backend:8000" bash -c 'grep -q "managed-settings.json" "$1" && grep -q "inferenceGatewayBaseUrl" "$1" && grep -q "http://backend:8000" "$1"' _ "$T/paso9"
chequear "Paso 9: prueba de aceptación: los tres modelos, un DNI de prueba, Cowork con un PDF y un PPT, un SVG y la auditoría" bash -c '
  grep -q "DNI" "$1" && grep -q "PDF" "$1" && grep -q "PPT" "$1" && grep -q "SVG" "$1" && grep -qi "auditor" "$1" && grep -qi "solo metadatos" "$1"' _ "$T/paso9"
chequear "Paso 9: notas: esfuerzo de razonamiento (gpt-5.1-chat solo medium), imágenes sin filtro (MASKING_IMAGES) y los modelos no generan imágenes" bash -c '
  grep -q "reasoning_effort" "$1" && grep -q "solo acepta .medium." "$1" && grep -q "MASKING_IMAGES=pass" "$1" && grep -qi "no generan imágenes" "$1"' _ "$T/paso9"
chequear "Paso 9: no cierra en silencio lo que no está verificado (MASKING_IMAGES y la URL del kit quedan marcados)" bash -c 'grep -q "no figura en la verificación" "$1" && grep -q "🔵" "$1"' _ "$T/paso9"
chequear "Paso 9: la leyenda de estado es honesta (🟡) y no se da nada por 🟢 sin prueba en vivo" bash -c 'grep -q "🟡" "$1" && ! grep -q "🟢" "$1"' _ "$T/paso9"
chequear "Paso 9: la credencial del catálogo reemplaza al .env en el Paso 6 (el .env queda para lo heredado) y el Paso 6 ya no dice que solo cumplimiento ve los destinos" bash -c '
  grep -q "es ahora \*\*la del catálogo\*\*" "$1" && grep -qi "quedan para lo heredado" "$1" && ! grep -q "solo los ve ese" "$1" && ! grep -q "la usa el motor desde .\.env" "$1"' _ "$T/paso6"
chequear "Paso 7 c): remite al Paso 9 (necesita modelos publicados antes) y d) aclara que ahí no queda nada servido" bash -c 'grep -q "Paso 9" "$1"' _ "$T/paso7"

echo "— honestidad, secretos y marca"
chequear "dice qué NO se probó con contenedores reales y que la prueba local T102 es previa" bash -c 'grep -qiE "no se prob" "$1" && grep -qi "contenedores reales" "$1" && grep -q "T102" "$1"' _ "$SEC"
chequear "apunta al archivo de evidencia de T102 y ese archivo existe" bash -c 'grep -q "EVIDENCIA-T102.md" "$1" && [ -s "$2/EVIDENCIA-T102.md" ]' _ "$SEC" "$AQUI"
chequear "dice que las imágenes -ext de ese tag están construidas pero NO publicadas todavía (publicar con VERSION=<tag>)" bash -c 'grep -qi "no publicad\|sin publicar\|no se publicaron" "$1" && grep -q "VERSION=" "$1"' _ "$SEC"
chequear "dice en qué pantalla y con qué usuario se dan de alta los destinos (cumplimiento / super_admin, Modelos, Ficha)" bash -c 'grep -q "super_admin" "$1" && grep -q "Ficha" "$1" && grep -q "Dirección base" "$1" && grep -q "Jurisdicción de inferencia" "$1"' _ "$SEC"
chequear "avisa que se trabaja desde la consola web por VPN" bash -c 'grep -qi "VPN" "$1" && grep -qi "consola web" "$1"' _ "$SEC"
chequear "no trae llaves reales (sk-…, tokens largos): solo marcadores <…> y nombres de variables" bash -c '! grep -Eq "sk-[A-Za-z0-9]{10,}|(KEY|TOKEN|PASSWORD)=[A-Za-z0-9+/]{20,}" "$1"' _ "$SEC"
chequear "no nombra internals prohibidos (litellm, berriai, presidio) ni el nombre de la extensión" bash -c '! grep -Eiq "litellm|berriai|presidio|sentinel" "$1"' _ "$SEC"
chequear "no nombra GDPR ni la EU AI Act (no rigen en esta línea)" bash -c '! grep -Eiq "GDPR|AI Act" "$1"' _ "$SEC"
chequear "no usa «anonimización» (el enmascarado es seudonimización reversible)" bash -c '! grep -Eiq "anonimiz" "$1"' _ "$SEC"

echo "— el README apunta al runbook"
chequear "«Actualizar una instalación existente» remite al runbook consolidado" bash -c '
  awk "/^## Actualizar una instalación existente/{d=1;next} d&&/^## /{exit} d" "$1" | grep -q "Actualizar el servidor de Elea (057 + bases separadas)"' _ "$README"
chequear "README: tests/test-runbook-actualizar.sh" grep -q 'bash tests/test-runbook-actualizar.sh' "$README"

echo
if [ "$FALLOS" = 0 ]; then echo "TODO OK"; else echo "$FALLOS FALLO(S)"; exit 1; fi
