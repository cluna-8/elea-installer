#!/usr/bin/env bash
# Prueba, sin Docker, de dos pasos de ./install.sh que rompían la REINSTALACIÓN (fake-docker):
#   1. Conectar AnythingLLM al motor: el contenedor recién levantado todavía no escucha (curl sale con 7) y, con la
#      API key ya en .env, no había espera → la instalación moría. Ahora siempre espera a que responda.
#   2. El proxy no tomaba un Caddyfile nuevo: va montado de solo lectura como ARCHIVO (se ata al inodo) y Caddy corre
#      con `admin off` (no hay `caddy reload`), así que se recrea solo ese servicio, solo si lo que ve difiere.
# Se corren SOLO esos bloques de install.sh (se extraen con awk), con el docker de mentira de tests/fake-docker.
# Correr:  bash tests/test-reinstalacion.sh
set -uo pipefail
AQUI="$(cd "$(dirname "$0")/.." && pwd)"
FALLOS=0
ok()   { echo "  ok   $1"; }
falla() { echo "  FALLA $1"; FALLOS=$((FALLOS + 1)); }
chequear() { local desc="$1"; shift; if "$@"; then ok "$desc"; else falla "$desc"; fi; }
chequear_no() { local desc="$1"; shift; if "$@"; then falla "$desc"; else ok "$desc"; fi; }

PATH_ORIG="$PATH"
nuevo_entorno() {
  T=$(mktemp -d); mkdir -p "$T/proxy"
  cp "$AQUI/proxy/Caddyfile" "$AQUI/proxy/arranque.sh" "$T/proxy/"
  export FAKE_LOG="$T/docker.log"; : > "$FAKE_LOG"
  export FAKE_PROXY_MONTADO="$T/montado"; mkdir -p "$FAKE_PROXY_MONTADO"
  cp "$AQUI/proxy/Caddyfile" "$AQUI/proxy/arranque.sh" "$FAKE_PROXY_MONTADO/"
  unset FAKE_ALLM_APAGADO FAKE_ALLM_ARRANCANDO FAKE_ALLM_RESP FAKE_PROXY_SIN_CONTENEDOR FAKE_CLIENTS
  export PATH="$AQUI/tests/fake-docker:$PATH_ORIG" ELEA_ESPERA_INTENTOS=5 ELEA_ESPERA_PAUSA=0
  export ANYTHINGLLM_API_KEY=k ANYTHINGLLM_PROVIDER_VIRTUAL_KEY=sk-prov
}
cabecera() { printf 'set -euo pipefail\nlog() { echo "▶ $1"; }\ndie() { echo "✗ $1" >&2; exit 1; }\nallm_curl() { docker exec elea-anythingllm curl -s "$@"; }\n'; }
# Bloque de install.sh entre dos marcas (`# >>> nombre` … `# <<< nombre`).
bloque() { awk -v n="$1" '$0 == "# >>> " n {p=1; next} $0 == "# <<< " n {p=0} p' "$AQUI/install.sh"; }

# ── 1. AnythingLLM ──────────────────────────────────────────────────────────────────────────────
echo "— install.sh: espera a AnythingLLM y lo conecta al motor"
chequear "el bloque de espera de AnythingLLM está en install.sh" bash -c '[ "$(echo "$1" | wc -l)" -gt 3 ]' _ "$(bloque anythingllm-espera)"
chequear "el bloque de conexión de AnythingLLM está en install.sh" bash -c '[ "$(echo "$1" | wc -l)" -gt 3 ]' _ "$(bloque anythingllm-conexion)"
allm() { # entorno extra …  → espera + conexión; deja $out y $rc
  nuevo_entorno
  { cabecera; bloque anythingllm-espera; bloque anythingllm-conexion; echo "echo SIGUE"; } > "$T/allm.sh"
  out=$(env "$@" bash "$T/allm.sh" </dev/null 2>&1); rc=$?
}
allm FAKE_X=1
chequear "AnythingLLM listo: conecta y sigue" bash -c '[ "$2" = 0 ] && grep -q SIGUE <<<"$1"' _ "$out" "$rc"
chequear "AnythingLLM listo: manda la configuración del motor" grep -q "update-env" "${FAKE_LOG}.allm"
chequear "AnythingLLM listo: espera con el ping antes de configurar" bash -c 'grep -n "" "$1" | grep -E "api/ping|update-env" | head -n1 | grep -q ping' _ "${FAKE_LOG}.allm"
# El caso del servidor: la API key ya está en .env (reinstalación) y AnythingLLM recién arrancó (rechaza 3 veces).
allm FAKE_ALLM_ARRANCANDO=3
chequear "recién arrancado (rechaza con 7 las primeras veces): espera y conecta" bash -c '[ "$2" = 0 ] && grep -q SIGUE <<<"$1"' _ "$out" "$rc"
chequear "recién arrancado: no configura hasta que responde el ping" bash -c '[ "$(grep -c "api/ping" "$1")" -ge 4 ] && [ "$(grep -c update-env "$1")" = 1 ]' _ "${FAKE_LOG}.allm"
chequear_no "recién arrancado: no muere con el código 7" grep -q "✗" <<<"$out"
allm FAKE_ALLM_APAGADO=1
chequear "no responde nunca: termina con error (no en silencio)" [ "$rc" != 0 ]
chequear "no responde nunca: dice qué mirar" grep -q "elea-logs.sh anythingllm" <<<"$out"
chequear_no "no responde nunca: no llega a configurar" grep -q update-env "${FAKE_LOG}.allm"
allm FAKE_ALLM_RESP='{"error":true}'
chequear "AnythingLLM rechaza la configuración: muere con el mensaje de siempre" bash -c '[ "$2" != 0 ] && grep -q "no aceptó la configuración" <<<"$1"' _ "$out" "$rc"

# ── 2. Proxy ────────────────────────────────────────────────────────────────────────────────────
echo "— install.sh: el proxy toma el Caddyfile nuevo"
chequear "el bloque del proxy está en install.sh" bash -c '[ "$(echo "$1" | wc -l)" -gt 3 ]' _ "$(bloque proxy-config)"
proxy() { # entorno extra …  → corre el bloque desde la raíz de la prueba; deja $out y $rc
  { cabecera; bloque proxy-config; echo "echo SIGUE"; } > "$T/proxy.sh"
  out=$(cd "$T" && env "$@" bash "$T/proxy.sh" </dev/null 2>&1); rc=$?
}
recreaciones() { grep -c "compose up -d --force-recreate --no-deps api-proxy" "$FAKE_LOG" || true; }
nuevo_entorno; proxy FAKE_X=1
chequear "Caddyfile igual al del contenedor: sigue" bash -c '[ "$2" = 0 ] && grep -q SIGUE <<<"$1"' _ "$out" "$rc"
chequear "Caddyfile igual: NO recrea el proxy (sin corte)" bash -c '[ "$(grep -c "force-recreate" "$1" || true)" = 0 ]' _ "$FAKE_LOG"
nuevo_entorno; echo "# regla nueva" >> "$T/proxy/Caddyfile"; proxy FAKE_X=1
chequear "Caddyfile nuevo: sigue" bash -c '[ "$2" = 0 ] && grep -q SIGUE <<<"$1"' _ "$out" "$rc"
chequear "Caddyfile nuevo: recrea SOLO el proxy, sin tocar sus dependencias" bash -c '[ "$(grep -c "force-recreate --no-deps api-proxy" "$1")" = 1 ] && [ "$(grep -c "force-recreate" "$1")" = 1 ]' _ "$FAKE_LOG"
chequear "Caddyfile nuevo: avisa" grep -qi "caddyfile" <<<"$out"
chequear_no "Caddyfile nuevo: no usa 'caddy reload' (Caddy corre con admin off)" grep -q "caddy reload" "$FAKE_LOG"
nuevo_entorno; echo "# arranque nuevo" >> "$T/proxy/arranque.sh"; proxy FAKE_X=1
chequear "arranque.sh nuevo: también recrea el proxy" bash -c '[ "$(grep -c "force-recreate --no-deps api-proxy" "$1")" = 1 ]' _ "$FAKE_LOG"
nuevo_entorno; echo "# regla nueva" >> "$T/proxy/Caddyfile"; proxy FAKE_PROXY_SIN_CONTENEDOR=1
chequear "proxy que no existe todavía (primera instalación): no fuerza nada" bash -c '[ "$2" = 0 ] && grep -q SIGUE <<<"$1" && ! grep -q force-recreate "$3"' _ "$out" "$rc" "$FAKE_LOG"
nuevo_entorno; echo "# regla nueva" >> "$T/proxy/Caddyfile"; export FAKE_CLIENTS=elea-api-proxy; proxy FAKE_PROXY_SIN_CONTENEDOR=1
chequear "proxy detenido (existe pero no responde): lo recrea para que tome el archivo" bash -c '[ "$(grep -c "force-recreate --no-deps api-proxy" "$1")" = 1 ]' _ "$FAKE_LOG"

# ── 3. Cableado ─────────────────────────────────────────────────────────────────────────────────
echo "— install.sh: cableado"
n_up=$(grep -n '^docker compose up -d backend api-proxy frontend' "$AQUI/install.sh" | head -n1 | cut -d: -f1)
n_prx=$(grep -n '^# >>> proxy-config' "$AQUI/install.sh" | head -n1 | cut -d: -f1)
n_hl=$(grep -n 'http://localhost:8091/health' "$AQUI/install.sh" | head -n1 | cut -d: -f1)
chequear "el proxy se revisa DESPUÉS de levantar el Guardian y ANTES de esperar su salud" bash -c '[ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ] && [ "$1" -lt "$2" ] && [ "$2" -lt "$3" ]' _ "$n_up" "$n_prx" "$n_hl"
n_esp=$(grep -n '^# >>> anythingllm-espera' "$AQUI/install.sh" | head -n1 | cut -d: -f1)
n_key=$(grep -n 'p.api_keys.create' "$AQUI/install.sh" | head -n1 | cut -d: -f1)
n_con=$(grep -n '^# >>> anythingllm-conexion' "$AQUI/install.sh" | head -n1 | cut -d: -f1)
chequear "la espera a AnythingLLM va antes de generar la API key y de conectarlo" bash -c '[ -n "$1" ] && [ "$1" -lt "$2" ] && [ "$2" -lt "$3" ]' _ "$n_esp" "$n_key" "$n_con"
chequear_no "la espera no depende de que falte la API key (sin 'if' dentro del bloque)" bash -c 'bloque() { awk -v n="$1" '"'"'$0 == "# >>> " n {p=1; next} $0 == "# <<< " n {p=0} p'"'"' "$2"; }; bloque anythingllm-espera "$1" | grep -q "^if "' _ "$AQUI/install.sh"

echo
if [ "$FALLOS" = 0 ]; then echo "TODO OK"; else echo "$FALLOS FALLO(S)"; exit 1; fi
