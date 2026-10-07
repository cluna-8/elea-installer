#!/bin/sh
# Arranque del proxy dentro del contenedor (busybox sh): deja las variables PROXY_TLS_* como las lee
# proxy/Caddyfile y arranca Caddy. Falla ANTES de arrancar si el certificado de la empresa está incompleto
# (Caddy lo diría con un error más críptico, o arrancaría con otro certificado).
#   PROXY_TLS_NAMES        IPs/DNS separados por coma (o espacio); default localhost
#   PROXY_TLS_CERT / KEY   rutas DENTRO del contenedor del certificado y la llave de la empresa (ambas o ninguna)
# Para las pruebas: CADDY_BIN (binario de Caddy) y CADDYFILE (ruta del Caddyfile).
set -eu

nombres=$(printf '%s' "${PROXY_TLS_NAMES:-}" | tr ',' ' ' | tr -s ' ' | sed 's/^ //;s/ $//')
[ -n "$nombres" ] || nombres=localhost
PROXY_TLS_NAMES="$nombres"
PROXY_TLS_PRIMERO="${nombres%% *}"
export PROXY_TLS_NAMES PROXY_TLS_PRIMERO

cert="${PROXY_TLS_CERT:-}"
llave="${PROXY_TLS_KEY:-}"
if [ -n "$cert" ] || [ -n "$llave" ]; then
  [ -n "$cert" ]  || { echo "arranque: falta PROXY_TLS_CERT (hay PROXY_TLS_KEY): el certificado y la llave van juntos." >&2; exit 1; }
  [ -n "$llave" ] || { echo "arranque: falta PROXY_TLS_KEY (hay PROXY_TLS_CERT): el certificado y la llave van juntos." >&2; exit 1; }
  for f in "$cert" "$llave"; do
    [ -s "$f" ] && [ -r "$f" ] || { echo "arranque: no puedo leer $f (PROXY_TLS_CERT / PROXY_TLS_KEY): ¿está montado y no vacío?" >&2; exit 1; }
  done
  export PROXY_TLS_CERT PROXY_TLS_KEY
else
  # Vacías = ausentes: con valor vacío Caddy no aplicaría su `internal` por defecto.
  unset PROXY_TLS_CERT PROXY_TLS_KEY
fi

exec "${CADDY_BIN:-caddy}" run --config "${CADDYFILE:-/etc/caddy/Caddyfile}" --adapter caddyfile
