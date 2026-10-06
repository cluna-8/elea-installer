# Evidencia T102 — prueba local del instalador con `ELEA_REDIRECT=1`

Fecha: 7-oct-2026 · PC del owner (Linux, 11 GiB de RAM, Docker Compose 2.39.2) · instalador de la rama `cluna-8/057-t102` (sobre `fb1c818`) ·
código de la aplicación: rama final de la 057 del repo `elea`, `8dfb40c`. **Sin contenido de pedidos, sin contraseñas, sin llaves**: solo comandos, códigos HTTP, tiempos y nombres.

Leyenda: ✅ verificado en esta prueba con contenedores reales · 🟡 verificado con una salvedad que se dice · ⬜ no se probó.

## 0. Preparación

| Qué | Resultado |
|---|---|
| Stack de prueba anterior (`elea057`, de la 057 en desarrollo) | ✅ `docker compose -p elea057 down` **sin `-v`** con los mismos `-f`/`--env-file` que mostraban los labels; el contenedor suelto del panel también. Los volúmenes del stack viejo siguen. |
| Imágenes del candidato | ✅ construidas **en local, sin push**, con los Dockerfile y contextos de `deploy/release/publish-elea.sh` (leído con `DRY_RUN=1`), de a una (`free -h` antes de cada build: disponible 4,1–4,4 GiB, nunca < 1,5 GiB). Los chequeos de importación del script (backend base y `-ext`) pasaron. La mayoría salió de la caché de Docker (mismo contenido que builds previos). |
| Tag del candidato | `2026-10-07` (base) y `2026-10-07-ext`. **No** lleva sufijo `-rc1`: `ELEA_EXT_VERSION` se valida como `AAAA-MM-DD` (`activar-redirect.sh`, `RE_FECHA`) y el compose le agrega `-ext` solo; un tag `…-rc1` no pasa. |
| Ejecutor de la prueba | Directorio propio `~/elea057-t102/Eleia-cli` (copia de `git archive HEAD`); nunca sobre `~/Documents/ELEA` ni sobre una instalación del owner. Un *shim* de `docker` en el `PATH` convierte `docker compose pull` en no-op (las imágenes son locales; un pull real habría bajado las publicadas y pisado los tags locales). El resto de los comandos pasan tal cual. |

Imágenes (ID, tamaño):

| Imagen | Tag | ID | Tamaño |
|---|---|---|---|
| `elea-guardian-backend` | `2026-10-07` / `latest` | `8336edbadcdc` | 859 MB |
| `elea-guardian-backend` | `2026-10-07-ext` | `91d01e34365b` | 862 MB |
| `elea-guardian-frontend` | `2026-10-07` / `latest` | `b29c7cdc86c4` | 787 MB |
| `elea-guardian-frontend` | `2026-10-07-ext` | `26bbbae0d670` | 787 MB |
| `elea-guardian-engine` | `2026-10-07` / `latest` | `c05a9fdd9d5e` | 1,12 GB |
| `elea-guardian-engine` | `2026-10-07-ext` | `1d0922bba0d7` | 1,12 GB |
| `elea-guardian-nlp`, `elea-rag-client`, `elea-tabular` | `2026-10-07` / `latest` | `b4e25338ac1f`, `b09152c938d1`, `d20a88e71a3b` | 669, 376, 381 MB |

El motor de la instalación **sin** redirección es el fijado por digest en `docker-compose.yml` (`…@sha256:1928af9d…`, 1.92.0 / 0.4.74); el `-ext` del motor deriva del motor construido del candidato (cambio esperado del Paso 6).

## 1. Pasos 0–5 (sin redirección)

La prueba no tenía una instalación vieja, así que primero se instaló de cero y después se **armó el estado de partida del Paso 3** (🟡):

1. `./install.sh` (primera corrida: genera `.env`; segunda, con `AZURE_OPENAI_*` en **marcadores** `PLACEHOLDER-T102…`, sin credencial real) → ✅ «Listo. Todo corriendo.» en 1 min 55 s. Creó solo el usuario de cumplimiento (`super_admin`); su contraseña quedó en `~/.elea057-t102/cumplimiento.pass` (modo 600) y no se mostró.
2. Estado de partida: se paró el motor, se copiaron las tablas del motor (`pg_dump | pg_restore`) a la base del Guardian y se borró la base propia del motor. `./migrar-base-motor.sh --detectar` → **código 0** (hay que separar).
3. Paso 0 (notas previas) ✅. Paso 1 `./respaldo.sh` ✅ (`sha256sum -c`: OK).
4. Paso 3 ✅: `--dry-run`, luego `./migrar-base-motor.sh --si` (sin terminal el script se niega a preguntar; el README ahora lo dice) → «Listo. Motor parado ~124 s en total (incluye la espera de gasto)», 126 s de reloj. `--verificar` → **OK** (0 tablas ajenas, misma fotografía, tres llaves de servicio HTTP 200). `./install.sh` → «Listo. Todo corriendo.» en 10 s. `--detectar` → **código 3**.
5. Paso 4 ✅: `./crear-super-admin.sh` repetido → «ya hay un super_admin en esta instalación: no se creó ni se cambió nada». (La creación se hizo en el punto 1, desde el instalador.) El usuario queda con cambio de contraseña obligatorio en el primer ingreso.
6. Paso 5 ✅:

| Comprobación | Resultado |
|---|---|
| `docker compose ps` | todo sano; backend sin puertos; `api-proxy` en `0.0.0.0:8091` |
| `GET /health` · `/docs` | 200 · 200 |
| `/api/v1/internal/identity` (localhost y por la IP de la LAN) | **404** · **404** |
| `/api/v1/redirect/health` | 404 (esperado: la extensión todavía no está) |
| `/openapi.json` → título | «Eleia GuardIAn API» (el README decía «Eleia GuardIAn»: corregido) |
| `./migrar-base-motor.sh --verificar` en una instalación **nueva** | ❌ «No se pudo leer el motor de elea_gateway»: compara contra una base compartida que nunca existió. No es un defecto del runbook (es de actualización); se aclaró en el Paso 5. |

## 2. Pasos 6–7 (con `ELEA_REDIRECT=1`)

- `ELEA_EXT_MIN_VERSION` en `install.sh`: `PENDIENTE-PRIMER-RELEASE` → **`2026-10-07`**. Con el centinela, `ELEA_REDIRECT=1` no se podía activar nunca.
- Respaldo previo (`./respaldo.sh`, dos bases, `sha256sum -c` OK), `ELEA_EXT_VERSION=2026-10-07` y `./install.sh` → ✅ sin errores, **96 s** de reloj completos (incluye el respaldo propio del instalador). El `/health` **no se sondeó** en esta primera activación.
- Verificación del Paso 6 ✅: motor, backend y panel con las imágenes `…:2026-10-07-ext`; entorno de la extensión en `~/.config/elea/redirect.env` modo 600 (fuera del repo, contenido no mostrado); `alembic current` → dos revisiones, las dos `(head)`; `/api/v1/redirect/health` → **200** (`{"status":"ok"}`) al primer intento; `--verificar` → OK; catálogo sembrado: 4 destinos (Azure) activos.
- Paso 7 ✅ (a) salud 200 (b) `/api/v1/internal/{identity,audit}` → **404** desde el servidor **y** desde la IP de la LAN (`http://192.168.0.18:8091`), `/api/v1/redirect/health` 200 (d) panel: «Modelos» → «Routing» → «Redirección» muestra Destinos, Modelos publicados, Reglas, Política, Residencia, Vista previa, Kits, Fidelidad y Costos. Probado con un usuario `admin` de la organización (creado para la prueba, cambio de contraseña forzado incluido; borrado al terminar). La pestaña de la consola del navegador se titula «Eleia Guardian».
- Hallazgo ✅ (runbook corregido): con el `admin` de la organización la lista de «Modelos» y «Destinos» sale **vacía**; los 4 destinos sembrados son de nivel instalación y solo los ve el usuario de cumplimiento (`super_admin`) hasta que los ofrece (`GET /api/v1/catalog/entries`: `admin` → `[]`, `cumplimiento` → 4).
- Alta de un destino ✅ por la API (usuario de cumplimiento, credencial **marcador**): `POST /api/v1/catalog/entries` con credencial nueva → creado, sin jurisdicción de inferencia («sin clasificar»); archivado después (`…/archive`). El alta con valores reales y la credencial de Azure es del owner. 🟡 Los campos y pantallas están en el README (Paso 6, «Falta, en el panel»); no se recorrieron en el navegador con el usuario de cumplimiento.
- ⬜ Conversación de Claude Desktop/Code con un destino Azure, auditoría de un pedido redirigido (postura, alcance), el respaldo de T094 (fila de región borrada por SQL), la migración rota a propósito (T088), `/redirect/health` 503: **no se probaron** (necesitan credencial de Azure o variaciones de la base de prueba que no se hicieron).

## 3. Vuelta atrás nivel 1 (apagar y volver a encender) ✅

| Acción | Resultado |
|---|---|
| Sacar `ELEA_REDIRECT=1` de `.env` + `./install.sh` | 78 s de reloj; sondeo de `/health` cada 0,5 s: **53 s caído** (151 muestras, 102 no-200). `/api/v1/redirect/health` **404**, `/health` 200, `/api/v1/internal/identity` 404; las imágenes siguen siendo `-ext`; `GATEWAY_PLUGINS` y `PLUGIN_PACKAGES` fuera del entorno de la extensión, `ALEMBIC_EXTRA_VERSION_LOCATIONS` presente; `--verificar` OK. |
| Volver a `ELEA_REDIRECT=1` + `./install.sh` | 83 s de reloj; `/health` **6,2 s caído** (161 muestras, 12 no-200). `/api/v1/redirect/health` **200**; los 4 destinos siguen. |

Nivel 2 (restaurar el respaldo con las imágenes base): ⬜ no probado.

## 4. Comando para cambiar la credencial de Azure ✅

`AZURE_OPENAI_API_KEY`, `AZURE_OPENAI_ENDPOINT` y `AZURE_API_VERSION` salen de `.env` hacia el motor y el backend (`docker-compose.yml`, servicios `engine` y `backend`). Comprobado cambiando `AZURE_API_VERSION` y volviendo atrás: `docker compose up -d engine backend` recrea los dos con el `.env` nuevo, conserva las imágenes `-ext` y la salud vuelve a 200 (`restart` no relee `.env`).

## 5. Consumo de la instalación de prueba

Memoria (`docker stats`, en reposo, 11 contenedores): ~2,3 GiB en total (motor ~1,0 GiB; analizador de datos personales ~0,3 GiB; presentaciones ~0,4 GiB; AnythingLLM ~0,2 GiB; el resto < 0,15 GiB cada uno). CPU ≈ 0 en reposo. Disco: volúmenes `eleia-cli_*` ≈ 111 MB (base de datos 83 MB, presentaciones 27 MB, AnythingLLM 1 MB) y `respaldos/` 3,6 MB; las imágenes suman unos 7 GB nominales (con capas compartidas entre tags, menos).

## 6. Qué cambió en el instalador por esta prueba

- `install.sh`: `ELEA_EXT_MIN_VERSION="2026-10-07"` (con comentario).
- `README.md`: marcadores completados; estado de verificación honesto (qué se probó y qué no); datos por pantalla/campo para los destinos y comando para recrear tras cambiar la credencial; `--si` sin terminal; título de la consola; aclaración de `--verificar` en instalaciones nuevas; tiempos medidos.
- Tests (sin Docker): `tests/test-runbook-actualizar.sh`, `tests/test-runbook-redirect.sh`, `tests/test-redirect-optin.sh` pasan a exigir fecha en el mínimo, sin marcadores, README coherente con `install.sh` y este archivo.
