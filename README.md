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
Presenton y AnythingLLM son imágenes públicas fijadas por digest/versión.

**Publicarlas siempre con el script del repo `elea`**, nunca con `docker build` a mano:

```bash
VERSION=2026-09-14 deploy/release/publish-elea.sh          # todas
ONLY="backend rag-client" deploy/release/publish-elea.sh   # solo algunas
```

Motivo (encontrado el 14-sep-2026 probando este instalador desde cero): el backend construido
con `backend/Dockerfile` (el de desarrollo) arranca en bucle con `No module named 'extensions'`,
porque en desarrollo esa carpeta llega por un bind mount que la imagen no tiene. La imagen
distribuible sale de `backend/Dockerfile.standalone`; el script fija eso y lo verifica antes de
subir. Después de publicar, probar este instalador desde cero (carpeta nueva, `docker compose
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

Qué hace en ese caso: descarga las imágenes nuevas y recrea solo los contenedores cuya imagen o
configuración cambió (los espacios, documentos y usuarios sobreviven); las cuentas `svc.*` que ya
existen se reutilizan (se revoca su llave anterior y se emite una nueva, porque Guardian permite
una sola llave activa por cuenta); crea `svc.tabular` y `svc.presenton`; reconecta AnythingLLM al
motor; y borra el contenedor viejo de DB-GPT (`exact-analysis-engine`) que ya no existe en este
compose. Las variables viejas del `.env` (`MASKING_VIRTUAL_KEY`, `DBGPT_ENGINE_VIRTUAL_KEY`) quedan
sin uso; se pueden borrar a mano.

Al terminar, las sesiones del Hub se cierran (viven en memoria): cada persona vuelve a entrar.
Verificar: entrar al Hub, ver las tres secciones (documentos, planillas, presentaciones) y, como
`admin`, abrir `http://<servidor>:8097/templates`.

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

**El motor (`engine`) tarda en aparecer sano la primera vez**: es esperado con una base
de datos nueva (migra sus tablas) — el instalador ya espera hasta 5 minutos. Si en algún
momento el contenedor se reinicia solo una vez durante ese lapso (`docker compose ps`
muestra un reinicio reciente), es normal — `restart: unless-stopped` lo recupera solo,
no hace falta intervenir.
