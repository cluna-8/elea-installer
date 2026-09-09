#!/usr/bin/env bash
# elea-logs.sh — comando propio de diagnóstico (spec 043 US6, T062).
#
# `docker compose logs engine` muestra el banner y las trazas reales de LiteLLM
# (LITELLM_LOG=INFO en el compose) — un operador que sigue el mensaje de error de
# `install.sh` ("Revisá: docker compose logs engine") termina leyendo el nombre del motor
# en texto plano, justo lo que la Constitución VII prohíbe exponer. Este wrapper corre el
# mismo comando pero sanea la salida antes de mostrarla — mismo criterio que
# `sanitize_engine_error()` del backend (backend/src/services/error_sanitizer.py), del
# lado del instalador.
#
# Uso: ./elea-logs.sh [servicio] [args de "docker compose logs"...]
# Sin argumentos: logs de todos los servicios. Con un nombre de servicio ("engine",
# "backend", "client", "anythingllm", ...): logs de ese servicio.
set -euo pipefail
cd "$(dirname "$0")"

sanear() {
  # Mismo nombre neutro que ya usa el backend (`error_sanitizer.sanitize_engine_error`,
  # "Sentinel Gateway") — no se inventa un tercer nombre acá. Nota: ese nombre es el del
  # producto base compartido, previo a esta sesión; si en algún momento se decide
  # renombrarlo (p. ej. a "Guardian" a secas), este script debe actualizarse junto con
  # `backend/src/services/error_sanitizer.py`, no por separado.
  sed -E 's/LiteLLM/Sentinel Gateway/g; s/litellm/sentinel-gateway/g'
}

docker compose logs "$@" 2>&1 | sanear
