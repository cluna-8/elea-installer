#!/usr/bin/env bash
# shellcheck shell=bash
# HTTPS del proxy (puerto 8443): nombres del certificado, puerto, certificado de la empresa y la URL
# por defecto de la pasarela. Se carga con `source`; no se ejecuta. Lo usan install.sh, activar-redirect.sh
# y exportar-ca.sh, que ya definen die/set_env (el set_env de install.sh no exporta: acá se exporta aparte).
#
# Variables (todas en .env):
#   PROXY_HTTPS_PORT   puerto publicado en el servidor (default 8443). Dentro del contenedor es siempre 8443.
#   PROXY_TLS_NAMES    IP y/o nombres DNS del servidor, separados por coma: los que van en el certificado y los
#                      que las PC usan en la URL. Default: la IP del servidor y su hostname.
#   PROXY_TLS_CERT / PROXY_TLS_KEY   (opcionales, juntas) certificado y llave de la empresa, rutas absolutas de
#                      archivos del servidor FUERA del repo. Sin ellas, Caddy usa su CA interna (`tls internal`).

# IP por la que el servidor sale a la red (la ruta por defecto), no la primera de `hostname -I` (que puede ser la
# de un puente de Docker). Sustituible en las pruebas.
https_ip_servidor() {
  local ip=""
  if command -v ip >/dev/null 2>&1; then
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1)
  fi
  if [ -z "$ip" ] && command -v hostname >/dev/null 2>&1; then
    ip=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+(\.[0-9]+){3}$' | grep -Ev '^(127\.|169\.254\.)' | head -n1)
  fi
  printf '%s' "$ip"
}
https_hostname_servidor() { hostname 2>/dev/null || true; }

# Lista de nombres → separada por comas, sin espacios, sin vacíos ni repetidos (se conserva el orden).
https_normalizar_nombres() {
  printf '%s' "$1" | tr ',[:space:]' '\n\n' | awk 'NF && !visto[$0]++' | paste -sd, -
}

# Cada nombre: una IPv4 o un nombre DNS (con comodín inicial opcional, para el certificado de la empresa).
# Nada que Caddy o el shell puedan leer de otra manera (espacios, comillas, $, ;, barras, puerto).
https_nombres_validos() {
  local n; [ -n "$1" ] || return 1
  while IFS= read -r n; do
    [[ "$n" =~ ^(\*\.)?[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$ ]] || return 1
  done < <(printf '%s\n' "$1" | tr ',' '\n')
}

# IP + hostname del servidor (sin repetir). Vacío si no se detecta nada.
https_nombres_defecto() {
  https_normalizar_nombres "$(https_ip_servidor),$(https_hostname_servidor)"
}

# https://<primer nombre>:<puerto>/api/v1/gw
https_url_pasarela() {
  local primero="${1%%,*}"
  printf 'https://%s:%s/api/v1/gw' "$primero" "$2"
}

_https_fijar() { set_env "$1" "$2"; export "$1=$2"; }

# Deja PROXY_HTTPS_PORT, PROXY_TLS_NAMES (y valida PROXY_TLS_CERT/KEY) listos en .env y en el entorno.
# Falla (die) si algo no sirve: es mejor que Caddy no arranque a medias.
https_preparar() {
  local puerto="${PROXY_HTTPS_PORT:-}" nombres="${PROXY_TLS_NAMES:-}" cert="${PROXY_TLS_CERT:-}" llave="${PROXY_TLS_KEY:-}"

  [ -n "$puerto" ] || puerto=8443
  if ! [[ "$puerto" =~ ^[0-9]+$ ]] || [ "$puerto" -lt 1 ] || [ "$puerto" -gt 65535 ] || [ "$puerto" = 8091 ]; then
    die "PROXY_HTTPS_PORT=${puerto} no sirve: un puerto entre 1 y 65535 que no sea el 8091 (HTTP del proxy)."; return 1
  fi
  [ "${PROXY_HTTPS_PORT:-}" = "$puerto" ] && [ -n "${PROXY_HTTPS_PORT:-}" ] && grep -q '^PROXY_HTTPS_PORT=' .env 2>/dev/null || _https_fijar PROXY_HTTPS_PORT "$puerto"

  if [ -z "$nombres" ]; then
    nombres=$(https_nombres_defecto)
    [ -n "$nombres" ] || { die "No pude deducir la IP ni el nombre de este servidor: poné PROXY_TLS_NAMES en .env (IP y/o nombres DNS que usan las PC, separados por coma; p. ej. PROXY_TLS_NAMES=172.16.0.120,elea-srv)."; return 1; }
    echo "  HTTPS: nombres del certificado por defecto (PROXY_TLS_NAMES): ${nombres}"
  else
    nombres=$(https_normalizar_nombres "$nombres")
  fi
  https_nombres_validos "$nombres" || { die "PROXY_TLS_NAMES='${PROXY_TLS_NAMES:-$nombres}' no es válido: IPs y/o nombres DNS separados por coma, sin puerto ni esquema (p. ej. 172.16.0.120,elea-srv)."; return 1; }
  [ "${PROXY_TLS_NAMES:-}" = "$nombres" ] && grep -q '^PROXY_TLS_NAMES=' .env 2>/dev/null || _https_fijar PROXY_TLS_NAMES "$nombres"

  if [ -n "$cert$llave" ]; then
    [ -n "$cert" ]  || { die "Falta PROXY_TLS_CERT: el certificado y la llave de la empresa van juntos (hay PROXY_TLS_KEY)."; return 1; }
    [ -n "$llave" ] || { die "Falta PROXY_TLS_KEY: el certificado y la llave de la empresa van juntos (hay PROXY_TLS_CERT)."; return 1; }
    local f
    for f in "$cert" "$llave"; do
      case "$f" in /*) ;; *) { die "PROXY_TLS_CERT y PROXY_TLS_KEY tienen que ser rutas absolutas de archivos del servidor (es: $f)."; return 1; } ;; esac
      [ -f "$f" ] && [ -r "$f" ] || { die "No encuentro el archivo $f (o no se puede leer): PROXY_TLS_CERT / PROXY_TLS_KEY."; return 1; }
    done
    for f in "$cert" "$llave"; do
      case "$(realpath -m "$f")/" in
        "$(pwd -P)"/*) { die "$f está dentro del repo del instalador, que se versiona: el certificado y la llave van en una ruta del servidor fuera de él."; return 1; } ;;
      esac
    done
    command -v openssl >/dev/null 2>&1 && { openssl x509 -in "$cert" -noout >/dev/null 2>&1 || { die "PROXY_TLS_CERT ($cert) no es un certificado PEM válido."; return 1; }; }
  fi
}

# REDIRECT_GATEWAY_URL por defecto: https://<primer nombre de PROXY_TLS_NAMES>:<puerto>/api/v1/gw. Solo si está
# vacío (el .env puede pisarlo) y hay HTTPS configurado (nombres).
https_fijar_url_pasarela() {
  [ -z "${REDIRECT_GATEWAY_URL:-}" ] || return 0
  [ -n "${PROXY_TLS_NAMES:-}" ] || return 0
  local url; url=$(https_url_pasarela "$PROXY_TLS_NAMES" "${PROXY_HTTPS_PORT:-8443}")
  _https_fijar REDIRECT_GATEWAY_URL "$url"
  echo "  REDIRECT_GATEWAY_URL (kits de Claude Desktop): ${url}"
}
