# PropFlow — Levantar la infraestructura local

Guía rápida para correr el stack de desarrollo en local.

## Arquitectura de puertos

| Servicio              | Tipo            | Puerto | Lo consume el frontend como        |
|-----------------------|-----------------|--------|------------------------------------|
| `app-saas-frontend`   | Vue 3 + Vite    | 5173   | — (la app)                         |
| `app-saas-service`    | FastAPI (Docker)| 8000   | `VITE_API_BASE_URL`                |
| `quotation-service`   | Node + Express  | 3007   | `VITE_QUOTATION_API_BASE_URL`      |
| `calendar-service`    | Node + Express  | 3002   | `VITE_CALENDAR_API_BASE_URL`       |
| `collection-service`  | —               | 40001  | `VITE_COLLECTION_API_BASE_URL`     |

El frontend funciona aunque no levantes todos los backends; cada módulo falla solo
si su servicio no está arriba.

## Requisitos previos

- **Node.js** ≥ 20.19 (probado con v26) y npm
- **Docker Desktop** (para `app-saas-service`) — debe estar **corriendo** antes de hacer `docker compose`
- Acceso a la base **Azure SQL** compartida (`propflow-ai.database.windows.net`)

---

## 1. Frontend — `app-saas-frontend` (puerto 5173)

```bash
cd app-saas-frontend
npm install
npm run dev
```

- El `.env` ya viene configurado apuntando a los servicios locales.
- App en http://localhost:5173
- Para exponerlo en la red local: `npm run dev -- --host`

---

## 2. API principal — `app-saas-service` (puerto 8000)

Es un stack de **Docker Compose** (FastAPI + Temporal + Redis + Postgres + Evolution/WhatsApp + Airflow).
El `.env` usa hostnames internos de Docker, así que **se corre dentro de docker-compose**, no nativo.

### Opción A — Solo lo que necesita el frontend (recomendado)

```bash
cd app-saas-service
docker compose up -d --build api redis
docker compose logs -f api
```

`api` arrastra `temporal` y `postgres-temporal` automáticamente (por `depends_on`).

### Opción B — Stack completo

```bash
cd app-saas-service
docker compose up -d --build
```

UIs extra: Temporal http://localhost:8088 · Airflow http://localhost:8090

### Notas
- `--build` solo es necesario la **primera vez** o al cambiar código / `Dockerfile` / dependencias.
  En arranques normales basta `docker compose up -d`.
- `up` (no `--build`) es lo que **levanta** los contenedores. `--build` por sí solo solo construye.
- API en http://localhost:8000 · docs en http://localhost:8000/docs
- La base de datos principal es **Azure SQL remota** (no se levanta SQL local).

### Migraciones (solo si el API se queja de tablas faltantes)

```bash
docker compose exec api alembic upgrade head
```

---

## 3. Cotizador — `quotation-service` (puerto 3007)

```bash
cd quotation-service
npm install
npm run dev      # nodemon
```

Conecta a la misma Azure SQL. Requiere credenciales válidas en `.env`
(`USER_DB` / `PASSWORD_DB`). Ver sección de credenciales abajo.

---

## 4. Calendario — `calendar-service` (puerto 3002)

> ⚠️ Este servicio **no trae `.env`**, hay que crearlo desde `.env.example`.

```bash
cd calendar-service
cp .env.example .env
# editar .env: PORT=3002, DB_*, API_KEYS, etc.
npm install
npm run dev
```

Variables clave: `PORT=3002`, `DB_SERVER`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`, `DB_PORT`,
`API_KEYS` (la API key debe coincidir con `CALENDAR_SERVICE_API_KEY` del `.env` de `app-saas-service`).

---

## Credenciales de base de datos (importante)

Varios servicios comparten la Azure SQL `propflow-ai.database.windows.net`.
El error más común al levantar es:

```
Login failed for user 'xxxxx'. (18456)
```

Significa que **el usuario y la contraseña no coinciden**. Para usar tu propio usuario:

- **Node** (`quotation-service/.env`): ajusta `USER_DB` y `PASSWORD_DB`.
- **Python** (`app-saas-service/.env`): ajusta `DATABASE_URL`:
  ```
  DATABASE_URL=mssql+pyodbc://USUARIO:PASSWORD@propflow-ai.database.windows.net:1433/BASE?driver=ODBC+Driver+18+for+SQL+Server&TrustServerCertificate=yes&...
  ```
  Si la contraseña tiene caracteres especiales, **URL-encódealos** (`@`→`%40`, `:`→`%3A`,
  `/`→`%2F`, `|`→`%7C`, `[`→`%5B`, `]`→`%5D`, `#`→`%23`).

### Recargar credenciales tras editar `.env`
- **Node (nodemon):** no observa `.env`. Reinicia el proceso (Ctrl+C y `npm run dev`).
- **Docker (app-saas-service):** `uvicorn --reload` y `docker compose restart` **no** releen el `.env`.
  Hay que recrear el contenedor:
  ```bash
  docker compose up -d --force-recreate api
  ```

---

## Comandos útiles de Docker

```bash
docker compose ps              # ver contenedores arriba
docker compose logs -f api     # seguir logs del API
docker compose stop            # detener sin borrar
docker compose down            # detener y eliminar contenedores
```
