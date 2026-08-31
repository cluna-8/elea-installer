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
| Panel del Guardian (admin) | http://localhost:8091/docs |
| AnythingLLM (interno, no hace falta entrar) | http://localhost:3001 |

## Apagar / prender

```bash
docker compose down    # apaga todo, conserva los datos
docker compose up -d   # prende de nuevo (rápido, ya está todo generado)
```

## Si algo falla

```bash
docker compose ps                 # estado de cada contenedor
docker compose logs backend       # logs del Guardian
docker compose logs client        # logs del cliente RAG
docker compose logs anythingllm   # logs de AnythingLLM
```
