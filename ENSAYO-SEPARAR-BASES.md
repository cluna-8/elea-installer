# Ensayo de punta a punta: separar la base del motor (instalador + imagen real)

Fecha: 2026-10-06 · Rama del instalador `cluna-8/fix-separar-bases-motor` (HEAD `fa0246d`) · Rama de elea
`fix-separar-bases-elea` (HEAD `03463a5`) · Docker 28.4.0 / Compose v2.39.2, PC de desarrollo (4 CPU, 11 GB RAM).

**Veredicto:** las tres fases pasan con contenedores reales. El ensayo encontró **4 fallas del procedimiento o de
la documentación** (sección 6) y **1 hallazgo de seguridad** (sección 5). Ninguna se arregló en esta tarea.

## Seguimiento de los puntos abiertos (rama `cluna-8/fix-separar-bases-motor-2`, 2026-10-06)

El resto de este documento es el registro del ensayo y **no se reescribe**; acá queda el estado de cada punto.

| Punto | Estado | Dónde |
|---|---|---|
| §5 `/api/v1/internal/*` alcanzable por `8091` | **Cerrado en el instalador, solo con pruebas sin Docker.** El backend ya no publica puertos; `api-proxy` (Caddy fijado por digest) publica `8091` y responde 404 a todo camino con un segmento `internal` (con o sin secreto, mayúsculas, `//`, `..`, letras codificadas); lo demás pasa. `INTERNAL_ALLOWED_CIDRS=auto` en el backend (la capa de origen la implementa el backend, no este repo). | `docker-compose.yml` (`api-proxy`, `backend`), `proxy/Caddyfile`, `tests/test-proxy.sh` (corre un Caddy real contra un backend de mentira si hay binario), README «Proxy de la API». **Verificado con contenedores reales en la sección 9** (2026-10-06): 404 desde afuera, con y sin la llave; desde adentro funciona. |
| 6.1 «volver a separar» no funcionaba | **Arreglado.** `./migrar-base-motor.sh --volver-a-separar` (pide `SEPARAR`); el comando pelado en ese estado se niega con un mensaje verdadero; la vuelta B anota la base que se separó; la base vieja se renombra, no se borra. | `migrar-base-motor.sh`, `tests/test-base-motor.sh` («volver a separar…»: el comando sale del texto del propio script y se ejecuta de punta a punta contra el Docker simulado), README. **Ensayado con contenedores reales en la sección 9** (migrar → vuelta atrás B → volver a separar). |
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

## 9. Segunda ronda con contenedores reales: el proxy y «volver a separar» (rama `cluna-8/fix-separar-bases-motor-2`, HEAD `bb6ef60`)

Fecha 2026-10-06. Rama del instalador `cluna-8/fix-separar-bases-motor-2` (HEAD `bb6ef60`); la rama de elea
(`fix-separar-bases-elea-2`, HEAD `b52f69b`) solo se leyó para citar código: no se tocó. Docker 28.4.0 / Compose
v2.39.2, la misma PC (4 CPU, 11 GB; 2,3–4,1 GB disponibles durante el ensayo). **Veredicto: (a) y (b) pasan.**
El ensayo no encontró fallas nuevas del instalador; sí **3 puntos a saber** (9.5).

### 9.1 Cómo se hizo (y qué NO es idéntico a una instalación completa)

- Proyecto aislado `ensayobases` (`COMPOSE_PROJECT_NAME`), carpetas temporales fuera del repo, **un stack a la vez**,
  cada uno terminó con `docker compose down -v --remove-orphans`. Los scripts bajo prueba son los de la rama, sin
  cambios (`install.sh`, `migrar-base-motor.sh`, `respaldo.sh`, `base-motor.lib.sh`, `proxy/Caddyfile`).
- **Sin descargas**: un envoltorio de `docker` dejó pasar todo salvo `compose pull` (se omite) y los servicios
  `anythingllm`, `tabular` y `presenton` (se omiten en `up/stop`; `docker exec elea-anythingllm …` se simula). Las
  imágenes son las que ya estaban en la PC: motor `…@sha256:1928af9d…` (el digest fijado en `docker-compose.yml:75`),
  backend `:latest` = `sha256:7cf1910a…` (creada el **2026-09-21**), `caddy:2-alpine@sha256:5f5c8640…` (el de
  `docker-compose.yml:177`), panel `:latest` y Hub `:latest` (2026-09-21). Quedan **sin probar** `anythingllm`,
  `tabular` y `presenton`.
- **Incidente del envoltorio (mío, sin efecto en los resultados):** al levantar el panel a mano (`docker compose up -d
  frontend`) el envoltorio le quitó el nombre «frontend» y quedó un `up -d` sin servicios, que levantó **todos**,
  incluidos `anythingllm`, `tabular` y `presenton`. Los vi en `docker ps` de la verificación A5 de la fase 1, los paré
  con `docker compose stop` en ~1 min y el envoltorio ya no deja `up`/`stop` sin servicios. Nunca hubo dos stacks.
- Credenciales de Azure: tomadas de `…/elea/.env` y escritas en el `.env` temporal del ensayo; no se imprimieron
  ni están acá. Los scripts de verificación solo imprimen códigos y conteos, jamás una llave.
- El panel se levantó (había 2,1 GB disponibles; el criterio era >1,5 GB) y el Hub también.
- **Pedido al gateway**, desde el host, por el puerto publicado: `POST http://localhost:8091/api/v1/gw/v1/messages`,
  formato Anthropic, cabeceras `x-api-key: <llave svc.anythingllm-provider>` + `anthropic-version: 2023-06-01`,
  `model=azure-gpt-5.4-mini`, `max_tokens=16`, un mensaje con sufijo aleatorio (el motor cachea pedidos idénticos,
  ver 6.4). La ruta es `backend/src/api/gateway.py:1636` (`/gw/v1/messages`) y la llave `sk-sentinel-…` en una cabecera
  de auth lo manda al motor (`_detect_mode_and_key`, `gateway.py:1249`).

### 9.2 Fase (a) — instalación nueva con el instalador nuevo (`./install.sh`, dos corridas)

`./install.sh` 2.ª corrida: **1 min 41 s**, rc 0. `elea_gateway` 21 tablas (0 del motor), `elea_engine` 66 tablas;
motor con `DATABASE_URL` → `elea_engine` y `SENTINEL_IDENTITY_URL=http://backend:8000/api/v1/internal/identity`
(`docker-compose.yml:86`); login `admin` 200; las tres llaves `svc.*` → `/v1/models` 200·200·200.

**Desde afuera** (host, `http://localhost:8091`, el único puerto de la API publicado): 12 caminos × {sin cabecera,
cabecera incorrecta, `X-Sentinel-Internal: <ENGINE_MASTER_KEY>`} = 36 pedidos, **todos 404**:

| Camino (GET) | sin cab. | cab. mala | con la llave |
|---|---|---|---|
| `/api/v1/internal/identity` · `/audit/probe` · `/verify-user` · `/audit` | 404 | 404 | **404** |
| `/api/v1/INTERNAL/identity` (mayúsculas) · `/api/v1//internal/identity` · `//api/v1/internal/identity` | 404 | 404 | **404** |
| `/api/v1/x/../internal/identity` (`--path-as-is`) · `/api/v1/%69nternal/identity` (letra codificada) | 404 | 404 | **404** |
| `/api/v1/internal` · `/api/v1/internal/` · `/internal/identity` | 404 | 404 | **404** |
| `POST /api/v1/internal/audit` con la llave | — | — | **404** |

Control (lo demás pasa): `/health` 200, `/docs` 200, `POST /api/v1/users/login` con cuerpo vacío 422. Antes, con el
instalador anterior (backend publicado directo), el mismo pedido con la llave daba **`identity` 422 y `audit/probe` 200**
desde afuera (visto en la instalación vieja de la fase 2, antes de actualizar): el §5 queda cerrado.
Esos 36 pedidos **no llegaron al backend**: su log solo registra los 11 pedidos hechos desde adentro o por la IP
interna (`identity` 404×2 y 422×2, `audit/probe` 404×2 y 200×2, `verify-user` 404×2 y 422×1) y el tráfico real del motor (abajo), ni uno más.

**Desde adentro** (contenedor del motor → `http://backend:8000`, sin pasar por el proxy):

| GET | sin cab. | cab. mala | con la llave |
|---|---|---|---|
| `/api/v1/internal/identity` | 404 | 404 | **422** (llegó al endpoint: falta `key_hash`) |
| `/api/v1/internal/audit/probe` | 404 | 404 | **200** |
| `/api/v1/internal/verify-user` | 404 | 404 | **422** |

Y en uso real: el backend registró del motor `GET /internal/identity` 200 ×3 (una por llave `svc.*`) y `POST
/internal/audit` 200 ×1 (la fila del pedido de abajo).

**Gateway desde afuera:** `POST /api/v1/gw/v1/messages` → **HTTP 200**, 3,7 s, `type=message`, `stop_reason=end_turn`,
`usage` 19 entrada + 4 salida; `audit_logs` 2 → **3** (fila `gpt-5.4-mini`, `compliance=passed`, `cost_usd=0,000032`).
**Panel** `:8090` 200 (servidor de desarrollo del panel, `npm run dev`), **Hub** `:8095` 200; `:8097/templates` 403 sin
sesión (es lo previsto: solo admins con sesión, `docker-compose.yml`, comentario del puerto 8097). Puertos publicados al
host: `8091` (`elea-api-proxy`), `8090` (panel), `8095` y `8097` (Hub); **`elea-backend` publica 0** (`docker port` vacío).

Bajada: `down -v --remove-orphans` en 26 s.

### 9.3 Fase (b) — instalación vieja → migrar → vuelta atrás B → volver a separar

Instalación **vieja** con el instalador anterior (`git archive 9754f13`): `./install.sh` 1 min 31 s; `elea_gateway` **87
tablas** (21 + 66 del motor), `elea_engine` no existe; `users=4`, `api_keys=3`, `audit_logs=3`, `alembic=199fe429762a`;
motor sobre `…engine:latest` con `DATABASE_URL` → `elea_gateway`; `--detectar` → **0**; `--inventario` → litellm
**1.92.0 / 0.4.74** (la misma que el análisis). Pedido a `azure-gpt-5.4-mini` por el gateway: HTTP 200, 3,6 s, `audit_logs` 2 → 3.

| Paso | Comando | Duración | Resultado verificado |
|---|---|---|---|
| **Migrar** (actualización: se pisan los archivos con los de la rama y se conserva el `.env`) | `printf 'MIGRAR\n' \| script -qec ./install.sh /dev/null` | **2 min 48 s** (motor parado ~155 s) | «COMPUERTA OK: 66 tablas, mismas filas, mismas llaves y gasto, 0 tablas ajenas»; los 16 pasos; `--detectar` → **3**; marca `separada-de:elea_gateway:2026-10-06`; `.env`: `ENGINE_DB=elea_engine`, sin URL vacías |
| Verificar | `./migrar-base-motor.sh --verificar` | 1–2 s | **OK**: 0 ajenas, misma fotografía, `alembic_version` igual, las 3 llaves 200 |
| **Vuelta atrás B** | `printf 'VOLVER\n' \| script -qec "./migrar-base-motor.sh --vuelta-atras" /dev/null` | **59 s** | motor `healthy` sobre `elea_gateway`; `.env`: `ENGINE_DB=elea_gateway`, `ENGINE_IDENTITY_URL=`, `ENGINE_AUDIT_URL=`, `ENGINE_IMAGE=…@sha256:1928af9d…`; llaves 200·200·200; `elea_engine` sigue con 66 tablas |
| Comando pelado tras la vuelta B | `./migrar-base-motor.sh` | — | **se niega (rc 1)** con un mensaje verdadero: «El motor está sobre la base compartida elea_gateway (vuelta atrás B activa o .env viejo), no separado. Para separarlo otra vez: ./migrar-base-motor.sh --volver-a-separar» (`migrar-base-motor.sh:176`). El 6.1 de este documento («dice que ya está separada») **ya no ocurre** |
| `--volver-a-separar --dry-run` | | 0 s | los 16 pasos, y en el 9: «si `elea_engine` existe con tablas… RENAME TO `elea_engine_vieja_<fecha>` # se conserva, no se borra» (`migrar-base-motor.sh:274`) |
| **Volver a separar** | `printf 'SEPARAR\n' \| script -qec "./migrar-base-motor.sh --volver-a-separar" /dev/null` | **2 min 20 s** (motor parado ~138 s) | la base vieja quedó como `elea_engine_vieja_20261006135837` (66 tablas, **no se borró**); «COMPUERTA OK: 66 tablas…»; `--detectar` → **3**; `--verificar` **OK** con las 3 llaves 200 |

Estado de los datos en cada punto (`users` / `api_keys` / `alembic`, `elea_gateway` siempre **87 tablas**):

| Punto | `users` · `api_keys` · `alembic` | `audit_logs` | `elea_engine` | `ENGINE_DB` / identidad |
|---|---|---|---|---|
| Vieja | 4 · 3 · `199fe429762a` | 3 | no existe | `elea_gateway` / SQL |
| Migrada | 4 · 3 · `199fe429762a` | 4 (+1 `license_evidence`, no tráfico) → 5 con el pedido | 66 tablas, 0 ajenas, 6 llaves | `elea_engine` / HTTP |
| Vuelta B | 4 · 3 · `199fe429762a` | 5 → **6** con el pedido (por SQL: no hubo `POST /internal/audit`) | 66, intacta | `elea_gateway` / SQL (URL vacías) |
| Vuelta a separar | 4 · 3 · `199fe429762a` | 6 → **7** con el pedido | 66, 0 ajenas; la vieja renombrada aparte | `elea_engine` / HTTP |

**(a) repetido en los tres estados con el instalador nuevo** (migrada, tras la vuelta B, tras volver a separar), mismos
36 + 1 pedidos desde afuera: **todos 404**, con y sin llave; desde adentro `identity` 404/404/422, `audit/probe`
404/404/200, `verify-user` 404/404/422 en los tres; `/health` 200; pedido Anthropic por el gateway desde afuera
**HTTP 200** en los tres (24 s el primero tras migrar, con el backend recién recreado y el motor en frío; 3,1 s y 3,0 s después;
19–22 tokens de entrada y 4 de salida). Panel `:8090` y Hub `:8095` 200 en los tres. En el estado «vuelta B» el
plano interno sigue cerrado desde afuera aunque el motor ya no lo use (URL vacías): el proxy no depende de eso.

**Gasto por llave** (`--gasto`, ≥ 70 s después de cada pedido):

| Punto | `anythingllm-provider` en la base del motor |
|---|---|
| Migrada (pedido de antes + pedido de después) | 6,75e-05 (2 filas en `LiteLLM_SpendLogs`) |
| Vuelta B (la base compartida: no tiene el pedido hecho sobre `elea_engine`) | `elea_gateway` 6,525e-05 (2 filas: el de antes de migrar + el de la vuelta B) |
| Vuelta a separar | **9,75e-05** (3 filas) |

Es el comportamiento del runbook: el gasto contado en `elea_engine` entre «migrar» y «vuelta B» **no vuelve a la base
compartida**; sigue entero en la base vieja renombrada (`elea_engine_vieja_…`: 2 filas, 6,75e-05). La auditoría no se pierde.

Bajada: `down -v --remove-orphans` en 27 s.

### 9.4 Qué cierra este ensayo del seguimiento

| Punto | Estado |
|---|---|
| §5 `/api/v1/internal/*` alcanzable por `8091` | **Cerrado y verificado con contenedores**: 404 desde afuera con y sin la llave, en los cuatro estados (nueva, migrada, vuelta B, vuelta a separar); desde adentro funciona (identidad y auditoría del motor) |
| 6.1 «volver a separar» | **Verificado de punta a punta con contenedores**, incluido el mensaje del comando pelado y que la base vieja se renombra |
| 6.2, 6.3 | Siguen abiertos, fuera de este repo (no se corrieron las suites de elea: no cambió código) |
| 6.4 | Visto otra vez: con un texto único por pedido, los 5 pedidos del ensayo (uno por estado y la instalación vieja) sumaron gasto |

### 9.5 Tres cosas a saber (no se arreglaron)

1. **La capa 2 (`INTERNAL_ALLOWED_CIDRS=auto`, `docker-compose.yml:155`) no actúa con la imagen publicada del backend.**
   Esa variable solo existe en el código de la rama de elea (`backend/src/api/internal.py:138`, `b52f69b`); la imagen
   `:latest` de la PC (2026-09-21) no la trae (`grep -r INTERNAL_ALLOWED_CIDRS /app/src` dentro de la imagen: 0
   resultados). Prueba: desde el host, por la IP interna del contenedor del backend (`:8000`, que el host sí alcanza
   por el puente), `GET /internal/identity` con la llave dio **422** y `audit/probe` **200**. No es un hueco de la LAN
   (el backend no publica ningún puerto y esa IP solo se alcanza desde el propio equipo Docker), pero **hoy la
   defensa es el proxy (capa 3) más no publicar el 8000**; la capa 2 queda para cuando se publique un backend que la traiga.
2. **El panel responde 200, pero es el servidor de desarrollo** (`docker-compose.yml:199`, puerto 5173 → 8090): solo se
   comprobó el código HTTP de `/`, no que el panel funcione contra la API ni el Hub contra AnythingLLM (omitido).
3. **`test-proxy.sh` sigue sin correr el Caddy real en una máquina sin el binario** (`salta no hay binario caddy`); este
   ensayo sí lo corrió, en su contenedor (`caddy:2-alpine@sha256:5f5c8640…`), con el `proxy/Caddyfile:21-22` de la rama
   (`@interno path_regexp "(?i)(^|/)internal(/|$)"` → `respond @interno 404`) y `reverse_proxy backend:8000` (`:25`).

### 9.6 Qué NO se probó en esta ronda

`anythingllm` / `tabular` / `presenton` (omitidos; AnythingLLM simulado) y el corte/arranque de esos servicios dentro del
migrador; el flujo del Hub contra AnythingLLM; las vueltas atrás **A** y **C**; una base de producción real; M4. Las
imágenes no se volvieron a bajar del registro (`compose pull` se omitió): el ensayo corrió con las de la PC, que son las
que ya estaban allí (el digest del motor, el de Caddy y el backend/panel/Hub del 2026-09-21).
Suites sin Docker corridas al terminar: `bash tests/test-base-motor.sh` → **TODO OK**; `bash tests/test-proxy.sh` → **TODO OK**
(el Caddy real se salta por falta de binario; ver arriba); `bash -n` de los 4 scripts OK. No cambió código: las suites del
backend, del panel y del Hub no se corrieron.

### 9.7 Restos de Docker

`down -v --remove-orphans` al terminar cada stack: **0 contenedores `elea-*`, 0 volúmenes y 0 redes** de `ensayobases`, y
ningún puerto 8090/8091/8095/8097 en escucha. Los 6 contenedores `eleae2e-*` que ya estaban (de otros ensayos) no se tocaron.
No se descargó ninguna imagen ni se creó ninguna. Se borraron las carpetas temporales con los `.env`, los volcados y los
respaldos, y los `/tmp/elea_svc_*.json` que escribe `install.sh` (contenían llaves).
