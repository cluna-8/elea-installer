#!/usr/bin/env bash
# Pruebas del HTTPS del proxy (puerto 8443, «HTTPS para Claude Desktop»), sin Docker:
#   · proxy/https.lib.sh: nombres del certificado (IP + hostname), puerto, certificado de la empresa y
#     REDIRECT_GATEWAY_URL por defecto (funciones puras, con el servidor simulado)
#   · cableado en docker-compose.yml, install.sh, activar-redirect.sh y .env.example (se lee, no se levanta)
#   · ./exportar-ca.sh con un Docker de mentira (tests/fake-docker): solo la raíz pública
#   · proxy/arranque.sh + proxy/Caddyfile con un binario `caddy` de verdad (PATH o $ELEA_CADDY_BIN): HTTPS con la
#     CA interna (la raíz valida el certificado, también sin SNI y por otra IP local) y con un certificado de la
#     empresa; /api/v1/internal/* da 404 por el HTTPS igual que por el 8091. Sin `caddy`, esa parte se salta.
# Correr:  bash tests/test-https.sh
set -uo pipefail
AQUI="$(cd "$(dirname "$0")/.." && pwd)"
FALLOS=0
ok()    { echo "  ok   $1"; }
falla() { echo "  FALLA $1"; FALLOS=$((FALLOS + 1)); }
salta() { echo "  salta $1"; }
chequear() { local desc="$1"; shift; if "$@"; then ok "$desc"; else falla "$desc"; fi; }

LIB="$AQUI/proxy/https.lib.sh"
COMPOSE="$AQUI/docker-compose.yml"
CADDYFILE="$AQUI/proxy/Caddyfile"
ARRANQUE="$AQUI/proxy/arranque.sh"
T0=$(mktemp -d); trap 'rm -rf "$T0"' EXIT

echo "— sintaxis y permisos"
chequear "bash -n tests/test-https.sh" bash -n "$AQUI/tests/test-https.sh"
for f in proxy/https.lib.sh exportar-ca.sh install.sh activar-redirect.sh; do
  chequear "bash -n $f" bash -n "$AQUI/$f"
done
chequear "sh -n proxy/arranque.sh (corre en el contenedor, con sh de busybox)" sh -n "$ARRANQUE"
chequear "exportar-ca.sh es ejecutable" [ -x "$AQUI/exportar-ca.sh" ]

# ───────────────────────────────────────────────────────────────────────────────────────────────
echo "— proxy/https.lib.sh: nombres, puerto, certificado y URL (servidor simulado)"
# Carpeta de trabajo descartable con su .env; die/set_env como los de install.sh.
nuevo() {
  R=$(mktemp -d -p "$T0"); cd "$R" || exit 1
  printf 'POSTGRES_PASSWORD=pw\n' > .env
  die() { echo "ERROR: $*" >&2; return 1; }
  set_env() { if grep -q "^$1=" .env; then sed -i "s|^$1=.*|$1=$2|" .env; else echo "$1=$2" >> .env; fi; }
  # shellcheck source=/dev/null
  source "$LIB"
  https_ip_servidor() { echo "${SIM_IP-172.16.0.120}"; }
  https_hostname_servidor() { echo "${SIM_HOST-elea-srv}"; }
  unset PROXY_TLS_NAMES PROXY_HTTPS_PORT PROXY_TLS_CERT PROXY_TLS_KEY REDIRECT_GATEWAY_URL SIM_IP SIM_HOST
}
# Como install.sh: .env leído con `set -a; source .env` y después https_preparar.
preparar() { set -a; source ./.env; set +a; https_preparar; }
igual() { [ "$1" = "$2" ]; }
no() { ! "$@"; }
valor() { grep "^$1=" "$R/.env" | head -n1 | cut -d= -f2-; }

nuevo
chequear "existe proxy/https.lib.sh" [ -s "$LIB" ]
chequear "normaliza comas, espacios, vacíos y repetidos (orden de primera aparición)" \
  igual "172.16.0.120,elea-srv,a.b.c" "$(https_normalizar_nombres " 172.16.0.120 ,elea-srv,, elea-srv ,a.b.c")"
chequear "acepta IP y DNS separados por coma" https_nombres_validos "172.16.0.120,elea-srv,elea.empresa.com.ar"
chequear "acepta un comodín DNS (certificado de la empresa)" https_nombres_validos "*.empresa.com.ar"
for malo in "a b" 'x;y' 'a/b' 'a$b' "a'b" 'a"b' '-a' 'a..b' 'http://x' 'x:8443' ''; do
  chequear "rechaza el nombre «$malo»" no https_nombres_validos "$malo"
done
chequear "nombres por defecto: la IP del servidor y su hostname" igual "172.16.0.120,elea-srv" "$(https_nombres_defecto)"
chequear "…sin repetir si el hostname es la IP" igual "172.16.0.120" "$(SIM_HOST=172.16.0.120 https_nombres_defecto)"
chequear "…con solo hostname si no hay IP" igual "elea-srv" "$(SIM_IP= https_nombres_defecto)"
chequear "…vacío si no se detecta nada" igual "" "$(SIM_IP= SIM_HOST= https_nombres_defecto)"
chequear "una IP de Docker (172.17/18…) no se elige sola si hay otra: la detección usa la ruta por defecto, no hostname -I" \
  bash -c 'grep -q "route get" "$1"' _ "$LIB"
chequear "URL: primer nombre + puerto + /api/v1/gw" igual "https://172.16.0.120:8443/api/v1/gw" "$(https_url_pasarela "172.16.0.120,elea-srv" 8443)"
chequear "URL con otro puerto" igual "https://elea.empresa.com.ar:9443/api/v1/gw" "$(https_url_pasarela "elea.empresa.com.ar" 9443)"

echo "    https_preparar: lo que escribe en .env"
nuevo; preparar >/dev/null 2>&1; rc=$?
chequear "sin nada en .env: termina bien" [ "$rc" = 0 ]
chequear "escribe PROXY_TLS_NAMES=IP,hostname" bash -c '[ "$1" = "172.16.0.120,elea-srv" ]' _ "$(valor PROXY_TLS_NAMES)"
chequear "…y lo exporta al proceso (compose le da prioridad al entorno)" bash -c '[ "${PROXY_TLS_NAMES-}" = "172.16.0.120,elea-srv" ]'
chequear "escribe PROXY_HTTPS_PORT=8443" bash -c '[ "$1" = 8443 ]' _ "$(valor PROXY_HTTPS_PORT)"
chequear "NO escribe REDIRECT_GATEWAY_URL (eso es de https_fijar_url_pasarela)" bash -c '[ -z "$1" ]' _ "$(valor REDIRECT_GATEWAY_URL)"
nuevo; printf 'PROXY_TLS_NAMES="elea.empresa.com.ar, 10.0.0.5 ,10.0.0.5"\nPROXY_HTTPS_PORT=9443\n' >> .env; preparar >/dev/null 2>&1
chequear "respeta y normaliza lo que ya hay en .env" bash -c '[ "$1" = "elea.empresa.com.ar,10.0.0.5" ] && [ "$2" = 9443 ]' _ "$(valor PROXY_TLS_NAMES)" "$(valor PROXY_HTTPS_PORT)"
nuevo; printf 'PROXY_TLS_NAMES=\n' >> .env; preparar >/dev/null 2>&1
chequear "un PROXY_TLS_NAMES vacío en .env se completa (sin duplicar la línea)" bash -c '[ "$1" = "172.16.0.120,elea-srv" ] && [ "$(grep -c "^PROXY_TLS_NAMES=" .env)" = 1 ]' _ "$(valor PROXY_TLS_NAMES)"
nuevo; SIM_IP=; SIM_HOST=; out=$(preparar 2>&1); rc=$?
chequear "sin nombres detectables y sin .env: falla pidiendo PROXY_TLS_NAMES" bash -c '[ "$1" != 0 ] && grep -q PROXY_TLS_NAMES <<<"$2"' _ "$rc" "$out"
nuevo; printf 'PROXY_TLS_NAMES="a b;c"\n' >> .env; out=$(preparar 2>&1); rc=$?
chequear "un nombre inválido en .env falla (no llega a Caddy)" bash -c '[ "$1" != 0 ]' _ "$rc"
for p in 0 70000 abc 8091 ""; do
  nuevo; printf 'PROXY_HTTPS_PORT=%s\n' "$p" >> .env; out=$(preparar 2>&1); rc=$?
  if [ -z "$p" ]; then chequear "PROXY_HTTPS_PORT vacío → 8443" bash -c '[ "$1" = 0 ] && [ "$2" = 8443 ]' _ "$rc" "$(valor PROXY_HTTPS_PORT)"
  else chequear "PROXY_HTTPS_PORT=$p se rechaza" bash -c '[ "$1" != 0 ]' _ "$rc"; fi
done

echo "    https_preparar: certificado de la empresa (PROXY_TLS_CERT / PROXY_TLS_KEY)"
FUERA=$(mktemp -d -p "$T0"); openssl req -x509 -newkey rsa:2048 -nodes -keyout "$FUERA/k.pem" -out "$FUERA/c.pem" -days 2 -subj /CN=elea.test -addext subjectAltName=DNS:elea.test >/dev/null 2>&1
chequear "(se generó un certificado de prueba fuera del repo)" [ -s "$FUERA/c.pem" ]
nuevo; printf 'PROXY_TLS_NAMES=elea.test\nPROXY_TLS_CERT=%s\nPROXY_TLS_KEY=%s\n' "$FUERA/c.pem" "$FUERA/k.pem" >> .env; out=$(preparar 2>&1); rc=$?
chequear "cert y llave existentes, absolutos y fuera del repo: pasa" [ "$rc" = 0 ]
nuevo; printf 'PROXY_TLS_NAMES=elea.test\nPROXY_TLS_CERT=%s\n' "$FUERA/c.pem" >> .env; out=$(preparar 2>&1); rc=$?
chequear "solo el certificado, sin llave: falla" bash -c '[ "$1" != 0 ] && grep -q PROXY_TLS_KEY <<<"$2"' _ "$rc" "$out"
nuevo; printf 'PROXY_TLS_NAMES=elea.test\nPROXY_TLS_KEY=%s\n' "$FUERA/k.pem" >> .env; out=$(preparar 2>&1); rc=$?
chequear "solo la llave, sin certificado: falla" bash -c '[ "$1" != 0 ] && grep -q PROXY_TLS_CERT <<<"$2"' _ "$rc" "$out"
nuevo; printf 'PROXY_TLS_NAMES=elea.test\nPROXY_TLS_CERT=%s\nPROXY_TLS_KEY=%s\n' "$FUERA/no-existe.pem" "$FUERA/k.pem" >> .env; out=$(preparar 2>&1); rc=$?
chequear "certificado que no existe: falla nombrándolo" bash -c '[ "$1" != 0 ] && grep -q no-existe <<<"$2"' _ "$rc" "$out"
nuevo; printf 'PROXY_TLS_NAMES=elea.test\nPROXY_TLS_CERT=c.pem\nPROXY_TLS_KEY=k.pem\n' >> .env; cp "$FUERA/c.pem" "$FUERA/k.pem" .; out=$(preparar 2>&1); rc=$?
chequear "rutas relativas: fallan (compose las resolvería contra otra carpeta)" bash -c '[ "$1" != 0 ] && grep -qi absolut <<<"$2"' _ "$rc" "$out"
nuevo; cp "$FUERA/c.pem" "$FUERA/k.pem" .; printf 'PROXY_TLS_NAMES=elea.test\nPROXY_TLS_CERT=%s/c.pem\nPROXY_TLS_KEY=%s/k.pem\n' "$R" "$R" >> .env; out=$(preparar 2>&1); rc=$?
chequear "una llave privada DENTRO del repo se rechaza (se versionaría)" bash -c '[ "$1" != 0 ] && grep -qi repo <<<"$2"' _ "$rc" "$out"
nuevo; printf 'PROXY_TLS_NAMES=elea.test\nPROXY_TLS_CERT=%s\nPROXY_TLS_KEY=%s\n' "$FUERA/k.pem" "$FUERA/k.pem" >> .env; out=$(preparar 2>&1); rc=$?
chequear "un «certificado» que no es un certificado (es la llave): falla" bash -c '[ "$1" != 0 ]' _ "$rc"

echo "    https_fijar_url_pasarela: REDIRECT_GATEWAY_URL"
nuevo; PROXY_TLS_NAMES=172.16.0.120,elea-srv; PROXY_HTTPS_PORT=8443; https_fijar_url_pasarela >/dev/null 2>&1
chequear "vacío → https://<primer nombre>:8443/api/v1/gw en .env" bash -c '[ "$1" = "https://172.16.0.120:8443/api/v1/gw" ]' _ "$(valor REDIRECT_GATEWAY_URL)"
chequear "…y exportado" bash -c '[ "${REDIRECT_GATEWAY_URL-}" = "https://172.16.0.120:8443/api/v1/gw" ]'
nuevo; PROXY_TLS_NAMES=172.16.0.120; PROXY_HTTPS_PORT=8443; printf 'REDIRECT_GATEWAY_URL=http://172.16.0.120:8091/api/v1/gw\n' >> .env; REDIRECT_GATEWAY_URL=http://172.16.0.120:8091/api/v1/gw; https_fijar_url_pasarela >/dev/null 2>&1
chequear "el .env puede pisarlo: un valor existente no se toca" bash -c '[ "$1" = "http://172.16.0.120:8091/api/v1/gw" ]' _ "$(valor REDIRECT_GATEWAY_URL)"
nuevo; PROXY_TLS_NAMES=172.16.0.120; PROXY_HTTPS_PORT=8443; printf 'REDIRECT_GATEWAY_URL=\n' >> .env; REDIRECT_GATEWAY_URL=; https_fijar_url_pasarela >/dev/null 2>&1
chequear "una línea vacía se completa sin duplicarse" bash -c '[ "$1" = "https://172.16.0.120:8443/api/v1/gw" ] && [ "$(grep -c "^REDIRECT_GATEWAY_URL=" .env)" = 1 ]' _ "$(valor REDIRECT_GATEWAY_URL)"
nuevo; PROXY_TLS_NAMES=; https_fijar_url_pasarela >/dev/null 2>&1
chequear "sin HTTPS configurado (sin nombres) no inventa nada" bash -c '[ -z "$1" ]' _ "$(valor REDIRECT_GATEWAY_URL)"
cd "$AQUI" || exit 1

# ───────────────────────────────────────────────────────────────────────────────────────────────
echo "— cableado: docker-compose.yml"
yml() { python3 - "$COMPOSE" "$@" <<'PY'
import json, sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for k in sys.argv[2:]:
    d = d.get(k) if isinstance(d, dict) else None
print(json.dumps(d))
PY
}
PORTS="$(yml services api-proxy ports)"; VOLS="$(yml services api-proxy volumes)"; ENVS="$(yml services api-proxy environment)"
chequear "el proxy publica el 8091 de siempre" bash -c 'echo "$1" | grep -q "\"8091:8091\""' _ "$PORTS"
chequear "el proxy publica el HTTPS: \${PROXY_HTTPS_PORT:-8443} → 8443 del contenedor" bash -c 'echo "$1" | grep -qF "\${PROXY_HTTPS_PORT:-8443}:8443"' _ "$PORTS"
chequear "no publica nada más" bash -c '[ "$(echo "$1" | python3 -c "import json,sys;print(len(json.load(sys.stdin)))")" = 2 ]' _ "$PORTS"
chequear "la CA interna persiste en un volumen con nombre montado en /data" bash -c 'echo "$1" | grep -q "proxy_caddy_data:/data"' _ "$VOLS"
chequear "…declarado en volumes: del compose" python3 -c 'import sys,yaml;sys.exit(0 if "proxy_caddy_data" in yaml.safe_load(open(sys.argv[1]))["volumes"] else 1)' "$COMPOSE"
chequear "no monta /data de otra forma (ni en el repo)" bash -c '! echo "$1" | grep -E ":/data\b" | grep -vq "proxy_caddy_data"' _ "$VOLS"
chequear "el certificado de la empresa se monta de solo lectura en /certs/tls.crt" bash -c 'echo "$1" | grep -qF "\${PROXY_TLS_CERT:-./proxy/sin-certificado}:/certs/tls.crt:ro"' _ "$VOLS"
chequear "la llave, de solo lectura en /certs/tls.key" bash -c 'echo "$1" | grep -qF "\${PROXY_TLS_KEY:-./proxy/sin-certificado}:/certs/tls.key:ro"' _ "$VOLS"
chequear "existe el archivo vacío de reemplazo proxy/sin-certificado (sin él Docker crearía una carpeta)" bash -c '[ -f "$1/proxy/sin-certificado" ] && ! grep -q "PRIVATE KEY" "$1/proxy/sin-certificado"' _ "$AQUI"
chequear "el Caddyfile sigue montado de solo lectura" bash -c 'echo "$1" | grep -q "./proxy/Caddyfile:/etc/caddy/Caddyfile:ro"' _ "$VOLS"
chequear "arranque.sh montado de solo lectura" bash -c 'echo "$1" | grep -q "./proxy/arranque.sh:/usr/local/bin/arranque.sh:ro"' _ "$VOLS"
chequear "…que es el comando del servicio" bash -c 'python3 -c "import sys,yaml;c=yaml.safe_load(open(sys.argv[1]))[\"services\"][\"api-proxy\"][\"command\"];sys.exit(0 if \"arranque.sh\" in \" \".join(c) else 1)" "$1"' _ "$COMPOSE"
chequear "recibe PROXY_TLS_NAMES (con default localhost)" bash -c 'echo "$1" | grep -qF "PROXY_TLS_NAMES=\${PROXY_TLS_NAMES:-localhost}"' _ "$ENVS"
chequear "el certificado va al contenedor solo si hay uno (ruta de dentro, no la del servidor)" bash -c 'echo "$1" | grep -qF "PROXY_TLS_CERT=\${PROXY_TLS_CERT:+/certs/tls.crt}" && echo "$1" | grep -qF "PROXY_TLS_KEY=\${PROXY_TLS_KEY:+/certs/tls.key}"' _ "$ENVS"
chequear "el healthcheck sigue siendo por el 8091 (camino completo)" bash -c 'python3 -c "import sys,yaml;h=yaml.safe_load(open(sys.argv[1]))[\"services\"][\"api-proxy\"][\"healthcheck\"][\"test\"];sys.exit(0 if \"8091/health\" in \" \".join(h) else 1)" "$1"' _ "$COMPOSE"
chequear "el backend sigue sin ports:" bash -c '[ "$1" = null ]' _ "$(yml services backend ports)"
chequear "nadie publica el 8443 salvo el proxy" bash -c '[ "$(grep -c ":8443\"" "$1")" = 1 ]' _ "$COMPOSE"
chequear "la imagen del proxy sigue por digest" bash -c 'echo "$1" | grep -Eq "caddy(:[A-Za-z0-9.-]+)?@sha256:[0-9a-f]{64}"' _ "$(yml services api-proxy image)"
chequear "el compose no nombra la extensión (el test de opt-in lo exige): ni «redirect» fuera de REDIRECT_GATEWAY_URL" \
  bash -c '! grep -Ein "redirect" "$1" | grep -iv "REDIRECT_GATEWAY_URL" | grep -q .' _ "$COMPOSE"
chequear "docker compose config -q valida (solo lee; sin Docker se salta)" bash -c '
  if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
    cd "$1" && POSTGRES_PASSWORD=x ENGINE_MASTER_KEY=x FERNET_SECRET_KEY=x JWT_SECRET_KEY=x AZURE_OPENAI_API_KEY=x AZURE_OPENAI_ENDPOINT=x AZURE_API_VERSION=x docker compose config -q
  else true; fi' _ "$AQUI"

echo "— cableado: install.sh, activar-redirect.sh, .env.example"
n_src=$(grep -n '^set -a; source .env; set +a' "$AQUI/install.sh" | head -n1 | cut -d: -f1)
n_prep=$(grep -n '^https_preparar' "$AQUI/install.sh" | head -n1 | cut -d: -f1)
n_lib=$(grep -n 'source ./proxy/https.lib.sh' "$AQUI/install.sh" | head -n1 | cut -d: -f1)
n_first=$(grep -n '^docker compose pull --quiet engine\|^if ! docker compose pull --quiet engine' "$AQUI/install.sh" | head -n1 | cut -d: -f1)
n_url=$(grep -n 'https_fijar_url_pasarela' "$AQUI/install.sh" | head -n1 | cut -d: -f1)
chequear "install.sh carga proxy/https.lib.sh" [ -n "$n_lib" ]
chequear "install.sh llama a https_preparar DESPUÉS de leer .env y ANTES de tocar docker" bash -c '[ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ] && [ "$1" -gt "$2" ] && [ "$1" -lt "$3" ]' _ "$n_prep" "$n_src" "$n_first"
chequear "install.sh fija la URL de la pasarela antes de levantar el Guardian (si hay extensión)" bash -c '[ -n "$1" ] && [ "$1" -lt "$(grep -n "docker compose up -d backend api-proxy frontend" "$2" | head -n1 | cut -d: -f1)" ]' _ "$n_url" "$AQUI/install.sh"
chequear "install.sh comprueba el HTTPS: /health 200 y /api/v1/internal/identity 404 por el puerto HTTPS" \
  bash -c 'grep -q "HTTPS_URL=\"https://\${PROXY_TLS_NAMES%%,\*}:\${PROXY_HTTPS_PORT}\"" "$1" && grep -q "HTTPS_URL}/health" "$1" && grep -q "HTTPS_URL}/api/v1/internal/identity" "$1" && grep -q "curl -sk" "$1"' _ "$AQUI/install.sh"
chequear "si el plano interno NO da 404 por el HTTPS, install.sh falla (cierra, no avisa)" bash -c 'grep -B3 -A3 "api/v1/internal/identity" "$1" | grep -q "die"' _ "$AQUI/install.sh"
chequear "install.sh avisa si el puerto HTTPS lo usa otro proceso" bash -c 'grep -q "PROXY_HTTPS_PORT" "$1" && grep -q "ss -ltn" "$1" && grep -Eq "puerto .*HTTPS|HTTPS.*puerto" "$1"' _ "$AQUI/install.sh"
chequear "el resumen final de install.sh nombra el HTTPS y exportar-ca.sh" bash -c 'tail -25 "$1" | grep -q "HTTPS_URL" && tail -25 "$1" | grep -q "exportar-ca.sh"' _ "$AQUI/install.sh"
chequear "activar-redirect.sh carga la librería y fija la URL de la pasarela al activar" bash -c 'grep -q "source ./proxy/https.lib.sh" "$1" && grep -q "https_fijar_url_pasarela" "$1"' _ "$AQUI/activar-redirect.sh"
chequear "activar-redirect.sh sigue comprobando el 404 por el 8091 (gate 3)" bash -c 'grep -q "ELEA_API_URL:-http://localhost:8091" "$1"' _ "$AQUI/activar-redirect.sh"
chequear ".env.example documenta PROXY_HTTPS_PORT, PROXY_TLS_NAMES, PROXY_TLS_CERT y PROXY_TLS_KEY" bash -c 'for v in PROXY_HTTPS_PORT PROXY_TLS_NAMES PROXY_TLS_CERT PROXY_TLS_KEY; do grep -Eq "^#? ?$v=" "$1" || exit 1; done' _ "$AQUI/.env.example"
chequear ".env.example: el ejemplo de REDIRECT_GATEWAY_URL es https por el 8443" bash -c 'grep -Eq "^# REDIRECT_GATEWAY_URL=https://.*:8443/api/v1/gw" "$1"' _ "$AQUI/.env.example"
chequear ".env.example no trae ninguna llave ni certificado" bash -c '! grep -Eq "BEGIN .*(PRIVATE KEY|CERTIFICATE)" "$1"' _ "$AQUI/.env.example"
chequear "ningún archivo versionado trae una llave privada" bash -c '! git -C "$1" ls-files -z | xargs -0 grep -lE "BEGIN [A-Z ]*PRIVATE KEY" 2>/dev/null | grep -v "^tests/" | grep -q .' _ "$AQUI"
chequear ".gitignore no hace falta tocar: el certificado y la raíz exportada viven fuera del repo (~/eleia-ca-raiz.crt)" bash -c 'grep -q "eleia-ca-raiz" "$1/exportar-ca.sh"' _ "$AQUI"

# ───────────────────────────────────────────────────────────────────────────────────────────────
echo "— ./exportar-ca.sh (Docker de mentira)"
PEM_RAIZ="$T0/raiz.crt"; PEM_LLAVE="$T0/raiz.key"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$PEM_LLAVE" -out "$PEM_RAIZ" -days 30 -subj "/CN=Caddy Local Authority - Prueba" >/dev/null 2>&1
exporta() { # [VAR=valor …] [-- args]: corre exportar-ca.sh en una carpeta de prueba; deja $out y $rc
  X=$(mktemp -d -p "$T0"); mkdir -p "$X/repo/proxy" "$X/home"; cp "$AQUI"/exportar-ca.sh "$AQUI"/base-motor.lib.sh "$X/repo/"; cp "$LIB" "$X/repo/proxy/"
  printf 'POSTGRES_PASSWORD=pw\n' > "$X/repo/.env"
  export FAKE_LOG="$X/docker.log"; : > "$FAKE_LOG"
  out=$(cd "$X/repo" && env HOME="$X/home" PATH="$AQUI/tests/fake-docker:$PATH" "$@" ./exportar-ca.sh 2>&1); rc=$?
}
exporta FAKE_CA_FILE="$PEM_RAIZ"
chequear "termina bien" [ "$rc" = 0 ]
chequear "escribe ~/eleia-ca-raiz.crt" [ -s "$X/home/eleia-ca-raiz.crt" ]
chequear "es la raíz pública, byte a byte" cmp -s "$PEM_RAIZ" "$X/home/eleia-ca-raiz.crt"
chequear "es un certificado válido" openssl x509 -in "$X/home/eleia-ca-raiz.crt" -noout
chequear "no contiene ninguna llave privada" bash -c '! grep -q "PRIVATE KEY" "$1"' _ "$X/home/eleia-ca-raiz.crt"
chequear "lee solo root.crt del contenedor (nunca root.key)" bash -c 'grep -q "root.crt" "$1" && ! grep -q "root.key" "$1"' _ "$FAKE_LOG"
chequear "usa el servicio api-proxy y el volumen persistente (/data/caddy/pki/authorities/local)" bash -c 'grep -q "api-proxy" "$1" && grep -q "/data/caddy/pki/authorities/local/root.crt" "$1"' _ "$FAKE_LOG"
chequear "el archivo es legible por todos y no ejecutable (644)" bash -c '[ "$(stat -c %a "$1")" = 644 ]' _ "$X/home/eleia-ca-raiz.crt"
chequear "imprime la huella SHA-256 (para cotejarla en la PC)" bash -c 'grep -qi "sha-\?256" <<<"$1" && grep -Eq "([0-9A-F]{2}:){31}[0-9A-F]{2}" <<<"$1"' _ "$out"
chequear "imprime las instrucciones de Windows: GPO, Entidades de certificación raíz de confianza, certutil, gpupdate" \
  bash -c 'for p in "Windows" "Directiva de grupo\|Group Policy\|GPO" "Entidades de certificación raíz de confianza" "certutil" "gpupdate"; do grep -qi "$p" <<<"$1" || { echo "falta: $p" >&2; exit 1; }; done' _ "$out"
chequear "imprime las instrucciones de macOS: security add-trusted-cert, llavero del sistema" \
  bash -c 'grep -q "macOS" <<<"$1" && grep -q "security add-trusted-cert" <<<"$1" && grep -qi "System.keychain" <<<"$1"' _ "$out"
chequear "imprime la prueba con curl (con y sin la raíz) y NODE_EXTRA_CA_CERTS para Claude Code" bash -c 'grep -q "curl" <<<"$1" && grep -q -- "--cacert" <<<"$1" && grep -q "NODE_EXTRA_CA_CERTS" <<<"$1"' _ "$out"
chequear "no imprime la llave ni el contenido del certificado" bash -c '! grep -q "BEGIN" <<<"$1"' _ "$out"
chequear "no ejecuta nada en las PC ni en el sistema (solo copia y explica): sin sudo ni certutil ejecutados" bash -c '! grep -Eq "^(sudo|certutil)" "$1"' _ "$FAKE_LOG"

exporta FAKE_CA_FILE="$PEM_RAIZ" ELEA_CA_DESTINO="$T0/otra/raiz.crt"
chequear "ELEA_CA_DESTINO cambia el destino (y crea la carpeta)" bash -c '[ "$1" = 0 ] && cmp -s "$2" "$3"' _ "$rc" "$PEM_RAIZ" "$T0/otra/raiz.crt"
cat "$PEM_RAIZ" "$PEM_LLAVE" > "$T0/con-llave.pem"
exporta FAKE_CA_FILE="$T0/con-llave.pem"
chequear "si lo leído trajera una llave privada, NO se escribe nada y falla" bash -c '[ "$1" != 0 ] && [ ! -e "$2/home/eleia-ca-raiz.crt" ]' _ "$rc" "$X"
echo "no es un certificado" > "$T0/basura.pem"
exporta FAKE_CA_FILE="$T0/basura.pem"
chequear "si lo leído no es un certificado, falla sin escribir" bash -c '[ "$1" != 0 ] && [ ! -e "$2/home/eleia-ca-raiz.crt" ]' _ "$rc" "$X"
exporta FAKE_CA_FILE=/no/existe
chequear "si el proxy todavía no creó la CA, falla con un mensaje que lo explica" bash -c '[ "$1" != 0 ] && grep -qi "api-proxy" <<<"$2" && [ ! -e "$3/home/eleia-ca-raiz.crt" ]' _ "$rc" "$out" "$X"
exporta FAKE_CA_FILE="$PEM_RAIZ" PROXY_TLS_CERT=/etc/ssl/empresa.crt PROXY_TLS_KEY=/etc/ssl/empresa.key
chequear "con certificado de la empresa (PROXY_TLS_CERT) no hay CA interna que exportar: lo dice y no escribe" \
  bash -c '[ "$1" != 0 ] && grep -qi "empresa" <<<"$2" && [ ! -e "$3/home/eleia-ca-raiz.crt" ]' _ "$rc" "$out" "$X"
chequear "…y sin tocar el contenedor" bash -c '! grep -q "root.crt" "$1"' _ "$FAKE_LOG"

# ───────────────────────────────────────────────────────────────────────────────────────────────
echo "— README: «HTTPS para Claude Desktop»"
SEC=$(awk '/^### HTTPS para Claude Desktop/{f=1;next} f&&/^##+ /{exit} f' "$AQUI/README.md")
chequear "existe la sección «HTTPS para Claude Desktop»" [ -n "$SEC" ]
s_() { grep -qF -- "$1" <<<"$SEC"; }
chequear "las dos variantes: certificado de la empresa (recomendada) y CA interna + GPO" bash -c 'grep -q "Variante A (recomendada): certificado de la empresa" <<<"$1" && grep -q "Variante B: CA interna del proxy + GPO" <<<"$1"' _ "$SEC"
chequear "las variables: PROXY_HTTPS_PORT, PROXY_TLS_NAMES, PROXY_TLS_CERT, PROXY_TLS_KEY, REDIRECT_GATEWAY_URL" bash -c 'for v in PROXY_HTTPS_PORT PROXY_TLS_NAMES PROXY_TLS_CERT PROXY_TLS_KEY REDIRECT_GATEWAY_URL; do grep -q "$v" <<<"$1" || exit 1; done' _ "$SEC"
chequear "GPO: Entidades de certificación raíz de confianza, gpupdate y certutil" bash -c 'grep -q "Entidades de certificación raíz de confianza" <<<"$1" && grep -q "gpupdate" <<<"$1" && grep -q "certutil" <<<"$1"' _ "$SEC"
chequear "macOS: security add-trusted-cert" s_ "security add-trusted-cert"
chequear "verificar desde una PC: curl -v https://172.16.0.120:8443/health con y sin la raíz" bash -c 'grep -q "curl -v https://172.16.0.120:8443/health" <<<"$1" && grep -q "curl -v --cacert eleia-ca-raiz.crt https://172.16.0.120:8443/health" <<<"$1"' _ "$SEC"
chequear "verificar Claude Desktop con la URL https y Claude Code con NODE_EXTRA_CA_CERTS" bash -c 'grep -q "https://<servidor>:8443/api/v1/gw" <<<"$1" && grep -q "NODE_EXTRA_CA_CERTS" <<<"$1"' _ "$SEC"
chequear "runbook del servidor: git pull, .env, ./install.sh, ./exportar-ca.sh" bash -c 'grep -q "^git pull" <<<"$1" && grep -q "^nano .env" <<<"$1" && grep -q "^./install.sh" <<<"$1" && grep -q "^./exportar-ca.sh" <<<"$1"' _ "$SEC"
chequear "dice que internal da 404 también por el 8443 y que el 8091 HTTP sigue igual" bash -c 'grep -q "404" <<<"$1" && grep -q "8091" <<<"$1"' _ "$SEC"
chequear "la CA persiste en un volumen y solo cambia si se borra" bash -c 'grep -q "proxy_caddy_data" <<<"$1" && grep -q "down -v" <<<"$1"' _ "$SEC"
chequear "la llave nunca se exporta" bash -c 'grep -qi "nunca la llave" <<<"$1"' _ "$SEC"
chequear "leyenda 🟢/🟡/🔵 con lo no probado en vivo marcado 🟡 (Claude Desktop en PC real, GPO)" bash -c 'grep -q "🟢" <<<"$1" && grep -q "🟡" <<<"$1" && grep -q "🔵" <<<"$1" && grep -q "Claude Desktop.* contra la URL HTTPS en una PC real" <<<"$1"' _ "$SEC"
chequear "avisa que entrar por IP presenta el certificado del primer nombre" bash -c 'grep -q "primer" <<<"$1" && grep -qi "SNI\|saludo TLS" <<<"$1"' _ "$SEC"
chequear "marca neutra: sin nombres de componentes internos" bash -c '! grep -Eiq "litellm|presenton|anythingllm|sentinel|guardian" <<<"$1"' _ "$SEC"
chequear "sin llaves ni certificados en el README" bash -c '! grep -Eq "BEGIN [A-Z ]*(PRIVATE KEY|CERTIFICATE)" "$1"' _ "$AQUI/README.md"
chequear "Paso 6: el GW_URL de la activación es https por el 8443" bash -c 'grep -q "GW_URL=.https://<servidor>:8443/api/v1/gw" "$1"' _ "$AQUI/README.md"
chequear "Paso 9: la URL de Claude Desktop es https://<servidor>:8443/api/v1/gw" bash -c 'grep -q "URL base del gateway | \`https://<servidor>:8443/api/v1/gw\`" "$1"' _ "$AQUI/README.md"
chequear "la lista de pruebas del README incluye tests/test-https.sh" grep -q "bash tests/test-https.sh" "$AQUI/README.md"

# ───────────────────────────────────────────────────────────────────────────────────────────────
echo "— proxy/Caddyfile y arranque.sh (texto)"
chequear "el Caddyfile escucha el HTTP de siempre (:8091)" grep -Eq '^:8091 \{' "$CADDYFILE"
chequear "…y el HTTPS con los nombres de PROXY_TLS_NAMES" grep -Eq '^\{\$PROXY_TLS_NAMES[^}]*\} \{' "$CADDYFILE"
chequear "el HTTPS usa el puerto 8443 de dentro (https_port)" grep -Eq '^\s*https_port 8443' "$CADDYFILE"
chequear "el cierre de internal está UNA vez, en un fragmento que importan los dos sitios (mismo enrutamiento)" \
  bash -c '[ "$(grep -c "path_regexp" "$1")" = 1 ] && [ "$(grep -c "^\s*import ruta" "$1")" = 2 ]' _ "$CADDYFILE"
chequear "tls: certificado de la empresa o internal" grep -Eq '^\s*tls \{\$PROXY_TLS_CERT:internal\} \{\$PROXY_TLS_KEY\}' "$CADDYFILE"
chequear "no instala la raíz en el sistema del contenedor (skip_install_trust)" grep -Eq '^\s*skip_install_trust' "$CADDYFILE"
chequear "sin redirección de HTTP a HTTPS ni puerto 80 (auto_https disable_redirects)" grep -Eq '^\s*auto_https disable_redirects' "$CADDYFILE"
chequear "default_sni: los clientes que entran por IP (sin SNI) reciben el certificado" grep -Eq '^\s*default_sni \{\$PROXY_TLS_PRIMERO' "$CADDYFILE"
chequear "sigue sin API de administración" grep -Eq '^\s*admin off' "$CADDYFILE"
chequear "no guarda la configuración en disco (persist_config off)" grep -Eq '^\s*persist_config off' "$CADDYFILE"
chequear "arranque.sh usa exec (Caddy recibe las señales de docker stop)" grep -Eq '^exec ' "$ARRANQUE"

# ───────────────────────────────────────────────────────────────────────────────────────────────
echo "— Caddy de verdad: HTTPS con la CA interna y con certificado de la empresa"
CADDY_BIN="${ELEA_CADDY_BIN:-$(command -v caddy || true)}"
if [ -z "$CADDY_BIN" ] || [ ! -x "$CADDY_BIN" ]; then
  salta "no hay binario caddy (PATH o ELEA_CADDY_BIN): no se corre el HTTPS real; correr con ELEA_CADDY_BIN=/ruta/a/caddy"
else
  libre() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])'; }
  # Backend de mentira: anota cada pedido y contesta 200 con el Host que vio.
  cat > "$T0/backend.py" <<'PY'
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
LOG = sys.argv[2]
class H(BaseHTTPRequestHandler):
    def _go(self):
        n = int(self.headers.get("content-length") or 0)
        if n: self.rfile.read(n)
        with open(LOG, "a") as f: f.write(f"{self.command} {self.path}\n")
        body = b"BACKEND"
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = _go
    def log_message(self, *a): pass
ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
  P_BACK=$(libre); python3 "$T0/backend.py" "$P_BACK" "$T0/back.log" & PID_BACK=$!
  trap 'kill "${PID_CADDY:-}" "$PID_BACK" 2>/dev/null; rm -rf "$T0"' EXIT

  # Levanta el proxy como lo hace el contenedor (arranque.sh + el Caddyfile del repo), cambiando solo destino y puertos.
  # $1 = carpeta de datos (la CA interna vive ahí), el resto = variables PROXY_* del caso.
  arrancar() {
    local datos="$1"; shift
    parar
    P_HTTP=$(libre); P_TLS=$(libre)
    sed -e "s|backend:8000|127.0.0.1:${P_BACK}|g" -e "s|^:8091 {|:${P_HTTP} {|" -e "s|https_port 8443|https_port ${P_TLS}|" "$CADDYFILE" > "$T0/Caddyfile"
    env "$@" XDG_DATA_HOME="$datos" XDG_CONFIG_HOME="$datos/cfg" CADDY_BIN="$CADDY_BIN" CADDYFILE="$T0/Caddyfile" \
      sh "$ARRANQUE" >"$T0/caddy.log" 2>&1 & PID_CADDY=$!
    for _ in $(seq 1 75); do curl -s -o /dev/null "http://127.0.0.1:${P_HTTP}/" && break; sleep 0.2; done
    sleep 0.5
  }
  parar() { [ -z "${PID_CADDY:-}" ] || { kill "$PID_CADDY" 2>/dev/null; wait "$PID_CADDY" 2>/dev/null; PID_CADDY=; }; }
  codigo() { curl -s --path-as-is -o /dev/null -w '%{http_code}' --max-time 10 "$@"; }

  echo "    CA interna (tls internal), nombres «127.0.0.1, localhost» pasados con coma"
  D1="$T0/datos1"; mkdir -p "$D1"
  arrancar "$D1" PROXY_TLS_NAMES="127.0.0.1,localhost"
  RAIZ="$D1/caddy/pki/authorities/local/root.crt"
  chequear "Caddy arrancó (el HTTP de siempre responde)" bash -c '[ "$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$1/health")" = 200 ]' _ "$P_HTTP"
  chequear "no tocó el almacén de confianza del sistema (skip_install_trust)" bash -c 'grep -q "trust store installation disabled" "$1" && ! grep -qi "sudo\|password" "$1"' _ "$T0/caddy.log"
  chequear "la CA interna quedó en el volumen de datos (/data/caddy/pki/authorities/local/root.crt)" [ -s "$RAIZ" ]
  chequear "la raíz pública es un certificado y la carpeta tiene aparte la llave (que exportar-ca.sh nunca lee)" bash -c 'openssl x509 -in "$1" -noout && [ -f "$(dirname "$1")/root.key" ]' _ "$RAIZ"
  chequear "HTTPS sin la raíz: curl lo rechaza (certificado no confiable)" bash -c '! curl -s -o /dev/null --max-time 10 "https://127.0.0.1:$1/health"' _ "$P_TLS"
  chequear "HTTPS con -k: /health 200" bash -c '[ "$(curl -sk -o /dev/null -w "%{http_code}" "https://127.0.0.1:$1/health")" = 200 ]' _ "$P_TLS"
  chequear "HTTPS con la raíz (--cacert) por la IP: /health 200 (la IP está en el certificado)" bash -c '[ "$(curl -s --cacert "$1" -o /dev/null -w "%{http_code}" "https://127.0.0.1:$2/health")" = 200 ]' _ "$RAIZ" "$P_TLS"
  chequear "…y por el nombre (localhost)" bash -c '[ "$(curl -s --cacert "$1" -o /dev/null -w "%{http_code}" "https://localhost:$2/health")" = 200 ]' _ "$RAIZ" "$P_TLS"
  chequear "…entrando por OTRA IP local del equipo (como en Docker, donde la IP de dentro no es la del servidor): default_sni" \
    bash -c '[ "$(curl -s --cacert "$1" --connect-to "127.0.0.1:$2:127.0.0.2:$2" -o /dev/null -w "%{http_code}" "https://127.0.0.1:$2/health")" = 200 ]' _ "$RAIZ" "$P_TLS"
  chequear "un nombre que no está en el certificado se rechaza" bash -c '! curl -s --cacert "$1" --resolve "otro.invalido:$2:127.0.0.1" -o /dev/null "https://otro.invalido:$2/health"' _ "$RAIZ" "$P_TLS"
  chequear "deja pasar lo que usa Claude (POST /api/v1/gw/chat/completions) por el HTTPS" bash -c '[ "$(curl -s --cacert "$1" -X POST -d "{}" -o /dev/null -w "%{http_code}" "https://127.0.0.1:$2/api/v1/gw/chat/completions")" = 200 ]' _ "$RAIZ" "$P_TLS"
  : > "$T0/back.log"
  U="https://127.0.0.1:${P_TLS}"
  for r in /api/v1/internal/identity /api/v1/internal /api/v1/internal/ /API/V1/INTERNAL/identity //api/v1/internal/identity /api/v1/%69nternal/identity '/api/v1%2Finternal/identity' /api/v1/x/../internal/identity '/api/v1/internal/identity?key_hash=x'; do
    chequear "HTTPS: $r da 404" bash -c '[ "$(curl -s --cacert "$1" --path-as-is -o /dev/null -w "%{http_code}" "$2$3")" = 404 ]' _ "$RAIZ" "$U" "$r"
  done
  chequear "HTTPS: POST /api/v1/internal/audit da 404" bash -c '[ "$(curl -s --cacert "$1" -X POST -d "{}" -o /dev/null -w "%{http_code}" "$2/api/v1/internal/audit")" = 404 ]' _ "$RAIZ" "$U"
  chequear "HTTPS: con la cabecera del secreto del motor, también 404" bash -c '[ "$(curl -s --cacert "$1" -H "X-Sentinel-Internal: x" -o /dev/null -w "%{http_code}" "$2/api/v1/internal/identity")" = 404 ]' _ "$RAIZ" "$U"
  chequear "HTTPS: /api/v1/internals-x pasa (no es el segmento «internal»)" bash -c '[ "$(curl -s --cacert "$1" -o /dev/null -w "%{http_code}" "$2/api/v1/internals-x")" = 200 ]' _ "$RAIZ" "$U"
  chequear "el backend de mentira no recibió ninguno de los pedidos a internal" bash -c '! grep -qi "internal/\|internal$" "$1"' _ "$T0/back.log"
  chequear "el 8091 sigue en HTTP plano y sigue cerrando internal (404)" bash -c '[ "$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$1/api/v1/internal/identity")" = 404 ]' _ "$P_HTTP"
  chequear "el 8091 NO habla TLS (no cambió)" bash -c '! curl -sk -o /dev/null --max-time 5 "https://127.0.0.1:$1/health"' _ "$P_HTTP"
  chequear "nadie escucha el 80 ni se redirige HTTP→HTTPS (el 8091 no redirige)" bash -c '[ "$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$1/health")" = 200 ]' _ "$P_HTTP"

  echo "    la CA persiste entre recreaciones (mismo volumen = misma raíz)"
  H1=$(openssl x509 -in "$RAIZ" -noout -fingerprint -sha256)
  arrancar "$D1" PROXY_TLS_NAMES="127.0.0.1,localhost"
  H2=$(openssl x509 -in "$RAIZ" -noout -fingerprint -sha256)
  chequear "reiniciar con el mismo /data conserva la raíz (no hay que reinstalarla en las PC)" bash -c '[ -n "$1" ] && [ "$1" = "$2" ]' _ "$H1" "$H2"
  chequear "…y el certificado sigue validando" bash -c '[ "$(curl -s --cacert "$1" -o /dev/null -w "%{http_code}" "https://127.0.0.1:$2/health")" = 200 ]' _ "$RAIZ" "$P_TLS"
  D2="$T0/datos2"; mkdir -p "$D2"
  arrancar "$D2" PROXY_TLS_NAMES="127.0.0.1"
  H3=$(openssl x509 -in "$D2/caddy/pki/authorities/local/root.crt" -noout -fingerprint -sha256)
  chequear "con un /data nuevo la raíz es OTRA (por eso el volumen no se borra: «down -v» obligaría a reinstalarla)" bash -c '[ -n "$1" ] && [ "$1" != "$2" ]' _ "$H1" "$H3"

  echo "    certificado de la empresa (PROXY_TLS_CERT / PROXY_TLS_KEY)"
  D3="$T0/datos3"; mkdir -p "$D3"
  EMP="$T0/empresa"; mkdir -p "$EMP"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$EMP/tls.key" -out "$EMP/tls.crt" -days 2 \
    -subj "/CN=elea.empresa.test" -addext "subjectAltName=DNS:elea.empresa.test,IP:127.0.0.1" >/dev/null 2>&1
  arrancar "$D3" PROXY_TLS_NAMES="elea.empresa.test" PROXY_TLS_CERT="$EMP/tls.crt" PROXY_TLS_KEY="$EMP/tls.key"
  RES="elea.empresa.test:${P_TLS}:127.0.0.1"
  chequear "con el certificado de la empresa, HTTPS valida contra ese certificado (sirve el suyo, no uno interno)" \
    bash -c '[ "$(curl -s --cacert "$1" --resolve "$2" -o /dev/null -w "%{http_code}" "https://elea.empresa.test:$3/health")" = 200 ]' _ "$EMP/tls.crt" "$RES" "$P_TLS"
  chequear "…y NO es el de la CA interna (la raíz interna no lo valida: no hay nada que instalar en las PC)" \
    bash -c '! curl -s --cacert "$1" --resolve "$2" -o /dev/null "https://elea.empresa.test:$3/health"' _ "$D3/caddy/pki/authorities/local/root.crt" "$RES" "$P_TLS"
  chequear "…internal sigue en 404 por el HTTPS" bash -c '[ "$(curl -s --cacert "$1" --resolve "$2" -o /dev/null -w "%{http_code}" "https://elea.empresa.test:$3/api/v1/internal/identity")" = 404 ]' _ "$EMP/tls.crt" "$RES" "$P_TLS"
  chequear "…y por IP (sin SNI) responde con el mismo certificado (default_sni)" bash -c '[ "$(curl -s --cacert "$1" --connect-to "elea.empresa.test:$2:127.0.0.2:$2" -o /dev/null -w "%{http_code}" "https://elea.empresa.test:$2/health")" = 200 ]' _ "$EMP/tls.crt" "$P_TLS"
  parar

  echo "    arranque.sh: configuraciones incompletas fallan antes de arrancar"
  prueba_arranque() { env "$@" CADDY_BIN=/bin/true CADDYFILE=/dev/null sh "$ARRANQUE" >"$T0/arq.out" 2>&1; echo $?; }
  rc_a=$(prueba_arranque PROXY_TLS_CERT=/x.crt PROXY_TLS_KEY=)
  chequear "certificado sin llave: falla con un mensaje que lo dice" bash -c '[ "$1" != 0 ] && grep -q PROXY_TLS_KEY "$2"' _ "$rc_a" "$T0/arq.out"
  rc_a=$(prueba_arranque PROXY_TLS_CERT= PROXY_TLS_KEY=/x.key)
  chequear "llave sin certificado: falla" bash -c '[ "$1" != 0 ]' _ "$rc_a"
  rc_a=$(prueba_arranque PROXY_TLS_CERT=/no/hay.crt PROXY_TLS_KEY=/no/hay.key)
  chequear "certificado que no se puede leer: falla nombrando el archivo" bash -c '[ "$1" != 0 ] && grep -q "hay.crt" "$2"' _ "$rc_a" "$T0/arq.out"
  rc_a=$(prueba_arranque PROXY_TLS_CERT= PROXY_TLS_KEY= PROXY_TLS_NAMES=1.2.3.4)
  chequear "ambos vacíos = CA interna: no falla" bash -c '[ "$1" = 0 ]' _ "$rc_a"
fi

echo
if [ "$FALLOS" = 0 ]; then echo "TODO OK"; else echo "$FALLOS FALLO(S)"; exit 1; fi
