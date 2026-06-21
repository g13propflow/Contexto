# PropFlow — Guía de desarrollador

Todo lo que necesitas para levantar, desarrollar y depurar el ecosistema PropFlow localmente.

---

## Índice

1. [Requisitos previos](#1-requisitos-previos)
2. [Variables de entorno](#2-variables-de-entorno)
3. [Levantar el sistema](#3-levantar-el-sistema)
4. [Docker](#4-docker)
5. [Migraciones](#5-migraciones)
6. [Seeds y datos iniciales](#6-seeds-y-datos-iniciales)
7. [Testing](#7-testing)
8. [Debugging](#8-debugging)
9. [Comandos frecuentes](#9-comandos-frecuentes)

---

## 1. Requisitos previos

### Software requerido

| Herramienta | Versión mínima | Uso |
|---|---|---|
| **Node.js** | 20.x | Frontend + microservicios Node |
| **Python** | 3.12 | app-saas-service |
| **uv** | latest | Gestor de paquetes Python (recomendado) |
| **Docker Desktop** | latest | Levantar infraestructura local |
| **Git** | 2.x | Control de versiones |
| **Microsoft ODBC Driver 18** | 18.x | Conexión a SQL Server desde Python |

> **Windows**: instalar ODBC Driver 18 desde https://learn.microsoft.com/en-us/sql/connect/odbc/download-odbc-driver-for-sql-server

### Accesos necesarios (pedir al equipo)

- Credenciales de **SQL Server (Azure)** — compartido por todos los servicios
- Credenciales de **Azure Blob Storage** — para documentos, PDFs, imágenes
- **Auth0** — domain, client_id, client_secret, audience
- **Azure OpenAI** — endpoint, api_key, deployment names
- **Pinecone** — api_key, environment, index_name
- **Redis** — url (o levantar local via Docker)
- API keys de integraciones: SendGrid, ElevenLabs, WhatsApp (Meta), Slack, Facebook, Google Maps

---

## 2. Variables de entorno

Cada repositorio tiene su propio `.env`. Copiar el `.env.example` y completar los valores.

```bash
cp .env.example .env   # en cada repositorio
```

### app-saas-service `.env`

```bash
# Entorno
ENVIRONMENT=development
LOG_LEVEL=INFO
LOG_FORMAT=text    # "text" en dev, "json" en prod

# Base de datos principal (SQL Server Azure)
DATABASE_URL=mssql+pyodbc://user:password@server.database.windows.net:1433/dbname?driver=ODBC+Driver+18+for+SQL+Server&TrustServerCertificate=yes
DATABASE_POOL_SIZE=10          # reducir en local
DATABASE_MAX_OVERFLOW=5
DATABASE_ECHO=false            # true para ver SQL en consola

# PostgreSQL (solo para LangGraph checkpointer)
POSTGRES_CHECKPOINT_HOST=localhost    # o dirección Azure
POSTGRES_CHECKPOINT_PORT=5432
POSTGRES_CHECKPOINT_DATABASE=propflow_checkpoint
POSTGRES_CHECKPOINT_USER=postgres
POSTGRES_CHECKPOINT_PASSWORD=password
POSTGRES_CHECKPOINT_SSL_MODE=disable  # "require" en Azure

# Azure OpenAI
AZURE_OPENAI_ENDPOINT=https://your-resource.openai.azure.com/
AZURE_OPENAI_API_KEY=your-key
AZURE_OPENAI_DEPLOYMENT_NAME=gpt-4o
AZURE_OPENAI_API_VERSION=2024-02-15-preview
AZURE_OPENAI_EMBEDDING_DEPLOYMENT=text-embedding-3-large
AZURE_OPENAI_GPT4O_DEPLOYMENT=gpt-4o
AZURE_OPENAI_GPT4O_MINI_DEPLOYMENT=gpt-4o-mini
AZURE_OPENAI_HAIKU_4_5=claude-haiku-4-5
AZURE_OPENAI_SONNET_4_6=claude-sonnet-4-6

# Azure AI Serverless (OCR dual-rail)
AZURE_AI_MISTRAL_ENDPOINT=https://...
AZURE_AI_MISTRAL_API_KEY=...
AZURE_AI_HAIKU_ENDPOINT=https://...
AZURE_AI_HAIKU_API_KEY=...

# Auth0
AUTH0_DOMAIN=propflow.us.auth0.com
AUTH0_AUDIENCE=https://api.gopropflow.com
AUTH0_CLIENT_ID=...
AUTH0_CLIENT_SECRET=...

# Redis
REDIS_URL=redis://localhost:6379/0

# Azure Storage
AZURE_STORAGE_CONNECTION_STRING=DefaultEndpointsProtocol=https;AccountName=...;AccountKey=...
AZURE_STORAGE_CONTAINER_PREFIX=tenant

# Pinecone
PINECONE_API_KEY=...
PINECONE_ENVIRONMENT=...
PINECONE_INDEX_NAME=propflow-properties

# Microservicios internos
CALENDAR_SERVICE_URL=http://localhost:3002
CALENDAR_SERVICE_API_KEY=your-internal-key
QUOTATION_SERVICE_HOST=localhost
QUOTATION_SERVICE_PORT=3007
QUOTATION_API_KEY=your-internal-key
COLLECTION_SERVICE_URL=http://localhost:3010
COLLECTION_API_KEY=your-internal-key

# Integraciones externas
SENDGRID_API_KEY=SG.xxxx
SENDGRID_FROM_EMAIL=noreply@gopropflow.com
ELEVENLABS_API_KEY=...
ELEVENLABS_VOICE_ID=...
WHATSAPP_API_KEY=...
WHATSAPP_PHONE_NUMBER_ID=...
EVOLUTION_API_URL=http://localhost:8080
EVOLUTION_API_KEY=...

# HubSpot / Pipedrive
HUBSPOT_API_KEY=
HUBSPOT_SYNC_ENABLED=false      # deshabilitar en dev local

# Frontends
FRONTEND_BASE_URL=http://localhost:5173
PORTAL_URL=http://localhost:5173
API_URL=http://localhost:8000
CORS_ORIGINS=["http://localhost:5173","http://localhost:3000"]

# Webhooks
WEBHOOK_SECRET=any-local-secret

# Temporal
# (no requiere config extra — usa docker-compose)

# Misc
ENCRYPTION_MASTER_KEY=32-byte-hex-key-for-local-dev
TURNSTILE_SECRET_KEY=1x0000000000000000000000000000000AA  # clave de test de Cloudflare
```

### app-saas-frontend `.env`

```bash
VITE_API_BASE_URL=http://localhost:8000
VITE_CALENDAR_API_BASE_URL=http://localhost:3002
VITE_QUOTATION_API_BASE_URL=http://localhost:3008
VITE_COLLECTION_API_BASE_URL=http://localhost:3010
VITE_AUTH0_DOMAIN=propflow.us.auth0.com
VITE_AUTH0_CLIENT_ID=your-spa-client-id
VITE_AUTH0_AUDIENCE=https://api.gopropflow.com
VITE_GOOGLE_MAPS_API_KEY=your-web-maps-key   # opcional
VITE_TENANT_ID=tenant_local                  # tenant de prueba local
```

### calendar-service `.env`

```bash
# Servidor
PORT=3002
NODE_ENV=development
AROUND=dev   # ⚠️ requerido — habilita trustServerCertificate

# SQL Server (mismo que app-saas-service)
HOST_DB=your-server.database.windows.net
DB=your-database
USER_DB=your-user
PASSWORD_DB=your-password
PORT_DB=1433

# Auth
API_KEYS=your-internal-key,another-key   # comma-separated
MCP_API_KEY=your-mcp-key
AUTH0_AUDIENCE=https://api.gopropflow.com
AUTH0_ISSUER=https://propflow.us.auth0.com/

# Email
SENDGRID_API_KEY=...
SENDGRID_VERIFIED_SENDER=noreply@gopropflow.com

# Callback a app-saas-service
SAAS_SERVICE_URL=http://localhost:8000

# Redis
REDIS_URL=redis://localhost:6379

# CORS
ALLOWED_ORIGINS=http://localhost:5173,http://localhost:3000

# MCP SSE
MCP_SSE_PORT=3003
```

### quotation-service `.env`

```bash
PORT=3007
AROUND=dev
VERSION_API=v1

# SQL Server
HOST_DB=your-server.database.windows.net
DB=your-database
USER_DB=your-user
PASSWORD_DB=your-password
PORT_DB=1433

# Azure Storage (PDFs)
AZURE_STORAGE_CONNECTION_STRING=...
AZURE_STORAGE_CONTAINER_PREFIX=tenant

# Auth
AUTH0_DOMAIN=propflow.us.auth0.com
AUTH0_AUDIENCE=https://api.gopropflow.com
API_KEY=your-internal-key

# MCP
MCP_SSE_PORT=3008

# Parámetros Guatemala
IUSI_PERCENTAGE=0.009
INSURANCE_PERCENTAGE=0.0035
```

### collection-service `.env`

```bash
PORT=3010
NODE_ENV=development

# SQL Server
HOST_DB=your-server.database.windows.net
DB=your-database
USER_DB=your-user
PASSWORD_DB=your-password
PORT_DB=1433

# Auth
AUTH_PROVIDER=auth0
API_KEY=your-internal-key

# Azure Storage
AZURE_STORAGE_CONNECTION_STRING=...
AZURE_STORAGE_CONTAINER=reservations
```

---

## 3. Levantar el sistema

### Orden de arranque recomendado

```
1. Infraestructura (Docker): SQL Server accesible, Redis, Temporal, PostgreSQL
2. app-saas-service           → :8000
3. calendar-service           → :3002 / :3003 (MCP)
4. quotation-service          → :3007 / :3008 (MCP)
5. collection-service         → :3010
6. app-saas-frontend          → :5173
```

### app-saas-service (Python/FastAPI)

```bash
cd app-saas-service
cp .env.example .env   # completar valores

# Opción A — uv (recomendado)
uv sync
uv run uvicorn app.main:app --reload --port 8000

# Opción B — pip clásico
python -m venv .venv
source .venv/bin/activate    # Windows: .venv\Scripts\activate
pip install -r requirements.txt
uvicorn app.main:app --reload --port 8000

# Opción C — Docker (ver sección 4)
docker-compose up -d --build

# Worker de Temporal (proceso separado, requerido para workflows)
uv run python -m app.temporal.worker
# o con Docker: ya incluido como servicio temporal-worker
```

La API queda disponible en:
- **REST API**: http://localhost:8000/api/v1
- **Swagger UI**: http://localhost:8000/docs _(solo en `ENVIRONMENT=development`)_
- **ReDoc**: http://localhost:8000/redoc

### calendar-service (Node.js)

```bash
cd calendar-service
npm install
cp .env.example .env   # completar valores

npm run dev            # API en :3002 con nodemon
npm run mcp            # MCP Server stdio (opcional)
npm run mcp:sse        # MCP Server SSE en :3003 (opcional)
```

### quotation-service (Node.js)

```bash
cd quotation-service
npm install
cp .env.example .env

npm run dev            # API en :3007 con nodemon
npm run mcp:sse        # MCP Server SSE en :3008 (opcional)
```

### collection-service (Node.js)

```bash
cd collection-service
npm install
cp .env.example .env

npm run dev            # API en :3010 con nodemon
```

### app-saas-frontend (Vue 3 / Vite)

```bash
cd app-saas-frontend
npm install
cp .env.example .env   # ajustar URLs

npm run dev            # Dev server en :5173 con HMR
npm run build          # Build de producción
npm run type-check     # Verificación TypeScript (sin build)
npm run preview        # Preview del build de producción
```

---

## 4. Docker

### app-saas-service — docker-compose completo

El `docker-compose.yml` de `app-saas-service` levanta todos los servicios de infraestructura necesarios:

```yaml
# Servicios incluidos:
api              # FastAPI app  → :8000
temporal-worker  # Worker de Temporal
temporal         # Temporal server → :7233
temporal-ui      # UI de Temporal → :8088
postgres-temporal  # PostgreSQL para Temporal → :5434
redis            # Redis → :6379
postgres-evolution # PostgreSQL para Evolution API → :5433
airflow-webserver  # Airflow UI → :8080
airflow-scheduler  # Airflow scheduler
postgres-airflow   # PostgreSQL para Airflow
```

```bash
cd app-saas-service

# Levantar todo
docker-compose up -d --build

# Levantar solo infraestructura (sin la API, para desarrollar local)
docker-compose up -d temporal temporal-ui postgres-temporal redis

# Ver logs
docker-compose logs -f api
docker-compose logs -f temporal-worker
docker-compose logs -f temporal

# Parar todo
docker-compose down

# Parar y borrar volúmenes (reset completo)
docker-compose down -v

# Reconstruir imagen sin caché
docker-compose build --no-cache api
```

### Puertos expuestos por Docker

| Servicio | Puerto local | Puerto container |
|---|---|---|
| FastAPI (`api`) | 8000 | 8000 |
| Temporal Server | 7233 | 7233 |
| Temporal UI | 8088 | 8080 |
| PostgreSQL Temporal | 5434 | 5432 |
| PostgreSQL Evolution | 5433 | 5432 |
| Redis | 6379 | 6379 |
| Airflow UI | 8080 | 8080 |

> **Nota**: SQL Server **no** está en docker-compose — se usa la instancia de Azure directamente. Configurar `DATABASE_URL` en `.env` para apuntar al servidor de Azure.

### Microservicios Node.js — Docker individual

Cada microservicio tiene su propio `Dockerfile` para producción con Traefik:

```bash
# calendar-service
cd calendar-service
docker-compose up -d --build   # incluye calendar-api y calendar-mcp

# quotation-service
cd quotation-service
docker-compose up -d --build
```

> En desarrollo local se recomienda usar `npm run dev` directamente en lugar de Docker, para aprovechar el hot-reload.

### Dockerfile de app-saas-service

Imagen base: `python:3.12-bookworm`. Instala:
- Dependencias del sistema: `build-essential`, `unixodbc-dev`, `ffmpeg`
- **Microsoft ODBC Driver 18** (requerido para `aioodbc`/`pyodbc`)
- Paquetes Python de `requirements.txt`

```bash
# Build manual de la imagen
docker build -t propflow-api .

# Correr con .env local
docker run --env-file .env -p 8000:8000 propflow-api
```

---

## 5. Migraciones

### app-saas-service (Alembic — SQL Server)

Alembic maneja todas las migraciones del dominio principal. La URL de conexión se toma de `DATABASE_URL` en el `.env`.

```bash
cd app-saas-service

# Ver estado actual
alembic current

# Ver historial de migraciones
alembic history --verbose

# Aplicar todas las migraciones pendientes
alembic upgrade head

# Aplicar una migración específica
alembic upgrade <revision_id>

# Revertir la última migración
alembic downgrade -1

# Revertir a una revisión específica
alembic downgrade <revision_id>

# Crear nueva migración (autogenerada desde modelos)
alembic revision --autogenerate -m "descripción del cambio"

# Crear migración vacía (para scripts manuales)
alembic revision -m "descripción del cambio"
```

> ⚠️ **Siempre revisar** el archivo generado antes de ejecutar `upgrade`. Alembic no detecta todos los cambios en SQL Server (ej: cambios en enums, índices especiales).

#### Workflow para agregar una columna

```bash
# 1. Editar el modelo en app/db/models.py (o models_*.py)
# 2. Generar la migración
alembic revision --autogenerate -m "add_column_X_to_leads"
# 3. Revisar alembic/versions/<hash>_add_column_X_to_leads.py
# 4. Aplicar
alembic upgrade head
```

#### Naming convention para constraints

```python
# Todos los constraints siguen esta convención automáticamente:
"ix": "ix_%(table_name)s_%(column_0_name)s"    # índice
"uq": "uq_%(table_name)s_%(column_0_name)s"    # unique
"fk": "fk_%(table_name)s_%(column_0_name)s_%(referred_table_name)s"  # FK
"pk": "pk_%(table_name)s"                       # PK
```

### quotation-service (SQL manual)

El `quotation-service` usa migraciones SQL manuales ubicadas en `migrations/`. No hay CLI — se ejecutan directamente en SQL Server.

```bash
# Ver migraciones disponibles
ls quotation-service/migrations/

# Aplicar una migración manualmente
# → Conectarse a SQL Server y ejecutar el archivo .sql correspondiente
# Ej: migrations/add-quotation-status-fields.sql
```

### calendar-service y collection-service

No tienen sistema de migraciones formal. Sequelize conecta y usa las tablas existentes. Para cambios de schema, el equipo aplica SQL directamente en la base de datos compartida.

> 💡 La base de datos **es compartida** entre todos los servicios. Los cambios de schema del `app-saas-service` (vía Alembic) afectan a todos.

### PostgreSQL del checkpointer LangGraph

El checkpointer de LangGraph crea sus propias tablas automáticamente al primer arranque via `AsyncPostgresSaver.setup()`. No requiere intervención manual.

---

## 6. Seeds y datos iniciales

Los seeds se ejecutan como scripts Python independientes desde la raíz de `app-saas-service`.

```bash
cd app-saas-service

# Seed de tipos de financiamiento (FHA, banco convencional, etc.)
uv run python scripts/seed_financing_types.py

# Seed de templates de nurturing
uv run python scripts/seed_nurturing_templates.py

# Seed completo de postventa (fases, plantillas, rutas de notificación)
uv run python scripts/seed_postventa.py
uv run python scripts/seed_postventa_phases.py
uv run python scripts/seed_postventa_templates.py
uv run python scripts/seed_postventa_routing.py
uv run python scripts/seed_postventa_holidays.py

# Seed de templates de expediente FHA
uv run python scripts/seed_fha_templates.py
```

> Los seeds son idempotentes en su mayoría — verifican si el dato ya existe antes de insertarlo.

### RBAC: roles y permisos

Los roles y permisos base se seed automáticamente al registrar el primer usuario de un tenant (endpoint `POST /api/v1/auth/owner`). Si se necesita re-seedear:

```bash
# El seed de RBAC vive en rbac_seed_service.py
# Se ejecuta automáticamente en el flujo de onboarding
# Para forzar manualmente: ver app/services/rbac_seed_service.py
```

---

## 7. Testing

### app-saas-service (pytest)

```bash
cd app-saas-service

# Correr todos los tests
uv run pytest

# Con output detallado
uv run pytest -v

# Tests async (modo auto activado en pytest.ini)
uv run pytest --asyncio-mode=auto

# Solo tests unitarios
uv run pytest tests/unit/ -v

# Solo tests de integración
uv run pytest tests/integration/ -v

# Un archivo específico
uv run pytest tests/unit/test_compare_properties.py -v

# Un test específico
uv run pytest tests/unit/test_compare_properties.py::test_basic_comparison -v

# Con cobertura de código
uv run pytest --cov=app --cov-report=html
# → Reporte en coverage_reports/html/index.html

# Por marcadores
uv run pytest -m unit           # solo tests unitarios
uv run pytest -m integration    # solo integración
uv run pytest -m "not slow"     # excluir lentos

# Fallar rápido (detener al primer error)
uv run pytest -x
```

#### Configuración de pytest (`pytest.ini`)

```ini
[pytest]
asyncio_mode = auto          # todos los tests async sin @pytest.mark.asyncio
pythonpath = .               # importar app.* sin sys.path hacks
markers =
    unit: Unit tests
    integration: Integration tests
    e2e: End-to-end tests
    slow: Tests lentos
```

#### Estructura de tests

```
tests/
├── unit/
│   ├── advisor_whatsapp/        # Tests del módulo WhatsApp del asesor
│   ├── campanas/                # Tests de campañas
│   ├── postventa/               # Tests de postventa
│   ├── test_compare_properties.py
│   ├── test_maps_directions_service.py
│   ├── test_quotations_phase3.py
│   └── ...
├── integration/
│   ├── test_compare_properties_integration.py
│   ├── test_sales_agent_real.py
│   └── ...
├── scripts/
│   ├── intake_chat.py          # Script interactivo para probar el agente de intake
│   ├── whatsapp_chat.py        # Simulador de conversación WhatsApp
│   ├── send_whatsapp_event.py  # Enviar evento de prueba
│   └── smoke_test_phase1_temporal.py
└── fixtures/
```

### calendar-service (Jest)

```bash
cd calendar-service

# Todos los tests
npm test

# Watch mode
npm run test:watch

# Con cobertura
npm run test:coverage

# Solo tests del MCP server
npm run test:mcp

# Solo tests de la API REST
npm run test:api
```

Configuración de cobertura mínima: **70%** en branches, functions, lines y statements.

### quotation-service (Node test runner)

```bash
cd quotation-service

# Correr tests
npm test
# → usa el test runner nativo de Node.js (node --test)
```

### app-saas-frontend (Vitest)

```bash
cd app-saas-frontend

# Correr tests una vez
npm test
# → equivalente a: vitest run

# Watch mode (interactivo)
npm run test:watch
# → equivalente a: vitest
```

### Scripts de smoke test y simulación

```bash
cd app-saas-service

# Simulador de chat de intake (conversación con el agente)
uv run python tests/scripts/intake_chat.py

# Simulador de chat WhatsApp
uv run python tests/scripts/whatsapp_chat.py

# Enviar evento de WhatsApp de prueba al webhook
uv run python tests/scripts/send_whatsapp_event.py

# Enviar evento de llamada de ElevenLabs de prueba
uv run python tests/scripts/send_elevenlabs_call_event.py

# Smoke test de Temporal (fase 1)
uv run python tests/scripts/smoke_test_phase1_temporal.py
```

---

## 8. Debugging

### app-saas-service

#### Activar logs SQL

```bash
# En .env
DATABASE_ECHO=true
```

Muestra todos los queries SQL en la consola. Útil para debuggear N+1 queries y joins inesperados.

#### Activar Swagger UI

```bash
# En .env
ENVIRONMENT=development
```

Acceder a http://localhost:8000/docs. En producción los docs están desactivados.

#### Aumentar nivel de log

```bash
# En .env
LOG_LEVEL=DEBUG
LOG_FORMAT=text   # más legible que JSON en local
```

#### Debuggear un endpoint con uvicorn + debugger

```bash
# Levantar con reload desactivado para poder usar breakpoints
uv run uvicorn app.main:app --host 0.0.0.0 --port 8000 --no-reload
```

En VS Code, agregar a `.vscode/launch.json`:

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "FastAPI",
      "type": "debugpy",
      "request": "launch",
      "module": "uvicorn",
      "args": ["app.main:app", "--reload", "--port", "8000"],
      "jinja": true,
      "justMyCode": false,
      "env": {
        "PYTHONPATH": "${workspaceFolder}"
      }
    },
    {
      "name": "Temporal Worker",
      "type": "debugpy",
      "request": "launch",
      "module": "app.temporal.worker",
      "justMyCode": false
    }
  ]
}
```

#### Probar autenticación localmente

```bash
# Obtener token de Auth0 para pruebas
curl -X POST "https://propflow.us.auth0.com/oauth/token" \
  -H "Content-Type: application/json" \
  -d '{
    "client_id": "YOUR_CLIENT_ID",
    "client_secret": "YOUR_CLIENT_SECRET",
    "audience": "https://api.gopropflow.com",
    "grant_type": "client_credentials"
  }'

# Usar el token en requests
curl http://localhost:8000/api/v1/leads/v2 \
  -H "Authorization: Bearer <token>" \
  -H "X-Tenant-ID: tenant_local"
```

#### Temporal UI

Acceder a http://localhost:8088 para ver workflows activos, historial, errores y estado de actividades.

```bash
# Ver workflows activos via CLI de Temporal
temporal workflow list --address localhost:7233 --namespace default

# Cancelar un workflow
temporal workflow cancel --workflow-id <id> --address localhost:7233

# Ver detalle de un workflow
temporal workflow show --workflow-id <id> --address localhost:7233
```

#### Debuggear agentes LangGraph

Los agentes guardan su estado en PostgreSQL. Para inspeccionar:

```sql
-- Ver checkpoints activos (en PostgreSQL del checkpointer)
SELECT thread_id, checkpoint_id, created_at
FROM checkpoints
ORDER BY created_at DESC
LIMIT 20;
```

```python
# En Python: obtener estado actual de un agente para un lead
from app.db.postgres_checkpoint import checkpointer_manager

checkpointer = await checkpointer_manager.get()
thread_id = f"supervisor_{tenant_id}_{lead_id}"
state = await checkpointer.aget({"configurable": {"thread_id": thread_id}})
```

### Node.js microservicios

#### Activar logging SQL

```bash
# En .env de calendar/quotation/collection-service
DB_LOGGING=true   # muestra todos los queries Sequelize
```

#### Debuggear con Node inspector

```bash
# calendar-service con inspector
node --inspect server.js

# O via nodemon
nodemon --inspect server.js
```

Conectar Chrome DevTools en `chrome://inspect`.

### app-saas-frontend

#### Vue DevTools

El proyecto incluye `vite-plugin-vue-devtools`. Aparece automáticamente en desarrollo como un botón flotante en la esquina inferior derecha.

#### Debuggear stores Pinia

```js
// En la consola del navegador
const { useLeadContextStore } = await import('/src/stores/leadContext.ts')
const store = useLeadContextStore()
console.log(store.$state)
```

#### Inspeccionar requests HTTP

Todos los requests a los backends pasan por los fetch helpers en `api.config.ts`. Para debuggear, abrir Network tab en DevTools y filtrar por `localhost:8000`, `localhost:3002`, etc.

#### Errores de CORS en desarrollo

Si el frontend recibe errores de CORS, verificar que en `app-saas-service/.env`:

```bash
CORS_ORIGINS=["http://localhost:5173","http://localhost:3000"]
```

---

## 9. Comandos frecuentes

### Desarrollo diario

```bash
# Levantar infraestructura (solo la primera vez o tras docker-compose down)
cd app-saas-service && docker-compose up -d temporal postgres-temporal redis

# Levantar backend
cd app-saas-service && uv run uvicorn app.main:app --reload --port 8000

# Levantar worker de Temporal (segunda terminal)
cd app-saas-service && uv run python -m app.temporal.worker

# Levantar microservicios
cd calendar-service && npm run dev     # :3002
cd quotation-service && npm run dev    # :3007
cd collection-service && npm run dev   # :3010

# Levantar frontend
cd app-saas-frontend && npm run dev    # :5173
```

### Migraciones

```bash
cd app-saas-service

alembic current                          # ¿dónde estoy?
alembic upgrade head                     # aplicar todo
alembic revision --autogenerate -m "..."  # nueva migración
alembic downgrade -1                     # revertir última
alembic history                          # ver historial
```

### Tests

```bash
# Backend
cd app-saas-service
uv run pytest -v                         # todos
uv run pytest tests/unit/ -v             # solo unit
uv run pytest -k "test_leads" -v         # por nombre
uv run pytest --cov=app -v               # con cobertura

# Calendar service
cd calendar-service
npm test                                  # todos
npm run test:mcp                          # solo MCP
npm run test:coverage                     # con cobertura

# Frontend
cd app-saas-frontend
npm test                                  # vitest run
```

### Docker

```bash
cd app-saas-service

docker-compose up -d                     # levantar todo
docker-compose up -d temporal redis      # solo infraestructura
docker-compose logs -f api               # logs de la API
docker-compose logs -f temporal-worker   # logs del worker
docker-compose restart api               # reiniciar API sin rebuild
docker-compose down                      # parar todo
docker-compose down -v                   # parar + borrar volúmenes
docker-compose build --no-cache          # rebuild sin caché
```

### Búsqueda en código

```bash
# Buscar un endpoint en el backend
grep -rn "def get_lead" app-saas-service/app/api/v1/
grep -rn "@router.get\|@router.post" app-saas-service/app/api/v1/leads.py

# Buscar un modelo de base de datos
grep -n "^class " app-saas-service/app/db/models.py
grep -n "^class " app-saas-service/app/db/models_auth.py

# Buscar una columna específica en los modelos
grep -rn "insights_summary\|star_rating" app-saas-service/app/db/models.py

# Buscar un componente Vue
find app-saas-frontend/src -name "LeadCard.vue"
find app-saas-frontend/src -name "*.vue" | xargs grep -l "usePermission"

# Ver contrato JSON de un endpoint
ls app-saas-service/contracts/leads/
cat app-saas-service/contracts/leads/PATCH_lead_id.json
```

### Diagnóstico y salud

```bash
# Health check de la API
curl http://localhost:8000/health

# Verificar conexión a DB (desde el contenedor)
docker-compose exec api python -c "
from app.db.session import engine
import asyncio
async def test():
    async with engine.connect() as conn:
        result = await conn.execute(sqlalchemy.text('SELECT 1'))
        print('DB OK:', result.scalar())
asyncio.run(test())
"

# Estado de migraciones
cd app-saas-service && alembic current

# Ver workers de Temporal registrados
temporal worker list --address localhost:7233 --namespace default

# Verificar Redis
redis-cli -u redis://localhost:6379 ping      # → PONG
redis-cli -u redis://localhost:6379 info server | grep redis_version

# Verificar pools de conexión SQL Server (en la consola de Azure)
# SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE database_id = DB_ID('your-db')
```

### Scripts de utilidad

```bash
cd app-saas-service

# Seeds de catálogos
uv run python scripts/seed_financing_types.py
uv run python scripts/seed_postventa.py
uv run python scripts/seed_fha_templates.py

# Cancelar workflows inválidos de Temporal
uv run python scripts/cancel_invalid_workflows.py

# Verificar workflows inválidos antes de cancelar
uv run python scripts/check_invalid_workflows.py

# Backfill de imágenes de marketplace
uv run python scripts/backfill_marketplace_images.py

# Probar ruta tool de Google Maps
uv run python tests/scripts/probe_route_destinations.py

# Simuladores interactivos
uv run python tests/scripts/intake_chat.py      # chat de intake
uv run python tests/scripts/whatsapp_chat.py    # chat WhatsApp
```

### Gestión de dependencias

```bash
# Python (uv)
cd app-saas-service
uv add httpx                  # agregar dependencia
uv add --dev pytest-mock      # agregar dev dependency
uv sync                       # sincronizar desde pyproject.toml
uv run pip list               # ver paquetes instalados

# Node.js
cd calendar-service
npm install lodash            # agregar dependencia
npm install --save-dev jest   # agregar dev dependency
npm update                    # actualizar dependencias
npm outdated                  # ver paquetes desactualizados
```

### TypeScript y linting

```bash
# Frontend
cd app-saas-frontend
npm run type-check             # verificar tipos sin compilar

# Backend Python
cd app-saas-service
uv run ruff check app/         # linting rápido
uv run ruff check app/ --fix   # auto-fix
uv run black app/              # formatear código
uv run isort app/              # ordenar imports
uv run mypy app/               # type checking estático

# Node.js (calendar-service)
cd calendar-service
npm run lint                   # ESLint
npm run lint:fix               # auto-fix
```

---

## Notas importantes

**Base de datos compartida**: todos los servicios (app-saas-service, calendar-service, quotation-service, collection-service) apuntan al mismo SQL Server de Azure. Los cambios de schema vía Alembic afectan a todos.

**Puerto de MCP vs API**: en los microservicios Node.js, el MCP server corre en puerto +1 respecto a la API REST:
- calendar-service: API `:3002`, MCP `:3003`
- quotation-service: API `:3007`, MCP `:3008`

**`AROUND=dev`**: las variables `AROUND=dev` en los microservicios Node.js habilitan `trustServerCertificate: true` en Sequelize, necesario para conectar a SQL Server sin certificado SSL válido en local.

**Temporal en Windows**: el checkpointer de LangGraph (PostgreSQL + psycopg async) no funciona con ProactorEventLoop de Windows. En dev local sobre Windows, el sistema usa automáticamente `MemorySaver` como fallback.

**`.env` nunca al repositorio**: todos los archivos `.env` están en `.gitignore`. Pedir credenciales al equipo o al 1Password del proyecto.
