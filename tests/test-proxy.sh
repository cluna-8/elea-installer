#!/usr/bin/env bash
# Pruebas del proxy delante del backend (capa 3 de la defensa de /api/v1/internal/*), sin Docker:
#   · cableado de docker-compose.yml e install.sh (se lee el YAML, no se levanta nada)
#   · reglas del proxy (proxy/Caddyfile): si hay un binario `caddy` (PATH o $ELEA_CADDY_BIN) se corre
#     de verdad contra un backend de mentira en localhost; si no, esa parte se salta (no falla).
# Correr:  bash tests/test-proxy.sh
set -uo pipefail
AQUI="$(cd "$(dirname "$0")/.." && pwd)"
FALLOS=0
ok()    { echo "  ok   $1"; }
falla() { echo "  FALLA $1"; FALLOS=$((FALLOS + 1)); }
salta() { echo "  salta $1"; }
chequear() { local desc="$1"; shift; if "$@"; then ok "$desc"; else falla "$desc"; fi; }

COMPOSE="$AQUI/docker-compose.yml"
CADDYFILE="$AQUI/proxy/Caddyfile"
# Lee una ruta del YAML (python+PyYAML) y la imprime como JSON: servicios.<svc>.<clave>…
yml() { python3 - "$COMPOSE" "$@" <<'PY'
import json, sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for k in sys.argv[2:]:
    d = d.get(k) if isinstance(d, dict) else None
print(json.dumps(d))
PY
}
chequear "hay python3 con PyYAML" python3 -c 'import yaml'

echo "— sintaxis"
chequear "bash -n tests/test-proxy.sh" bash -n "$AQUI/tests/test-proxy.sh"

echo "— compose: el proxy publica el puerto de hoy y el backend deja de publicarlo"
chequear "existe el servicio api-proxy" bash -c '[ "$1" != null ]' _ "$(yml services api-proxy)"
chequear "el proxy publica 8091 (el mismo puerto que usan las PC)" bash -c '[ "$1" = "[\"8091:8091\"]" ]' _ "$(yml services api-proxy ports)"
chequear "el backend NO tiene ports:" bash -c '[ "$1" = null ]' _ "$(yml services backend ports)"
chequear "el backend NO publica nada con 'ports' ni en el texto" bash -c '! sed -n "/^  backend:/,/^  api-proxy:/p" "$1" | grep -Eq "^\s+ports:|8091:8000"' _ "$COMPOSE"
chequear "el proxy va por digest (caddy@sha256:…)" bash -c 'echo "$1" | grep -Eq "caddy(:[A-Za-z0-9.-]+)?@sha256:[0-9a-f]{64}"' _ "$(yml services api-proxy image)"
chequear "el proxy monta su Caddyfile de solo lectura" bash -c 'echo "$1" | grep -q "./proxy/Caddyfile:/etc/caddy/Caddyfile:ro"' _ "$(yml services api-proxy volumes)"
chequear "el proxy espera a un backend sano" bash -c 'echo "$1" | grep -q "\"condition\": \"service_healthy\""' _ "$(yml services api-proxy depends_on backend)"
chequear "el proxy está en elea-net (ve al backend)" bash -c 'echo "$1" | grep -q elea-net' _ "$(yml services api-proxy networks)"
chequear "el proxy no está en las redes internas de los motores" bash -c '! echo "$1" | grep -Eq "tabular-net|presentations-net"' _ "$(yml services api-proxy networks)"
chequear "el proxy tiene healthcheck" bash -c '[ "$1" != null ]' _ "$(yml services api-proxy healthcheck)"
chequear "el proxy se reinicia solo" bash -c '[ "$1" = "\"unless-stopped\"" ]' _ "$(yml services api-proxy restart)"
chequear "el backend recibe INTERNAL_ALLOWED_CIDRS=auto" bash -c 'echo "$1" | grep -q "INTERNAL_ALLOWED_CIDRS=auto"' _ "$(yml services backend environment)"
chequear "el motor sigue hablando con backend:8000 (red interna, sin pasar por el proxy)" bash -c 'echo "$1" | grep -q "SENTINEL_IDENTITY_URL=\${ENGINE_IDENTITY_URL-http://backend:8000/api/v1/internal/identity}"' _ "$(yml services engine environment)"
chequear "el Hub sigue hablando con backend:8000" bash -c 'echo "$1" | grep -q "ELEA_BACKEND_URL=http://backend:8000/api/v1"' _ "$(yml services client environment)"
chequear "el panel sigue en 8090" bash -c '[ "$1" = "[\"8090:5173\"]" ]' _ "$(yml services frontend ports)"
chequear "el Hub sigue en 8095 y 8097" bash -c '[ "$1" = "[\"8095:8095\", \"8097:8097\"]" ]' _ "$(yml services client ports)"
chequear "nadie más publica el 8000 del backend" bash -c '! grep -Eq "\"[0-9]+:8000\"" "$1"' _ "$COMPOSE"
chequear "los motores internos siguen sin ports:" bash -c '[ "$(python3 - "$1" <<PY
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))["services"]
print(sorted(s for s in d if "ports" in d[s]))
PY
)" = "['"'"'api-proxy'"'"', '"'"'client'"'"', '"'"'frontend'"'"']" ]' _ "$COMPOSE"

echo "— install.sh levanta el proxy junto con el backend y espera por él"
chequear "install.sh levanta backend, api-proxy y panel juntos (el backend suelta el 8091 antes de que el proxy lo tome)" \
  grep -Eq 'docker compose up -d backend api-proxy frontend' "$AQUI/install.sh"
chequear "install.sh baja la imagen del proxy" grep -Eq 'docker compose pull .*api-proxy' "$AQUI/install.sh"
n_up=$(grep -n 'docker compose up -d backend api-proxy frontend' "$AQUI/install.sh" | head -n1 | cut -d: -f1)
n_wait=$(grep -n 'curl -sf -o /dev/null http://localhost:8091/health' "$AQUI/install.sh" | head -n1 | cut -d: -f1)
chequear "espera el /health por el puerto publicado DESPUÉS de levantar el proxy" bash -c '[ -n "$1" ] && [ -n "$2" ] && [ "$1" -lt "$2" ]' _ "$n_up" "$n_wait"
chequear "install.sh avisa si el 8091 ya lo usa otro proceso" grep -q 'puerto 8091' "$AQUI/install.sh"

echo "— proxy/Caddyfile (texto)"
chequear "existe proxy/Caddyfile" [ -s "$CADDYFILE" ]
chequear "responde 404 a /internal" grep -Eq 'respond .*404' "$CADDYFILE"
chequear "el resto va al backend por la red interna" grep -q 'reverse_proxy backend:8000' "$CADDYFILE"
chequear "sin API de administración de Caddy" grep -Eq '^\s*admin off' "$CADDYFILE"
chequear "sin TLS automático (HTTP plano de LAN, como hoy)" grep -Eq '^\s*auto_https off' "$CADDYFILE"
chequear "escucha en 8091" grep -Eq '^:8091 \{' "$CADDYFILE"
chequear "la regla de internal va ANTES del reverse_proxy" bash -c '[ "$(grep -n "respond.*404" "$1" | head -n1 | cut -d: -f1)" -lt "$(grep -n "reverse_proxy" "$1" | head -n1 | cut -d: -f1)" ]' _ "$CADDYFILE"
chequear "no nombra componentes internos (white-label)" bash -c '! grep -Eiq "litellm|presenton|sentinel|guardian" "$1"' _ "$CADDYFILE"

echo "— proxy/Caddyfile (corriendo Caddy de verdad contra un backend de mentira)"
CADDY_BIN="${ELEA_CADDY_BIN:-$(command -v caddy || true)}"
if [ -z "$CADDY_BIN" ] || [ ! -x "$CADDY_BIN" ]; then
  salta "no hay binario caddy (PATH o ELEA_CADDY_BIN): no se corre el proxy real; correr con ELEA_CADDY_BIN=/ruta/a/caddy para ensayarlo"
else
  T=$(mktemp -d)
  trap 'kill "${PID_CADDY:-}" "${PID_BACK:-}" 2>/dev/null; rm -rf "$T"' EXIT
  libre() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])'; }
  P_BACK=$(libre); P_PROXY=$(libre)
  # Backend de mentira: anota cada pedido (método + ruta cruda) y contesta 200; /sse manda dos trozos
  # separados por 1,5 s para comprobar que el proxy no los junta.
  cat > "$T/backend.py" <<'PY'
import sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
LOG = sys.argv[2]
class H(BaseHTTPRequestHandler):
    def _go(self):
        n = int(self.headers.get("content-length") or 0)
        if n: self.rfile.read(n)
        with open(LOG, "a") as f: f.write(f"{self.command} {self.path}\n")
        if self.path.startswith("/sse"):
            self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
            self.wfile.write(b"data: uno\n\n"); self.wfile.flush(); time.sleep(1.5)
            self.wfile.write(b"data: dos\n\n"); self.wfile.flush(); return
        body = b"BACKEND"
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = _go
    def log_message(self, *a): pass
ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
  python3 "$T/backend.py" "$P_BACK" "$T/back.log" & PID_BACK=$!
  # El Caddyfile del repo, tal cual, salvo el destino y el puerto (que en el contenedor son fijos).
  sed -e "s|backend:8000|127.0.0.1:${P_BACK}|g" -e "s|^:8091 {|:${P_PROXY} {|" "$CADDYFILE" > "$T/Caddyfile"
  chequear "caddy validate acepta el Caddyfile" bash -c '"$1" validate --config "$2" --adapter caddyfile >/dev/null 2>&1' _ "$CADDY_BIN" "$T/Caddyfile"
  "$CADDY_BIN" run --config "$T/Caddyfile" --adapter caddyfile >"$T/caddy.log" 2>&1 & PID_CADDY=$!
  for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:${P_PROXY}/" && break; sleep 0.2; done

  http() { curl -s --path-as-is -o /dev/null -w '%{http_code}' --max-time 10 "$@"; }
  U="http://127.0.0.1:${P_PROXY}"
  pasa()  { [ "$(http "${@:2}" "$U$1")" = 200 ]; }
  nopasa() { [ "$(http "${@:2}" "$U$1")" = 404 ]; }

  echo "    deja pasar lo que usan las PC y el instalador"
  chequear "GET /health" pasa /health
  chequear "GET /docs" pasa /docs
  chequear "GET /openapi.json" pasa /openapi.json
  chequear "POST /api/v1/gw/chat/completions (Claude Desktop / Claude Code)" pasa /api/v1/gw/chat/completions -X POST -d '{}'
  chequear "GET /api/v1/gw/models" pasa /api/v1/gw/models
  chequear "POST /api/v1/users/login (panel)" pasa /api/v1/users/login -X POST -d '{}'
  chequear "GET /api/v1/users?include_service=true (instalador)" pasa '/api/v1/users?include_service=true'
  chequear "DELETE /api/v1/keys/abc (instalador)" pasa /api/v1/keys/abc -X DELETE
  chequear "GET /api/v1/internals-x pasa (no es el segmento 'internal')" pasa /api/v1/internals-x
  chequear "GET /api/v1/gw/internal-x pasa (no es el segmento 'internal')" pasa /api/v1/gw/internal-x

  echo "    responde 404 a /api/v1/internal/* y el backend NO ve esos pedidos"
  : > "$T/back.log"
  chequear "GET /api/v1/internal/identity" nopasa /api/v1/internal/identity
  chequear "…con la cabecera del secreto (la que usa el motor)" nopasa /api/v1/internal/identity -H 'X-Sentinel-Internal: lo-que-sea'
  chequear "POST /api/v1/internal/audit" nopasa /api/v1/internal/audit -X POST -d '{}'
  chequear "GET /api/v1/internal/audit/probe" nopasa /api/v1/internal/audit/probe
  chequear "GET /api/v1/internal/verify-user" nopasa /api/v1/internal/verify-user
  chequear "GET /api/v1/internal/model-credential (extensión)" nopasa /api/v1/internal/model-credential
  chequear "GET /api/v1/internal (sin barra final)" nopasa /api/v1/internal
  chequear "GET /api/v1/internal/ (barra final)" nopasa /api/v1/internal/
  chequear "mayúsculas /API/V1/INTERNAL/identity" nopasa /API/V1/INTERNAL/identity
  chequear "mayúsculas mezcladas /api/v1/Internal/identity" nopasa /api/v1/Internal/identity
  chequear "barras repetidas //api/v1/internal/identity" nopasa //api/v1/internal/identity
  chequear "barras repetidas /api//v1///internal//identity" nopasa /api//v1///internal//identity
  chequear "letra codificada /api/v1/%69nternal/identity" nopasa /api/v1/%69nternal/identity
  chequear "barra codificada /api/v1%2Finternal/identity" nopasa '/api/v1%2Finternal/identity'
  chequear "punto-punto /api/v1/x/../internal/identity" nopasa /api/v1/x/../internal/identity
  chequear "punto-punto codificado /api/v1/x/%2e%2e/internal/identity" nopasa /api/v1/x/%2e%2e/internal/identity
  chequear "con query /api/v1/internal/identity?key_hash=x" nopasa '/api/v1/internal/identity?key_hash=x'
  chequear "con método HEAD" bash -c '[ "$(curl -s -I -o /dev/null -w "%{http_code}" --max-time 10 "$1")" = 404 ]' _ "$U/api/v1/internal/identity"
  chequear "con método PUT" nopasa /api/v1/internal/audit -X PUT -d '{}'
  chequear "el backend de mentira no recibió ninguno de esos pedidos" bash -c '! grep -qi "internal" "$1"' _ "$T/back.log"
  chequear "el 404 no revela nada del backend (cuerpo vacío)" bash -c '[ -z "$(curl -s --max-time 10 "$1")" ]' _ "$U/api/v1/internal/identity"

  echo "    streaming (el gateway responde con SSE)"
  t0=$(date +%s.%N)
  primero=$(curl -sN --max-time 10 "$U/sse" | while IFS= read -r l; do [ -n "$l" ] && { date +%s.%N; break; }; done)
  chequear "el primer trozo llega antes de que termine la respuesta (no se junta)" \
    python3 -c 'import sys; sys.exit(0 if float(sys.argv[2]) - float(sys.argv[1]) < 1.0 else 1)' "$t0" "${primero:-9999999999}"
  kill "$PID_CADDY" "$PID_BACK" 2>/dev/null
fi

echo
if [ "$FALLOS" = 0 ]; then echo "TODO OK"; else echo "$FALLOS FALLO(S)"; exit 1; fi
