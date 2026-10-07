#!/usr/bin/env bash
# Copia la raíz PÚBLICA de la CA interna del proxy a ~/eleia-ca-raiz.crt y explica cómo instalarla en las PC
# (Windows por GPO, macOS) para que Claude Desktop confíe en https://<servidor>:8443.
# Solo sirve cuando el proxy usa su CA interna (sin PROXY_TLS_CERT / PROXY_TLS_KEY): con el certificado de la
# empresa las PC ya confían en él y no hay nada que instalar.
#
#   ./exportar-ca.sh [destino]        destino por defecto: ~/eleia-ca-raiz.crt (o ELEA_CA_DESTINO)
#
# Lee SOLO root.crt (la raíz pública) del volumen de la CA; la llave (root.key) no se toca ni se copia. No instala
# nada en este servidor ni en las PC.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=base-motor.lib.sh
source ./base-motor.lib.sh
# shellcheck source=proxy/https.lib.sh
source ./proxy/https.lib.sh

if [ -f .env ]; then
  # Lo que ya viene del entorno manda sobre el .env (mismo criterio que docker compose).
  ENV_CERT="${PROXY_TLS_CERT-}"; ENV_NAMES="${PROXY_TLS_NAMES-}"; ENV_PORT="${PROXY_HTTPS_PORT-}"
  set -a; source .env; set +a
  [ -z "$ENV_CERT" ] || PROXY_TLS_CERT="$ENV_CERT"
  [ -z "$ENV_NAMES" ] || PROXY_TLS_NAMES="$ENV_NAMES"
  [ -z "$ENV_PORT" ] || PROXY_HTTPS_PORT="$ENV_PORT"
fi

DESTINO="${1:-${ELEA_CA_DESTINO:-$HOME/eleia-ca-raiz.crt}}"
RAIZ_EN_CONTENEDOR=/data/caddy/pki/authorities/local/root.crt
PUERTO="${PROXY_HTTPS_PORT:-8443}"
PRIMERO="${PROXY_TLS_NAMES:-<servidor>}"; PRIMERO="${PRIMERO%%,*}"

if [ -n "${PROXY_TLS_CERT:-}" ]; then
  die "El proxy usa el certificado de la empresa (PROXY_TLS_CERT=${PROXY_TLS_CERT}): no hay CA interna que exportar. Las PC confían en él si confían en la CA de la empresa que lo firmó."
fi
command -v docker >/dev/null || die "Falta Docker."

tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
docker compose exec -T api-proxy cat "$RAIZ_EN_CONTENEDOR" > "$tmp" 2>/dev/null \
  || die "No pude leer la raíz de la CA en el contenedor api-proxy ($RAIZ_EN_CONTENEDOR). ¿Está levantado (docker compose ps api-proxy) y con los nombres del certificado en PROXY_TLS_NAMES? La CA se crea cuando el proxy arranca; ver ./elea-logs.sh api-proxy."

# Solo un certificado público: nunca una llave, y tiene que ser un certificado.
if grep -q "PRIVATE KEY" "$tmp"; then
  die "Lo leído trae una llave privada: no se escribe nada. (Esto no debería pasar; avisar.)"
fi
grep -q -- "-----BEGIN CERTIFICATE-----" "$tmp" || die "Lo leído en $RAIZ_EN_CONTENEDOR no es un certificado PEM: no se escribe nada."
if command -v openssl >/dev/null; then
  openssl x509 -in "$tmp" -noout 2>/dev/null || die "Lo leído en $RAIZ_EN_CONTENEDOR no es un certificado válido: no se escribe nada."
  HUELLA=$(openssl x509 -in "$tmp" -noout -fingerprint -sha256 | cut -d= -f2)
  SUJETO=$(openssl x509 -in "$tmp" -noout -subject | sed 's/^subject= *//')
  VENCE=$(openssl x509 -in "$tmp" -noout -enddate | cut -d= -f2)
else
  aviso "No hay openssl en este servidor: no pude validar el certificado ni calcular su huella SHA-256."
  HUELLA="(sin openssl: sha256sum del archivo $(sha256sum "$tmp" | cut -d' ' -f1))"; SUJETO="(desconocido)"; VENCE="(desconocido)"
fi

mkdir -p "$(dirname "$DESTINO")"
install -m 644 "$tmp" "$DESTINO"
NOMBRE="$(basename "$DESTINO")"

paso "Raíz pública de la CA interna copiada a: $DESTINO"
cat <<TXT

  Sujeto:        $SUJETO
  Vence:         $VENCE
  Huella SHA-256: $HUELLA
  (Es solo la parte PÚBLICA: la llave de la CA queda en el volumen del proxy y no sale del servidor. La raíz
   no cambia mientras no se borre el volumen proxy_caddy_data: no hay que reinstalarla en las PC en cada
   actualización. Cotejar esta huella en la PC antes de instalarla.)

 Windows — por directiva de grupo (GPO), para todas las PC del dominio
 ─────────────────────────────────────────────────────────────────────
  1. Copiar $NOMBRE a un equipo con las herramientas de administración (RSAT) y abrir la consola de
     administración de directivas de grupo:  gpmc.msc
  2. Crear una GPO nueva (o editar una existente) y vincularla a la unidad organizativa de las PC.
  3. Editar → Configuración del equipo → Directivas → Configuración de Windows → Configuración de seguridad →
     Directivas de clave pública → «Entidades de certificación raíz de confianza» → clic derecho → Importar…
     → elegir $NOMBRE → Finalizar.
  4. En cada PC (o al reiniciar):  gpupdate /force
     Comprobar:  certutil -store Root | findstr /i "Caddy"      (o  certmgr.msc → Entidades de certificación
     raíz de confianza → Certificados)
  Alternativas por línea de comandos (como administrador):
     • una sola PC:             certutil -addstore -f Root $NOMBRE
     • todo el dominio (AD):    certutil -dspublish -f $NOMBRE RootCA     (requiere permisos de administrador de la empresa)
  Claude Desktop usa el almacén de certificados de Windows: después de instalar la raíz, cerrar Claude Desktop
  por completo (también del área de notificación) y volver a abrirlo.

 macOS
 ─────
  • Una Mac:   sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain $NOMBRE
    (o doble clic en $NOMBRE → Acceso a Llaveros → llavero «Sistema» → Información → Confiar → «Confiar siempre»)
  • Flota gestionada (MDM): un perfil de configuración con un payload «Certificado» (com.apple.security.root)
    que lleve $NOMBRE.
  Cerrar y volver a abrir Claude Desktop.

 Claude Code (línea de comandos) — usa su propio almacén de certificados
 ──────────────────────────────────────────────────────────────────────
     export NODE_EXTRA_CA_CERTS=/ruta/a/$NOMBRE
     export ANTHROPIC_BASE_URL=https://${PRIMERO}:${PUERTO}/api/v1/gw

 Comprobar desde una PC
 ──────────────────────
     curl -v https://${PRIMERO}:${PUERTO}/health                       # sin la raíz: falla (certificado no confiable)
     curl -v --cacert $NOMBRE https://${PRIMERO}:${PUERTO}/health      # con la raíz: HTTP 200
  Usar en la URL uno de los nombres de PROXY_TLS_NAMES (${PROXY_TLS_NAMES:-no definido en .env}): otro nombre no está en el certificado.
TXT
