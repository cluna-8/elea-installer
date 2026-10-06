#!/usr/bin/env bash
# Crea, UNA sola vez, el usuario de cumplimiento (rol super_admin) de esta instalación.
# Uso: ./crear-super-admin.sh [--usuario <nombre>] [--email <correo>]
#
# Es un usuario distinto del admin de la empresa (el que crea ./install.sh): cumplimiento crea a los
# Auditores y relaja el enmascarado de la 057. La contraseña la genera el backend (no el instalador) y
# se muestra acá UNA sola vez: no se guarda en .env, ni en ningún archivo, ni en los logs. Es
# temporal: el usuario queda obligado a cambiarla en su primer ingreso.
#
# Si ya existe algún super_admin (cualquiera, no solo este usuario) informa y no toca nada: se puede
# volver a correr sin riesgo. Las instalaciones nuevas lo corren solas desde ./install.sh; las que ya
# existían lo corren a mano. Detalle: README, «Usuario de cumplimiento».
set -euo pipefail
cd "$(dirname "$0")"

die() { echo -e "\033[1;31m✗ $1\033[0m" >&2; exit 1; }

USUARIO=cumplimiento
EMAIL=cumplimiento@elea-internal.com   # mismo dominio ficticio que las cuentas de servicio (un TLD real: ".local" no pasa el validador)
while [ $# -gt 0 ]; do
  case "$1" in
    --usuario) [ $# -ge 2 ] || die "Falta el valor de --usuario."; USUARIO="$2"; shift 2 ;;
    --email)   [ $# -ge 2 ] || die "Falta el valor de --email.";   EMAIL="$2";   shift 2 ;;
    -h|--help) sed -n '2,/^set -/p' "$0" | sed '$d;s/^# \{0,1\}//'; exit 0 ;;
    *) die "Opción desconocida: $1 (uso: ./crear-super-admin.sh [--usuario <nombre>] [--email <correo>])" ;;
  esac
done
[ "$USUARIO" != admin ] || die "El usuario de cumplimiento no puede ser 'admin': ese es el administrador de la empresa."

command -v docker >/dev/null || die "Falta Docker."
docker compose version >/dev/null 2>&1 || die "Falta Docker Compose v2."

# Contrato del comando del backend: la contraseña sale por stdout en una línea «PASSWORD=<valor>» y los
# mensajes por stderr (se ven en pantalla tal cual). Exit 0 = creado, 3 = ya hay un super_admin, otro = error.
# `-T`: sin terminal (la salida se captura). La contraseña no viaja por argumentos ni por archivos.
rc=0
salida=$(docker compose exec -T backend python -m src.cli crear-super-admin --username "$USUARIO" --email "$EMAIL") || rc=$?

case "$rc" in
  0) ;;
  3) echo
     echo "  ya hay un super_admin en esta instalación: no se creó ni se cambió nada."
     echo "  (Si se perdió su contraseña, no se recupera desde acá: ver README, «Usuario de cumplimiento».)"
     exit 0 ;;
  *) die "No se pudo crear el usuario (código ${rc}). Si el mensaje de arriba dice «No module named src.cli», la imagen del backend es anterior a este comando: actualizá las imágenes (./install.sh) y volvé a correr ./crear-super-admin.sh." ;;
esac

clave=$(printf '%s\n' "$salida" | sed -n 's/^PASSWORD=//p' | head -n1)
unset salida
[ -n "$clave" ] || die "El comando terminó bien pero no devolvió la contraseña (contrato roto): el backend y este instalador no son de la misma versión. Revisá con ./elea-logs.sh backend antes de reintentar."

echo
echo "================================================================"
echo "  Usuario de cumplimiento creado (rol super_admin)"
echo
echo "    Usuario:     ${USUARIO}"
echo "    Contraseña:  ${clave}"
echo
echo "  ► Se muestra UNA sola vez. Guardala ahora en el gestor de contraseñas"
echo "    de la empresa (no en .env, ni en el repositorio, ni por chat o correo)."
echo "  ► Es temporal: hay que cambiarla en el primer ingreso (el sistema lo exige)."
echo "  ► Entra en el panel: http://localhost:8090"
echo "================================================================"
unset clave
