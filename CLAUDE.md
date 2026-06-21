# PropFlow — Workspace CLAUDE.md

Documentación de referencia del ecosistema de repositorios PropFlow para desarrollo y exploración asistida por IA.

---

## Repositorios en este workspace

| Repositorio | Tipo | Lenguaje / Framework | Puerto |
|---|---|---|---|
| `app-saas-frontend` | Frontend | Vue 3 + Vite + TypeScript | — |
| `app-saas-service` | Backend principal | Python + FastAPI | 8000 |
| `calendar-service` | Microservicio | Node.js + Express | 3002 (API), 3003 (MCP) |
| `quotation-service` | Microservicio | Node.js + Express | 3007 (API), 3008 (MCP) |
| `collection-service` | Microservicio | Node.js + Express | 3010 |

---

## Descripción de cada repositorio

### `app-saas-frontend`
SPA (Single Page Application) en Vue 3. Es la interfaz principal del CRM inmobiliario PropFlow. Consume los cuatro backends directamente vía fetch. Incluye vistas para leads, contactos, proyectos, propiedades, conversaciones, analytics, cobranza, cotizaciones, postventa/expedientes y calendarios.

Stack: Vue 3 · Vite · TypeScript · Pinia · Vue Router · Tailwind CSS · Auth0 SPA SDK · Tiptap · Vue Flow · Chart.js.

### `app-saas-service`
El núcleo del sistema. API REST que contiene el dominio principal completo: leads, contactos, proyectos, propiedades, usuarios, roles, tenants, y todas las integraciones externas (WhatsApp/Meta, HubSpot, Pipedrive, ElevenLabs, Twilio, SendGrid, Facebook Ads). Además:
- Agentes de IA con **LangGraph/LangChain** (supervisor, intake, calificación, reenganche, negociación)
- Workers asincrónicos con **Celery + Redis**
- Flujos durables con **Temporal**
- Pipelines de datos con **Airflow**
- Vector store con **Pinecone** para RAG
- OCR con Mistral + Claude (dual-rail)

Base de datos principal: **SQL Server** (Azure). Checkpointer de LangGraph: **PostgreSQL**.

### `calendar-service`
Microservicio de gestión de calendarios, eventos con recurrencia, agendas de asesores y asistentes. Multitenancy nativo. Incluye un **MCP Server** con 23 herramientas para que LLMs (Claude, etc.) interactúen directamente con calendarios y eventos.

Módulos principales: `calendars`, `events`, `advisor_schedules`, `leads`, `tasks`, `project_milestones`, `lead_activity_timeline`.

También envía callbacks a `app-saas-service` cuando se confirma una visita (adapter `saas-service/send.event.calendar.js`).

### `quotation-service`
Microservicio de cotizaciones. Genera PDFs con cálculos de financiamiento inmobiliario (FHA y banco convencional). Recibe parámetros de propiedad + lead y devuelve PDF almacenado en **Azure Blob Storage**. También tiene un **MCP Server** para integración con LLMs.

Módulos principales: `quotation_tool` (commands, controllers, entities, queries, services).

### `collection-service`
El microservicio financiero/cobranza. El más complejo de los tres. Maneja: préstamos, cuotas, pagos, reconciliación bancaria, reservas de pago, documentos con OCR, plantillas de formularios dinámicos, ficha del cliente (customer card) y shortcuts de URLs.

Módulos principales: `loans`, `installments`, `payments`, `bank`, `reservations`, `documents`, `form_templates`, `customer_card_config`, `customer_card_values`, `charges`, `payment_applications`.

---

## Arquitectura general

```
┌─────────────────────────────────────────────────┐
│              app-saas-frontend (Vue 3)           │
│  apiFetch  calendarApiFetch  quotationApiFetch   │
│                  collectionApiFetch              │
└──────┬──────────────┬───────────┬───────────────┘
       │              │           │           │
       ▼              ▼           ▼           ▼
 :8000/api/v1    :3002/v1    :3008/v1    :3010/v1
       │
┌──────┴────────────────────────┐
│       app-saas-service        │
│   (FastAPI + LangGraph +      │
│    Celery + Temporal)         │
│                               │
│  calendar_microservice.py ────┼──► calendar-service :3002
│  collection_service.py ───────┼──► collection-service :3010
│  quotation_service.py ────────┼──► quotation-service :3007
└───────────────────────────────┘

calendar-service ──► app-saas-service (callbacks de visita confirmada)

Base de datos compartida: SQL Server (Azure)
Archivos:           Azure Blob Storage
Auth:               Auth0 (JWT Bearer + X-Tenant-ID)
Cache / Workers:    Redis (solo app-saas-service)
```

El frontend llama a los cuatro servicios directamente. `app-saas-service` es además el orquestador interno: cuando un agente de IA necesita agendar una visita, generar una cotización o crear una reserva, llama a los microservicios vía HTTP (httpx).

---

## Flujo frontend → backend → base de datos

### Flujo estándar (ej: consultar leads)
```
1. Usuario abre LeadsView.vue
2. leads.service.ts llama apiFetch('/leads', ...)
3. api.config.ts añade Authorization: Bearer <auth0_token> + X-Tenant-ID
4. app-saas-service recibe la request
5. authentication_middleware valida el token con Auth0
6. Router despacha a app/api/v1/leads.py
7. Dependency injection (get_current_user, get_db)
8. Service/repository consulta SQL Server (SQLAlchemy async)
9. Respuesta JSON al frontend
10. Pinia store actualiza el estado reactivo
```

### Flujo con agente de IA (ej: agendar visita)
```
1. Asesor solicita agendar visita en la UI
2. Frontend → POST /api/v1/leads/{id}/... → app-saas-service
3. app-saas-service activa el agente LangGraph (supervisor_agent)
4. El agente ejecuta el tool schedule_visit
5. CalendarMicroserviceClient → POST /v1/events → calendar-service
6. calendar-service guarda en SQL Server, envía email (SendGrid)
7. calendar-service → callback POST /api/v1/leads/send-visit-confirmation/{id} → app-saas-service
8. app-saas-service actualiza lead + registra en lead_activity_timeline
9. Respuesta final al frontend
10. Frontend refresca CalendarView llamando directamente a calendar-service
```

---

## Convenciones encontradas

### Autenticación (todos los servicios)
- Tokens **Auth0** vía `Authorization: Bearer <token>`
- Header **`X-Tenant-ID`** en cada request para aislamiento multitenancy
- Los microservicios Node.js usan `express-oauth2-jwt-bearer`
- `app-saas-service` usa middleware propio (`authentication_middleware`) que valida con Auth0 y extrae el contexto de usuario

### Comunicación entre servicios (server-to-server)
- `app-saas-service` → microservicios: usa **API Key** (`X-API-Key`) o Bearer token, más `X-Tenant-ID`
- Los microservicios Node.js pueden llamar de vuelta a `app-saas-service` usando `SAAS_SERVICE_URL` + `QUOTATION_API_KEY` (variable de entorno reutilizada para API keys internas)

### Estructura de módulos (microservicios Node.js)
Todos siguen el mismo patrón de arquitectura limpia:
```
src/modules/<nombre>/
  commands/      # Escritura (create, update, delete)
  queries/       # Lectura (getById, list, etc.)
  controllers/   # HTTP handlers (Express)
  entities/      # Modelos Sequelize
  services/      # Lógica de negocio (cuando existe)
src/infrastructure/
  adapters/      # Clientes de servicios externos
  common/        # DB, Redis, utilidades compartidas
  presentation/
    routes/      # Definición de rutas Express
    middlewares/ # Auth, CORS, error handler
```

### Estructura de módulos (app-saas-service)
```
app/
  api/v1/        # Un archivo .py por entidad (leads.py, projects.py, etc.)
  agents/        # Agentes LangGraph (supervisor, intake, qualification, etc.)
  services/      # Lógica de negocio + clientes HTTP a microservicios
  db/
    models.py         # Todos los modelos SQLAlchemy
    models_auth.py    # Modelos de auth (User, Role, etc.)
    repositories/     # Capa de acceso a datos
  schemas/       # Pydantic schemas (request/response)
  middleware/    # Auth middleware
  tasks/         # Celery tasks
  temporal/      # Temporal workflows y workers
contracts/       # JSON con contratos de API por entidad
alembic/         # Migraciones de SQL Server
```

### Convenciones de naming
- **Python**: snake_case en todo. Archivos de API nombrados por entidad (`leads.py`, `projects.py`).
- **Node.js**: camelCase. Archivos de commands con verbo (`create.loan.js`, `get.by-id.loan.js`).
- **Frontend**: PascalCase para componentes y vistas (`LeadsView.vue`), camelCase para servicios (`leads.service.ts`), kebab-case para rutas (`/dashboard/leads`).
- **Rutas API**: `app-saas-service` usa `/api/v1/`, los microservicios usan `/v1/`.
- **Multitenancy**: Todos los recursos están aislados por `tenant_id`. No existe endpoint que cruce tenants excepto endpoints de admin.

### Nomenclatura de constraints SQL (app-saas-service)
```python
NAMING_CONVENTION = {
    "ix": "ix_%(table_name)s_%(column_0_name)s",
    "uq": "uq_%(table_name)s_%(column_0_name)s",
    "fk": "fk_%(table_name)s_%(column_0_name)s_%(referred_table_name)s",
    "pk": "pk_%(table_name)s"
}
```

### MCP Servers
`calendar-service` y `quotation-service` tienen servidores MCP independientes (puerto +1 respecto a la API REST). Permiten que Claude y otros LLMs llamen directamente a sus herramientas usando el protocolo MCP.

---

## Cómo ejecutar cada servicio

### `app-saas-frontend`
```bash
cd app-saas-frontend
npm install
npm run dev          # Servidor de desarrollo (Vite)
npm run build        # Build de producción
npm run test         # Tests con Vitest
npm run type-check   # Verificación TypeScript
```
Variables de entorno relevantes:
```
VITE_API_BASE_URL=http://localhost:8000
VITE_CALENDAR_API_BASE_URL=http://localhost:3002
VITE_QUOTATION_API_BASE_URL=http://localhost:3008
VITE_COLLECTION_API_BASE_URL=http://localhost:3010
```

### `app-saas-service`
```bash
cd app-saas-service
cp .env.example .env   # Configurar credenciales

# Opción A — Docker (recomendado, incluye Temporal)
docker-compose up -d --build

# Opción B — Local con uv
uv sync
uv run uvicorn app.main:app --reload --port 8000

# Migraciones de base de datos
alembic upgrade head              # Aplicar todas las migraciones
alembic revision --autogenerate -m "descripción"  # Nueva migración
alembic downgrade -1              # Revertir última migración

# Worker de Temporal (proceso separado)
python -m app.temporal.worker
```

### `calendar-service`
```bash
cd calendar-service
npm install
cp .env.example .env

npm run dev          # Servidor con nodemon (puerto 3002)
npm run mcp          # MCP Server stdio (puerto 3003)
npm run mcp:sse      # MCP Server SSE
npm test             # Jest (54 tests)
npm run test:coverage

# Docker
docker-compose up -d --build
```

### `quotation-service`
```bash
cd quotation-service
npm install
cp .env.example .env

npm run dev          # Servidor con nodemon
npm run mcp          # MCP Server stdio
npm run mcp:sse      # MCP Server SSE
npm test             # Node test runner

# Docker
docker-compose up -d --build
```

### `quotation-service` — notas de puertos
- API REST: puerto `3007` (docker-compose) / valor de `PORT` en .env
- MCP Server: puerto `3008`

### `collection-service`
```bash
cd collection-service
npm install
cp .env.example .env   # Configurar SQL Server + Azure Blob

npm run dev    # Servidor con nodemon (puerto 3010)
npm start      # Producción
```

---

## Dependencias entre repositorios

```
app-saas-frontend
  └── depende de (consume vía HTTP):
        ├── app-saas-service  (dominio principal, auth, todo lo demás)
        ├── calendar-service  (vistas de calendario)
        ├── quotation-service (cotizaciones)
        └── collection-service (cobranza / finanzas)

app-saas-service
  └── depende de (llama vía HTTP internamente):
        ├── calendar-service  (CalendarMicroserviceClient — agenda visitas)
        ├── collection-service (CollectionService — crea reservas)
        └── quotation-service  (QuotationService — genera PDFs de cotización)

calendar-service
  └── depende de:
        └── app-saas-service (callback al confirmar visita)

quotation-service  → independiente (SQL Server + Azure Blob + Auth0)
collection-service → independiente (SQL Server + Azure Blob + Auth0)
```

**Orden de arranque recomendado para desarrollo local:**
1. SQL Server (Azure o local)
2. Redis (si se usa Celery)
3. `app-saas-service`
4. `calendar-service`, `quotation-service`, `collection-service` (cualquier orden)
5. `app-saas-frontend`

---

## Orden recomendado para explorar el sistema

### 1. `app-saas-service` — El modelo de datos y dominio
Empieza aquí. Todo lo demás depende de entender las entidades core:
- `app/db/models.py` — Todos los modelos: `Tenant`, `Lead`, `Project`, `Property`, `User`
- `app/api/v1/leads.py` — El endpoint más central del CRM
- `app/services/lead_service.py` — Lógica de negocio de leads
- `app/agents/` — Cómo funciona el sistema de agentes IA

### 2. `app-saas-frontend` — La interfaz y cómo consume el dominio
- `src/services/api.config.ts` — Cómo se conecta a cada servicio
- `src/services/leads.service.ts` — Ejemplo de servicio típico
- `src/views/LeadsView.vue` → `src/stores/leadContext.ts` — Patrón view + store
- `src/router/index.ts` — Mapa de toda la aplicación

### 3. `quotation-service` — El microservicio más simple
- `src/modules/quotation_tool/` — Dominio completo en un módulo
- `src/infrastructure/presentation/routes/` — Rutas Express
- `mcp-server.js` — Cómo expone herramientas a LLMs

### 4. `calendar-service` — Microservicio con MCP avanzado
- `src/modules/calendars/` y `src/modules/events/` — Dominio principal
- `mcp-server.js` — 23 herramientas MCP
- `src/infrastructure/adapters/saas-service/` — Callback a app-saas-service

### 5. `collection-service` — El más complejo
- `src/modules/loans/` — Entidad raíz del módulo financiero
- `src/modules/installments/` y `src/modules/payments/` — El ciclo de cobro
- `src/modules/bank/` — Reconciliación bancaria

---

## Comandos útiles

### Buscar un endpoint en app-saas-service
```bash
grep -r "def <nombre>" app-saas-service/app/api/v1/
grep -r "router.get\|router.post" app-saas-service/app/api/v1/leads.py
```

### Buscar una entidad de base de datos
```bash
grep -n "class.*Base" app-saas-service/app/db/models.py
grep -n "class.*Model" calendar-service/src/modules/*/entities/*.js
```

### Ver contrato de un endpoint
```bash
ls app-saas-service/contracts/leads/
cat app-saas-service/contracts/leads/PATCH_lead_id.json
```

### Ver estado de migraciones (app-saas-service)
```bash
cd app-saas-service
alembic current
alembic history --verbose
```

### Logs en Docker
```bash
docker-compose logs -f api              # app-saas-service
docker-compose logs -f calendar-api     # calendar-service
docker-compose logs -f quotation        # quotation-service
```

### Tests
```bash
# Frontend
cd app-saas-frontend && npm test

# calendar-service
cd calendar-service && npm test
cd calendar-service && npm run test:mcp   # Solo tests MCP
cd calendar-service && npm run test:api   # Solo tests API

# quotation-service
cd quotation-service && npm test

# app-saas-service
cd app-saas-service && pytest
cd app-saas-service && pytest tests/ -v --asyncio-mode=auto
```

### Ver documentación Swagger (app-saas-service, solo en dev)
```
http://localhost:8000/docs
http://localhost:8000/redoc
```

---

## Ubicación de los módulos más importantes

### app-saas-service
| Qué buscar | Dónde está |
|---|---|
| Modelos de base de datos | `app/db/models.py`, `app/db/models_auth.py` |
| Endpoints REST | `app/api/v1/<entidad>.py` |
| Lógica de negocio | `app/services/<entidad>_service.py` |
| Agentes de IA | `app/agents/` |
| Configuración / variables de entorno | `config/settings.py` |
| Migraciones SQL | `alembic/versions/` |
| Clientes HTTP a microservicios | `app/services/calendar_microservice.py`, `collection_service.py`, `quotation_service.py` |
| Contratos de API (JSON) | `contracts/<entidad>/` |
| Tasks Celery | `app/tasks/` |
| Workflows Temporal | `app/temporal/` |

### app-saas-frontend
| Qué buscar | Dónde está |
|---|---|
| Config de APIs y fetch helpers | `src/services/api.config.ts` |
| Servicios por entidad | `src/services/<entidad>.service.ts` |
| Vistas principales | `src/views/` |
| Estado global (Pinia) | `src/stores/` |
| Rutas | `src/router/index.ts` |
| Componentes reutilizables | `src/components/` |
| Composables | `src/composables/` |
| Tipos TypeScript | `src/types/` |
| i18n | `src/locales/` |

### calendar-service
| Qué buscar | Dónde está |
|---|---|
| Dominio de calendarios | `src/modules/calendars/` |
| Dominio de eventos | `src/modules/events/` |
| Agendas de asesores | `src/modules/advisor_schedules/` |
| MCP Server (herramientas IA) | `mcp-server.js`, `src/mcp/` |
| Callback a app-saas-service | `src/infrastructure/adapters/saas-service/` |
| Rutas Express | `src/infrastructure/presentation/routes/` |

### quotation-service
| Qué buscar | Dónde está |
|---|---|
| Generación de PDFs | `src/modules/quotation_tool/` |
| MCP Server | `mcp-server.js`, `src/mcp/` |
| Assets (plantillas PDF) | `src/assets/` |
| Migraciones | `migrations/` |

### collection-service
| Qué buscar | Dónde está |
|---|---|
| Préstamos | `src/modules/loans/` |
| Cuotas | `src/modules/installments/` |
| Pagos | `src/modules/payments/` |
| Reservas | `src/modules/reservations/` |
| Reconciliación bancaria | `src/modules/bank/` |
| Documentos + OCR | `src/modules/documents/` |
| Plantillas de formularios | `src/modules/form_templates/` |
| Ficha del cliente | `src/modules/customer_card_config/`, `src/modules/customer_card_values/` |
| Rutas Express | `src/infrastructure/presentation/routes/` |

---

## Infraestructura compartida

| Componente | Usado por |
|---|---|
| **SQL Server (Azure)** | Todos los servicios (base de datos principal) |
| **Azure Blob Storage** | `quotation-service`, `collection-service`, `app-saas-service` |
| **Auth0** | Todos los servicios (JWT Bearer tokens) |
| **Redis** | `app-saas-service` (Celery workers + caché) |
| **PostgreSQL** | `app-saas-service` (solo para checkpointer de LangGraph) |
| **Pinecone** | `app-saas-service` (vector store para RAG) |
| **SendGrid** | `app-saas-service`, `calendar-service` (emails) |
| **Traefik** | Reverse proxy en producción (todos los servicios) |
| **Azure OpenAI** | `app-saas-service` (GPT-4o, GPT-4o-mini, Claude Haiku/Sonnet) |

---

## Dominios de producción (Traefik)

| Servicio | Dominio |
|---|---|
| calendar-service API | `calendar.gopropflow.com` |
| calendar-service MCP | `calendar-mcp.gopropflow.com` |
| quotation-service API | `quotation.gopropflow.com` |
| quotation-service MCP | `quotation-mcp.gopropflow.com` |
