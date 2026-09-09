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

Las imágenes son privadas — el script te pide un usuario y token de GitHub con permiso
`read:packages` la primera vez (te lo da quien te compartió este instalador).

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
| Cliente RAG (para probar) | http://localhost:8095 |
| Panel del Guardian (admin, visual) | http://localhost:8090 |
| API del Guardian (Swagger) | http://localhost:8091/docs |
| AnythingLLM (interno, no hace falta entrar) | http://localhost:3001 |

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
