# Elea — instalador

Paquete de instalación: Guardian (gobernanza IA) + cliente RAG + AnythingLLM, todo en
un solo `docker compose`. Las imágenes ya están construidas — este repo no tiene el
código fuente del Guardian, solo la configuración para levantarlo.

## Instalación

```bash
./install.sh
```

Primera corrida: genera `.env` con secretos y te pide completar las credenciales del
modelo (Azure OpenAI). Completalas y volvé a correr `./install.sh` — esa segunda vez
levanta todo, crea el usuario admin, conecta AnythingLLM al motor y te muestra la
contraseña de admin generada.

Repo e imágenes públicos (desde el 14-sep-2026): no hace falta ningún token. Solo si la
descarga de imágenes fallara, el script pide usuario y token de GitHub (`read:packages`).

## Agregar gente que va a probar

```bash
./create-tester.sh ana.gomez ana.gomez@elea.com 50
```

(usuario, email, presupuesto en USD/mes — el presupuesto es opcional). Te devuelve la
contraseña generada — cada persona entra a `http://localhost:8095` con la suya, sesiones
aisladas entre sí.

## URLs

| Qué | URL |
|---|---|
| Eleia Hub (chat con documentos, planillas, presentaciones) | http://localhost:8095 |
| Plantillas de presentaciones (solo admins, misma sesión del Hub) | http://localhost:8097/templates |
| Panel del Guardian (admin, visual) | http://localhost:8090 |
| API del Guardian (Swagger) | http://localhost:8091/docs |

## Imágenes que publica el equipo (registro `ghcr.io/cluna-8`)

`elea-guardian-backend`, `elea-guardian-frontend`, `elea-guardian-engine`, `elea-guardian-nlp`,
`elea-rag-client` (Eleia Hub) y, desde la spec 050, **`elea-tabular`** (motor de planillas).
Presenton y AnythingLLM son imágenes públicas fijadas por digest/versión, **y el motor
(`elea-guardian-engine`) también va fijado por digest** en `docker-compose.yml` (desde oct-2026):
ni `./install.sh` ni `docker compose pull` lo cambian solos. Subirlo es una tarea deliberada, con
copia previa: ver «Subir la versión del motor».

**Publicarlas siempre con el script del repo `elea`**, nunca con `docker build` a mano:

```bash
VERSION=2026-09-14 deploy/release/publish-elea.sh          # todas
ONLY="backend rag-client" deploy/release/publish-elea.sh   # solo algunas
```

Motivo (encontrado el 14-sep-2026 probando este instalador desde cero): el backend construido
con `backend/Dockerfile` (el de desarrollo) arranca en bucle con `No module named 'extensions'`,
porque en desarrollo esa carpeta llega por un bind mount que la imagen no tiene. La imagen
distribuible sale de `backend/Dockerfile.standalone`; el script fija eso y lo verifica antes de
subir. Por cada imagen imprime una línea `PINNED <nombre>=<imagen>@sha256:…`: esa es la referencia
que se pega para fijar una versión (el motor, ver más abajo). Después de publicar, probar este instalador desde cero (carpeta nueva, `docker compose
down -v` si había algo) antes de sincronizarlo a Azure DevOps.

## Después de instalar

1. **Plantilla corporativa de presentaciones**: entrar al Hub como `admin`, abrir la pestaña
   "Plantillas" (o `http://localhost:8097/templates`), subir el `.pptx` corporativo, aceptar las
   fuentes de respaldo y confirmar. Tarda unos 5 minutos por 6 diapositivas. Después aparece
   primera en el formulario "Crear presentación".
2. **Planillas con encabezados abreviados** (exportaciones de SAP): en el espacio de planillas,
   clic en cada columna para escribir qué significa. Mejora las respuestas.
3. **Límites conocidos**: la sesión del Hub vive en memoria (reiniciar el contenedor cierra las
   sesiones); las planillas `.xls` viejas no se aceptan (solo `.csv` y `.xlsx`); el gasto de los
   motores se atribuye a sus cuentas `svc.*`, no a la persona.

## Actualizar una instalación existente (servidor de Elea)

El mismo `./install.sh` sirve para actualizar: no borra datos, no toca volúmenes ni el `.env`.
Probado el 14-sep-2026 sobre una instalación previa con cuentas de servicio ya creadas.

```bash
cd ~/Eleia-cli
git pull                                   # este repo (GitHub público; Azure DevOps solo de respaldo)
echo -n "$TOKEN" | docker login ghcr.io -u cluna-8 --password-stdin   # si el token venció
./install.sh
```

Qué hace en ese caso, **antes de tocar nada**: hace una copia de las dos bases (`./respaldo.sh`) y,
si la instalación todavía tiene la base del motor compartida con el Guardian, la separa
(`./migrar-base-motor.sh`, ver «Separar la base del motor»: pide escribir `MIGRAR` y tiene un corte
corto del motor). Después, descarga las imágenes nuevas y recrea solo los contenedores cuya imagen o
configuración cambió (los espacios, documentos y usuarios sobreviven); las cuentas `svc.*` que ya
existen se reutilizan (se revoca su llave anterior y se emite una nueva, porque Guardian permite
una sola llave activa por cuenta); crea `svc.tabular` y `svc.presenton`; reconecta AnythingLLM al
motor; y borra el contenedor viejo de DB-GPT (`exact-analysis-engine`) que ya no existe en este
compose. Las variables viejas del `.env` (`MASKING_VIRTUAL_KEY`, `DBGPT_ENGINE_VIRTUAL_KEY`) quedan
sin uso; se pueden borrar a mano.

Al terminar, las sesiones del Hub se cierran (viven en memoria): cada persona vuelve a entrar.
Verificar: entrar al Hub, ver las tres secciones (documentos, planillas, presentaciones) y, como
`admin`, abrir `http://<servidor>:8097/templates`.

## Base propia del motor, respaldo y versión del motor

### Qué cambió (oct-2026) y por qué

El motor tiene su **propia base** (`ENGINE_DB`, por defecto `elea_engine`), separada de la del Guardian
(`POSTGRES_DB`, `elea_gateway`). Motivo: al arrancar, el motor compara su base con su esquema y **borra las
tablas que no conoce**. Con la base compartida eso se dispara con una restauración parcial o con una
imagen del motor de otra versión, y se llevaba `users`, `audit_logs` y `alembic_version`: reproducido en
un ensayo (21 tablas del Guardian → 0 en ~80 s) y el `/health` del backend sigue en 200 aunque la base
esté vacía, así que ningún monitoreo lo ve. Con base propia, el mismo borrado solo puede alcanzar tablas del motor.

Qué hace el instalador ahora:

| Pieza | Qué hace |
|---|---|
| `db-engine-init` (en `docker-compose.yml`) | Servicio de un solo disparo, idempotente: crea `ENGINE_DB` si no existe. Sirve en instalación nueva y al actualizar con datos. El motor espera a que termine. |
| `SENTINEL_IDENTITY_URL` / `SENTINEL_AUDIT_URL` del motor | Con la base separada, la identidad de las llaves y la auditoría viven en la base del Guardian: el motor las pide por HTTP interno al backend (protegido con `ENGINE_MASTER_KEY`). **Sin ellas todas las llaves darían 401** y el tráfico dejaría de auditarse: por eso se cambian juntas con la base. El backend pasa a ser dependencia del motor (si está caído, la identidad falla cerrada). |
| `ENGINE_IMAGE` (opcional, `.env`) | Reemplaza la imagen fijada del motor. Vacío = la del `docker-compose.yml`. |
| `./respaldo.sh` | Copia de las dos bases (ver abajo). |
| `./migrar-base-motor.sh` | Pasa una instalación vieja (base compartida) a base propia, con vuelta atrás. |

Aviso de seguridad: el puerto `8091` del backend está publicado y `/api/v1/internal/*` (identidad y
auditoría del motor) no tiene otra protección que el secreto `ENGINE_MASTER_KEY`. No exponer `8091` fuera
de la red de confianza; es lo que ya pasaba con el resto de la API.

**Instalación nueva**: no hay nada que hacer; `./install.sh` crea las dos bases solo.

**Actualización de una instalación existente con base compartida**: ver el runbook. No usar
`docker compose up -d` a mano después de bajar el compose nuevo sin haber migrado: el motor arrancaría
sobre una base vacía (las llaves del motor viejo quedarían en `elea_gateway`). Siempre `./install.sh`
o `./migrar-base-motor.sh`.

### Separar la base del motor — runbook de producción (VPN + consola web)

> **Estado de la verificación.** El procedimiento se ensayó **a mano** con Docker el 06-oct-2026 (ida,
> vuelta atrás B y C, instalación nueva, y el caso destructivo). Estos scripts lo automatizan y se
> probaron contra un Docker simulado (`bash tests/test-base-motor.sh`), **no** contra contenedores
> reales: falta el ensayo de punta a punta con ellos (tarea «ensayo», con la compuerta del dueño). Los
> tiempos de abajo son de una sola corrida en una PC con datos de prueba; el servidor de Elea no se midió.

**Ventana.** Medido en el ensayo: ≈ **62 s** con el motor parado (parar → crear base → copiar → motor
sano), con tablas de ~13 MB; con una tabla de gasto de 1,7 GB la copia sumó ~40 s más (medido aparte).
El script agrega una espera de **70 s** antes de parar el motor, porque el motor vuelca el gasto por
lotes (`--espera-gasto 0` la saltea; no se verificó si un `stop` descarga el lote pendiente). Esperable:
**≈ 2,5 min** con el Hub, planillas y presentaciones sin servicio. Reservar **30 min**: el peor caso del
ensayo (copia mal hecha estando ya separado) fue 20 min de arranque del motor, y para eso existe la compuerta.

**Antes de la ventana (sin corte)** — conectado por VPN, en la consola web del servidor:

```bash
cd ~/Eleia-cli
git pull origin main                      # trae el compose nuevo y los scripts
set -a; source .env; set +a

# 1. Qué motor corre (imagen, versión) y cuánto pesan sus tablas (define cuánto dura la copia)
./migrar-base-motor.sh --inventario
#   El análisis se hizo sobre «1.92.0 0.4.74». Si da otra versión, PARAR y consultar:
#   todo habría que releerlo contra esa versión.

# 2. Que el compose nuevo es válido con tu .env, y el plan con tus nombres reales (no toca nada)
docker compose config -q && echo "compose OK"
./migrar-base-motor.sh --dry-run
```

**En la ventana:**

```bash
cd ~/Eleia-cli
./migrar-base-motor.sh                    # pide escribir MIGRAR; en ~2,5 min termina con «Listo»
```

Qué hace, en orden (el `--dry-run` los imprime con los nombres reales):

1. *Previa*: baja la imagen fijada del motor; anota la imagen en marcha (`.migracion-motor/imagen-anterior`);
   **copia completa de las dos bases** y la verifica (`respaldos/<fecha>/`); comprueba que el libro de
   migraciones del motor esté completo.
2. *Corte*: para Hub, planillas, presentaciones y AnythingLLM; espera 70 s; para el motor (el contenedor
   viejo queda parado, no se borra); fotografía previa (filas por tabla, libro, huella de llaves + gasto);
   crea `elea_engine`; copia **solo** las tablas del motor con `pg_dump -T` de las del Guardian
   (**`-T`, no `-t`**: `-t` no arrastra los tipos y el restore aborta); **compuerta de integridad**
   (misma fotografía en las dos bases, 0 tablas ajenas); si falla, vuelta atrás A sola.
3. *Apuntar*: escribe `ENGINE_DB` en `.env` y recrea el motor con la base nueva **y** las dos URL internas
   (las tres juntas o ninguna); espera `healthy`.
4. *Verificar*: el log del motor sin `creating baseline migration` / `P3005` / `Resolving migration:`
   (un primer arranque sobre base vacía sí dice «diff applied»: es inocuo); cada llave `svc.*` del `.env`
   responde 200 contra el motor (prueba la identidad por HTTP de punta a punta); las tablas viejas y
   `alembic_version` de `elea_gateway` siguen idénticas. Levanta de nuevo los clientes.

Si la verificación automática falla, el script lo dice y la salida es la vuelta atrás B (abajo).

**Verificación después del corte** (todo tiene que cumplirse; si no, vuelta atrás):

```bash
./migrar-base-motor.sh --verificar        # compuerta entre las dos bases + llaves + log; debe terminar en «OK»
docker exec elea-db psql -U "$POSTGRES_USER" -d elea_engine  -c '\dt' | head -5      # solo tablas del motor
docker exec elea-db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c '\dt' | head -30   # las del Guardian, intactas
docker compose restart backend && docker compose logs backend | tail -5               # migra sin tocar el motor
```

Prueba funcional (a mano, con una pregunta real por cada una): **planillas**, **presentación** y **chat con
documentos**. En cada una: `docker exec elea-db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT count(*) FROM audit_logs"`
sube en 1, y `./migrar-base-motor.sh --gasto` (esperar ≥ 70 s desde el pedido) muestra el gasto de la
llave. El panel de costos lee la auditoría y no debería cambiar de criterio. Observación del ensayo, **no
causada por separar** (se reproduce con la base compartida): tras reiniciar el motor, el pedido siguiente
se registró con gasto 0; si pasa en el servidor, mirarlo aparte y no confundirlo con una falla de la migración.

Cuando todo esté bien, `./install.sh` completa la actualización normal (resto de las imágenes, etc.).

**Vuelta atrás** (cada escalón ensayado a mano; los scripts aún no contra contenedores reales):

| Escalón | Cuándo | Qué hacer |
|---|---|---|
| **A** | El script falla *antes* de apuntar el motor a la base nueva (copia o compuerta) | **Automática**: borra `elea_engine` (solo si la creó esa corrida) y arranca con `docker start` los contenedores viejos tal como estaban. El `.env` no se toca. |
| **B** | Después de apuntar el motor, mientras las tablas viejas sigan en `elea_gateway` | `./migrar-base-motor.sh --vuelta-atras` (pide escribir `VOLVER`; ~50 s). Pone en `.env` `ENGINE_DB=<base del Guardian>`, `ENGINE_IDENTITY_URL=`, `ENGINE_AUDIT_URL=` (vacías = camino por SQL de la base compartida) y la imagen anterior en `ENGINE_IMAGE`, y recrea el motor. Se pierde solo el gasto que el motor contó en `elea_engine` desde el corte (la auditoría vive en el Guardian y no se afecta). Queda otra vez con base compartida: no subir la imagen del motor hasta volver a separar. |
| **C** | `elea_gateway` dañada | Restaurar la copia completa en una base nueva y comprobarla (ver abajo). |

Vuelta C, comandos (la restauración y el arranque del motor sobre ella se ensayaron; el cambio de nombre final no):

```bash
set -a; source .env; set +a
D=$(cat .ultimo-respaldo)                 # o respaldos/<fecha> a elección; verificar: (cd $D && sha256sum -c SHA256SUMS)
docker exec elea-db psql -U "$POSTGRES_USER" -d postgres -c 'CREATE DATABASE elea_gateway_restaurada'
docker exec -i elea-db pg_restore -U "$POSTGRES_USER" -d elea_gateway_restaurada --no-owner --exit-on-error < "$D/elea_gateway.dump"
docker compose stop backend frontend client tabular presenton anythingllm engine
docker exec elea-db psql -U "$POSTGRES_USER" -d postgres \
  -c 'ALTER DATABASE "elea_gateway" RENAME TO "elea_gateway_danada"' \
  -c 'ALTER DATABASE "elea_gateway_restaurada" RENAME TO "elea_gateway"'
docker compose up -d
```

La copia completa trae el libro de migraciones del motor y no dispara nada; **restaurar solo las tablas
del Guardian sí dispara el borrado** (el motor no tendría su libro): si alguna vez hay que restaurar
parcialmente, hacerlo con el motor parado y la base del motor aparte.

**Borrar las copias viejas del motor en `elea_gateway` (decisión D8)** — **a mano, no antes de 7 días** con
el motor ya sobre `elea_engine`, con `--verificar` en OK y una copia completa **nueva** (`./respaldo.sh`).
El script no las borra nunca. Después de borrarlas ya no hay vuelta B (solo la C).

```bash
./respaldo.sh
./migrar-base-motor.sh --mostrar-limpieza > limpieza.sql      # solo IMPRIME; leer el archivo entero
docker exec -i elea-db psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 < limpieza.sql
```

**Estado ambiguo** (`./install.sh` se niega a seguir): las dos bases tienen tablas del motor y `elea_engine`
no la creó este script. Pasa si alguien levantó el compose nuevo a mano sin migrar: el motor arrancó vacío y
las llaves del motor viejo siguen en `elea_gateway`. Resolverlo a mano: `./migrar-base-motor.sh --verificar`
muestra las diferencias; si `elea_engine` no tiene datos que importen (solo un motor recién arrancado),
`docker exec elea-db psql -U "$POSTGRES_USER" -d postgres -c 'DROP DATABASE elea_engine'` (parando antes el motor)
y `./migrar-base-motor.sh`. No se migra nada solo.

### Respaldo de las dos bases

```bash
./respaldo.sh                  # respaldos/AAAA-MM-DD-HHMMSS/{elea_gateway.dump,elea_engine.dump,SHA256SUMS,MANIFEST.txt}
./respaldo.sh --dry-run        # solo muestra los pasos
./respaldo.sh --conservar 20   # cuántas copias dejar (por defecto 10)
```

Un `pg_dump` de una sola base ya no alcanza: las llaves virtuales y el gasto del motor están en la otra. Cada
copia se verifica con `pg_restore -l` y registra su SHA-256; carpeta `700`, archivos `600` (traen
datos reales). Las dos copias se toman una tras otra (segundos de diferencia), no en un instante único.
**La carpeta está en el mismo servidor que la base**: copiarla a otro lado (`scp`/almacenamiento del
cliente) antes de cualquier cambio grande; si no, no es un respaldo. `./install.sh` la corre solo antes de
actualizar (`ELEA_SIN_RESPALDO=1` la omite, bajo tu responsabilidad).

Restaurar una base de la copia: `docker exec -i elea-db pg_restore -U "$POSTGRES_USER" -d <base_nueva> --no-owner --exit-on-error < respaldos/<fecha>/<base>.dump`.

### Subir la versión del motor

El digest del motor está en `docker-compose.yml` (`image: ${ENGINE_IMAGE:-…@sha256:…}`). Cambiarlo es
una tarea deliberada: una imagen sobre otra versión puede traer migraciones propias, y en una base
compartida eso borraba tablas del Guardian. Con la base propia el riesgo baja a las tablas del motor, pero
igual se hace con copia previa:

1. `./respaldo.sh` y copiar la carpeta fuera del servidor.
2. Tomar la línea `PINNED elea-guardian-engine=ghcr.io/cluna-8/elea-guardian-engine@sha256:…` que imprime
   `deploy/release/publish-elea.sh` (repo `elea`) y poner esa referencia en `docker-compose.yml` (por PR)
   o, solo para una prueba, en `.env` como `ENGINE_IMAGE=…`.
3. `./install.sh`, y verificar con `./migrar-base-motor.sh --verificar`.

El digest que trae este repo es el de la etiqueta `2026-09-17` (`sha256:1928af9d…6189dafe`); la `2026-09-14`
tiene el mismo motor por dentro (capas idénticas), así que pasar de una a otra no trae migraciones.

## Cómo llega este instalador al servidor de Elea (decisión del 14-sep-2026)

**Decisión del dueño (14-sep-2026), por los problemas de acceso que hubo en Elea:** los repos se
hacen **públicos** para que desde el servidor de Elea se puedan bajar directo desde GitHub las
instrucciones (este repo) y el desarrollo (`cluna-8/elea`), sin token y sin pasar por Azure DevOps.
Esto reemplaza la regla del 31-ago ("GitHub privado, Azure DevOps como puente"). Azure DevOps queda
solo como respaldo si la red del servidor vuelve a bloquear GitHub.

Ejecutado el 14-sep: `cluna-8/elea-installer` y `cluna-8/elea` son públicos y el instalador ya
no pide login al registro (solo si una descarga falla). Las imágenes de `ghcr.io/cluna-8` deben
ser públicas las seis (la visibilidad de paquetes se cambia en la web de GitHub, no por API).

Checklist antes de hacer público cada repo (hecho el 14-sep para los dos, limpio):
- ningún `.env`, llave de API, contraseña ni token en el árbol ni en el historial
  (`git log --all -p -G 'API_KEY=[A-Za-z0-9]{20,}'`); en `elea` lo único rastreado son la clave
  **pública** de licencias (`sentinel_public_keys.pem`) y la licencia de demo `dev-demo.lic`;
- nada del cliente que no deba verse (las specs mencionan planillas reales de Elea solo por nombre
  de archivo; los datos no están en el repo).

Después de hacerlo público, en el servidor:

```bash
cd ~/Eleia-cli
git remote set-url origin https://github.com/cluna-8/elea-installer.git
git pull origin main
./install.sh
```

Respaldo por Azure DevOps (solo si GitHub vuelve a estar bloqueado):

```bash
git remote add azure "https://dev.azure.com/celula-ia/C%C3%A9lula%20IA%20Proyectos/_git/celula-ia-proyectos"   # una sola vez
git push azure HEAD:master
```

## Apagar / prender

```bash
docker compose down    # apaga todo, conserva los datos
docker compose up -d   # prende de nuevo (rápido, ya está todo generado)
```

## Si algo falla

```bash
docker compose ps            # estado de cada contenedor
./elea-logs.sh backend       # logs del Guardian
./elea-logs.sh client        # logs del cliente RAG
./elea-logs.sh anythingllm   # logs de AnythingLLM
./elea-logs.sh engine        # logs del motor (usar esto, no "docker compose logs engine" —
                              # ese comando muestra el nombre interno del motor sin filtrar)
```

**"Authentication failed against database server... credentials... not valid"** en los
logs del motor o el backend: el volumen de la base (`elea-installer_pgdata`) quedó de una
instalación anterior con una contraseña distinta a la que tiene el `.env` actual. Pasa si
se borró `.env` y se corrió `./install.sh` de nuevo (genera una contraseña nueva) sin
antes borrar los datos viejos. Arreglo — **borra todos los datos**, solo hacerlo si no
importa perder lo que había:
```bash
docker compose down -v
./install.sh
```

**El motor da 401 a todas las llaves** después de tocar `.env` o el compose: el motor tiene que tener a
la vez su base propia **y** las dos URL internas (`SENTINEL_IDENTITY_URL`/`SENTINEL_AUDIT_URL`); con una
sola de las dos cosas no funciona. Ver «Base propia del motor».

**El motor (`engine`) tarda en aparecer sano la primera vez**: es esperado con una base
de datos nueva (migra sus tablas) — el instalador ya espera hasta 5 minutos. Si en algún
momento el contenedor se reinicia solo una vez durante ese lapso (`docker compose ps`
muestra un reinicio reciente), es normal — `restart: unless-stopped` lo recupera solo,
no hace falta intervenir.
