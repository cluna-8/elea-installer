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
levanta todo, crea el usuario admin, crea el usuario de cumplimiento (solo en una
instalación nueva, ver «Usuario de cumplimiento»), conecta AnythingLLM al motor y te muestra
la contraseña de admin generada. La del usuario de cumplimiento se muestra **una sola vez**,
en el momento en que se crea: copiala entonces.

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
| API por HTTPS (la URL de Claude Desktop) | `https://<servidor>:8443` (ver «HTTPS para Claude Desktop») |

El puerto `8091` lo publica el **proxy de la API** (`api-proxy`), no el backend: las PC de la LAN (el panel,
Claude Desktop y Claude Code, que apuntan a `/api/v1/gw/*`) lo usan exactamente igual que antes. Lo único que
cambia es que el proxy responde `404` a `/api/v1/internal/*` (ver «Proxy de la API»). El mismo proxy publica además
el **HTTPS** en el `8443` (`PROXY_HTTPS_PORT`), con el mismo enrutamiento: es la URL que se configura en Claude Desktop
(ver «HTTPS para Claude Desktop»). El `8091` HTTP sigue igual para el Hub y los servicios.

## Imágenes que publica el equipo (registro `ghcr.io/cluna-8`)

`elea-guardian-backend`, `elea-guardian-frontend`, `elea-guardian-engine`, `elea-guardian-nlp`,
`elea-rag-client` (Eleia Hub) y, desde la spec 050, **`elea-tabular`** (motor de planillas).
Presenton y AnythingLLM son imágenes públicas fijadas por digest/versión, **y el motor
(`elea-guardian-engine`) también va fijado por digest** en `docker-compose.yml` (desde oct-2026):
ni `./install.sh` ni `docker compose pull` lo cambian solos. Subirlo es una tarea deliberada, con
copia previa: ver «Subir la versión del motor».

Además, `publish-elea.sh` publica variantes **`-ext`** de backend, panel y motor (tag `<versión>-ext`, nunca `latest`): solo las usa
`./install.sh` con `ELEA_REDIRECT=1`. Ver «Extensión de redirección de modelos».

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

0. **Guardar la contraseña del usuario de cumplimiento** que mostró `./install.sh` (se muestra una sola vez,
   ver «Usuario de cumplimiento») y entregarla a quien cumple ese rol en la empresa.
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

> **Servidor de Elea (producción, por VPN y consola web)**: no usar solo esta sección. El orden completo —respaldo, separar la base del motor,
> usuario de cumplimiento, verificación, activación de la extensión de redirección y vuelta atrás, cada paso con su verificación— está en
> «Actualizar el servidor de Elea (057 + bases separadas)», más abajo.

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
configuración cambió (el backend pasa a no publicar puerto y arranca el proxy `api-proxy` en el `8091`, ver «Proxy de la API») (los espacios, documentos y usuarios sobreviven); las cuentas `svc.*` que ya
existen se reutilizan (se revoca su llave anterior y se emite una nueva, porque Guardian permite
una sola llave activa por cuenta); crea `svc.tabular` y `svc.presenton`; reconecta AnythingLLM al
motor; y borra el contenedor viejo de DB-GPT (`exact-analysis-engine`) que ya no existe en este
compose. Las variables viejas del `.env` (`MASKING_VIRTUAL_KEY`, `DBGPT_ENGINE_VIRTUAL_KEY`) quedan
sin uso; se pueden borrar a mano.

**El usuario de cumplimiento no se crea solo al actualizar**: una instalación existente lo pide a mano,
una vez, con `./crear-super-admin.sh` (ver «Usuario de cumplimiento»). Si ya hay un `super_admin`, informa y no toca nada.

Al terminar, las sesiones del Hub se cierran (viven en memoria): cada persona vuelve a entrar.
Verificar: entrar al Hub, ver las tres secciones (documentos, planillas, presentaciones) y, como
`admin`, abrir `http://<servidor>:8097/templates`.

## Actualizar el servidor de Elea (057 + bases separadas)

Un solo orden, de punta a punta, para el servidor de producción: se opera desde la **consola web por VPN**, copiando y pegando.
Antes de empezar el dueño ya hizo **M1** (congelar las actualizaciones del motor) y **M2** (respaldo). Cada paso trae sus comandos, **cómo se
verifica** y **qué hacer si falla**; el detalle de cada pieza está en las secciones de más abajo («Separar la base del motor», «Usuario de
cumplimiento», «Extensión de redirección de modelos»).

**Cómo usarlo.**

* Un bloque por vez; leer la salida **antes** de pegar el siguiente. Si un paso falla, **no seguir**: la consola web ejecuta lo que se pega línea
  por línea y no se detiene sola. Por eso los bloques que cambian algo están armados con `if … fi` o con `&&`.
* Todo se corre en `~/Eleia-cli`. Lo que está entre `<…>` es un dato que hay que reemplazar; el bloque que lo necesita **se niega** si no se lo cambió.
* Nada de este runbook usa Docker de forma destructiva: no hay `down -v`, ni borrado de volúmenes, ni `DROP DATABASE`. Antes de cada cambio grande hay una copia verificada.
* No pegar la salida de ningún comando en un chat ni en un correo sin leerla: algunas pantallas muestran una contraseña (Pasos 3 y 4).

| Paso | Qué | Corte del servicio | Si hay que parar |
|---|---|---|---|
| 0 | Precondiciones y datos a anotar | no | no se tocó nada |
| 1 | Respaldo con `./respaldo.sh` | no | no se tocó nada |
| 2 | Bajar el instalador nuevo | no | `git pull` no cambia lo que corre |
| 3 | Separar la base del motor (actualización) | **sí, ~2,5 min** (reservar 30 min) | vuelta atrás A/B/C de la separación |
| 4 | Crear el primer `super_admin` | no | se puede repetir |
| 5 | Verificar **sin** redirección | no | punto de parada: la instalación queda completa |
| 6 | Activar `ELEA_REDIRECT=1` | **sí, corto** (motor, backend y panel) | nivel 1 o 2 del Paso 8 |
| 7 | Verificar con redirección | no | nivel 1 del Paso 8 |
| 8 | Vuelta atrás en dos niveles | nivel 1: corto · nivel 2: sí | — |
| 9 | Configurar modelos y Claude Desktop (lo hace el `admin` en la consola) | no | se deshace en el panel (reglas, política, llaves); no toca datos |

> **Estado de la verificación.** **T102** (7-oct-2026, PC del owner, contenedores reales; comandos, salidas y tiempos en `EVIDENCIA-T102.md`): el orden de los
> Pasos 0 a 7 se corrió de punta a punta con `ELEA_REDIRECT=1`, más el nivel 1 del Paso 8 (apagar y volver a encender), y dio lo esperado. Antes se había probado la
> separación de la base del motor con contenedores reales (`ENSAYO-SEPARAR-BASES.md`, 06-oct-2026) y los scripts con Docker simulado
> (`bash tests/test-runbook-actualizar.sh`, `bash tests/test-redirect-optin.sh`). **No se probó con contenedores reales**: (1) el **nivel 2** del Paso 8 (restaurar el respaldo
> previo con las imágenes base); (2) una conversación de Claude Desktop o Claude Code contra un destino Azure —falta la credencial del owner, que la prueba no cargó— ni, por lo tanto,
> la auditoría de un pedido redirigido (postura y alcance del enmascarado); (3) el Paso 3 sobre una instalación vieja real: se corrió sobre una base compartida **armada para la
> prueba** (copia de las tablas del motor dentro de la base del Guardian). Los tiempos son de una PC con datos de prueba; el servidor de Elea no se midió.
>
> **Imágenes del candidato (no publicadas).** Se construyeron en local, con los mismos Dockerfile y contextos de `deploy/release/publish-elea.sh` (repo `elea`, rama final de la 057, `8dfb40c`) y **sin
> subirlas a ningún registro**, con el tag `2026-10-07` (base) y `2026-10-07-ext`. Publicarlas es una decisión aparte del owner: `VERSION=2026-10-07 deploy/release/publish-elea.sh`, ya logueado en
> el registro. `ELEA_EXT_MIN_VERSION` en `install.sh` ya vale `2026-10-08` y el Paso 6 usa ese mismo tag: **no quedan marcadores por completar**. Si el release sale con otra fecha, tiene que ser
> **igual o posterior** a `2026-10-07` y construida desde esa rama o una posterior; ese tag es el que se pone en `ELEA_EXT_VERSION`. Las referencias por digest de las `-ext`
> (`BACKEND_EXT_IMAGE`, `FRONTEND_EXT_IMAGE`, `ENGINE_EXT_IMAGE`, opcionales) salen de las líneas `PINNED …` de ese release.

### Paso 0 — Precondiciones y datos a anotar

Sin corte. Todo lo que sale acá se guarda en un archivo para compararlo después (no contiene secretos: nombres de imágenes, versiones, tamaños).

```bash
cd ~/Eleia-cli
set -a; source .env; set +a
{
  date -Is
  git log -1 --format='instalador actual: %h %ad %s' --date=short
  ls -l respaldo.sh migrar-base-motor.sh crear-super-admin.sh   # tienen que existir (si no, ver «Si falla»)
  ./migrar-base-motor.sh --inventario                  # imagen y versión del motor + tamaño de sus tablas
  docker compose ps                                    # estado de cada contenedor
  docker compose images                                # imágenes en marcha (repositorio, tag, ID)
  docker inspect --format '{{.Name}} {{.Config.Image}} {{.Image}}' elea-engine elea-backend elea-frontend elea-rag-client
  docker exec elea-db psql -U "${POSTGRES_USER:-elea_admin}" -d "${POSTGRES_DB:-elea_gateway}" -Atc 'SELECT version_num FROM alembic_version'
  docker exec elea-db psql -U "${POSTGRES_USER:-elea_admin}" -d "${POSTGRES_DB:-elea_gateway}" -Atc 'SELECT pg_size_pretty(pg_database_size(current_database()))'
  df -h . /var/lib/docker                              # espacio libre donde van los respaldos y donde vive Docker
  docker system df
  grep -E '^(ENGINE_IMAGE|ENGINE_DB|ELEA_REDIRECT|ELEA_EXT_VERSION|COMPOSE_FILE|EXTRA_ENV_FILE)=' .env || echo "(.env sin esas variables: lo esperado)"
} 2>&1 | tee ~/notas-previas-057.txt
```

El respaldo **M2** existe y se puede leer (reemplazar la ruta; sirve una carpeta de `./respaldo.sh` o un `.dump` suelto):

```bash
M2='<RUTA-DEL-RESPALDO-M2>'
if [ -d "$M2" ]; then
  ls -l "$M2"
  [ -f "$M2/SHA256SUMS" ] && (cd "$M2" && sha256sum -c SHA256SUMS)
  for f in "$M2"/*.dump; do [ -f "$f" ] && { echo "$f"; docker exec -i elea-db pg_restore -l < "$f" | grep -c ' TABLE '; }; done
elif [ -f "$M2" ]; then
  ls -l "$M2"; docker exec -i elea-db pg_restore -l < "$M2" | grep -c ' TABLE '
else
  echo "PARAR: no encuentro el respaldo M2 en $M2"
fi
```

**Verificar** (todo tiene que cumplirse):

* El motor en marcha es **`1.92.0 0.4.74`** (línea de `--inventario`): es la versión sobre la que se hizo el análisis. M1 se cumple si es la misma que antes de congelar y
  la imagen del motor (`elea-engine` en la salida) no cambió: nadie corrió `docker compose pull` ni `./install.sh` desde entonces.
* Hay espacio: como regla práctica (no medida) **al menos 3 veces el tamaño de la base** libres donde va `respaldos/` y en el disco de Docker. Cada corrida de `./install.sh`
  y de `./migrar-base-motor.sh` toma una copia de las dos bases; en este runbook se toman varias.
* La salida de M2 muestra una cantidad de tablas mayor que 0 por cada `.dump` (y `OK` en cada línea de `sha256sum -c`, si la hay).
* `grep ELEA_ .env` **no** muestra `ELEA_REDIRECT=1` (si lo hubiera, `./install.sh` activaría la extensión en los Pasos 3 y 4; sacarlo antes).
* Se anotó el nombre del archivo `~/notas-previas-057.txt`: es el «antes» de todo lo que sigue.

**Si falla**

| Síntoma | Qué hacer |
|---|---|
| Falta `respaldo.sh`, `migrar-base-motor.sh` o `crear-super-admin.sh` (el instalador del servidor es anterior) | Adelantar el `git pull` del Paso 2 (solo baja archivos; no cambia lo que corre) y repetir este Paso 0 y el Paso 1. M2 es la copia de partida hasta entonces. |
| El motor da otra versión que `1.92.0 0.4.74` | **PARAR** y consultar: el análisis de la separación habría que releerlo contra esa versión. |
| El motor cambió de imagen desde M1 | **PARAR**: alguien actualizó. No seguir hasta saber qué. |
| Poco espacio | Liberar (`docker system df` dice qué se puede recuperar) o copiar los respaldos viejos fuera del servidor. No seguir con poco espacio: un respaldo cortado a la mitad no sirve. |
| M2 no existe o `pg_restore -l` no lo lee | **PARAR**. Tomar el respaldo del Paso 1 y verificarlo: ese pasa a ser la copia de partida. No se actualiza sin una copia legible. |
| `ELEA_REDIRECT=1` en `.env` | `sed -i '/^ELEA_REDIRECT=/d' .env` y volver a empezar el Paso 0. |

### Paso 1 — Respaldo con `./respaldo.sh`

Sin corte. Copia **las dos bases** (la del Guardian y, si ya existe, la del motor), verifica cada copia con `pg_restore -l` y anota su SHA-256. Carpeta `700`, archivos `600`.

```bash
cd ~/Eleia-cli
./respaldo.sh                                          # respaldos/AAAA-MM-DD-HHMMSS/…
D=$(cat .ultimo-respaldo); echo "$D"
(cd "$D" && sha256sum -c SHA256SUMS && cat MANIFEST.txt)
ls -l "$D"
cp -a "$D" ~/respaldo-pre-057-"$(basename "$D")"        # una copia que la retención de respaldo.sh no toca
```

**Verificar.** `sha256sum -c` da `OK` por cada `.dump`; `MANIFEST.txt` nombra las bases respaldadas y la imagen del motor en marcha; los `.dump` pesan algo parecido a lo
anotado en el Paso 0. La carpeta está en el **mismo servidor** que la base: copiarla también **fuera del servidor** (`scp` o el almacenamiento de la empresa) antes de seguir; si no, no es un respaldo.
`./respaldo.sh` conserva solo las últimas 10 carpetas de `respaldos/` y este runbook toma varias: por eso la copia de la última línea queda fuera de esa carpeta.

**Si falla**

| Síntoma | Qué hacer |
|---|---|
| `No existe la base …: instalación nueva` | No es una actualización: usar `./install.sh` (ver «Instalación»). Este runbook es solo para actualizar. |
| `pg_dump … falló` / `La copia … no se puede leer` / `quedó vacío` | **PARAR.** `docker compose ps db` (tiene que estar `healthy`), espacio en disco, y repetir. No se sigue sin una copia verificada. |
| `sha256sum -c` da `FAILED` | La copia está dañada: borrar esa carpeta y repetir `./respaldo.sh`. |

### Paso 2 — Bajar el instalador nuevo

Sin corte: bajar los archivos no cambia lo que está corriendo. **No** correr `docker compose up -d` a mano después de esto hasta terminar el Paso 3: el motor arrancaría sobre una base vacía.

```bash
cd ~/Eleia-cli
git status --short                                     # tiene que salir vacío
git fetch origin && git log --oneline HEAD..origin/main
git pull origin main
git log -1 --format='instalador nuevo: %h %ad %s' --date=short
docker compose config -q && echo "compose OK"
grep -n '^ELEA_EXT_MIN_VERSION=' install.sh            # 2026-10-08: el Paso 6 necesita un ELEA_EXT_VERSION igual o posterior
ls -l respaldo.sh migrar-base-motor.sh crear-super-admin.sh activar-redirect.sh docker-compose.redirect.yml proxy/Caddyfile
```

**Verificar.** `git pull` termina sin conflictos; el último commit es el esperado; `compose OK`; los seis archivos de la última línea existen (los scripts, con permiso de ejecución).
`ELEA_EXT_MIN_VERSION` tiene que dar una fecha (`2026-10-08` en este instalador); si no, el instalador es anterior a T102 y el Paso 6 se va a negar (falla cerrado, sin tocar nada). Repetir este Paso 2.

**Si falla**

| Síntoma | Qué hacer |
|---|---|
| `git status` no sale vacío / `git pull` se queja de cambios locales | **No** usar `git reset --hard` ni `git stash`: consultar. Alguien tocó archivos del instalador en el servidor. |
| `git pull` no llega a GitHub | Ver «Cómo llega este instalador al servidor de Elea» (Azure DevOps de respaldo). |
| `docker compose config -q` da error | Falta o sobra una variable en `.env`: el mensaje dice cuál. No seguir hasta que dé `compose OK`. |

### Paso 3 — Separar la base del motor (actualización, no instalación nueva)

**Con corte**: el Hub, planillas, presentaciones y AnythingLLM quedan sin servicio ~2,5 min (medido en una PC; con una tabla de gasto grande, más). **Reservar 30 minutos.**
El motor tiene que pasar a su **propia base** (`elea_engine`) *antes* de levantar el compose nuevo; el detalle y las vueltas atrás están en «Separar la base del motor — runbook de producción».

Antes de la ventana (sin corte):

```bash
cd ~/Eleia-cli
set -a; source .env; set +a
./migrar-base-motor.sh --detectar; echo "código $?"    # 0 = hay que separar · 3 = ya está separada (saltear la migración) · 4 = ambiguo (PARAR)
./migrar-base-motor.sh --dry-run                       # el plan con tus nombres reales; no toca nada
```

En la ventana. Este primer comando **pregunta** (hay que escribir `MIGRAR`), así que se pega **solo**: si se pegara junto con otros, la pregunta se comería las líneas siguientes. Termina en «Listo»:

```bash
cd ~/Eleia-cli
./migrar-base-motor.sh                                 # escribir MIGRAR cuando lo pida (sin terminal pregunta nada y se niega: usar --si)
```

Recién después, la verificación y `./install.sh`, que completa la actualización (imágenes nuevas, proxy de la API, resto de servicios):

```bash
./migrar-base-motor.sh --verificar                     # compuerta entre las dos bases + llaves + log: debe terminar en «OK»
./install.sh                                           # repetirlo es seguro; al final muestra la contraseña de admin: copiarla y luego `clear`
```

Si `--detectar` dio 3, omitir el comando de `MIGRAR` y correr el segundo bloque. **No** poner `ELEA_REDIRECT` todavía.

**Verificar.** `--verificar` termina en `OK`; `./install.sh` termina con «Listo. Todo corriendo.»; `docker compose ps` muestra todo sano, el backend **sin** puertos publicados y `api-proxy` en `0.0.0.0:8091`;
`./migrar-base-motor.sh --detectar` ahora da código 3. Las sesiones del Hub se cerraron (viven en memoria): cada persona vuelve a entrar.

**Si falla**

| Síntoma | Qué hacer |
|---|---|
| `--detectar` da 4 | **PARAR**: estado ambiguo. Ver «Estado ambiguo (`./install.sh` se niega a seguir)». No se migra nada solo. |
| La migración falla *antes* de apuntar el motor a la base nueva (copia o compuerta) | Vuelta atrás **A**, **automática**: arranca los contenedores viejos tal como estaban y el `.env` no se toca. Comprobar `docker compose ps`, anotar el mensaje, **no seguir** y consultar. |
| `--verificar` falla o las llaves dan 401 después del corte | Vuelta atrás **B**: `./migrar-base-motor.sh --vuelta-atras` (pide escribir `VOLVER`, ~50 s). Queda otra vez con base compartida; no subir la imagen del motor. Para reintentar, `./migrar-base-motor.sh --volver-a-separar`. |
| `elea_gateway` dañada | Vuelta atrás **C**: restaurar la copia del Paso 1 en una base nueva (ver «Vuelta C, comandos»). |
| `./install.sh` dice que el puerto 8091 lo usa otro proceso | `ss -ltnp \| grep 8091`, liberarlo y repetir `./install.sh`. |
| `./install.sh` falla a mitad | Es idempotente: leer el mensaje, corregir y repetirlo. |

### Paso 4 — Crear el primer `super_admin`

Sin corte. El usuario de cumplimiento **no** se crea solo al actualizar (aparece una credencial nueva y es una decisión de la empresa). Se corre **una vez**.

```bash
cd ~/Eleia-cli
docker compose ps backend                              # tiene que estar «healthy»
./crear-super-admin.sh                                 # la contraseña se muestra UNA sola vez: copiarla ANTES de seguir
```

Recién cuando esté copiada y guardada: `clear` (la pantalla puede quedar en el historial de la consola; si se corrió por una consola web o VPN, cerrar la sesión al terminar).

La contraseña la genera el backend, no se escribe en ningún archivo y es temporal (el usuario tiene que cambiarla en su primer ingreso, en el panel `http://<servidor>:8090`).
Guardarla en el gestor de contraseñas de la empresa o entregarla en mano a quien cumple ese rol; **nunca** por chat ni por correo. Detalle en «Usuario de cumplimiento».

**Verificar.** Repetir el comando tiene que decir `ya hay un super_admin en esta instalación: no se creó ni se cambió nada` (no cambia nada, se puede repetir sin riesgo):

```bash
./crear-super-admin.sh
```

Después, que la persona de cumplimiento entre una vez al panel y cambie la contraseña. Cerrar la sesión de la consola al terminar.

**Si falla**

| Síntoma | Qué hacer |
|---|---|
| `No module named src.cli` | La imagen del backend es anterior a este comando: `./install.sh` (baja las imágenes) y repetir. |
| `ya hay un super_admin` en la **primera** corrida | Ya existía uno: no hace falta nada más. Si se perdió su contraseña, el instalador no la recupera: consultar al equipo antes de tocar la base a mano. |
| El backend no está `healthy` | `./elea-logs.sh backend`. No seguir con el backend caído. |
| Se perdió la contraseña antes del primer ingreso | Si hay otro `super_admin`, puede restablecerla desde el panel; si era el único, consultar (ver «Usuario de cumplimiento»). |

### Paso 5 — Verificar sin redirección

Sin corte. Este es un **buen punto para parar**: hasta acá no se tocó nada de la extensión y la instalación queda completa, separada y con proxy. Si algo de lo siguiente no da lo esperado, no seguir. (`--verificar` compara la base del motor con la del Guardian: solo tiene sentido en una **actualización** con la separación hecha; en una instalación nueva, que nunca tuvo base compartida, termina en «No se pudo leer el motor de elea_gateway». Es lo esperado: este runbook no es para instalaciones nuevas.)

```bash
cd ~/Eleia-cli
set -a; source .env; set +a
./migrar-base-motor.sh --verificar                                                     # «OK»
./migrar-base-motor.sh --inventario                                                    # la misma versión del motor que en el Paso 0
docker compose ps                                                                      # todo sano; backend sin puertos; api-proxy en 0.0.0.0:8091
docker inspect --format '{{.Name}} {{.Config.Image}}' elea-engine                      # la misma imagen del motor que anotaste (M1)
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8091/health                            # 200
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8091/docs                              # 200
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8091/api/v1/internal/identity          # 404
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8091/api/v1/redirect/health            # 404: la extensión todavía no está (lo esperado)
curl -s http://localhost:8091/openapi.json | grep -o '"title":"[^"]*"' | head -1                # el título de la consola dice «Eleia GuardIAn API»
docker exec elea-db psql -U "${POSTGRES_USER:-elea_admin}" -d "${POSTGRES_DB:-elea_gateway}" -Atc 'SELECT count(*) FROM audit_logs'
```

Desde **otra máquina de la LAN/VPN** (no el servidor): `curl -s -o /dev/null -w '%{http_code}\n' http://<servidor>:8091/api/v1/internal/identity` tiene que dar **404**.

**Verificar.** Los códigos de arriba. El título de la consola (`/openapi.json`) dice **«Eleia GuardIAn API»** (lo fija `BRAND_NAME` en `docker-compose.yml`; no debería verse el default de fábrica del backend). Además, prueba funcional a mano con **una pregunta real por cada servicio** (Hub: chat con documentos, planillas, presentación; un texto **distinto** en cada una,
porque el motor parece cachear pedidos idénticos): en cada una `audit_logs` sube en 1 (repetir el último `psql`) y `./migrar-base-motor.sh --gasto` (esperar ≥ 70 s) muestra el gasto de la llave. Como `admin`, abrir `http://<servidor>:8097/templates`.

**Si falla**

| Síntoma | Qué hacer |
|---|---|
| `/api/v1/internal/identity` **no** da 404 | **PARAR y avisar**: el plano interno quedó expuesto. `docker compose ps` (el backend no debe publicar puertos) y `./elea-logs.sh api-proxy`. No activar nada hasta resolverlo. |
| `/health` no da 200 | `./elea-logs.sh backend`; el backend puede estar migrando (esperar 1–2 min) o caído. |
| El motor da 401 a todas las llaves | El motor tiene que tener a la vez su base propia **y** las dos URL internas: ver «El motor da 401 a todas las llaves». Si no se resuelve en la ventana, vuelta atrás **B** del Paso 3. |
| Una pregunta del Hub no responde o `audit_logs` no sube | `./elea-logs.sh engine` y `./elea-logs.sh client`. Si no sube con un texto nuevo, mirar el log del backend: la auditoría vive ahí. |

### Paso 6 — Activar `ELEA_REDIRECT=1`

**Con corte corto** (el instalador recrea el motor, el backend y el panel; medido en T102: `./install.sh` completo 96 s; el corte de `/health` se midió en el nivel 1 (apagar 53 s, volver a encender 6 s), no en la primera activación; reservar 15 minutos de margen). **Precondiciones**: Paso 5 verde y las imágenes `-ext` de `ELEA_EXT_VERSION` disponibles (publicadas, o construidas en local como en T102).
El instalador comprueba tres condiciones y, si falta alguna, **falla cerrado sin tocar nada**: (1) el compose tiene `api-proxy` y el backend no publica puertos; (2) `ELEA_EXT_VERSION` ≥ `ELEA_EXT_MIN_VERSION`
(hoy `2026-10-07`, fijado en `install.sh`; un valor en `.env` no lo baja); (3) `/api/v1/internal/*` da 404 por el puerto publicado.

Primero, un respaldo propio **previo a la activación** y anotar cuál es (el nivel 2 del Paso 8 lo usa; el instalador toma además uno al activar):

```bash
cd ~/Eleia-cli
./respaldo.sh && cat .ultimo-respaldo | tee ~/respaldo-previo-a-la-activacion.txt
D=$(cat ~/respaldo-previo-a-la-activacion.txt); (cd "$D" && sha256sum -c SHA256SUMS)
```

Copiar esa carpeta también **fuera del servidor**. Después, activar. El bloque se niega si el tag no tiene el formato AAAA-MM-DD:

```bash
cd ~/Eleia-cli
ELEA_EXT_VERSION='2026-10-08'                          # el tag de las imágenes -ext (AAAA-MM-DD); si el release sale con otra fecha, esa (>= 2026-10-08)
GW_URL='https://<servidor>:8443/api/v1/gw'              # la dirección HTTPS con que las PC llegan a la pasarela por la VPN (va en los kits de Claude Desktop); <servidor> = el primer nombre de PROXY_TLS_NAMES
if [[ "$ELEA_EXT_VERSION" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  [ -z "$(tail -c1 .env)" ] || echo >> .env
  sed -i '/^ELEA_REDIRECT=/d;/^ELEA_EXT_VERSION=/d;/^REDIRECT_GATEWAY_URL=/d' .env
  printf 'ELEA_REDIRECT=1\nELEA_EXT_VERSION=%s\nREDIRECT_GATEWAY_URL=%s\n' "$ELEA_EXT_VERSION" "$GW_URL" >> .env
  ./install.sh
else
  echo "PARAR: falta el tag de las imágenes -ext (ELEA_EXT_VERSION). No se tocó nada."
fi
```

(`REDIRECT_GATEWAY_URL` es opcional: sin ella, el instalador usa `https://<primer nombre de PROXY_TLS_NAMES>:<PROXY_HTTPS_PORT>/api/v1/gw`; con ella, la que se escriba. El HTTPS y su certificado se preparan antes: «HTTPS para Claude Desktop».)
`./install.sh` hace su actualización normal y, al final, `./activar-redirect.sh`: comprueba las tres condiciones, baja las `-ext`, toma su propio respaldo (si es la primera activación), escribe el entorno de la extensión (**fuera del repo, modo 600**:
`~/.config/elea/redirect.env`, con las llaves generadas una sola vez; nunca se imprime), recrea motor, backend y panel, espera al backend (si una migración de la extensión falla, el backend **aborta** el arranque),
comprueba que los seeds estén en la imagen y consulta `/api/v1/redirect/health`. **Cualquier respuesta que no sea 200 es un error visible.** Pegar solo `./activar-redirect.sh` no sirve: no conoce el tag mínimo y falla cerrado.

**Verificar**

```bash
cd ~/Eleia-cli
set -a; source .env; set +a
docker inspect --format '{{.Name}} {{.Config.Image}}' elea-engine elea-backend elea-frontend     # las tres terminan en «-ext» (el tag de arriba)
ls -l "$EXTRA_ENV_FILE"                                                                           # -rw------- (600), fuera de ~/Eleia-cli; NO mostrar su contenido
docker compose exec -T backend alembic current                                                    # dos revisiones, las dos «(head)»: la de siempre y la de la extensión (verificado en T102)
curl -s -w '\n%{http_code}\n' http://localhost:8091/api/v1/redirect/health                        # 200
./migrar-base-motor.sh --verificar                                                                # el libro de migraciones del motor no cambió
```

Si se fijó el digest de las `-ext` (`BACKEND_EXT_IMAGE`, `FRONTEND_EXT_IMAGE`, `ENGINE_EXT_IMAGE` en `.env`, de la línea `PINNED …` que imprime `publish-elea.sh`), `docker inspect` muestra esa referencia en lugar del tag.
**Falta, en el panel** (`http://<servidor>:8090`, «Modelos»): dar de alta los modelos, cargar sus fichas, publicarlos, mapearlos y crear las llaves. **Lo hace el `admin` de la empresa**, en el orden del **Paso 9**; el usuario de
cumplimiento (`super_admin`, Paso 4) interviene solo en lo que es suyo: los campos de residencia de la ficha (entidad responsable, jurisdicciones de entidad, control e inferencia, retención cero). El instalador siembra cuatro modelos de Azure de **ejemplo** como entradas de **instalación**: **solo el usuario de cumplimiento (`super_admin`) las ve y las administra**; el `admin` de la empresa **no las ve** (su lista de «Destinos» sale vacía) hasta que cumplimiento se las **ofrece**
(botón «Ofrecer»), y aun así no las edita ni las archiva (verificado el 7-oct, T102: `admin` → 0 entradas, cumplimiento → 4). El `admin` da de alta **los suyos** (Paso 9, punto 2) y cumplimiento archiva los de ejemplo que no se usen. Sin la jurisdicción de inferencia en la ficha, el modelo se rechaza.

La **credencial de Azure** es ahora **la del catálogo**: se carga en «Modelos» → «Credenciales» (clave y versión de API `2025-04-01-preview`; la dirección va en cada modelo, «Editar» → «Dirección base») y **no se edita**: para cambiarla se crea otra y se reasigna (Paso 9, punto 1).
Las variables `AZURE_OPENAI_API_KEY`, `AZURE_OPENAI_ENDPOINT` y `AZURE_API_VERSION` de `.env` **quedan para lo heredado** (lo que ya las leía antes de la redirección); los modelos nuevos usan la credencial del catálogo. Si se cambian en `.env`, recrear lo que las lee
(`restart` **no** relee `.env`):

```bash
cd ~/Eleia-cli
docker compose up -d engine backend                    # recrea con el .env nuevo; conserva las imágenes -ext (COMPOSE_FILE ya está en .env)
```

**Despliegue de embeddings del ruteo (`ROUTER_EMBEDDINGS_DEPLOYMENT`).** El ruteo semántico (el que elige modelo según el contenido) calcula sus vectores con un modelo de embeddings **del mismo recurso de Azure**. Azure lo identifica por el **nombre del despliegue**, que elige quien creó el recurso, no por el nombre del modelo. Si en `.env` no está o está vacía, el motor usa `text-embedding-3-large` (lo de siempre). **En Elea el despliegue se llama `text-embedding-3-large-azure-openai`**, así que en `.env` va:

```
ROUTER_EMBEDDINGS_DEPLOYMENT=text-embedding-3-large-azure-openai
```

Para ver cómo se llaman los despliegues del recurso, usando la llave que ya está en `.env` **sin imprimirla** (va al curl por la entrada estándar, no por la línea de comandos ni por pantalla):

```bash
cd ~/Eleia-cli
KEY=$(grep -m1 '^AZURE_OPENAI_API_KEY=' .env | cut -d= -f2-)
BASE=$(grep -m1 '^AZURE_OPENAI_ENDPOINT=' .env | cut -d= -f2-)
printf 'api-key: %s\n' "$KEY" | curl -sS -H @- "${BASE%/}/openai/deployments?api-version=2022-12-01" \
  | python3 -c 'import json,sys; [print(d["id"], "->", d.get("model"), d.get("status")) for d in json.load(sys.stdin)["data"]]'
unset KEY BASE
```

Cada línea es `nombre-del-despliegue -> modelo estado`: se copia el de `text-embedding-3-large` a `ROUTER_EMBEDDINGS_DEPLOYMENT` y se recrea el motor (`docker compose up -d engine`; `restart` **no** relee `.env`). Si no sale ninguna línea, la salida es un error (por ejemplo `401`: la llave no es de ese recurso, o una dirección mal escrita): no se sigue hasta que el listado salga. Esto necesita el motor con la imagen que lee la variable; con una anterior se ignora y rige el nombre de siempre.

**Variables opcionales del enmascarado (no hace falta tocarlas).** La 057 agregó estas variables; **todas tienen un valor por defecto seguro** y el instalador **no las escribe**: rige el default.
Llegan al motor y al backend por el mismo archivo de entorno de la extensión (`redirect.env`; `EXTRA_ENV_FILE`), y ni el compose ni el instalador definen ninguna, así que lo que se agregue ahí **no se pisa** (lo comprueba `bash tests/test-redirect-optin.sh`).

| Variable | Default | Para qué |
|---|---|---|
| `MASKING_NONCE_KEY` | la **genera el instalador** (≥ 32 caracteres, distinta de las demás, una sola vez) | clave de los marcadores estables por conversación. Sin ella (o más corta) los marcadores son aleatorios por pedido: la protección es la misma, solo rinde menos la caché del proveedor. No reutilizarla como credencial de un modelo; cambiarla cambia los marcadores de las conversaciones en curso. |
| `MASKING_ANALYSIS_CACHE_ENABLED`, `MASKING_ANALYSIS_CACHE_MAX_ENTRIES`, `MASKING_ANALYSIS_CACHE_TTL_S`, `MASKING_ANALYSIS_CACHE_SALT` | encendida · 20000 · 3600 s · vacío | caché de **detecciones** por segmento (posición, tipo y puntaje; nunca el texto) en la memoria del motor. `MASKING_ANALYSIS_CACHE_ENABLED=false` la apaga; no cambia el resultado. |
| `MASKING_PDF_MAX_PAGES`, `MASKING_PDF_MAX_BYTES`, `MASKING_PDF_MAX_MEMORY_MB`, `MASKING_PDF_TIMEOUT_S`, `MASKING_PDF_MAX_CONCURRENCY`, `MASKING_PDF_MAX_STREAM_BYTES`, `MASKING_PDF_MAX_TEXT_CHARS`, `MASKING_PDF_MAX_PER_REQUEST`, `MASKING_PDF_REQUEST_DEADLINE_S`, `MASKING_PDF_CACHE_ENTRIES` | 200 · 20 MB · 512 MB · 20 s · 2 · 25 MB · 2 000 000 · 5 · 30 s · 32 | topes de la lectura de PDF con texto cuando el enmascarado es forzado. Un PDF que no se puede leer (escaneado, protegido, corrupto o que supera un tope) **no se envía**: el pedido se bloquea con «no pudo protegerse». Un valor inválido deja el default. |
| `MASKING_EXEMPT_SYSTEM_PROMPT`, `MASKING_EXEMPT_TOOL_DEFINITIONS` | apagadas (`false`) | exenciones opcionales: el prompt de sistema o las definiciones de herramientas viajan sin analizar. **Encenderlas es una decisión explícita de la instalación** (queda en la auditoría solo el nombre de lo exento); el pedido no puede encenderlas. |

`S14_EXEMPT_POSITIONS` **no es una variable**: es una tabla del código del motor (qué posiciones del pedido no se reescriben); no hay nada que configurar ni que pasar. Las exenciones opcionales de arriba están apagadas por defecto.
Para cambiar una: agregar la línea en el archivo de entorno (sin cambiar su modo 600) y recrear lo que la lee, con un corte corto:

```bash
cd ~/Eleia-cli
set -a; source .env; set +a
nano "$EXTRA_ENV_FILE"                                 # agregar, p. ej., MASKING_PDF_MAX_PAGES=100; no tocar las líneas existentes
docker compose up -d --force-recreate engine backend
```

**Si falla** (el instalador dice cuál; el mensaje es el de `./activar-redirect.sh`)

| Síntoma | Qué hacer |
|---|---|
| «ELEA_REDIRECT=1 todavía no se puede activar … (ELEA_EXT_MIN_VERSION) sigue sin fijar» | Es el marcador pendiente: no se publicó todavía el release que lo fija. **No se tocó nada.** Esperar ese release; no editarlo a mano en el servidor. |
| «ELEA_EXT_VERSION … es anterior al mínimo» o «Falta ELEA_EXT_VERSION» | Usar un tag ≥ al mínimo, con formato `AAAA-MM-DD`. No se tocó nada. |
| «Falta la dependencia de la vuelta 2 de la base propia del motor (proxy y canal interno cerrado)» | El instalador es viejo o el compose no tiene el proxy: repetir el Paso 2. No se tocó nada. |
| «/api/v1/internal/identity dio … (se esperaba 404)» | **PARAR y avisar.** El plano interno no está cerrado (o el Guardian no está levantado). No se activa. |
| «No se pudieron bajar las imágenes -ext» | El tag no existe o las imágenes no se publicaron. No se activa nada: verificar el tag con quien publicó. |
| «Sin respaldo previo no se activa la extensión» | `./respaldo.sh` falló: ver Paso 1. **No** usar `ELEA_SIN_RESPALDO=1`: sin respaldo no hay nivel 2. |
| «El motor no terminó de arrancar después de 5 minutos» | `./elea-logs.sh engine`. Si no se resuelve rápido, **nivel 1** del Paso 8 no ayuda (las imágenes `-ext` se conservan): consultar; el recurso seguro es el **nivel 2**. |
| «El backend no respondió en 3 minutos» (migración de la extensión fallida) | `./elea-logs.sh backend`. **No insistir ni repetir el instalador**: una migración puede haber quedado a medias. Ir al **nivel 2** del Paso 8, salvo que el equipo indique otra cosa. |
| `/api/v1/redirect/health` da **503** (`region_unresolved` o `region_row_missing`) | Rige el respaldo en código: se rechaza todo lo redirigido; los seeds no se cargaron. `./elea-logs.sh backend`. Lo no redirigido sigue igual. Si no se arregla, **nivel 1**. |
| `/api/v1/redirect/health` da **404** | La extensión no está montada (imagen `-ext` sin entorno): `docker compose ps backend` y que exista el archivo de `EXTRA_ENV_FILE`. |

### Paso 7 — Verificar con redirección

Sin corte. Hay cuatro comprobaciones (a, b, c y d); **todas** tienen que cumplirse, y si una no, nivel 1 del Paso 8.

**a) En el servidor** (el puerto publicado es el del proxy, 8091):

```bash
cd ~/Eleia-cli
curl -s -w '\n%{http_code}\n' http://localhost:8091/api/v1/redirect/health                        # 200
curl -s -H "Authorization: Bearer <LLAVE>" http://localhost:8091/api/v1/gw/v1/models              # los modelos publicados para esa llave
./migrar-base-motor.sh --verificar                                                                # «OK»
./elea-logs.sh backend                                                                            # sin errores de arranque ni de migración
```

**b) Desde OTRA máquina de la LAN/VPN** (no desde el servidor): el plano interno tiene que estar cerrado.

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://<servidor>:8091/api/v1/internal/identity          # 404
curl -s -o /dev/null -w '%{http_code}\n' http://<servidor>:8091/api/v1/redirect/health            # 200
```

**c) Una conversación de Claude Code con un dato personal de prueba** (necesita haber hecho antes los puntos 1 a 8 del **Paso 9**: sin un modelo con credencial, publicado, con su regla y la política encendida, la llave no tiene a qué responder; las comprobaciones a, b y d no lo necesitan), desde la PC de una persona, con una **llave virtual de prueba** (la crea el panel; entregarla por el gestor de contraseñas, nunca por chat):

```bash
export ANTHROPIC_BASE_URL=http://<servidor>:8091/api/v1/gw
export ANTHROPIC_AUTH_TOKEN='<LLAVE>'
claude
```

Pedirle algo que incluya datos **inventados** (nunca los de una persona real), por ejemplo: «Redactá un saludo para Juana Pérez, DNI 12.345.678, correo juana.perez@example.com, y repetí sus datos al final».

* **Qué se espera.** El dato personal **sale enmascarado** hacia el modelo (seudonimización reversible: el modelo recibe un marcador, no el valor) y **vuelve restaurado** a la persona: la respuesta se lee normal. Que el enmascarado se aplicó se ve en la **auditoría**, que
  guarda **solo metadatos** (jamás el texto del pedido ni el dato): el id pedido y el destino real, la postura (`default_posture_applied`, `masked_all` por defecto), si el destino estaba en región y el alcance del enmascarado (`masking_scope`).
  Se mira en el panel (`http://<servidor>:8090`, pantalla «Logs de Auditoría»; el destino real de un pedido redirigido se confirmó ahí y en los registros el 7-oct, al cambiar el destino de `sonnet`; qué columnas muestra de postura y alcance **no se verificó** en pantalla: si no aparecen, están en la tabla `audit_logs`). Con la postura por defecto (`masked_all`) todo lo redirigido sale enmascarado, sea cual sea el destino.
* Anotar **sin contenido** (fecha, id del modelo, destino, postura, `masking_scope`) como evidencia; no copiar el prompt ni la respuesta.

**d) En el panel** (verificado en T102): entrar al panel (se probó con un usuario `admin` de la organización), «Modelos» → «Routing» → «Redirección» muestra las pestañas Destinos, Modelos publicados, Reglas, Política, Residencia, Vista previa, Kits, Fidelidad y Costos. Con eso **no** queda nada servido: dar de alta los modelos, publicarlos, mapearlos y crear las llaves es el **Paso 9**, que hace el `admin` de la empresa.

**Verificar.** (a) la salud en 200, los modelos publicados listados y `--verificar` en `OK`; (b) el plano interno en 404 desde otra máquina; (c) la conversación responde con el dato restaurado y la auditoría muestra la postura y el alcance del enmascarado, sin contenido.

**Si falla**

| Síntoma | Qué hacer |
|---|---|
| `/api/v1/internal/identity` **no** da 404 desde otra máquina | **Nivel 1 ya** (Paso 8) y **avisar**: es el requisito de seguridad de la activación. |
| `/api/v1/redirect/health` no da 200 | Ver la tabla del Paso 6 (503 / 404). |
| `/api/v1/gw/v1/models` no lista nada | Todavía no hay modelos publicados en «Modelos» para esa llave: es del panel, no del instalador. |
| 403 «Modelo no disponible para tu región.» | Residencia: el destino está fuera de lo permitido para esa región. Es la política funcionando; Cumplimiento ajusta en «Modelos». En Claude Desktop aparece con «Failed to authenticate» antepuesto: es el texto de esa herramienta, no un error de la llave. |
| 404 «Modelo no disponible para tu organización.» | El id pedido no está publicado para esa llave. |
| 400 «El pedido no pudo protegerse…» | El analizador de datos personales no respondió (o un PDF no se pudo leer): `docker compose ps nlp-analyzer` y `./elea-logs.sh engine`. El pedido **no** sale sin proteger: es el comportamiento correcto. |
| La respuesta trae el dato sin que la auditoría muestre postura/alcance de enmascarado | **Nivel 1** y consultar: la política no se aplicó. |

### Paso 8 — Vuelta atrás en dos niveles

**Cuál elegir.** El **nivel 1** *apaga* la extensión: minutos, sin tocar datos. El **nivel 2** *vuelve a las imágenes base* y **solo** se puede con el respaldo previo a la activación (el del Paso 6): con las migraciones de la
extensión aplicadas, volver a una imagen sin la extensión **no está soportado** (la imagen base fallaría al arrancar por revisiones desconocidas en la base). **Sin el respaldo previo no hay nivel 2.**
Nunca: `docker compose down -v`, borrar volúmenes, borrar las copias de `respaldos/`, ni restaurar solo algunas tablas.

#### Nivel 1 — apagar

1. En el panel («Modelos»), dejar la política **Apagada** para el alcance: los pedidos vuelven al camino de siempre.
2. Sacar la variable y correr el instalador:

```bash
cd ~/Eleia-cli
unset ELEA_REDIRECT
sed -i '/^ELEA_REDIRECT=/d' .env
./install.sh
```

`./activar-redirect.sh` ve la activación anterior, **quita `GATEWAY_PLUGINS` y `PLUGIN_PACKAGES`** del entorno de la extensión y recrea motor y backend. **Conserva** la imagen `-ext` del backend (y la del panel y el motor) y
`ALEMBIC_EXTRA_VERSION_LOCATIONS`: con las migraciones ya aplicadas, la imagen base no arranca (el `upgrade head` falla por revisiones desconocidas).

**Verificar.** `/api/v1/redirect/health` pasa a **404** (lo esperado: las rutas de la extensión desaparecen); `curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8091/health` da 200; `/api/v1/gw/v1/models` y una pregunta del Hub responden como antes;
`./migrar-base-motor.sh --verificar` da `OK`. Para volver a encender: poner otra vez `ELEA_REDIRECT=1` (Paso 6). Medido en T102: apagar, `./install.sh` 78 s con `/health` caído 53 s; volver a encender, 83 s con `/health` caído 6 s; con las migraciones ya aplicadas y las imágenes `-ext` en su lugar.

**Si falla.** `./install.sh` dice `Falta el archivo de entorno de la extensión`: el archivo de `EXTRA_ENV_FILE` no está; no inventarlo, ir al nivel 2. Si el backend no arranca después de apagar: `./elea-logs.sh backend` y, si no se resuelve, nivel 2.

#### Nivel 2 — volver a las imágenes base

**Solo** restaurando el respaldo previo a la activación (`~/respaldo-previo-a-la-activacion.txt`, Paso 6). **Se pierde todo lo que pasó después de ese respaldo** (usuarios, llaves, auditoría, gasto). Nada se borra: la base con la extensión se
**renombra**, no se elimina. El cambio de nombre y el arranque con las imágenes base **no se probaron con contenedores reales**. Tres bloques, **uno por vez**, y no pasar al siguiente si el anterior no terminó bien.

**A.** Un respaldo del estado actual (por si hay que deshacer esto) y la restauración en una base **aparte** (no toca la actual):

```bash
cd ~/Eleia-cli
set -a; source .env; set +a
./respaldo.sh && D=$(cat ~/respaldo-previo-a-la-activacion.txt) && echo "$D" && [ -d "$D" ] && (cd "$D" && sha256sum -c SHA256SUMS) && \
docker exec elea-db psql -U "$POSTGRES_USER" -d postgres -c 'CREATE DATABASE elea_gateway_restaurada' && \
docker exec -i elea-db pg_restore -U "$POSTGRES_USER" -d elea_gateway_restaurada --no-owner --exit-on-error < "$D/elea_gateway.dump" && \
echo "RESTAURACIÓN OK: seguir con el bloque B" || echo "FALLÓ: NO seguir con el bloque B"
```

**B.** Solo si A dijo `RESTAURACIÓN OK`: parar los servicios y cambiar los nombres (la base con la extensión queda guardada como `elea_gateway_con_extension`):

```bash
docker compose stop api-proxy frontend client tabular presenton anythingllm backend engine && \
docker exec elea-db psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 \
  -c 'ALTER DATABASE "elea_gateway" RENAME TO "elea_gateway_con_extension"' \
  -c 'ALTER DATABASE "elea_gateway_restaurada" RENAME TO "elea_gateway"'
```

**C.** Sacar del instalador todo lo de la extensión (en `.env` y en esta sesión) y volver a las imágenes base:

```bash
sed -i -E '/^(ELEA_REDIRECT|ELEA_EXT_VERSION|COMPOSE_FILE|EXTRA_ENV_FILE|ELEA_REDIRECT_ACTIVADA|ELEA_REDIRECT_CATALOGO|BACKEND_EXT_IMAGE|FRONTEND_EXT_IMAGE|ENGINE_EXT_IMAGE)=/d' .env
unset ELEA_REDIRECT ELEA_EXT_VERSION COMPOSE_FILE EXTRA_ENV_FILE ELEA_REDIRECT_ACTIVADA ELEA_REDIRECT_CATALOGO BACKEND_EXT_IMAGE FRONTEND_EXT_IMAGE ENGINE_EXT_IMAGE
./install.sh                                           # sin las variables, compose vuelve a ver solo docker-compose.yml: imágenes base
```

La extensión solo agrega tablas a la base del Guardian: la base del motor (`elea_engine`) no se restaura (el motor `-ext` deriva del mismo digest del motor base). Cuando todo ande, el archivo de entorno de la extensión
(`~/.config/elea/redirect.env`) se borra a mano y, si más adelante se vuelve a activar, se generan llaves nuevas. La base `elea_gateway_con_extension` se borra solo por decisión de una persona (`DROP DATABASE`, con copia previa).

**Verificar.** `docker inspect --format '{{.Name}} {{.Config.Image}}' elea-engine elea-backend elea-frontend` ya **no** muestra `-ext` en el backend ni en el panel (el motor vuelve a su digest fijado);
`/api/v1/redirect/health` da 404; `/health` da 200; `./migrar-base-motor.sh --verificar` da `OK`; el Hub responde y los usuarios que existían **antes** del respaldo entran.

**Si falla**

| Síntoma | Qué hacer |
|---|---|
| El bloque A falla (copia ilegible, `CREATE DATABASE` o `pg_restore` con error) | **No seguir.** Nada cambió en la base actual (la restauración fue a una base aparte). Si quedó `elea_gateway_restaurada` a medias, es una base de prueba: consultar antes de borrarla. |
| El bloque B falló en el segundo `ALTER` (queda sin `elea_gateway`) | Deshacer el primero **ya**: `docker exec elea-db psql -U "$POSTGRES_USER" -d postgres -c 'ALTER DATABASE "elea_gateway_con_extension" RENAME TO "elea_gateway"'`, y consultar. |
| El backend con imágenes base no arranca después del bloque C | La restauración no quedó donde se esperaba: `./elea-logs.sh backend`; el estado anterior está en `elea_gateway_con_extension` y en la copia del bloque A (`respaldos/`). Consultar antes de tocar nada más. |
| No hay respaldo previo a la activación | No hay nivel 2. Quedarse en el nivel 1 y consultar al equipo. |

### Paso 9 — Configurar modelos y Claude Desktop

Lo hace el **administrador de la empresa** (`admin`) desde la consola (`http://<servidor>:8090`, «Modelos»); no hace falta el usuario de cumplimiento salvo para **lo que es suyo**: los cinco campos de residencia de la
ficha de cada modelo (entidad responsable y jurisdicciones de entidad, control e inferencia, más «Retención cero»). Si un `admin` intenta escribirlos, el panel responde 403; el resto de la ficha sí lo edita él.
Requiere haber terminado el Paso 7 (la extensión activa y `/api/v1/redirect/health` en 200). Sin corte del servicio: todo es configuración en el panel.

> **Estado.** 🟢 **Verificado en vivo el 7-oct-2026** con Claude Desktop contra Azure, en una instalación hecha con este instalador y `ELEA_REDIRECT=1` (T102): conexión por gateway (URL `/api/v1/gw`, `bearer`, llave estática, descubrimiento); chat con `haiku` → `gpt-5.4-mini`, `sonnet` → `gpt-5.1-chat` y
> `opus` → `gpt-5.6-luna`; cambio de destino de `sonnet` en «Reglas» sin tocar el cliente; DNI enmascarado hacia Azure; Cowork con PDF y presentación; diseño de SVG; lectura de imágenes (`sonnet` tras marcar «Imágenes» en su ficha); llave con 1.000.000 tpm / 120 rpm por «Editar límites»; esfuerzo ajustado; etiqueta «id pedido»;
> credencial de Azure del catálogo con `2025-04-01-preview`; alta de modelos y ficha. 🟡 **No se probó en vivo** (se marca 🟡 o 🔵 donde aparece): OpenRouter/Kimi u otro proveedor que no sea Azure, los grupos (solo pruebas automatizadas), el kit `managed-settings.json` instalado en una PC, Bedrock, Claude Code, el filtro de imágenes (a futuro, 🔵),
> la vuelta atrás de nivel 2 y la región real del recurso de Azure (US, a confirmar). La generación de imágenes no existe 🔵.
> Fuente: la guía «Claude Desktop con la pasarela» y la de «Redirección de modelos» del producto (rama de integración de la 057) y su verificación.

Los datos de Azure se anotaron en el Paso 0 y viven en `.env` del servidor (`AZURE_OPENAI_API_KEY`, `AZURE_OPENAI_ENDPOINT`); **no se copian a este documento**: se pegan en el panel.

**1. Credencial de Azure** — «Modelos» → «Credenciales» → crear. Proveedor Azure; **clave** (la del recurso) y **versión de API `2025-04-01-preview`** (o posterior: con una anterior el panel avisa, sin bloquear, y el producto sube la versión solo para las
herramientas y el razonamiento). La **dirección del recurso no va en la credencial**: va en cada modelo («Editar» → «Dirección base», punto 2). Las credenciales son **de solo escritura y no se editan**: el panel nunca devuelve la clave. Para
cambiarla (rotación, versión de API) se **crea otra credencial y se reasigna** a cada modelo que usaba la anterior (en «Editar», campo credencial). Cuando ya no la use ninguno, se borra la vieja.
🟢 Verificado en vivo el 7-oct-2026 (la credencial por sí sola no prueba nada: se prueba con el modelo, punto 2).

**2. Dar de alta los modelos** — «Modelos» → «Destinos» → «Dar de alta modelos». Proveedor **Azure**, el modelo **se busca por el nombre del despliegue** tal como existe en el recurso: `gpt-5.6-luna`, `gpt-5.1-chat`, `gpt-5.4-mini` y `gpt-4o-mini`
(los que no se vayan a usar, no se dan de alta). Asignar la credencial del punto 1 y cargar «Dirección base» (la del recurso, la misma de `AZURE_OPENAI_ENDPOINT`). Al guardar, el producto hace una **prueba mínima contra el recurso** («Verificar despliegue»):
si el nombre no es un despliegue existente, la entrada queda **inactiva** con el motivo «El despliegue … no existe en el recurso configurado» hasta que pase. Declarar también la **ventana de contexto real**, las capacidades que acepta (**Imágenes** y **PDF**
donde corresponda: sin «Imágenes», la pasarela reemplaza las imágenes por una nota), la **salida máxima** real y los parámetros no soportados (por ejemplo `temperature`).
Los **cuatro modelos de Azure que sembró el instalador** son de ejemplo y de **nivel instalación**: el `admin` no los ve; **cumplimiento** (`super_admin`) los archiva si no se usan (no se borran) o los ofrece a la empresa. 🟢 (alta y verificación de despliegue en vivo el 7-oct-2026)

**3. Ficha de cada modelo** — pestaña «Ficha». Quién escribe cada campo: los cinco primeros, **cumplimiento** (`super_admin`); el resto, el `admin`.

| Campo | Valor | Quién |
|---|---|---|
| Entidad responsable | Microsoft Corporation | cumplimiento |
| Jurisdicción de la entidad, de control y de registros | la **región real del recurso** de Azure (US en Elea, **a confirmar** en el portal de Azure); sin la de control el modelo no cuenta «en región» | cumplimiento (entidad y control); «registros», como lo permita la ficha del panel |
| Jurisdicción de inferencia | la **región real del recurso** de Azure (la misma; **a confirmar**); sin ella el modelo se rechaza | cumplimiento |
| Retención cero | **No** (salvo que Microsoft haya otorgado la exención a la suscripción) | cumplimiento |
| Entrena con datos | **No** | `admin` |
| Mecanismo de transferencia | contrato / cláusulas contractuales | `admin` |
| DPA | el acuerdo de tratamiento de datos de Microsoft, si la empresa lo tiene firmado (adjuntarlo o referenciarlo) | `admin` |

**Resultado esperado:** junto a cada modelo, el semáforo dice **Dentro de AMERICAS** y **Estándar** (no «Sin clasificar»). Con jurisdicción de inferencia vacía el modelo no sirve a nadie, aunque esté dado de alta. 🟢 (ficha cargada y modelos sirviendo en vivo el 7-oct-2026; la región real del recurso sigue **a confirmar**)
Las jurisdicciones de la tabla son datos de la ficha: nada de esto es una afirmación legal del producto (la base de las transferencias internacionales —Ley 25.326, art. 12— la cubre quien opera la instalación, por fuera del sistema).

**4. Modelos publicados** — «Modelos» → «Routing» → «Redirección» → «Modelos publicados». Cara **Claude**, uno por nivel: `claude-opus-5-5` (nivel *opus*), `claude-sonnet-5-5` (*sonnet*) y `claude-haiku-4-5` (*haiku*). El prefijo `claude` lo exige el panel y es lo que
la herramienta reconoce. **Etiqueta: «id pedido»**: la persona ve el mismo id que pidió y **nunca a qué modelo va** (ni en la lista ni en las respuestas). **Alcance**: toda la **organización**, o un **grupo** (punto 7); gana el más específico. 🟢 (etiqueta «id pedido» verificada en vivo el 7-oct-2026; el alcance por grupo, 🟡)

**5. Reglas y política** — pestaña «Reglas»: una regla por id publicado, con el **mismo alcance** que el id: `claude-opus-5-5` → `gpt-5.6-luna`, `claude-sonnet-5-5` → `gpt-5.1-chat`, `claude-haiku-4-5` → `gpt-5.4-mini`. Opcionalmente, un destino de respaldo (si el principal falla, responde el
siguiente y la auditoría lo anota). Después, pestaña «Política»: **encendida** para el alcance. **Sin la política encendida el id se manda tal cual al proveedor y falla.** Antes de usar la aplicación, la **«Vista previa»**: cada id tiene que resolver a su
modelo y ninguno aparecer como descartado (un modelo fuera de la postura de residencia **desaparece del selector**: es el comportamiento seguro y se corrige en la ficha o en la postura, no en el cliente). 🟢 (verificado en vivo el 7-oct-2026)

**6. Cambiar el destino de un tier sin tocar a los clientes** — en «Reglas», editar la regla del id y cambiar el destino principal; por ejemplo `claude-sonnet-5-5` pasa de `gpt-5.1-chat` a un modelo de **OpenRouter**, dado de alta antes con su propia **credencial de OpenRouter** (punto 1, otro proveedor), su
lista obligatoria de «Proveedores permitidos» (sin ella el alta da 422) y su ficha **con la jurisdicción del proveedor final de la lista, no la de OpenRouter**. Comprobar con la «Vista previa». El cliente sigue pidiendo el mismo id, ve la misma etiqueta y recibe el mismo id en `model`:
no se reinstala ni se reconfigura nada; solo cambia la ventana de contexto del destino y la auditoría registra el destino real de cada pedido. 🟡 (cubierto con un proveedor simulado; sin prueba en vivo). 🟢 El cambio de destino entre dos modelos **de Azure** (`claude-sonnet-5-5`: de `gpt-5.1-chat` a `gpt-5.6-luna`) sí se verificó en vivo el 7-oct-2026, confirmado en los registros y en la auditoría.

**7. Grupos: quién ve qué** — un grupo **«Todos»** que ve los tres ids (y los extra que se publiquen con su alcance) y un grupo **«Solo Azure»** que ve únicamente los que van a Azure. Se arma así: (a) los tres ids de la familia, **alcance organización**, con una regla de
organización hacia Azure; (b) un id extra (por ejemplo uno que va al modelo de OpenRouter) con **alcance de grupo «Todos»** y su regla del mismo alcance; (c) en la pestaña «Acceso», un **perfil de acceso** «Solo Azure» que **incluye solo el proveedor Azure**, asignado al
grupo. Qué pasa: la lista de modelos de cada llave trae solo lo suyo; un pedido de «Solo Azure» al id del otro grupo recibe 404 «Modelo no disponible para tu organización.»; y el perfil es el cinturón: «Solo Azure» **nunca llega a otro proveedor** aunque una regla de organización lo mande
(cae a un respaldo de Azure si lo hay; si no, 403 «Este modelo no está permitido para tu perfil.»). Comprobar con la «Vista previa» y con la lista de modelos de una llave de cada grupo. Una llave o persona **sin grupo** solo ve lo publicado para la organización. 🟡

**8. Llave por persona** — «Usuarios & Presupuestos» → «Llaves Virtuales» → «Generar Llave Virtual», herramienta **Claude Desktop**, a nombre de la persona (o del equipo responsable). **Límites: 1.000.000 tpm y 120 rpm.** Con los de fábrica (100.000 tpm / 60 rpm) entran 2 o 3 pedidos por minuto
(cada pedido de Claude Desktop pesa 35.000–67.000 tokens), el agente de Cowork recibe 429 y reintenta hasta 10 veces. La llave que emite el **kit** de «Modelos» → «Kits» ya nace con esos límites; una llave **ya existente** (o una generada a mano) se corrige con **«Editar límites»**, sin emitir otra
(rige de inmediato; si el motor no responde, el panel lo avisa y no cambia nada; solo el rol `admin`). Se entrega por el gestor de contraseñas de la empresa, nunca por chat ni correo. 🟢 «Editar límites» verificado en vivo el 7-oct-2026; 🟡 los límites con que nace la llave del kit, sin prueba en vivo.

**9. Claude Desktop en la PC de la persona** — sin iniciar sesión. «Help» → «Troubleshooting» → «Enable Developer Mode»; luego «Developer» → «Configure Third-Party Inference…» («Configurar inferencia de terceros»); al terminar «Apply Changes» → «Save & Restart» y salir **del todo** de la aplicación antes de volver a abrirla.

| Sección | Campo | Valor |
|---|---|---|
| Conexión | Proveedor | **Gateway** |
| Conexión | URL base del gateway | `https://<servidor>:8443/api/v1/gw` — **sin `/v1`** al final (la aplicación lo agrega; con `/v1` el pedido va a una ruta que no existe). `<servidor>` es uno de los nombres de `PROXY_TLS_NAMES`, el primero si se entra por IP; la PC tiene que confiar en el certificado («HTTPS para Claude Desktop»). El `http://<servidor>:8091/api/v1/gw` (HTTP plano, solo dentro de la VPN/LAN) sigue funcionando para Claude Code y para lo que ya estaba probado con él. |
| Conexión | Tipo de credencial | **Clave de API estática** (la llave del punto 8) |
| Conexión | Esquema de autenticación | `bearer` (no `sso`) |
| Conexión | Descubrimiento de modelos | **activado** (el selector se arma con los ids publicados para esa llave); «Lista de modelos» vacía |
| Conexión | Usar 1M de contexto por defecto | **desactivado** (evita que arranque en la variante de 1M si el destino no la tiene) |
| Espacio de trabajo | Hosts de egreso permitidos | **`* Permitir todo`** (o la lista que la empresa autorice): sin ella Cowork y Code no salen a internet |
| Espacio de trabajo | Omitir verificación de dominio de WebFetch | **activado** (sin esto, antes de leer una página consulta a un servicio que en modo gateway no responde) |
| Espacio de trabajo | Restricciones de Chat → Análisis avanzado de archivos | **activado** (lee adjuntos Excel, PowerPoint y PDF) |

Esta configuración (conexión y espacio de trabajo) está 🟢 verificada en vivo con la aplicación real el 7-oct-2026, **con la URL HTTP del `8091`**; con la URL HTTPS del `8443` (y la raíz instalada en la PC) 🟡 todavía no se probó en vivo: ver «HTTPS para Claude Desktop». En **Cowork**, elegir una **carpeta de trabajo** en cada tarea, mejor vacía y dedicada: sin carpeta el agente no tiene dónde escribir y falla al guardar (`FileNotFoundError`). Si una tarea falla por el modelo, se abre una tarea nueva con otro; no se reintenta en la misma.

**Alternativa para repartir a muchas PC: el kit.** «Modelos» → «Kits» → Claude Desktop genera un `managed-settings.json` con la dirección, el esquema y los modelos del alcance, para repartirlo con la gestión de dispositivos (si lleva credencial, emite una llave nueva y queda auditado). **Antes de repartirlo, abrirlo y
comprobar que `inferenceGatewayBaseUrl` sea la del servidor (`https://<servidor>:8443/api/v1/gw`)**: la toma de `REDIRECT_GATEWAY_URL` (Paso 6; por defecto, la HTTPS del primer nombre de `PROXY_TLS_NAMES`). Si no está configurada y no se puede deducir, el kit trae el marcador `REEMPLAZAR_CON_LA_URL_DE_LA_PASARELA` y el panel avisa; nunca la dirección interna del contenedor. 🟡

```bash
# En el servidor: la lista de modelos que ve esa llave (solo los ids publicados; sin destinos). Tiene que dar los ids del punto 4 que correspondan a su grupo.
cd ~/Eleia-cli
curl -s -H "Authorization: Bearer <LLAVE>" http://localhost:8091/api/v1/gw/v1/models
# Un kit generado: la dirección tiene que ser la del servidor.
grep -o '"inferenceGatewayBaseUrl"[^,}]*' "<ruta-del-managed-settings.json>"      # tiene que ser la del servidor, no la interna del contenedor
```

**10. Prueba de aceptación** — con la llave de una persona de prueba y datos **inventados** (nunca los de una persona real):

| Prueba | Qué hacer | Resultado esperado |
|---|---|---|
| Selector | Abrir Chat y desplegar el selector | los ids publicados para ese grupo, con el id como etiqueta y sin el destino |
| Chat con los tres modelos | «hola» con opus, sonnet y haiku; después, un mensaje con un **DNI de prueba** («Mi DNI es 12.345.678») | responde con cada uno; el DNI **sale enmascarado** hacia el modelo y vuelve restaurado |
| Cowork: PDF | tarea nueva, **carpeta de trabajo elegida**: «creame un PDF de una página sobre …» | el PDF queda en la carpeta, sin avisos de «Reintentando» |
| Cowork: presentación | lo mismo con «una presentación (PPT) de tres láminas sobre …» | el archivo queda en la carpeta |
| SVG | «diseñame un logo como SVG» | el SVG se genera y se guarda (los modelos **no generan imágenes**; sí diseñan SVG/HTML) |
| Auditoría | «Logs de Auditoría» (y, si no aparece ahí, la tabla `audit_logs`) | por pedido: id pedido y destino real, postura (`default_posture_applied`, `masked_all` por defecto), alcance del enmascarado (`masking_scope`); **solo metadatos**: nunca el texto ni el DNI |

Anotar **sin contenido** (fecha, ids, destino, postura, alcance) como evidencia. 🟢 Hechas en vivo el 7-oct-2026, salvo el detalle de postura y alcance en pantalla (ver el Paso 7, c).

**11. Notas**

* **Esfuerzo de razonamiento**: se ajusta solo por modelo. Si la herramienta pide un esfuerzo que el modelo no admite (`gpt-5.1-chat` solo acepta `medium`), la pasarela lo cambia al **más cercano que el destino acepta** y lo anota en la auditoría como ajuste de `reasoning_effort` (sin el valor): nunca un error por eso. 🟢 (verificado en vivo el 7-oct-2026 con `gpt-5.1-chat`)
* **Imágenes**: por ahora **salen sin filtro** hacia los modelos que aceptan imágenes (`MASKING_IMAGES=pass`, el valor por defecto del motor; el filtro de imágenes (`filter`) existe pero no se probó en vivo: a futuro, 🔵): tanto las que **adjunta la persona** como las capturas que devuelve una herramienta de Cowork. Cada imagen que sale sin revisar queda en la auditoría (`images_unmasked`, conteo y tipo). El **texto** se sigue enmascarando completo. Para volver a bloquearlas: `MASKING_IMAGES=filter` en el entorno de la extensión. Si el modelo no acepta imágenes, la pasarela avisa («Este modelo no acepta imágenes») y las imágenes de mensajes anteriores se reemplazan por una nota para que la conversación siga. La lectura de imágenes con `haiku`, `opus` y `sonnet` (este tras marcar «Imágenes» en su ficha) se probó en vivo con Claude Desktop el 7-oct-2026 🟢; el modelo tiene que tener marcado «Imágenes» en su ficha.
* **Los modelos no generan imágenes**: Cowork arma documentos, PDF y presentaciones ejecutando código, y puede **diseñar** SVG/HTML; una «imagen» generada por un modelo no existe.
* Los síntomas por contrato (403 «Failed to authenticate» + «Modelo no disponible para tu región.», 404 de organización, 429 de límites, `FileNotFoundError`, no lee páginas) están en la guía del producto «Claude Desktop con la pasarela»; el 403 con «Failed to authenticate» **no es** un error de credenciales: es el texto de la aplicación.

**Verificar.** (1) credencial creada y asignada; (2) cada modelo **activo** (la verificación de despliegue pasó); (3) semáforo **Dentro de AMERICAS · Estándar** en cada uno; (4) los tres ids publicados con etiqueta «id pedido»; (5) la «Vista previa» resuelve cada id sin descartados y la política está encendida;
(8) la llave aparece con 1.000.000 tpm / 120 rpm en «Llaves Virtuales»; la lista de modelos de esa llave (bloque de arriba) trae los ids esperados; (10) la prueba de aceptación completa, con la auditoría mostrando postura y alcance del enmascarado, sin contenido.

**Si falla**

| Síntoma | Qué hacer |
|---|---|
| El modelo queda **inactivo**: «El despliegue … no existe en el recurso configurado» | El nombre no es el del despliegue (se busca por **nombre de despliegue**, no por el del modelo), la «Dirección base» no es la del recurso o la credencial no es de ese recurso. Corregir y «Verificar despliegue». |
| El panel avisa de la versión de API al cargar la credencial | Es anterior a `2025-04-01-preview`: no bloquea, pero conviene crear otra credencial con esa versión y reasignarla (las credenciales no se editan). |
| Semáforo «Sin clasificar», o el id no aparece en el selector, o 403 «Modelo no disponible para tu región.» | Falta la jurisdicción de inferencia (o la de control) en la ficha, o la postura la excluye: lo corrige **cumplimiento** (punto 3). No es un problema de la llave. |
| `admin` recibe 403 al guardar la ficha | Los cinco campos de residencia son de cumplimiento (`super_admin`, Paso 4). |
| La lista de modelos está vacía o muestra un solo nivel | Política apagada para ese alcance, falta la regla de un nivel, o el id está publicado solo para otro grupo. Revisar la «Vista previa». |
| 404 «Modelo no disponible para tu organización.» | El id no está publicado para el alcance de esa llave, o la llave tiene una lista de modelos que no lo incluye. |
| 403 «Este modelo no está permitido para tu perfil.» | El perfil de acceso del grupo no admite el proveedor al que va la regla: corregir la regla o el perfil. |
| «Límite de solicitudes alcanzado. Reintentando… (intento 3 de 10)» | La llave tiene los límites de fábrica: «Editar límites» (punto 8). |
| `FileNotFoundError` al guardar en Cowork | La tarea no tiene carpeta de trabajo. |
| No lee páginas web | Faltan los hosts de egreso o omitir la verificación de WebFetch (punto 9). |
| Claude Desktop no conecta y la dirección es `http://backend:8000` | Es el kit con la URL interna (punto 9): corregir `inferenceGatewayBaseUrl` a la del servidor y volver a repartir. |
| «El pedido no pudo protegerse…» (400) | Algo no analizable que **adjuntó la persona** (imagen, PDF escaneado), o el analizador caído (`docker compose ps nlp-analyzer`, `./elea-logs.sh engine`). El pedido **no** sale sin proteger: es lo correcto. Quitar el adjunto o abrir una conversación nueva. |

## Usuario de cumplimiento (`super_admin`)

Cada instalación tiene dos tipos de usuario con poder de administración, y no son la misma persona:

| Usuario | Quién lo usa | Para qué |
|---|---|---|
| `admin` | quien administra la plataforma (TI) | usuarios, llaves, presupuestos, configuración. Su contraseña está en `.env` (`ADMIN_PASSWORD`). |
| `cumplimiento` (rol `super_admin`) | el oficial de cumplimiento de la empresa | **crea a los Auditores** y **relaja el enmascarado** de la 057 (qué datos se ven enmascarados y cuáles no). |

Separarlos es deliberado: quien administra la plataforma no es quien decide qué se audita ni qué se enmascara.

### Cómo se crea

* **Instalación nueva**: `./install.sh` lo crea solo, en su segunda corrida (la que levanta todo), con el usuario
  `cumplimiento` y el correo `cumplimiento@elea-internal.com`. Lo hace llamando a `./crear-super-admin.sh`.
  Si ese paso falla, la instalación sigue; la próxima corrida de `./install.sh` (o el comando a mano) lo reintenta.
* **Instalación que ya existía** (la actualización con `./install.sh` **no** lo crea, a propósito: aparece una
  credencial nueva y es una decisión de la empresa):

  ```bash
  ./crear-super-admin.sh                      # usuario «cumplimiento»
  ./crear-super-admin.sh --usuario oficial.cumplimiento --email oficial@empresa.com   # con otro nombre/correo
  ```

  Se corre **una vez**. Si ya hay un `super_admin` (cualquiera, no solo este usuario) lo informa y no toca nada, así
  que repetirlo no hace daño. No se puede llamar `admin`: ese es el administrador de la empresa. Hace falta el backend
  levantado (`docker compose ps`) y una imagen que traiga el comando; si el mensaje dice `No module named src.cli`,
  primero actualizar (`./install.sh`).

### La contraseña

* La **genera el backend** (alta entropía) y se muestra **una sola vez** en la pantalla donde se corrió el comando.
  No se escribe en `.env`, ni en ningún archivo del instalador, ni en los logs, y no viaja por los argumentos de ningún
  comando. Por eso no se puede volver a ver: si se pierde, no la recupera el instalador (el segundo intento da «ya hay un `super_admin`»).
* Es **temporal**: el usuario queda obligado a cambiarla en su primer ingreso (panel, `http://<servidor>:8090`) y el sistema
  registra la creación en la auditoría de autenticación.
* **Dónde guardarla**: en el gestor de contraseñas de la empresa, o en un sobre cerrado en la caja fuerte, entregada en
  mano a la persona de cumplimiento. **No** en `.env`, ni en el repositorio, ni por chat o correo. Hasta que esa persona
  la cambie, quien la vio en pantalla conoce una credencial de `super_admin`: conviene que el primer ingreso sea enseguida.
* **Si se pierde antes del primer ingreso**: si existe otro `super_admin` puede restablecerla desde el panel; si era el único,
  el instalador no tiene un camino para eso (no está probado acá cuál es el procedimiento en el backend): consultar al equipo
  antes de tocar la base a mano.

### Runbook (producción)

```bash
cd ~/Eleia-cli
docker compose ps backend                  # tiene que estar «healthy»
./crear-super-admin.sh                     # copiar la contraseña de la pantalla ANTES de seguir
#   «ya hay un super_admin…»  → no hace falta nada más (no se creó ni se cambió nada)
#   «No module named src.cli» → la imagen es anterior: ./install.sh y repetir
```

La pantalla puede quedar en el historial de la terminal: limpiarla (`clear`) y, si se corrió por una consola web o VPN,
cerrar la sesión al terminar.

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
| `api-proxy` (en `docker-compose.yml`, config en `proxy/Caddyfile`) | Proxy delante del backend: publica `8091` (HTTP) y `8443` (HTTPS) y responde 404 a `/api/v1/internal/*` por los dos; el backend ya no publica puertos. Ver «Proxy de la API» y «HTTPS para Claude Desktop». |
| `./respaldo.sh` | Copia de las dos bases (ver abajo). |
| `./migrar-base-motor.sh` | Pasa una instalación vieja (base compartida) a base propia, con vuelta atrás. |

### Proxy de la API (`/api/v1/internal/*` no sale de la red de Docker)

`/api/v1/internal/*` es el plano por donde el motor le pide al backend la identidad de cada llave y le
manda la auditoría. Se protege con tres capas, en toda instalación:

| Capa | Dónde | Qué hace |
|---|---|---|
| 1 | backend | Exige el secreto `ENGINE_MASTER_KEY` (sin él, 404). |
| 2 | backend (`INTERNAL_ALLOWED_CIDRS=auto` en `docker-compose.yml`) | Atiende ese plano solo si el pedido llega desde la red de compose. Hace falta una imagen del backend que traiga esta capa; una que no, ignora la variable y las otras dos siguen valiendo. |
| 3 | `api-proxy` (`proxy/Caddyfile`) | Es lo único que se publica hacia la LAN. Responde **404** a todo camino con un segmento `internal` (sin distinguir mayúsculas, con barras repetidas, `..` o letras codificadas), traiga o no el secreto, y deja pasar el resto al backend. |

Antes (ensayo del 06-oct-2026, `ENSAYO-SEPARAR-BASES.md`, §5) el backend publicaba `8091` y, con la llave maestra, ese
plano respondía desde cualquier máquina que alcanzara el puerto. Ahora el motor y el Hub le hablan a
`backend:8000` **por la red interna** (no pasan por el proxy) y el 404 se aplica solo al camino de afuera.

Qué sigue funcionando igual desde las PC: `http://<servidor>:8091/docs`, `/health`, `/api/v1/gw/*` (el gateway),
el login del panel y toda la API. No cambió ningún puerto (`8090` panel, `8091` API, `8095`/`8097` Hub).

Comprobarlo (desde cualquier PC de la LAN o desde el servidor; un pedido al gateway con una llave válida responde igual que antes):

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8091/health                              # 200
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8091/docs                                   # 200 (Swagger de la API)
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8091/api/v1/internal/identity            # 404
curl -s -o /dev/null -w '%{http_code}\n' -H "X-Sentinel-Internal: $ENGINE_MASTER_KEY" \
     http://localhost:8091/api/v1/internal/audit/probe                                              # 404 aunque traiga el secreto (antes: 200)
docker compose ps api-proxy backend                                                                 # backend sin puertos publicados; api-proxy en 0.0.0.0:8091
```

Notas de operación:

- **Al actualizar** una instalación que ya tenía el backend publicando `8091`: `./install.sh` recrea el backend
  (sin puerto) y arranca el proxy en la misma orden, así que el `8091` queda sin servicio unos segundos. Si otro
  proceso (que no es este instalador) usa el `8091`, el instalador se detiene antes y lo dice: liberarlo y volver a correr.
- Los logs del proxy: `./elea-logs.sh api-proxy`. Si el proxy aparece «unhealthy», casi siempre es el backend (el
  chequeo pasa por el camino completo).
- La imagen del proxy va fijada por digest en `docker-compose.yml` (la misma que usa el panel de producción);
  subirla es un cambio deliberado, por PR. Al subir de versión, correr `bash tests/test-proxy.sh` con un
  binario `caddy` de esa versión (`ELEA_CADDY_BIN=/ruta/caddy`): corre el proxy de verdad contra un backend de mentira.
- El `8091` es HTTP plano de LAN, igual que hasta ahora. El HTTPS (`8443`, con el mismo enrutamiento y el mismo 404 a `/api/v1/internal/*`) está en la sección siguiente.
- Con el proxy no se puede publicar un puerto del backend por error: no hay ningún `ports:` en el backend y
  `bash tests/test-proxy.sh` falla si aparece.

**Instalación nueva**: no hay nada que hacer; `./install.sh` crea las dos bases solo.

**Actualización de una instalación existente con base compartida**: ver el runbook. No usar
`docker compose up -d` a mano después de bajar el compose nuevo sin haber migrado: el motor arrancaría
sobre una base vacía (las llaves del motor viejo quedarían en `elea_gateway`). Siempre `./install.sh`
o `./migrar-base-motor.sh`.

### HTTPS para Claude Desktop

El proxy (`api-proxy`) publica, además del `8091` HTTP de siempre, un **HTTPS en el `8443`** (`PROXY_HTTPS_PORT`) con
**el mismo enrutamiento**: todo pasa al backend, salvo `/api/v1/internal/*`, que da **404 también por el `8443`**. El Hub y los
servicios siguen por el `8091`. La URL que se configura en Claude Desktop es `https://<servidor>:8443/api/v1/gw`
(`<servidor>` = el primer nombre de `PROXY_TLS_NAMES`, por defecto la IP del servidor).

| Variable (`.env`) | Qué es | Por defecto |
|---|---|---|
| `PROXY_HTTPS_PORT` | Puerto HTTPS publicado en el servidor | `8443` (dentro del contenedor es siempre 8443) |
| `PROXY_TLS_NAMES` | IPs y/o nombres DNS con que las PC llegan al servidor, **separados por coma y sin espacios** | la IP del servidor y su hostname (`./install.sh` los completa) |
| `PROXY_TLS_CERT`, `PROXY_TLS_KEY` | Certificado y llave **de la empresa**: rutas absolutas de archivos del servidor, **fuera del repo**, las dos juntas; se montan de solo lectura | vacías → CA interna |
| `REDIRECT_GATEWAY_URL` | URL de la pasarela que llevan los kits de Claude Desktop | `https://<primer nombre de PROXY_TLS_NAMES>:<PROXY_HTTPS_PORT>/api/v1/gw` con la extensión de redirección; el `.env` la pisa |

**Hay que elegir una de dos variantes de certificado.**

**Variante A (recomendada): certificado de la empresa.** Un certificado emitido por la CA de la empresa (o una pública) para el
nombre con que las PC llegan al servidor (p. ej. `elea.empresa.com.ar`; el servidor puede tener también la IP como SAN). Las PC ya
confían en la CA de la empresa: **no hay nada que instalar en ellas** y se renueva con el proceso de certificados de la empresa.

```bash
# En el servidor (rutas fuera del repo; la llave solo legible por quien administra el servidor):
sudo install -d -m 755 /etc/ssl/elea
sudo install -m 644 elea.crt /etc/ssl/elea/elea.crt          # certificado + cadena intermedia, en PEM
sudo install -m 600 elea.key /etc/ssl/elea/elea.key          # llave privada, en PEM (nunca dentro del repo)
# En ~/Eleia-cli/.env:
#   PROXY_TLS_NAMES=elea.empresa.com.ar
#   PROXY_TLS_CERT=/etc/ssl/elea/elea.crt
#   PROXY_TLS_KEY=/etc/ssl/elea/elea.key
```

`./install.sh` valida antes de tocar nada que las dos rutas existan, sean absolutas, no estén dentro del repo y que el certificado sea un PEM
válido; el proxy lo vuelve a comprobar al arrancar y se niega a hacerlo con uno solo de los dos. Para renovar: reemplazar los archivos y
`docker compose restart api-proxy`. `PROXY_TLS_NAMES` tiene que ser el nombre (o los nombres) del certificado: el proxy enruta por ellos.

**Variante B: CA interna del proxy + GPO.** Sin `PROXY_TLS_CERT`/`PROXY_TLS_KEY`, el proxy emite el certificado con su propia CA para
los nombres de `PROXY_TLS_NAMES`. Esa CA **persiste** en el volumen `proxy_caddy_data` (`/data` del contenedor): la raíz que se instala en las PC no cambia
al actualizar ni al recrear el contenedor; **solo cambia si se borra el volumen** (`docker compose down -v`, que no se hace). El certificado
del servidor lo renueva solo; la raíz (válida 10 años) se instala **una vez** en cada PC:

```bash
cd ~/Eleia-cli
./exportar-ca.sh                    # copia SOLO la raíz pública a ~/eleia-ca-raiz.crt (nunca la llave) e imprime la huella y las instrucciones
```

* **Windows, por GPO** (`gpmc.msc` → una GPO vinculada a las PC → Configuración del equipo → Directivas → Configuración de Windows → Configuración de seguridad →
  Directivas de clave pública → **Entidades de certificación raíz de confianza** → Importar `eleia-ca-raiz.crt`; en cada PC `gpupdate /force`). Alternativas
  por línea de comandos: `certutil -addstore -f Root eleia-ca-raiz.crt` (una PC, como administrador) o `certutil -dspublish -f eleia-ca-raiz.crt RootCA` (todo el dominio).
  Cerrar del todo Claude Desktop y volver a abrirlo.
* **macOS**: `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain eleia-ca-raiz.crt`, o un perfil de configuración (MDM) con un payload «Certificado».
* **Claude Code** usa su propio almacén: `export NODE_EXTRA_CA_CERTS=/ruta/a/eleia-ca-raiz.crt` y `export ANTHROPIC_BASE_URL=https://<servidor>:8443/api/v1/gw`.
* **Cotejar la huella** SHA-256 que imprime `./exportar-ca.sh` con la de la raíz que llegó a la PC: `openssl x509 -in eleia-ca-raiz.crt -noout -fingerprint -sha256` (macOS/Linux) o `certutil -dump eleia-ca-raiz.crt` (Windows, muestra «Cert Hash(sha256)»).

**Qué nombre usar.** Una PC que entra por una **IP** no manda el nombre en el saludo TLS y el proxy le presenta el certificado del **primer** nombre de
`PROXY_TLS_NAMES`: por eso `./install.sh` pone la IP del servidor primero. Entrar por otra IP de la lista no valida; por un nombre DNS de la lista, sí. Si las PC usan
un nombre, ponerlo primero. La URL, el certificado y `PROXY_TLS_NAMES` tienen que decir lo mismo.

**Verificar desde una PC** (no desde el servidor). Con la CA interna, `curl` falla **sin** la raíz y funciona **con** ella:

```bash
curl -v https://172.16.0.120:8443/health                                    # sin la raíz: «SSL certificate problem: unable to get local issuer certificate»
curl -v --cacert eleia-ca-raiz.crt https://172.16.0.120:8443/health         # con la raíz: HTTP 200
curl -s -o /dev/null -w '%{http_code}\n' --cacert eleia-ca-raiz.crt https://172.16.0.120:8443/api/v1/internal/identity   # 404
# Con el certificado de la empresa el primero ya da 200 sin --cacert.
```

Después, **Claude Desktop** con `https://<servidor>:8443/api/v1/gw` («Developer» → «Configure Third-Party Inference…», Paso 9): si lista los modelos, la PC confía en el certificado.
Si da un error de certificado, la raíz no está instalada en esa PC (o se entró por un nombre que no está en `PROXY_TLS_NAMES`).

**Runbook del servidor** (con corte corto: `./install.sh` recrea el proxy para publicar el `8443`):

```bash
cd ~/Eleia-cli
git pull                                  # trae el HTTPS del proxy
# Variante A: cargar PROXY_TLS_NAMES, PROXY_TLS_CERT y PROXY_TLS_KEY en .env (arriba). Variante B: no hace falta nada; opcional fijar los nombres:
#   PROXY_TLS_NAMES=172.16.0.120,elea-srv   (la IP que usan las PC primero)
nano .env
./install.sh                              # completa PROXY_TLS_NAMES/PROXY_HTTPS_PORT si faltan, levanta el proxy con el 8443 y comprueba /health y el 404 de internal por HTTPS
./exportar-ca.sh                          # solo Variante B: copia la raíz pública a ~/eleia-ca-raiz.crt y muestra las instrucciones de GPO/macOS
docker compose ps api-proxy               # sano; 0.0.0.0:8091 y 0.0.0.0:8443
curl -sk -o /dev/null -w '%{http_code}\n' https://localhost:8443/health                       # 200 (-k: solo comprueba el proxy)
curl -sk -o /dev/null -w '%{http_code}\n' https://localhost:8443/api/v1/internal/identity     # 404
```

Si el puerto `8443` lo usa otro proceso, `./install.sh` se detiene antes y lo dice: liberarlo o poner otro en `PROXY_HTTPS_PORT`. El firewall del servidor tiene que dejar
pasar el puerto HTTPS desde la VPN/LAN, igual que el `8091`. Los logs: `./elea-logs.sh api-proxy`.

**Estado de esta función** (leyenda: 🟢 verificado en vivo, 🟡 cubierto por pruebas pero sin prueba en vivo, 🔵 a futuro):

* 🟢 Verificado en local con Docker el 7-oct-2026 (proxy levantado con el `docker-compose.yml` real en una carpeta de prueba): `curl -k https://localhost:8443/health` → 200; `/api/v1/internal/identity` → **404 por el 8443** (y por el 8091); `./exportar-ca.sh` copia solo la raíz pública y esa raíz **valida** el certificado (`curl --cacert`) por nombre y por IP; sin ella `curl` falla; la raíz es **la misma** después de bajar y volver a levantar el proxy (`docker compose down` sin `-v`); con un certificado de la empresa montado, el proxy sirve ese y `./exportar-ca.sh` se niega (no hay CA interna que exportar); con solo uno de los dos archivos, el proxy no arranca y lo dice. **Claude Code** (`claude -p`, `CLAUDE_CONFIG_DIR` propio, `ANTHROPIC_BASE_URL=https://localhost:8443/api/v1/gw` y `NODE_EXTRA_CA_CERTS` con la raíz) llegó al backend de prueba por el HTTPS (recibió el 401 sin llave); sin `NODE_EXTRA_CA_CERTS` falla con «SSL certificate verification failed».
* 🟡 Sin probar en vivo: **Claude Desktop** contra la URL HTTPS en una PC real, la instalación de la raíz por GPO en Windows y por MDM/llavero en macOS (las instrucciones son las del sistema operativo y no se ejecutaron acá), y el certificado de la empresa de verdad (se probó uno de prueba).
* 🔵 A futuro: la rotación programada de la raíz de la CA interna (hoy dura 10 años y solo cambia si se borra el volumen).

Pruebas sin Docker: `bash tests/test-https.sh` (con `ELEA_CADDY_BIN=/ruta/a/caddy` corre el proxy de verdad y valida la CA, el 404 por HTTPS, la persistencia y el certificado de la empresa).

### Separar la base del motor — runbook de producción (VPN + consola web)

> **Estado de la verificación.** El procedimiento se ensayó **a mano** con Docker el 06-oct-2026, y los
> scripts se probaron contra un Docker simulado (`bash tests/test-base-motor.sh`) y **de punta a punta con
> contenedores reales** ese mismo día (`ENSAYO-SEPARAR-BASES.md`): instalación nueva, actualización de una
> instalación vieja con la compuerta de integridad, vuelta atrás B y arranque normal del motor con
> `DISABLE_SCHEMA_UPDATE=true`. **No se probaron con contenedores reales**: la vuelta atrás A, la C, el borrado
> de las copias viejas, `--volver-a-separar` y el proxy `api-proxy` (estos dos últimos, solo con Docker simulado
> y con un Caddy real fuera de Docker). Los tiempos de abajo son de una PC con datos de prueba; el servidor de
> Elea no se midió.

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
llave. El panel de costos lee la auditoría y no debería cambiar de criterio. **Usar un texto distinto en cada
pregunta de la prueba**: el motor parece cachear los pedidos idénticos (ensayo del 06-oct-2026, §6.4: de 5 pedidos
iguales solo el primero sumó gasto; los demás dieron gasto 0 y 1–2 s de latencia). No tiene que ver con separar
las bases (pasa también con la base compartida): una pregunta repetida que no sube el gasto no es una falla de la migración.

Cuando todo esté bien, `./install.sh` completa la actualización normal (resto de las imágenes, etc.).

**Vuelta atrás** (cada escalón ensayado a mano; los scripts aún no contra contenedores reales):

| Escalón | Cuándo | Qué hacer |
|---|---|---|
| **A** | El script falla *antes* de apuntar el motor a la base nueva (copia o compuerta) | **Automática**: borra `elea_engine` (solo si la creó esa corrida) y arranca con `docker start` los contenedores viejos tal como estaban. El `.env` no se toca. |
| **B** | Después de apuntar el motor, mientras las tablas viejas sigan en `elea_gateway` | `./migrar-base-motor.sh --vuelta-atras` (pide escribir `VOLVER`; ~50 s). Pone en `.env` `ENGINE_DB=<base del Guardian>`, `ENGINE_IDENTITY_URL=`, `ENGINE_AUDIT_URL=` (vacías = camino por SQL de la base compartida) y la imagen anterior en `ENGINE_IMAGE`, y recrea el motor. Se pierde solo el gasto que el motor contó en `elea_engine` desde el corte (la auditoría vive en el Guardian y no se afecta). Anota la base que se separó (`.migracion-motor/base-motor-separada`) y deja `elea_engine` con sus tablas, sin tocarla. Queda otra vez con base compartida: no subir la imagen del motor hasta volver a separar (ver abajo). |
| **C** | `elea_gateway` dañada | Restaurar la copia completa en una base nueva y comprobarla (ver abajo). |

**Volver a separar después de una vuelta atrás B.** Con la vuelta B el `.env` queda con `ENGINE_DB` igual a
`POSTGRES_DB`, y el comando pelado `./migrar-base-motor.sh` **no sirve en ese estado**: se niega (código ≠ 0) y
dice cuál usar. El comando es:

```bash
./migrar-base-motor.sh --volver-a-separar --dry-run   # el plan con los nombres reales, sin tocar nada
./migrar-base-motor.sh --volver-a-separar             # pide escribir SEPARAR; mismo corte que la primera vez
```

Hace lo mismo que la separación original (previa con copia completa, corte, `pg_dump -T`, compuerta de
integridad, apuntar el motor con las dos URL internas, verificar), con estas diferencias:

- La base a la que vuelve la toma de la nota que dejó la vuelta B (`.migracion-motor/base-motor-separada`);
  sin nota, `elea_engine`.
- La base vieja del motor (la que quedó con tablas desde la separación anterior) **se renombra a
  `elea_engine_vieja_<fecha>`, no se borra**. Si un paso falla antes de apuntar el motor, la vuelta atrás A le
  devuelve su nombre. Borrarla es decisión de una persona (`DROP DATABASE`, con copia previa); el gasto que contiene
  desde el corte anterior ya se había dejado fuera con la vuelta B.
- En `.env` repone `ENGINE_DB`, borra las URL vacías y quita `ENGINE_IMAGE` (vuelve la imagen fijada por digest).
- Solo vale con la vuelta B activa (`ENGINE_DB` = `POSTGRES_DB`) y con las tablas del motor todavía en la base del
  Guardian; si no, se niega y lo dice. `./install.sh` **no** vuelve a separar solo después de una vuelta B: avisa y sigue con la base compartida.

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

El digest que trae este repo es el de la etiqueta `2026-10-08` (`sha256:520a8d72…1abd7`): la `2026-10-07` (arreglos de la base de la 057:
detección de llaves, enmascarado y caché) más `ROUTER_EMBEDDINGS_DEPLOYMENT`. Tiene la misma LiteLLM que las `2026-09-17` (`sha256:1928af9d…6189dafe`) y `2026-09-14`
(1.92.0 / proxy-extras 0.4.74, verificado el 7-oct), así que pasar de una a otra no trae migraciones del motor.

## Extensión de redirección de modelos (opcional, apagada por defecto)

Permite que Claude Desktop y Claude Code de los empleados le hablen a la pasarela del Guardian y que sus pedidos se sirvan
con los modelos de Azure de Elea que el administrador de la empresa publica en el panel («Modelos»; el orden está en el Paso 9), con el enmascarado de datos personales
(seudonimización reversible) que rija para cada destino. Se activa **a propósito**, por instalación, con una variable:

* **Sin `ELEA_REDIRECT`, este instalador hace exactamente lo de siempre**: `docker-compose.yml` no cambia ni un byte (la extensión
  es un archivo aparte, `docker-compose.redirect.yml`, que solo se suma cuando se la activa) y `./activar-redirect.sh` no escribe ni recrea nada.
* **Con `ELEA_REDIRECT=1`**: backend, panel y motor pasan a las imágenes `-ext` de **la misma versión publicada**
  (`ghcr.io/cluna-8/elea-guardian-{backend,frontend,engine}:<ELEA_EXT_VERSION>-ext`; las `-ext` derivan de las imágenes base y solo les
  suman archivos; **nunca mueven `latest`**), el backend arranca con `alembic upgrade heads` (la extensión trae su propia rama de
  migraciones) y backend y motor reciben el entorno de la extensión, que genera el instalador en un archivo **fuera del repo, modo 600**
  (`~/.config/elea/redirect.env`, o `ELEA_REDIRECT_ENV_FILE=/ruta/absoluta`). Ese archivo tiene secretos (`REDIRECT_INTERNAL_KEY`,
  `MASKING_NONCE_KEY`): nunca se versiona ni se imprime; las llaves se generan **una vez** y no se pisan al repetir `./install.sh`.
  Lo que el operador agregue ahí (credenciales de destinos de la instalación) se conserva.
* **Siembra** (solo con la extensión): las regiones (`AMERICAS`) y la habilitación (reglas vacías: ningún destino bloqueado de fábrica) las
  carga el backend solo al arrancar; el catálogo de ejemplo de Azure lo siembra el instalador **una vez**. En el panel, cumplimiento
  completa, por destino, la jurisdicción de inferencia y la entidad responsable (sin jurisdicción de inferencia el destino se rechaza) y el administrador de la empresa hace el resto (Paso 9).

> **Estado de la verificación.** Este procedimiento se probó con un Docker simulado (`bash tests/test-redirect-optin.sh`, `bash tests/test-runbook-redirect.sh`), con `docker compose config -q` y,
> en T102 (7-oct-2026), con **contenedores reales**: activación con `ELEA_REDIRECT=1`, salud 200, plano interno 404 (desde el servidor y desde la IP de la LAN), consola y «Routing» → «Redirección», y el
> nivel 1 de la vuelta atrás (`EVIDENCIA-T102.md`). **No se probó con contenedores** el nivel 2, el respaldo en código con la fila de región borrada ni una migración rota a propósito. Sobre esa misma instalación, el owner probó en vivo el 7-oct-2026 Claude Desktop contra Azure (conexión por gateway, los tres niveles, cambio de destino, DNI enmascarado, Cowork, imágenes: ver el Paso 9); **Claude Code** y el kit `managed-settings.json` instalado en una PC siguen sin probarse en vivo.
>
> **Tag mínimo.** El instalador solo activa la extensión con una `ELEA_EXT_VERSION` igual o posterior a `ELEA_EXT_MIN_VERSION`, la fecha del primer juego de imágenes que trae el chequeo de origen
> del canal interno. Hoy esa constante (en `install.sh`) vale `2026-10-07`: el candidato construido en T102, **todavía no publicado** (ver «Imágenes del candidato» en el runbook). Con una fecha anterior,
> o sin `ELEA_EXT_VERSION`, **`ELEA_REDIRECT=1` falla cerrado** con un mensaje que lo explica. Un valor puesto en `.env` no la baja.

> **Servidor de Elea (consola web por VPN):** el orden completo y con guardas para pegar —respaldo, separar la base del motor, usuario de cumplimiento, verificación sin redirección, activar,
> verificar y los dos niveles de vuelta atrás— está en «Actualizar el servidor de Elea (057 + bases separadas)». Esta sección es la referencia de la extensión.

### Antes de activar

El instalador comprueba tres condiciones y, si falta alguna, **no toca nada** y termina con un error que la explica:

1. el compose del instalador tiene el proxy de la API (`api-proxy`) y el backend no publica puertos (sale solo el proxy, que niega `/api/v1/internal/*`);
2. `ELEA_EXT_VERSION` >= `ELEA_EXT_MIN_VERSION` (ver arriba);
3. `/api/v1/internal/*` da 404 por el puerto publicado (8091), con el Guardian ya levantado.

Además, por tu cuenta:

* La versión: `ELEA_EXT_VERSION=AAAA-MM-DD` es el `VERSION` con que `deploy/release/publish-elea.sh` (repo `elea`) publicó las imágenes `-ext`
  (no hay valor por omisión: ni `latest` ni una fecha implícita). Si una imagen no se publicó, el instalador lo dice al bajarla y no activa nada.
* El motor `-ext` deriva del motor base **de esa versión**: fijalo por digest con la línea `PINNED elea-guardian-engine=…@sha256:…` que imprime `publish-elea.sh` al publicar la `-ext` (viene después de la de la imagen base)
  (`ENGINE_EXT_IMAGE=` en `.env`; igual `BACKEND_EXT_IMAGE` y `FRONTEND_EXT_IMAGE`) y, después de activar, confirmá con
  `./migrar-base-motor.sh --verificar` que el libro de migraciones del motor no cambió.
* Ventana: la activación recrea el motor, el backend y el panel (un corte corto de la API, el panel, el Hub, planillas y presentaciones).

### Respaldo previo

**Antes de activar**, la copia de las dos bases. Volver a las imágenes base **solo** se puede restaurándola (ver «Vuelta atrás»):

```bash
cd ~/Eleia-cli
git pull origin main
./respaldo.sh                              # respaldos/AAAA-MM-DD-HHMMSS/{elea_gateway.dump,elea_engine.dump,SHA256SUMS}
```

Copiar esa carpeta **fuera del servidor** (`scp` o el almacenamiento de la empresa) antes de seguir: en el mismo servidor no es un respaldo.
`./install.sh` toma además un respaldo propio al activar por primera vez (`ELEA_SIN_RESPALDO=1` lo omite, bajo tu responsabilidad: sin él no hay nivel 2).

### Activar

```bash
cd ~/Eleia-cli
echo 'ELEA_REDIRECT=1'                  >> .env
echo 'ELEA_EXT_VERSION=AAAA-MM-DD'      >> .env     # la versión publicada con las imágenes -ext
./install.sh
```

`./install.sh` hace su actualización normal y, al final, `./activar-redirect.sh`: comprueba las tres condiciones, baja las `-ext`, toma el respaldo,
escribe el entorno de la extensión, recrea motor, backend y panel, espera al backend (si una migración de la extensión falla, el backend **aborta**
el arranque y el instalador lo dice), comprueba que los seeds estén en la imagen y consulta `/api/v1/redirect/health`. **Cualquier respuesta que no
sea 200 es un error visible** (503 de la postura de respaldo, 404 de una imagen `-ext` inerte). Deja en `.env` las marcas que necesita para recordar la
activación (`ELEA_REDIRECT`, `ELEA_EXT_VERSION`, `COMPOSE_FILE`, `EXTRA_ENV_FILE`, `ELEA_REDIRECT_ACTIVADA`, `ELEA_REDIRECT_CATALOGO`): no tienen secretos,
y con `COMPOSE_FILE` todo `docker compose` de esta carpeta ve las imágenes `-ext`. Repetir `./install.sh` es seguro.

### Verificar

```bash
# En el servidor (el puerto publicado es el del proxy, 8091):
curl -s -w '\n%{http_code}\n' http://localhost:8091/api/v1/redirect/health      # 200
curl -s -H "Authorization: Bearer <LLAVE>" http://localhost:8091/api/v1/gw/v1/models   # los modelos publicados para esa llave
curl -s http://localhost:8091/api/v1/gw/v1/messages \
  -H "Authorization: Bearer <LLAVE>" -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' \
  -d '{"model":"<ID PUBLICADO>","max_tokens":32,"messages":[{"role":"user","content":"Respondé solo: ok"}]}'
# Desde OTRA máquina de la LAN/VPN (no desde el servidor): el plano interno tiene que estar cerrado.
curl -s -o /dev/null -w '%{http_code}\n' http://<servidor>:8091/api/v1/internal/identity     # 404
```

* `/api/v1/redirect/health`: **200** = la extensión está activa y su región está resuelta. **503** con `region_unresolved` o `region_row_missing` =
  rige el respaldo en código (se rechaza todo lo redirigido): los seeds no se cargaron; mirar `./elea-logs.sh backend`. **404** = la extensión no está
  montada (imagen `-ext` sin entorno): revisar `docker compose ps backend` y que `EXTRA_ENV_FILE` (en `.env`) exista.
* `/api/v1/gw/v1/models` lista los modelos publicados para esa llave; sin nada publicado todavía en «Modelos», no hay qué listar.
* El pedido de prueba no lleva datos personales: la auditoría registra metadatos (modelo pedido, destino, enmascarado aplicado), nunca el texto.
* `/api/v1/internal/*` ⇒ 404 desde afuera es el requisito de seguridad de la activación. Si da otra cosa, **apagar la extensión** (nivel 1) y avisar.
* Publicar los modelos, las reglas y encender la política es trabajo del panel («Modelos») y lo hace el `admin` de la empresa, con cumplimiento solo para los campos de residencia de la ficha (Paso 9 del runbook): el instalador no lo hace.

### Configurar Claude Desktop y Claude Code de los empleados

> **Antes de esto, el panel.** Ninguna herramienta responde hasta que el `admin` de la empresa haya dado de alta los modelos, publicado los ids, mapeado las reglas, encendido la política y creado las llaves: el orden, con cómo verificar cada paso, está en el **Paso 9** del runbook
> «Actualizar el servidor de Elea (057 + bases separadas)». Esta sección es la referencia de lo que va en la PC de cada persona.

Una **llave por persona** (con **1.000.000 tpm y 120 rpm**: con los límites de fábrica el agente de Cowork recibe 429): se crea en el panel del Guardian (`http://<servidor>:8090`, «Usuarios & Presupuestos» → «Llaves Virtuales») y se entrega en mano o por el gestor de contraseñas de la
empresa (canal seguro), nunca por chat ni correo. La URL de la pasarela es `https://<servidor>:8443/api/v1/gw` para Claude Desktop (ver «HTTPS para Claude Desktop») y
`http://<servidor>:8091/api/v1/gw` para el resto (`<servidor>` = el nombre o la IP con que las PC llegan al servidor **por la VPN**). El
tráfico del `8091` va por **HTTP plano**: solo dentro de la VPN/LAN de la empresa.

* **Claude Code** (variables de entorno de la PC de la persona):

  ```bash
  export ANTHROPIC_BASE_URL=http://<servidor>:8091/api/v1/gw
  export ANTHROPIC_AUTH_TOKEN=<LLAVE>
  # opcional, con los ids publicados que la versión instalada de Claude Code reconozca:
  # export ANTHROPIC_DEFAULT_SONNET_MODEL=<ID PUBLICADO>
  ```

* **Claude Desktop** (modo de terceros, pasarela): `inferenceProvider = gateway`, `inferenceGatewayBaseUrl = https://<servidor>:8443/api/v1/gw`,
  la llave virtual como credencial, `inferenceGatewayAuthScheme = bearer` y el descubrimiento de modelos activado (así lista los modelos publicados). Por la pantalla de la aplicación («Developer» → «Configure Third-Party Inference…»): en *Conexión*, Gateway, la URL **sin `/v1`**, «Clave de API estática»
  y `bearer`; en *Espacio de trabajo*, hosts de egreso «`* Permitir todo`», «Omitir verificación de dominio de WebFetch» y «Análisis avanzado de archivos» activados; y en Cowork, una **carpeta de trabajo** por tarea. Con el `managed-settings.json` del kit de «Modelos» → «Kits», comprobar antes que `inferenceGatewayBaseUrl` sea la del servidor y no `http://backend:8000`. Todo, con sus pruebas de aceptación, en el Paso 9.
  Si un rechazo de residencia (403) aparece con «Failed to authenticate» antepuesto, es el texto de Claude Desktop, no un error de la llave.

### Vuelta atrás (dos niveles)

**Cuál elegir.** El nivel 1 *apaga* la extensión y se hace en minutos, sin tocar datos. El nivel 2 *vuelve a las imágenes base* y **solo** se puede
con el respaldo previo a la activación: con las migraciones de la extensión aplicadas, el rollback a una imagen sin la extensión **no está soportado**
(la imagen base fallaría al arrancar por revisiones desconocidas en la base). **Sin el respaldo previo no hay nivel 2.**

#### Nivel 1 — apagar

1. En el panel («Modelos»), dejar la política **Apagada** para el alcance: los pedidos vuelven al camino de siempre.
2. Sacar la variable y correr el instalador:

   ```bash
   cd ~/Eleia-cli
   unset ELEA_REDIRECT
   sed -i '/^ELEA_REDIRECT=/d' .env
   ./install.sh
   ```

   `./activar-redirect.sh` ve la activación anterior (`ELEA_REDIRECT_ACTIVADA=1`), quita `GATEWAY_PLUGINS` y `PLUGIN_PACKAGES` del entorno de la
   extensión y recrea motor y backend. **Conserva** la imagen `-ext` del backend (y la del panel y el motor) y `ALEMBIC_EXTRA_VERSION_LOCATIONS`: con las
   migraciones ya aplicadas, la imagen base no arranca (el `upgrade head` falla por revisiones desconocidas). Las rutas de la extensión desaparecen
   (`/api/v1/redirect/health` pasa a 404: es lo esperado) y la pasarela queda como antes. Para volver a encender: poner otra vez `ELEA_REDIRECT=1`.

#### Nivel 2 — volver a las imágenes base

**Solo** restaurando el respaldo previo (`respaldos/<fecha>/`, el que se tomó **antes** de activar). Se pierde todo lo que pasó después de ese respaldo
(usuarios, llaves, auditoría, gasto). El procedimiento no borra nada: la base con la extensión se renombra, no se elimina. Mismo patrón que la «Vuelta C»;
**el cambio de nombre y el arranque con las imágenes base no se probaron con contenedores reales**:

```bash
cd ~/Eleia-cli
./respaldo.sh                                      # copia del estado ACTUAL, por si hay que deshacer esto
set -a; source .env; set +a
D=respaldos/AAAA-MM-DD-HHMMSS                      # el respaldo previo a la activación; verificar: (cd $D && sha256sum -c SHA256SUMS)
docker exec elea-db psql -U "$POSTGRES_USER" -d postgres -c 'CREATE DATABASE elea_gateway_restaurada'
docker exec -i elea-db pg_restore -U "$POSTGRES_USER" -d elea_gateway_restaurada --no-owner --exit-on-error < "$D/elea_gateway.dump"
docker compose stop api-proxy frontend client tabular presenton anythingllm backend engine
docker exec elea-db psql -U "$POSTGRES_USER" -d postgres \
  -c 'ALTER DATABASE "elea_gateway" RENAME TO "elea_gateway_con_extension"' \
  -c 'ALTER DATABASE "elea_gateway_restaurada" RENAME TO "elea_gateway"'
# Sacar del instalador todo lo de la extensión (en .env y en esta sesión) y volver a las imágenes base:
sed -i -E '/^(ELEA_REDIRECT|ELEA_EXT_VERSION|COMPOSE_FILE|EXTRA_ENV_FILE|ELEA_REDIRECT_ACTIVADA|ELEA_REDIRECT_CATALOGO|BACKEND_EXT_IMAGE|FRONTEND_EXT_IMAGE|ENGINE_EXT_IMAGE)=/d' .env
unset ELEA_REDIRECT ELEA_EXT_VERSION COMPOSE_FILE EXTRA_ENV_FILE ELEA_REDIRECT_ACTIVADA ELEA_REDIRECT_CATALOGO BACKEND_EXT_IMAGE FRONTEND_EXT_IMAGE ENGINE_EXT_IMAGE
./install.sh                                       # sin las variables, compose vuelve a ver solo docker-compose.yml: imágenes base
```

La extensión solo agrega tablas a la base del Guardian: la base del motor (`elea_engine`) no se restaura (el motor `-ext` deriva del mismo digest del motor
base; confirmar con `./migrar-base-motor.sh --verificar` después). Cuando todo ande, el archivo de entorno de la extensión (`~/.config/elea/redirect.env`) se borra
a mano y, si se vuelve a activar más adelante, se generan llaves nuevas. La base `elea_gateway_con_extension` se borra solo por decisión de una persona (`DROP DATABASE`, con copia previa).

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

**`/api/v1/internal/...` da 404 desde mi PC** (o desde el servidor, por `localhost:8091`): es lo esperado. Ese plano
solo se habla por la red interna entre el motor y el backend; el proxy lo niega a propósito (ver «Proxy de la API»).
Si el 404 aparece en `/api/v1/gw/*` o en el resto de la API, no es esto: revisar `docker compose ps` y `./elea-logs.sh backend`.

**`./install.sh` dice que el puerto 8091 lo usa otro proceso**: el proxy de la API necesita ese puerto. `ss -ltnp | grep 8091`
muestra quién lo tiene; liberarlo y volver a correr.

**El ruteo semántico cae siempre al modelo por defecto** (la decisión de ruteo queda degradada con el motivo `embed_error`; en `./elea-logs.sh backend` se lee «Auto-router: fallo al embeber»): lo más común es que el **despliegue de embeddings** no se llame como cree el motor. En `./elea-logs.sh engine` aparece algo como `DeploymentNotFound` / «The API deployment for this resource does not exist». Arreglo: listar los despliegues del recurso con la llave de `.env` (README, «Despliegue de embeddings del ruteo»), poner el nombre correcto en `ROUTER_EMBEDDINGS_DEPLOYMENT=` (en Elea, `text-embedding-3-large-azure-openai`) y recrear el motor con `docker compose up -d engine`. El resto del producto sigue andando: es una degradación, no una caída.

**El motor (`engine`) tarda en aparecer sano la primera vez**: es esperado con una base
de datos nueva (migra sus tablas) — el instalador ya espera hasta 5 minutos. Si en algún
momento el contenedor se reinicia solo una vez durante ese lapso (`docker compose ps`
muestra un reinicio reciente), es normal — `restart: unless-stopped` lo recupera solo,
no hace falta intervenir.

## Pruebas del instalador (sin Docker real)

```bash
bash tests/test-embeddings-deployment.sh   # despliegue de embeddings del ruteo: compose (base y -ext), .env.example y README (sin Docker)
bash tests/test-base-motor.sh    # separar la base del motor, vuelta atrás B, volver a separar, respaldo (Docker simulado)
bash tests/test-super-admin.sh   # usuario de cumplimiento: ./crear-super-admin.sh y su cableado en install.sh (Docker simulado)
bash tests/test-proxy.sh         # cableado del proxy en el compose e install.sh; con un binario `caddy`, el proxy de verdad
bash tests/test-https.sh         # HTTPS del proxy: nombres, certificado de la empresa, ./exportar-ca.sh, cableado; con `caddy`, la CA interna y el 404 de internal por HTTPS
bash tests/test-redirect-optin.sh    # extensión de redirección: opt-in, imágenes -ext, entorno 600, gate, salud, apagar (Docker y curl simulados)
bash tests/test-runbook-redirect.sh  # runbook de la extensión: respaldo, activar, verificar, configurar herramientas, vuelta atrás
bash tests/test-runbook-actualizar.sh  # runbook consolidado de actualización (057 + bases separadas): pasos 0 a 9 (incluye el Paso 9 de modelos y Claude Desktop), comandos que existen, marcadores
ELEA_CADDY_BIN=/ruta/a/caddy bash tests/test-proxy.sh   # si `caddy` no está en el PATH
docker compose config -q         # el compose es válido con tu .env
```

`tests/test-proxy.sh` sin binario `caddy` **salta** la parte que corre el proxy (lo dice en la salida) y no falla.
