#!/usr/bin/env bash
# Pruebas del runbook de la extensión de redirección de modelos (README.md, T103): que nombre el respaldo previo,
# la activación, la verificación, la configuración de Claude Desktop y Claude Code y los DOS niveles de vuelta
# atrás, en ese orden; que sus comandos existan y tengan sintaxis válida, y que no traiga secretos.
# Correr:  bash tests/test-runbook-redirect.sh
set -uo pipefail
AQUI="$(cd "$(dirname "$0")/.." && pwd)"
README="$AQUI/README.md"
FALLOS=0
ok()   { echo "  ok   $1"; }
falla() { echo "  FALLA $1"; FALLOS=$((FALLOS + 1)); }
chequear() { local desc="$1"; shift; if "$@"; then ok "$desc"; else falla "$desc"; fi; }

chequear "bash -n tests/test-runbook-redirect.sh" bash -n "$AQUI/tests/test-runbook-redirect.sh"

# La sección del runbook: desde su título «## Extensión de redirección de modelos» hasta el siguiente «## ».
SEC=$(mktemp); trap 'rm -f "$SEC"' EXIT
awk '/^## Extensión de redirección de modelos/{d=1;print;next} d&&/^## /{exit} d' "$README" > "$SEC"
chequear "el README tiene la sección «Extensión de redirección de modelos»" [ -s "$SEC" ]
tiene() { grep -qF -- "$1" "$SEC"; }
linea() { grep -nF -- "$1" "$SEC" | head -n1 | cut -d: -f1; }

echo "— los pasos, nombrados y en orden"
for h in "Antes de activar" "Respaldo previo" "Activar" "Verificar" "Configurar Claude Desktop y Claude Code" "Vuelta atrás"; do
  chequear "tiene el apartado «$h»" grep -Eq "^###+ .*$h" "$SEC"
done
n_resp=$(grep -nE '^###+ .*Respaldo previo' "$SEC" | head -n1 | cut -d: -f1)
n_act=$(grep -nE '^###+ .*Activar' "$SEC" | head -n1 | cut -d: -f1)
n_ver=$(grep -nE '^###+ .*Verificar' "$SEC" | head -n1 | cut -d: -f1)
n_cfg=$(grep -nE '^###+ .*Configurar Claude Desktop' "$SEC" | head -n1 | cut -d: -f1)
n_vta=$(grep -nE '^###+ .*Vuelta atrás' "$SEC" | head -n1 | cut -d: -f1)
chequear "el orden es respaldo → activar → verificar → configurar → vuelta atrás" \
  bash -c '[ -n "$1" ] && [ "$1" -lt "$2" ] && [ "$2" -lt "$3" ] && [ "$3" -lt "$4" ] && [ "$4" -lt "$5" ]' _ "$n_resp" "$n_act" "$n_ver" "$n_cfg" "$n_vta"

echo "— respaldo y activación"
chequear "nombra el respaldo previo con ./respaldo.sh" tiene './respaldo.sh'
chequear "dice que se toma ANTES de activar y que se copia fuera del servidor" bash -c 'grep -qiE "antes de activar" "$1" && grep -qiE "fuera del servidor" "$1"' _ "$SEC"
chequear "activa con ELEA_REDIRECT=1" tiene 'ELEA_REDIRECT=1'
chequear "pide ELEA_EXT_VERSION (la versión publicada con las imágenes -ext)" tiene 'ELEA_EXT_VERSION'
chequear "corre ./install.sh para activar" tiene './install.sh'
chequear "explica que sin ELEA_REDIRECT no cambia nada" bash -c 'grep -qiE "sin .?ELEA_REDIRECT" "$1" && grep -qiE "ni un byte|no cambia" "$1"' _ "$SEC"
chequear "explica el tag mínimo (ELEA_EXT_MIN_VERSION, fecha fijada en install.sh) y que ya no es el centinela" \
  bash -c 'grep -q "ELEA_EXT_MIN_VERSION" "$1" && ! grep -q "PENDIENTE-PRIMER-RELEASE" "$1" && grep -qi "release" "$1"' _ "$SEC"
chequear "dice que el motor -ext se fija por digest (ENGINE_EXT_IMAGE) y se verifica el libro de migraciones del motor" bash -c 'grep -q "ENGINE_EXT_IMAGE" "$1" && grep -q "migrar-base-motor.sh --verificar" "$1"' _ "$SEC"
chequear "dice dónde queda el entorno de la extensión (fuera del repo, modo 600) sin mostrar secretos" bash -c 'grep -q "redirect.env" "$1" && grep -q "600" "$1" && grep -qi "fuera del repo" "$1"' _ "$SEC"

echo "— verificación"
chequear "verifica /api/v1/redirect/health (200)" bash -c 'grep -q "/api/v1/redirect/health" "$1" && grep -q "503" "$1"' _ "$SEC"
chequear "verifica /api/v1/gw/v1/models con una llave" tiene '/api/v1/gw/v1/models'
chequear "verifica un pedido (chat) con una llave de prueba" bash -c 'grep -q "/api/v1/gw/v1/chat/completions" "$1" || grep -q "/api/v1/gw/v1/messages" "$1"' _ "$SEC"
chequear "verifica que /api/v1/internal/ da 404 desde otra máquina de la LAN" bash -c 'grep -q "/api/v1/internal/" "$1" && grep -q "404" "$1" && grep -qi "otra máquina\|otra PC" "$1"' _ "$SEC"
chequear "dice qué hacer si health da 503 o 404" bash -c 'grep -q "region_unresolved\|region_row_missing" "$1" && grep -q "404" "$1"' _ "$SEC"

echo "— Claude Desktop y Claude Code"
chequear "Claude Code: ANTHROPIC_BASE_URL y ANTHROPIC_AUTH_TOKEN con la URL del gateway" bash -c 'grep -q "ANTHROPIC_BASE_URL=http://<servidor>:8091/api/v1/gw" "$1" && grep -q "ANTHROPIC_AUTH_TOKEN=<" "$1"' _ "$SEC"
chequear "Claude Desktop: inferenceGatewayBaseUrl, esquema bearer y descubrimiento" bash -c 'grep -q "inferenceGatewayBaseUrl" "$1" && grep -q "bearer" "$1" && grep -qi "descubrimiento" "$1"' _ "$SEC"
chequear "Claude Desktop: inferenceProvider = gateway" bash -c 'grep -q "inferenceProvider" "$1"' _ "$SEC"
chequear "la llave es una por persona, la crea el panel y se entrega por canal seguro" bash -c 'grep -qi "llave" "$1" && grep -qi "por persona" "$1" && grep -qi "canal seguro\|en mano\|gestor de contraseñas" "$1"' _ "$SEC"
chequear "advierte que va por HTTP plano: solo dentro de la VPN/LAN" bash -c 'grep -qi "HTTP plano" "$1" && grep -qiE "VPN|LAN" "$1"' _ "$SEC"

echo "— vuelta atrás en dos niveles"
chequear "nivel 1: apagar (nombrado)" grep -Eq '^###+ .*Nivel 1.*apagar' "$SEC"
chequear "nivel 2: volver a las imágenes base (nombrado)" grep -Eq '^###+ .*Nivel 2.*volver a las imágenes base' "$SEC"
n1=$(grep -nE '^###+ .*Nivel 1' "$SEC" | head -n1 | cut -d: -f1); n2=$(grep -nE '^###+ .*Nivel 2' "$SEC" | head -n1 | cut -d: -f1)
sed -n "${n1:-1},$((${n2:-1} - 1))p" "$SEC" > "$SEC.n1"; sed -n "${n2:-1},\$p" "$SEC" > "$SEC.n2"; trap 'rm -f "$SEC" "$SEC.n1" "$SEC.n2"' EXIT
chequear "nivel 1: sacar ELEA_REDIRECT y correr ./install.sh" bash -c 'grep -q "ELEA_REDIRECT" "$1" && grep -q "./install.sh" "$1"' _ "$SEC.n1"
chequear "nivel 1: quita GATEWAY_PLUGINS y PLUGIN_PACKAGES" bash -c 'grep -q "GATEWAY_PLUGINS" "$1" && grep -q "PLUGIN_PACKAGES" "$1"' _ "$SEC.n1"
chequear "nivel 1: CONSERVA la imagen -ext del backend y ALEMBIC_EXTRA_VERSION_LOCATIONS, y dice por qué" \
  bash -c 'grep -q "ALEMBIC_EXTRA_VERSION_LOCATIONS" "$1" && grep -qi "conserva" "$1" && grep -qiE "imagen base.*(no arranca|fallar)|revisiones desconocidas" "$1"' _ "$SEC.n1"
chequear "nivel 2: SOLO restaurando el respaldo previo (pg_restore) y sacando las variables del instalador" \
  bash -c 'grep -q "pg_restore" "$1" && grep -qi "solo" "$1" && grep -q "COMPOSE_FILE" "$1" && grep -q "ELEA_REDIRECT_ACTIVADA" "$1"' _ "$SEC.n2"
chequear "nivel 2: dice que NO hay vuelta atrás sin el respaldo (el rollback con migraciones aplicadas no está soportado)" bash -c 'grep -qiE "sin (el )?respaldo" "$1" && grep -qiE "no está soportad" "$1"' _ "$SEC"
chequear "nivel 2: toma un respaldo del estado actual antes de restaurar" bash -c 'grep -q "respaldo.sh" "$1"' _ "$SEC.n2"

echo "— honestidad de la verificación"
chequear "dice qué se probó con contenedores reales (T102) y qué NO (nivel 2, conversación con el modelo)" bash -c 'grep -qiE "no se prob" "$1" && grep -qiE "contenedores reales" "$1" && grep -q "T102" "$1"' _ "$SEC"
chequear "dice que Claude Desktop contra Azure se probó en vivo el 7-oct-2026 y que Claude Code y el kit en una PC siguen sin probarse en vivo" bash -c 'grep -q "7-oct-2026" "$1" && grep -q "Claude Code" "$1" && grep -q "managed-settings.json" "$1" && grep -qiE "siguen sin probarse en vivo" "$1"' _ "$SEC"

echo "— los comandos del runbook existen y tienen sintaxis válida"
awk '/^```bash$/{b=1;n++;next} /^```$/{b=0;next} b{print > ("'"$SEC"'.bloque" n)}' "$SEC"
nb=$(ls "$SEC".bloque* 2>/dev/null | wc -l)
chequear "la sección trae bloques de comandos" [ "$nb" -ge 4 ]
for b in "$SEC".bloque*; do chequear "bash -n del bloque $(basename "$b" | sed 's/.*bloque/#/')" bash -n "$b"; done
for s in respaldo.sh install.sh activar-redirect.sh migrar-base-motor.sh; do
  chequear "el runbook menciona sólo scripts que existen: $s" bash -c '! grep -q "\./$1" "$2" || [ -x "$3/$1" ]' _ "$s" "$SEC" "$AQUI"
done
chequear "todo ./script.sh del runbook existe en el repo" bash -c 'for s in $(grep -ohE "\./[a-z-]+\.sh" "$1" | sort -u); do [ -x "$2/${s#./}" ] || { echo "falta $s"; exit 1; }; done' _ "$SEC" "$AQUI"
rm -f "$SEC".bloque*

echo "— secretos y white-label"
chequear "no trae llaves reales (sk-…, tokens largos): solo marcadores <…>" bash -c '! grep -Eq "sk-[A-Za-z0-9]{10,}|(KEY|TOKEN)=[A-Za-z0-9+/]{24,}" "$1"' _ "$SEC"
chequear "los marcadores de llave son <LLAVE…>" bash -c 'grep -q "<LLAVE" "$1"' _ "$SEC"
chequear "la sección no nombra internals prohibidos (la lista compartida de nombres prohibidos y el nombre de la extensión)" bash -c '! grep -Eiq "litellm|berriai|presidio|sentinel" "$1"' _ "$SEC"

echo "— el README lista las pruebas nuevas"
chequear "README: tests/test-redirect-optin.sh" grep -q 'bash tests/test-redirect-optin.sh' "$README"
chequear "README: tests/test-runbook-redirect.sh" grep -q 'bash tests/test-runbook-redirect.sh' "$README"

echo
if [ "$FALLOS" = 0 ]; then echo "TODO OK"; else echo "$FALLOS FALLO(S)"; exit 1; fi
