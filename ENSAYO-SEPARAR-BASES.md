# Ensayo de punta a punta: separar la base del motor (instalador + imagen real)

Fecha: 2026-10-06 · Rama del instalador `cluna-8/fix-separar-bases-motor` (HEAD `fa0246d`) · Rama de elea
`fix-separar-bases-elea` (HEAD `03463a5`) · Docker 28.4.0 / Compose v2.39.2, PC de desarrollo (4 CPU, 11 GB RAM).

**Veredicto:** las tres fases pasan con contenedores reales. El ensayo encontró **4 fallas del procedimiento o de
la documentación** (sección 6) y **1 hallazgo de seguridad** (sección 5). Ninguna se arregló en esta tarea.

## Seguimiento de los puntos abiertos (rama `cluna-8/fix-separar-bases-motor-2`, 2026-10-06)

El resto de este documento es el registro del ensayo y **no se reescribe**; acá queda el estado de cada punto.

| Punto | Estado | Dónde |
|---|---|---|
| §5 `/api/v1/internal/*` alcanzable por `8091` | **Cerrado en el instalador, solo con pruebas sin Docker.** El backend ya no publica puertos; `api-proxy` (Caddy fijado por digest) publica `8091` y responde 404 a todo camino con un segmento `internal` (con o sin secreto, mayúsculas, `//`, `..`, letras codificadas); lo demás pasa. `INTERNAL_ALLOWED_CIDRS=auto` en el backend (la capa de origen la implementa el backend, no este repo). | `docker-compose.yml` (`api-proxy`, `backend`), `proxy/Caddyfile`, `tests/test-proxy.sh` (corre un Caddy real contra un backend de mentira si hay binario), README «Proxy de la API». **No se levantó el compose ni se repitió el §5 con contenedores**: queda para el ensayo con Docker. |
| 6.1 «volver a separar» no funcionaba | **Arreglado.** `./migrar-base-motor.sh --volver-a-separar` (pide `SEPARAR`); el comando pelado en ese estado se niega con un mensaje verdadero; la vuelta B anota la base que se separó; la base vieja se renombra, no se borra. | `migrar-base-motor.sh`, `tests/test-base-motor.sh` («volver a separar…»: el comando sale del texto del propio script y se ejecuta de punta a punta contra el Docker simulado), README. Sin ensayo con contenedores reales. |
| 6.2 el gate de `elea` cuelga sin Postgres | **Abierto, fuera de este repo** (`tests/migration_harness.py`, gate de `elea`). | repo `elea` |
| 6.3 `make docs-refs` ensucia `openapi.json` | **Abierto, fuera de este repo** (`deploy/Makefile`). | repo `elea` |
| 6.4 el motor cachea pedidos idénticos | **Documentado**: la prueba funcional del README pide un texto distinto por pregunta. No es un cambio de comportamiento. | README, «Prueba funcional» |

## 0. Cómo se hizo (y qué NO es idéntico a una instalación completa)

- Proyecto Compose aislado `ensayobases` (volumen `ensayobases_pgdata`, redes `ensayobases_*`), carpetas
  temporales fuera del repo. Un stack a la vez; cada fase terminó con `docker compose down -v --remove-orphans`.
- **Imágenes reales y públicas de ghcr**, sin tocar ninguna:
  - Motor: `ghcr.io/cluna-8/elea-guardian-engine@sha256:1928af9d…` (el digest fijado en `docker-compose.yml:75`;
    la etiqueta `:latest` apunta al mismo digest). Creada el 2026-09-17. **litellm 1.92.0 / litellm-proxy-extras
    0.4.74** (`docker run --entrypoint python … m.version(...)`; coincide con la versión del análisis y con
    `./migrar-base-motor.sh --inventario`).
  - Backend: `elea-guardian-backend:latest` = `sha256:742981ff…`, creada el 2026-09-21; trae `/internal/identity`,
    `/internal/audit`, `/internal/audit/probe` (`backend/src/api/internal.py:161,298,368` en la rama de elea).
  - `nlp-analyzer:latest`, `postgres:16-alpine`, `redis:7-alpine`.
- **Servicios omitidos por memoria** (el dueño dejó 2,3 GB libres): `frontend`, `anythingllm`, `client`,
  `tabular`, `presenton`. Se hizo con (a) una copia del `docker-compose.yml` sin esos servicios (el servicio
  `engine`, `db-engine-init`, `db`, `backend`, `redis`, `nlp-analyzer` quedan **idénticos** al compose del repo) y
  (b) un envoltorio de `docker` que omite `compose up/pull/stop` de los servicios pesados y simula
  `docker exec elea-anythingllm …` (ping, `update-env`, clave de API). **Los scripts bajo prueba son los del
  repo, sin cambios:** `install.sh`, `migrar-base-motor.sh`, `respaldo.sh`, `base-motor.lib.sh`.
  Consecuencia: no se probó el arranque de los cinco servicios omitidos ni que AnythingLLM acepte la
  configuración real. Sí se probó todo lo que toca las bases y la identidad.
- La «instalación vieja» se armó con el instalador **anterior** (`git archive 9754f13`, motor sobre
  `elea_gateway`, sin `db-engine-init`), y se actualizó pisando los archivos versionados con los de la rama
  (equivale a `git pull`) y conservando su `.env`.
- Credenciales de Azure: tomadas de `…/elea/.env` y escritas en el `.env` temporal del ensayo; no se imprimieron
  ni están en este archivo. Los `.env`, los respaldos y los volcados quedaron en el directorio temporal y se borraron.
- Los pedidos al motor se hicieron **dentro del contenedor del motor**, con la llave `svc.anythingllm-provider`
  (`POST http://localhost:4000/v1/chat/completions`, `model=azure-gpt-5.4-mini`, `max_tokens=16`, 1 mensaje corto).
  Cada pedido lleva un sufijo aleatorio: **el motor parece cachear los pedidos idénticos** (gasto 0 y 1–2 s de latencia con los tokens contados: inferido, no se miró el caché); con el mismo texto repetido solo el primero cuesta y llega a Azure (ver 6.4). Los pedidos de la
  tabla de abajo son pedidos únicos, es decir, **uno real a Azure por verificación**.
- Qué se verifica cada vez (`verif.sh`, scratchpad): login de `admin` (HTTP 200 + token), tablas por base, filas de
  `users`/`api_keys`/`audit_logs`, `alembic_version`, cuentas `svc.*`, `GET /v1/models` con cada llave `svc.*` desde
  el motor, gasto por alias, un pedido a `azure-gpt-5.4-mini`, y que `audit_logs` suba en 1.

## 1. Fase (a) — instalación nueva con el instalador nuevo

`cd nueva && ./install.sh` (primera corrida: genera `.env`; se le agregan las credenciales; segunda corrida: instala).

| Medida | Resultado |
|---|---|
| `./install.sh` (2.ª corrida, con imágenes ya locales) | **1 min 45 s** (incluye el primer arranque del motor con base vacía: ~14 s de `prisma migrate deploy`, 127 migraciones) |
| `db-engine-init` | `Exited` (0): creó `elea_engine` |
| Tablas en `elea_gateway` | **21** (todas del Guardian), **0** del motor; sin cambios durante todo el ensayo |
| Tablas en `elea_engine` | **66**, **0 ajenas** al motor |
| Log del motor, marcas `creating baseline migration` / `P3005` / `Resolving migration:` | **0** |
| Login `admin` | HTTP 200, < 1 s |
| Cuentas `svc.*` | `svc.anythingllm-provider`, `svc.tabular`, `svc.presenton` |
| `/v1/models` con cada llave `svc.*` | **200 · 200 · 200** (la identidad viaja por HTTP motor → backend) |
| Pedido a `azure-gpt-5.4-mini` (`max_tokens=16`) | **HTTP 200**, 7 s, 11 prompt + 4 completion tokens, `finish=stop` |
| `audit_logs` | 2 → 3 (fila `gpt-5.4-mini`, `compliance=passed`) |
| Gasto (esperando 62 s) | `anythingllm-provider = 2,625e-05` en `elea_engine` |

Bajada: `docker compose down -v --remove-orphans` en 16,7 s, sin contenedores, volúmenes ni redes del proyecto.

## 2. Fase (c) — M3 (`DISABLE_SCHEMA_UPDATE=true`) arranca normal

Se hizo dos veces, ambas con un `docker-compose.override.yml` junto al compose (como en el análisis §5) y el motor
sobre la **base compartida** con el libro de migraciones completo: la instalación vieja, antes de actualizar (C1),
y la misma base tras la vuelta atrás B (C2, con pedido único).

| | C1 (instalación vieja) | C2 (tras vuelta atrás B) |
|---|---|---|
| Motor `healthy` tras recrearlo | **55 s** | **50 s** |
| Variable dentro del contenedor | `true` | `true` |
| `Running prisma migrate deploy` en el arranque | **0** | **0** |
| Marcas `baseline`/`P3005`/`Resolving` | 0 | 0 |
| Tablas en `elea_gateway` después | **87** (21 + 66), igual que antes | **87** |
| Login / 3 llaves `svc.*` | 200 / 200·200·200 | 200 / — |
| Pedido a `azure-gpt-5.4-mini` | HTTP 200 (con texto repetido: salió del caché, ver 6.4) | **HTTP 200**, texto único, `audit_logs` 10 → 11 |

**Efecto lateral que hay que saber:** con M3 el arranque sí corre `check_prisma_schema_diff` y deja en el log un
`ERROR … prisma schema out of sync with db. Consider running these sql_commands…` con el SQL que el migrador
*habría* ejecutado: **21 `DROP TABLE` (todas las tablas del Guardian: `users`, `audit_logs`, `alembic_version`…)**
y 37 `ALTER TABLE`. Se loguea y no se ejecuta (las 87 tablas siguen ahí), pero ese `ERROR` es normal con M3 y
alguien lo va a ver: sirve de prueba de que, con base compartida, el borrado era el camino por defecto.
M3 solo es válida con la imagen fijada (análisis §5, M1).

## 3. Fase (b) — instalación vieja → instalador nuevo, verificación y vuelta atrás B

### 3.1 Estado de partida (instalador `9754f13`, base compartida)

| Medida | Resultado |
|---|---|
| `./install.sh` viejo | **1 min 25 s** |
| `elea_gateway` | **87 tablas** (21 Guardian + 66 motor); `elea_engine` no existe |
| Datos | 6 usuarios (`admin`, 3 `svc.*`, `tester1`, `tester2`), 3 llaves, `alembic_version=199fe429762a`, `audit_logs=5` |
| Gasto | `anythingllm-provider = 2,625e-05` (3 pedidos; los 2 repetidos salieron del caché) |
| `./migrar-base-motor.sh --inventario` | imagen `…engine:latest`, versión `1.92.0 0.4.74`; tablas del motor ≤ 144 kB |
| `./migrar-base-motor.sh --detectar` | código **0** (hay que migrar) |
| `./migrar-base-motor.sh --dry-run` | imprime los 16 pasos con los nombres reales en 0,03 s, no toca nada |

### 3.2 Actualización: `printf 'MIGRAR\n' | script -qec ./install.sh /dev/null` (el script pide terminal)

| Medida | Resultado |
|---|---|
| `install.sh` completo (detecta → migra → levanta el resto) | **2 min 26 s** |
| Motor parado (corte, incluye 70 s de espera de gasto) | **137 s** («Motor parado ~137 s en total») |
| Copia previa (`respaldo.sh`) | `elea_gateway.dump` 283 919 B, `pg_restore -l` la lee: 174 «tablas» según el script |
| Compuerta de integridad | **«COMPUERTA OK: 66 tablas, mismas filas, mismas llaves y gasto, 0 tablas ajenas»** |
| Verificación automática paso 14 | log sin marcas baseline; las 3 llaves `svc.*` → **200**; `elea_gateway` idéntica a la fotografía previa; `alembic_version` igual |
| `./migrar-base-motor.sh --detectar` después | código **3**; la base trae la marca `separada-de:elea_gateway:2026-10-06` |
| `.env` | `ENGINE_DB=elea_engine`; sin `ENGINE_IDENTITY_URL`/`ENGINE_AUDIT_URL`/`ENGINE_IMAGE` |
| Motor | imagen `…@sha256:1928af9d…`, `DATABASE_URL` → `elea_engine`, `SENTINEL_IDENTITY_URL=http://backend:8000/api/v1/internal/identity` |

### 3.3 Verificación después de actualizar

| Comprobación | Resultado |
|---|---|
| Login `admin` | HTTP 200 (< 1 s) |
| Datos del Guardian | `users=6`, `api_keys=3`, `alembic=199fe429762a` iguales; `elea_gateway` 87 tablas (las del motor viejo siguen = vuelta atrás B posible); `elea_engine` 66, 0 ajenas |
| Llaves `svc.*` **antiguas** (las del `.env` previo, no se reemitieron) | **200 · 200 · 200** por HTTP |
| Pedido único a `azure-gpt-5.4-mini`, `max_tokens=16` | **HTTP 200**, 3 s, 16+9 tokens |
| Auditoría | `audit_logs` 7 → 8 (la fila se escribió por `POST /internal/audit`: la base del motor ya no tiene `audit_logs`) |
| Gasto (esperando 72 s) | `anythingllm-provider`: 2,625e-05 → **7,875e-05** (+5,25e-05 = ese pedido); la fila del `SpendLogs` y la de auditoría coinciden (0,000053) |
| `./migrar-base-motor.sh --gasto` | muestra el gasto por alias de `elea_engine` |
| `./migrar-base-motor.sh --verificar` (1,2 s) | **OK**: 0 tablas ajenas, `alembic_version` igual, 3 llaves 200; la única diferencia con `elea_gateway` es +1 fila en `LiteLLM_SpendLogs` (el pedido nuevo), la esperada |

### 3.4 Vuelta atrás B: `printf 'VOLVER\n' | script -qec "./migrar-base-motor.sh --vuelta-atras" /dev/null`

| Medida | Resultado |
|---|---|
| Duración | **52 s** |
| `.env` | `ENGINE_DB=elea_gateway`, `ENGINE_IDENTITY_URL=`, `ENGINE_AUDIT_URL=`, `ENGINE_IMAGE=…@sha256:1928af9d…` |
| Motor | `healthy`; `DATABASE_URL` → `elea_gateway`; identidad y auditoría por SQL (URL vacías) |
| Llaves `svc.*` | **200 · 200 · 200** |
| Datos del Guardian | `users=6`, `api_keys=3`, `alembic` igual, `elea_gateway` 87 tablas |
| Pedido único a `azure-gpt-5.4-mini` | **HTTP 200**, 3 s; `audit_logs` 8 → 9 |
| Gasto (72 s) | **2,625e-05 → 8,925e-05**: el gasto del pedido hecho sobre `elea_engine` (5,25e-05) **se perdió**, como dice el runbook («se pierde solo el gasto desde el corte»); la auditoría no |
| `elea_engine` | sigue existiendo con 66 tablas (el script no la borra) |

### 3.5 Extra: volver a separar tras la vuelta B, y «estado ambiguo»

1. Tras la vuelta B el script **no deja volver a separar con el comando que él mismo recomienda**: ver 6.1.
2. Con `ENGINE_DB=elea_engine` a mano y `elea_engine` con tablas y marca vieja, `--detectar` da 3 (no hace falta).
   Tras `DROP DATABASE elea_engine`, da 0.
3. **Estado ambiguo reproducido** (por un error mío: levanté el compose nuevo a mano con `elea_engine` vacía):
   el motor arrancó sano sobre `elea_engine` con 66 tablas recién migradas y **la llave `svc.anythingllm-provider`
   dio 401** (las llaves viejas siguen en `elea_gateway`); `--detectar` → código **4** con los tres avisos del
   README; `./install.sh` **se negó** («✗ Estado de las bases ambiguo (código 4): no se actualiza nada»).
   Es exactamente lo que describe el README, «Estado ambiguo».
4. Siguiendo el README (parar el motor, `DROP DATABASE elea_engine`, volver a la base compartida, `ENGINE_DB=elea_engine`
   en `.env`) la **segunda migración** completó: compuerta OK (66 tablas), 3 llaves 200, **2 min 7 s**,
   motor parado ~126 s. Verificación final: login 200, 3 llaves 200, pedido único 200, `audit_logs` 11 → 12,
   gasto acumulado `anythingllm-provider` = 2,0475e-04 en `elea_engine`.
5. `./respaldo.sh` con las dos bases: **1,2 s**; `elea_gateway.dump` 284 892 B (174) y `elea_engine.dump`
   193 737 B (132); `sha256sum -c SHA256SUMS` OK en los dos; carpetas `respaldos/` y `.migracion-motor/` con permiso `700`.

Bajada: `down -v --remove-orphans` en 17,4 s; sin contenedores, volúmenes ni redes `elea-*`/`ensayobases*`.

## 4. Rama de elea (`fix-separar-bases-elea`, `03463a5`)

| Comando | Resultado |
|---|---|
| `make -C deploy docs-refs` (2.ª corrida) | rc 0 en 18,7 s; **`git diff` vacío** (`openapi.json` y `configuration.md: 46 variables` sin cambios) |
| `make -C deploy check-docs` | **`check-docs OK`**, 2 min 12 s: imagen de docs (14 rutas, 0-egress), build estricto, contenido (9 secciones, leyenda 🟢/🟡/🔵), naming neutro (0 menciones), white-label (2 marcas), búsqueda offline, API/config single-source, estructura (template GUÍA/RUNBOOK) y versionado/i18n |
| `docker compose run --rm --no-deps backend pytest tests/ -q` | **2783 passed, 24 skipped** en 642,6 s (10 min 43 s), con `db` y `redis` del compose del repo levantados (proyecto aislado `ensayobases-elea`, prefijo `ensayoelea`) y un `.env` mínimo con secretos generados (ver 6.2); `.env`, contenedores y volumen borrados después |
| `python3 -m pytest harness/tests/test_separar_bases_motor.py -q` (rama de elea; cableado de compose/backup/docs) | **39 passed** en 0,8 s |
| `bash tests/test-base-motor.sh` (instalador, Docker simulado) | **TODO OK** (1,4 s); `bash -n` de los 4 scripts OK |
| `make -C deploy check` (agregado completo de artefactos) | **no se corrió** en esta tarea (el brief pide `check-docs` y la suite); queda para el PR |

## 5. Seguridad: `/api/v1/internal/*` alcanzable desde fuera de la red de Docker (instalador)

El backend del instalador publica `8091:8000` en `0.0.0.0` (`docker-compose.yml:129`; `ss -ltn` →
`0.0.0.0:8091` y `[::]:8091`). Probado **desde el host**, fuera de la red de Docker, el 2026-10-06:

| Ruta (`GET http://localhost:8091/api/v1/internal/…`) | sin cabecera | cabecera incorrecta | `X-Sentinel-Internal: <ENGINE_MASTER_KEY>` |
|---|---|---|---|
| `identity` | 404 | 404 | **422** (llegó al endpoint: falta `key_hash`) |
| `audit/probe` | 404 | 404 | **200** `{"writable":true}` |
| `verify-user` | 404 | 404 | **422** (llegó al endpoint) |
| `/internal/identity` (sin `/api/v1`) | 404 | — | — |

Es decir: **sin la llave maestra, 404** (fail-closed: `backend/src/api/internal.py:120-126`); **con ella, el
endpoint responde desde cualquier máquina que alcance el 8091**. La llave maestra es la única barrera. Con ella
quien la tenga puede: preguntar la identidad de un `key_hash` (confirmar qué llaves existen y de quién son) y
**escribir filas en `audit_logs` por `POST /internal/audit`**. El README ya lo avisa («No exponer `8091` fuera de
la red de confianza»), pero el instalador lo deja publicado a todas las interfaces.

La producción de elea **sí lo cierra**: `deploy/docker/Caddyfile.ingress:20` responde 404 a
`/api/v1/internal/*` antes del `handle /api/*` general. El instalador no tiene ese ingress.

**Propuesta mínima para cerrarlo (no aplicada):** poner delante del backend, en el compose del instalador, un
proxy de una regla que sea el mismo `handle /api/v1/internal/* { respond 404 }` de `Caddyfile.ingress`, publicar
**solo el proxy** en `8091` y dejar el backend sin `ports:`. El motor sigue hablándole a `backend:8000` por la red
interna (las URL de `docker-compose.yml:86-87` no cambian), y el panel y el Hub usan el 8091 como hoy.
Alternativas peores: filtrar por IP de origen en el backend no sirve (el puerto publicado llega con la IP del
puente de Docker, indistinguible de la red interna); publicar `127.0.0.1:8091` rompe el acceso del navegador al panel.
Una opción de código sería servir `/internal/*` en un segundo puerto no publicado (cambia backend y las dos URL).

## 6. Fallas encontradas (no se arreglaron: se reportan)

**6.1 «Para volver a separar: `./migrar-base-motor.sh`» no funciona tras la vuelta B.** La vuelta B deja
`ENGINE_DB=elea_gateway` en `.env`. `migrar-base-motor.sh --si` responde «No hace falta migrar: la base del motor
ya está separada (o no hay motor que migrar)» (`migrar-base-motor.sh:74-77` devuelve 3 y `:179` imprime el mensaje) y sale con 0:
un mensaje **falso** que cierra el camino. El mismo texto está en el cierre de la vuelta atrás
(`migrar-base-motor.sh:395`, y el aviso de `:76`). Para separar de nuevo hay que, a mano: poner `ENGINE_DB=elea_engine` en
`.env`, borrar `ENGINE_IMAGE=`/URLs vacías si se quiere, y `DROP DATABASE elea_engine` (si quedó con tablas y marca,
`--detectar` da 3). Probado: con esos pasos manuales funciona (3.5.4). Arreglo propuesto: que la vuelta B no deje
`ENGINE_DB` igual a `POSTGRES_DB` en un lugar donde `--detectar` lo confunda (p. ej. que `migrar` acepte
`--volver-a-separar`, que reponga `ENGINE_DB`) y que el README diga los pasos reales.

**6.2 El gate de elea `docker compose run --rm --no-deps backend pytest tests/ -q` cuelga sin Postgres.** Sin la
`db` del compose levantada la recolección queda **inmóvil más de 10 minutos** sin imprimir nada (`SIGABRT` con
`PYTHONFAULTHANDLER` muestra `psycopg2.connect` en `tests/migration_harness.py:59` al importar
`tests/integration/test_audit_filtro_estado.py:54`). El `connect_timeout=3` de ese helper no alcanza en un proyecto
aislado donde el nombre `db` no existe. Además, **sin `.env`** (la rama de elea no trae uno) hay centenares de
`ERROR … JWT_SECRET_KEY is missing or too short`. Hubo que levantar `docker compose up -d db redis` y escribir un
`.env` mínimo con secretos generados (ignorado por git, borrado al final). El gate debería decirlo.

**6.3 `make docs-refs` ensucia `openapi.json` la primera vez.** Con la imagen del backend sin construir, el
progreso de BuildKit sale por **stdout** y el `2>/dev/null` de `deploy/Makefile:46-48` no lo captura: el
`openapi.json` quedó con 46 líneas de log al principio (`git diff` +46). La segunda corrida (imagen ya
construida) dejó `git diff` vacío. Quien corra el gate en una máquina limpia compromete un JSON inválido.

**6.4 El motor parece cachear los pedidos idénticos** (gasto 0, auditoría con `cost_usd=0`, 1–2 s de latencia; inferido, no
se inspeccionó el caché ni la cuenta de Azure). Las verificaciones de «gasto» con un texto fijo dan 0 desde el segundo pedido (visto antes de
poner un sufijo aleatorio: de 5 pedidos iguales solo el primero sumó 2,625e-05). **No tiene que ver con separar las
bases** (pasa con la base compartida y con la separada), pero el README de la prueba funcional («el gasto de su
llave tiene que subir») fallaría con una pregunta repetida: conviene decirlo.

## 7. Qué NO se probó

- Los servicios `frontend`, `anythingllm`, `client`, `tabular`, `presenton` (omitidos por memoria) y su corte/arranque
  dentro de `migrar-base-motor.sh` (`levantar_clientes` no encontró contenedores que levantar).
- Vuelta atrás **A** (fallo de la copia o de la compuerta antes de apuntar el motor): no se forzó un fallo.
- Vuelta atrás **C** (restaurar la copia completa) y el borrado de las copias viejas (`--mostrar-limpieza`).
- Una base de producción real: las tablas del ensayo pesan ≤ 144 kB; el servidor de Elea no se midió.
- Una imagen del motor sobre otro litellm (no hay otra imagen) ni M4 (`--use_v2_migration_resolver`).
- El caso destructivo con base propia (que el borrado solo alcance tablas del motor) no se repitió: no hay otra imagen que lo dispare.

## 8. Restos de Docker

Las dos fases (instalador y elea) se bajaron con `docker compose down -v --remove-orphans`: **0 contenedores,
volúmenes y redes** de los proyectos `ensayobases` y `ensayobases-elea`. Se borró la imagen `ensayobases-elea-backend`
que construyó el ensayo. Se dejaron: las imágenes públicas (motor, backend, nlp, postgres, redis, que ya estaban en
la PC) y las etiquetas `sentinel-docs:prod|wl-base|wl-aegis` que reconstruye `check-docs` (nombres compartidos con
otros worktrees; reconstruirlas es parte del gate). Los contenedores `eleae2e-*` y los volúmenes `elea_*` /
`eleae2e_*` (de otros ensayos) no se tocaron. `git status` de la rama de elea: limpio.
