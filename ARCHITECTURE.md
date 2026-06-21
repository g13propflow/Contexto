# PropFlow — Architecture Reference

Documento de arquitectura del ecosistema PropFlow. Generado a partir del análisis directo del código fuente.

---

## Mapa de repositorios

| Repositorio | Tipo | Framework | Puerto local | Dominio producción |
|---|---|---|---|---|
| `app-saas-frontend` | Frontend SPA | Vue 3 + Vite + TypeScript | — | — |
| `app-saas-service` | Backend principal | Python + FastAPI | 8000 | — |
| `calendar-service` | Microservicio + MCP | Node.js + Express | 3002 (API) · 3003 (MCP) | `calendar.gopropflow.com` · `calendar-mcp.gopropflow.com` |
| `quotation-service` | Microservicio + MCP | Node.js + Express | 3007 (API) · 3008 (MCP) | `quotation.gopropflow.com` · `quotation-mcp.gopropflow.com` |
| `collection-service` | Microservicio | Node.js + Express | 3010 | — |

```mermaid
graph TB
    subgraph Frontend
        FE["app-saas-frontend<br/>Vue 3 · TypeScript · Pinia"]
    end

    subgraph Backend["Backend — API Layer"]
        SAAS["app-saas-service<br/>FastAPI · Python"]
        CAL["calendar-service<br/>Express · Node.js"]
        QUO["quotation-service<br/>Express · Node.js"]
        COL["collection-service<br/>Express · Node.js"]
    end

    subgraph MCP["MCP Servers (LLM integration)"]
        CALMCP["calendar-mcp<br/>port 3003"]
        QUOMCP["quotation-mcp<br/>port 3008"]
    end

    FE -->|apiFetch /api/v1| SAAS
    FE -->|calendarApiFetch /v1| CAL
    FE -->|quotationApiFetch /v1| QUO
    FE -->|collectionApiFetch /v1| COL

    SAAS -->|httpx + X-API-Key| CAL
    SAAS -->|httpx + Bearer| COL
    SAAS -->|httpx| QUO

    CAL -->|callback POST| SAAS

    CAL --- CALMCP
    QUO --- QUOMCP
```

---

## Responsabilidad de cada repositorio

### `app-saas-frontend`
Interfaz web principal del CRM. Es el único cliente que agrupa y presenta toda la funcionalidad del sistema. Consume los cuatro backends directamente mediante cuatro funciones fetch independientes (`apiFetch`, `calendarApiFetch`, `quotationApiFetch`, `collectionApiFetch`), cada una con su propio base URL configurado por variable de entorno.

Dominios funcionales cubiertos: leads, contactos, proyectos, propiedades, conversaciones, analytics, cobranza, cotizaciones, expedientes/postventa, calendarios, campañas de marketing, agentes de IA, configuraciones.

### `app-saas-service`
El núcleo del sistema y orquestador interno. Contiene el modelo de datos completo (leads, contactos, proyectos, propiedades, usuarios, roles, tenants) y todas las integraciones externas. Adicionalmente:

- **Agentes de IA** (LangGraph): supervisor con tool-calling que coordina intake, calificación BANT, reenganche, negociación, comunicación y gestión de expedientes.
- **Workers asincrónicos** (Celery + Redis): tareas en background.
- **Flujos durables** (Temporal): orquesta workflows de larga duración — seguimiento post-visita, reenganche, SLA de expedientes, resúmenes diarios, recordatorios, campañas, análisis de sentimiento, WhatsApp window management, supervisor de asesores.
- **RAG** (Pinecone): recuperación semántica sobre proyectos y propiedades.
- **OCR dual-rail** (Mistral + Claude Haiku): validación de documentos de expedientes.

### `calendar-service`
Gestión de calendarios, eventos con soporte de recurrencia, asistentes y agendas de asesores. Multitenancy nativo. Incluye un **MCP Server** que expone herramientas de calendarios y eventos directamente a LLMs. Envía callbacks a `app-saas-service` cuando se confirma o reagenda una visita.

### `quotation-service`
Generación de PDFs de cotizaciones inmobiliarias con cálculos de financiamiento FHA (enganche mínimo 5%, ingreso mínimo ×2) y banco convencional (enganche mínimo 20%, ingreso mínimo ×2.5). Los PDFs se almacenan en Azure Blob Storage. También incluye un **MCP Server** para integración con LLMs.

### `collection-service`
Microservicio financiero/cobranza. El más extenso de los tres (23 módulos). Maneja el ciclo de vida completo de un crédito inmobiliario: préstamos, tabla de cuotas, pagos manuales, reconciliación bancaria, reservas de pago, documentos con OCR, plantillas de formularios dinámicos, ficha configurable del cliente y shortcuts de URL para portal del cliente.

---

## Dependencias entre repositorios

```mermaid
graph LR
    FE["app-saas-frontend"]
    SAAS["app-saas-service"]
    CAL["calendar-service"]
    QUO["quotation-service"]
    COL["collection-service"]

    FE --> SAAS
    FE --> CAL
    FE --> QUO
    FE --> COL

    SAAS -->|"CalendarMicroserviceClient\n(httpx + X-API-Key)"| CAL
    SAAS -->|"QuotationService\n(httpx)"| QUO
    SAAS -->|"CollectionService\n(httpx + Bearer)"| COL

    CAL -->|"send.event.calendar.js\n(POST /api/v1/leads/send-visit-confirmation/:id)"| SAAS
```

### Tabla de dependencias directas

| Quién llama | A quién llama | Mecanismo | Cuándo |
|---|---|---|---|
| `app-saas-frontend` | `app-saas-service` | `apiFetch` + Auth0 JWT + X-Tenant-ID | Toda la operación core del CRM |
| `app-saas-frontend` | `calendar-service` | `calendarApiFetch` + Auth0 JWT | Vistas de calendario |
| `app-saas-frontend` | `quotation-service` | `quotationApiFetch` + Auth0 JWT | Generación/listado de cotizaciones |
| `app-saas-frontend` | `collection-service` | `collectionApiFetch` + Auth0 JWT | Préstamos, pagos, cobranza |
| `app-saas-service` | `calendar-service` | httpx + `X-API-Key` + `X-Tenant-ID` | Agentes IA agendan/consultan visitas |
| `app-saas-service` | `quotation-service` | httpx | Generación automática de cotizaciones |
| `app-saas-service` | `collection-service` | httpx + Bearer token | Crear/consultar reservas |
| `calendar-service` | `app-saas-service` | axios + `X-API-Key` (`QUOTATION_API_KEY`) | Callback al confirmar visita |

**Servicios independientes**: `quotation-service` y `collection-service` no dependen de ningún otro microservicio PropFlow.

---

## Flujo de autenticación

Todos los servicios usan **Auth0** como proveedor de identidad. El patrón es idéntico en todos: JWT Bearer + `X-Tenant-ID`.

```mermaid
sequenceDiagram
    participant U as Usuario (Browser)
    participant FE as app-saas-frontend
    participant A0 as Auth0
    participant SAAS as app-saas-service
    participant MS as Microservicio (cal/quo/col)

    U->>FE: Abre la app
    FE->>A0: Redirect login (PKCE flow)
    A0-->>FE: JWT access token
    FE->>FE: Guarda token + tenant_id en localStorage

    Note over FE,MS: Cada request posterior incluye:
    Note over FE,MS: Authorization: Bearer <jwt>
    Note over FE,MS: X-Tenant-ID: <tenant_id>

    FE->>SAAS: GET /api/v1/leads (+ headers)
    SAAS->>SAAS: authentication_middleware valida JWT con Auth0
    SAAS->>SAAS: Extrae user_id, tenant_id → request.state
    SAAS->>SAAS: TenantContext filtra todos los queries por tenant_id
    SAAS-->>FE: 200 OK + datos

    FE->>MS: GET /v1/calendars (+ mismos headers)
    MS->>MS: express-oauth2-jwt-bearer valida JWT
    MS->>MS: X-Tenant-ID filtra queries por tenant_id
    MS-->>FE: 200 OK + datos
```

### Rutas públicas (sin autenticación en app-saas-service)
- `/health`, `/docs`, `/openapi.json`
- `/api/v1/webhooks/*` — webhooks de plataformas externas
- `/api/v1/public/*` — master plan, mapa de propiedades
- `/api/v1/leads/send-visit-confirmation/*` — callback desde `calendar-service` (usa `X-API-Key`)
- `/api/v1/integrations/facebook/callback`, `/api/v1/integrations/slack/callback`

### Comunicación servidor-a-servidor
Los microservicios no usan JWT para llamarse entre sí. Usan **API Key** en header `X-API-Key`. Configurado via `CALENDAR_SERVICE_API_KEY` (en app-saas-service) y `QUOTATION_API_KEY` (reutilizado como API key genérica interna entre servicios).

---

## Flujo de datos

### Flujo estándar: consultar leads

```mermaid
sequenceDiagram
    participant FE as LeadsView.vue
    participant SVC as leads.service.ts
    participant CFG as api.config.ts
    participant API as app-saas-service
    participant DB as SQL Server (Azure)

    FE->>SVC: fetchLeads(filters)
    SVC->>CFG: apiFetch('/leads', options)
    CFG->>CFG: getAccessToken() + getTenantId()
    CFG->>API: GET /api/v1/leads + Bearer + X-Tenant-ID
    API->>API: authentication_middleware (valida JWT)
    API->>API: get_current_user + get_db (FastAPI DI)
    API->>DB: SELECT * FROM leads WHERE tenant_id = ?
    DB-->>API: rows
    API-->>CFG: 200 JSON
    CFG-->>SVC: typed response
    SVC->>FE: leadContext store.setLeads(data)
```

### Flujo con agente IA: agendar visita

```mermaid
sequenceDiagram
    participant FE as app-saas-frontend
    participant SAAS as app-saas-service
    participant LG as LangGraph Supervisor
    participant TOOL as qualification_tools
    participant CAL as calendar-service
    participant DB as SQL Server
    participant SG as SendGrid

    FE->>SAAS: POST /api/v1/leads/{id}/schedule-visit
    SAAS->>LG: supervisor_agent.run(lead_context)
    LG->>LG: Decide tool: schedule_visit
    LG->>TOOL: schedule_visit(lead_id, datetime, tenant_id)
    TOOL->>CAL: POST /v1/events (X-API-Key + X-Tenant-ID)
    CAL->>DB: INSERT evento + asistentes
    CAL->>SG: Envía email de confirmación
    CAL-->>TOOL: 201 event created
    TOOL-->>LG: success + event_id
    LG->>SAAS: resultado final
    SAAS->>DB: UPDATE lead status + INSERT lead_activity_timeline
    SAAS-->>FE: 200 OK + lead actualizado

    Note over CAL,SAAS: Callback asíncrono posterior
    CAL->>SAAS: POST /api/v1/leads/send-visit-confirmation/{id}
    SAAS->>DB: UPDATE lead + registro en timeline
```

### Flujo de cobranza: crear préstamo desde expediente

```mermaid
sequenceDiagram
    participant FE as CollectionsView.vue
    participant COL as collection-service
    participant DB as SQL Server

    FE->>COL: POST /v1/loans (Bearer + X-Tenant-ID)
    COL->>COL: checkAuth middleware
    COL->>DB: INSERT loan + installments schedule
    DB-->>COL: loan_id
    COL-->>FE: 201 loan created

    Note over FE,COL: Registro de pago posterior
    FE->>COL: POST /v1/payments/manual
    COL->>DB: INSERT payment
    COL->>DB: UPDATE installments (apply payment)
    COL->>DB: INSERT payment_applications
    COL-->>FE: 200 payment registered
```

### Flujo de Temporal (workflows durables)

```mermaid
graph LR
    subgraph "app-saas-service"
        API["FastAPI endpoint\no Celery task"]
        TC["Temporal Client"]
        TW["Temporal Worker"]
        subgraph Workflows
            VF["visit_followup"]
            RE["reengagement_v2"]
            SLA["expediente_sla"]
            DS["daily_summary"]
            CAM["campaign"]
            ADV["advisor_supervisor"]
        end
    end
    subgraph "Temporal Server"
        TS["Temporal :7233"]
    end

    API --> TC
    TC --> TS
    TS --> TW
    TW --> Workflows
```

Los workflows de Temporal gestionan todo proceso de larga duración: seguimiento post-visita, reenganche progresivo, SLA de expedientes, resúmenes diarios de asesores, campañas masivas WhatsApp, supervisión de performance de asesores, y gestión de ventanas de conversación WhatsApp.

---

## Sistema de agentes IA (LangGraph)

El `supervisor_agent.py` implementa el patrón **Supervisor con Tool-Calling** usando LangGraph. El agente mantiene estado (`SupervisorState`) y decide qué tool ejecutar en cada interacción con un lead.

```mermaid
graph TD
    IN["Mensaje entrante\n(WhatsApp / manual)"]
    SUP["Supervisor Agent\nGPT-4o (Azure)"]

    subgraph Tools["Herramientas disponibles"]
        QT["qualification_tools\n(BANT, schedule_visit)"]
        CT["communication_tools\n(send_whatsapp, send_email)"]
        NT["negotiation_tools"]
        ET["expediente_tools"]
        DOC["document_tools\n(OCR validation)"]
        CTXT["context_tools\n(get_lead_info)"]
        PROP["property_tools + project_rag_tools"]
        QUO["quotation_tools"]
        BANK["bank_tools + credit_tools"]
        ROUTE["route_tools"]
    end

    subgraph Subagents["Sub-agentes especializados"]
        IA["intake_agent"]
        QA["qualification_agent"]
        RA["reengagement_agent"]
        NA["negotiation_agent"]
        COM["communication_agent"]
        EXP["expediente agent"]
        ADV["advisor_supervisor"]
    end

    IN --> SUP
    SUP --> Tools
    SUP --> Subagents
    SUP -->|"Guardrails\n(semantic + regex)"| GRD["Guardrails"]
```

El supervisor usa **Azure OpenAI GPT-4o** para decisiones de orquestación. Los guardrails (filtrado de contenido fuera de scope) usan **GPT-4o-mini**. El supervisor de asesores usa **Claude Haiku 4.5 y Claude Sonnet 4.6** servidos desde Azure AI Foundry.

---

## Integraciones externas

```mermaid
graph LR
    subgraph PropFlow
        SAAS["app-saas-service"]
        CAL["calendar-service"]
        QUO["quotation-service"]
        COL["collection-service"]
    end

    subgraph Auth
        A0["Auth0\n(JWT + JWKS)"]
    end

    subgraph AI
        AOI["Azure OpenAI\n(GPT-4o, GPT-4o-mini,\nClaude Haiku, Claude Sonnet)"]
        PCN["Pinecone\n(vector store / RAG)"]
        MIS["Mistral OCR\n(Azure AI Serverless)"]
        HAI["Claude Haiku OCR\n(Azure AI Serverless)"]
        EL["ElevenLabs\n(TTS / voz IA)"]
    end

    subgraph Messaging
        WA["WhatsApp Cloud API\n(Meta / Graph API)"]
        EVO["Evolution API\n(WhatsApp alternativo)"]
        TW["Twilio\n(llamadas / SMS)"]
        SG["SendGrid\n(emails)"]
        SLK["Slack"]
    end

    subgraph CRM
        HS["HubSpot\n(sync bidireccional)"]
        PD["Pipedrive\n(sync bidireccional)"]
        ZAP["Zapier\n(webhooks)"]
        FAD["Facebook Ads\n(lead capture)"]
    end

    subgraph Storage
        AZ["Azure Blob Storage\n(PDFs, archivos, media)"]
        MS365["Microsoft Graph\n(SharePoint / Excel)"]
    end

    subgraph Infra
        RED["Redis\n(Celery + caché)"]
        TMP["Temporal\n(workflows durables)"]
        PG["PostgreSQL\n(checkpointer LangGraph)"]
        SQL["SQL Server (Azure)\n(base de datos principal)"]
    end

    SAAS --- A0
    CAL --- A0
    QUO --- A0
    COL --- A0

    SAAS --- AOI
    SAAS --- PCN
    SAAS --- MIS
    SAAS --- HAI
    SAAS --- EL
    SAAS --- WA
    SAAS --- EVO
    SAAS --- TW
    SAAS --- SG
    CAL --- SG
    SAAS --- HS
    SAAS --- PD
    SAAS --- ZAP
    SAAS --- FAD
    SAAS --- AZ
    QUO --- AZ
    COL --- AZ
    SAAS --- MS365
    SAAS --- RED
    SAAS --- TMP
    SAAS --- PG
    SAAS --- SQL
    CAL --- SQL
    QUO --- SQL
    COL --- SQL
```

### Tabla de integraciones

| Integración | Servicio que la usa | Propósito |
|---|---|---|
| **Auth0** | Todos | Autenticación JWT (PKCE en frontend, Bearer en backends) |
| **Azure OpenAI** | `app-saas-service` | GPT-4o (supervisor agente), GPT-4o-mini (guardrails) |
| **Azure AI Foundry** | `app-saas-service` | Claude Haiku 4.5 y Sonnet 4.6 (supervisor asesores), Mistral OCR y Claude Haiku (OCR dual-rail) |
| **Pinecone** | `app-saas-service` | Vector store para RAG de proyectos y propiedades |
| **ElevenLabs** | `app-saas-service` | Text-to-speech para voz de IA |
| **WhatsApp Cloud API** | `app-saas-service` | Canal principal de comunicación con leads (Meta/Graph) |
| **Evolution API** | `app-saas-service` | Canal WhatsApp alternativo |
| **Twilio** | `app-saas-service` | Llamadas y SMS |
| **SendGrid** | `app-saas-service`, `calendar-service` | Emails transaccionales y notificaciones |
| **Slack** | `app-saas-service` | Notificaciones internas a equipos |
| **HubSpot** | `app-saas-service` | Sincronización bidireccional de leads (pipeline mapping) |
| **Pipedrive** | `app-saas-service` | Sincronización bidireccional de leads (pipeline mapping) |
| **Facebook Ads** | `app-saas-service` | Captura de leads, ad performance insights |
| **Zapier** | `app-saas-service` | Webhooks de entrada/salida para automatizaciones externas |
| **Azure Blob Storage** | `app-saas-service`, `quotation-service`, `collection-service` | Almacenamiento de PDFs, documentos, media |
| **Microsoft Graph** | `app-saas-service` | Acceso a SharePoint / Excel (sales tracking de asesores) |
| **Redis** | `app-saas-service` | Celery workers + caché de contexto de usuario |
| **Temporal** | `app-saas-service` | Workflows durables (reenganche, SLA, campañas, etc.) |
| **PostgreSQL** | `app-saas-service` | Solo checkpointer de LangGraph (no datos de negocio) |
| **SQL Server (Azure)** | Todos los backends | Base de datos principal compartida |
| **Traefik** | Producción | Reverse proxy + TLS para todos los servicios |

---

## Infraestructura compartida

```mermaid
graph TD
    subgraph "Azure Cloud"
        SQL[("SQL Server\n(base de datos principal)")]
        BLOB["Azure Blob Storage\n(archivos / PDFs)"]
        AOI["Azure OpenAI / AI Foundry"]
    end

    subgraph "Self-hosted / Managed"
        RED[("Redis")]
        PG[("PostgreSQL\n(LangGraph checkpoints)")]
        TMP["Temporal Server\n:7233"]
        TRF["Traefik\n(reverse proxy)"]
    end

    SAAS["app-saas-service"] --> SQL
    SAAS --> BLOB
    SAAS --> AOI
    SAAS --> RED
    SAAS --> PG
    SAAS --> TMP

    CAL["calendar-service"] --> SQL
    QUO["quotation-service"] --> SQL
    QUO --> BLOB
    COL["collection-service"] --> SQL
    COL --> BLOB

    TRF --> CAL
    TRF --> QUO
    TRF --> COL
```

**Nota sobre base de datos**: Todos los microservicios conectan al mismo SQL Server de Azure. No se confirmó si comparten la misma base de datos o usan bases separadas dentro del mismo servidor.

---

## MCP Servers

`calendar-service` y `quotation-service` exponen servidores MCP que permiten a LLMs (Claude u otros) interactuar directamente con sus capacidades sin pasar por la API REST.

```mermaid
graph LR
    LLM["LLM (Claude, etc.)"]

    subgraph "calendar-service"
        CALMCP["MCP Server :3003\ncalendar-mcp.gopropflow.com"]
        CALAPI["REST API :3002"]
        CALDB[("SQL Server")]
        CALMCP --- CALDB
        CALAPI --- CALDB
    end

    subgraph "quotation-service"
        QUOMCP["MCP Server :3008\nquotation-mcp.gopropflow.com"]
        QUOAPI["REST API :3007"]
        QUODB[("SQL Server + Azure Blob")]
        QUOMCP --- QUODB
        QUOAPI --- QUODB
    end

    LLM -->|"MCP protocol\n(stdio o SSE)"| CALMCP
    LLM -->|"MCP protocol\n(stdio o SSE)"| QUOMCP
```

Ambos MCP servers se autentican via `MCP_API_KEY` o `API_KEY` (variable de entorno) y acceden directamente a la base de datos, no a través de la REST API.

---

## Estructura interna de módulos (patrón Node.js)

Los tres microservicios Node.js comparten la misma arquitectura interna:

```
src/modules/<entidad>/
  commands/        # Escritura: create, update, delete (un archivo por operación)
  queries/         # Lectura: getById, list, filter
  controllers/     # Express request handlers (llaman commands/queries)
  entities/        # Modelos Sequelize (mapeo a SQL Server)
  services/        # Lógica de negocio adicional (cuando aplica)

src/infrastructure/
  adapters/        # Clientes de servicios externos
  common/          # DB connection, utilidades compartidas
  presentation/
    routes/        # Definición de rutas Express
    middlewares/   # Auth (checkJwt), CORS, error handler
```

### Módulos por microservicio

**calendar-service**: `advisor`, `advisor_schedules`, `calendars`, `events`, `lead_activity_timeline`, `leads`, `project_milestones`, `projects`, `tasks`, `tenants`

**quotation-service**: `quotation_tool`, `version`

**collection-service**: `bank`, `charges`, `contacts`, `customer_card_config`, `customer_card_values`, `documents`, `files`, `form_template_fields`, `form_templates`, `generated_documents`, `installments`, `leads`, `loans`, `ocr_field_config`, `payment_applications`, `payment_reservations`, `payment_transactions`, `projects`, `properties`, `public_customer_card`, `reservations`, `url_shortcuts`

---

## Workflows Temporal activos

Los siguientes workflows están implementados en `app/temporal/` y son gestionados por el `temporal-worker`:

| Workflow | Propósito |
|---|---|
| `visit_followup` | Seguimiento automático post-visita |
| `visit_overdue` | Notificación de visitas vencidas |
| `reengagement_v2` / `insistence_reengagement` | Reenganche progresivo de leads inactivos |
| `intake_reengagement` | Reenganche durante el proceso de intake |
| `expediente_sla` | Control de SLAs de expedientes de postventa |
| `campaign` | Envío masivo de campañas WhatsApp |
| `daily_summary` | Resumen diario de actividad de asesores |
| `sentiment` | Análisis de sentimiento de conversaciones |
| `task_reminders` | Recordatorios de tareas programadas |
| `postventa_reminders` / `postventa_maintenance` | Recordatorios y mantenimiento de expedientes |
| `advisor_supervisor` | Evaluación periódica de performance de asesores |
| `advisor_whatsapp` | Gestión de conversaciones WhatsApp de asesores |
| `whatsapp_window` / `whatsapp_window_alert` | Control de ventana de 24h de WhatsApp |
| `facebook_insights` | Sync de métricas de Facebook Ads |

---

## Aspectos no confirmados en el código

Los siguientes puntos son inferencias arquitectónicas que **no fueron verificados** leyendo código fuente específico:

- **Esquema SQL compartido vs separado**: No está confirmado si `calendar-service`, `quotation-service` y `collection-service` usan la misma base de datos SQL Server que `app-saas-service` o bases de datos independientes en el mismo servidor.
- **Si `collection-service` tiene MCP Server**: No tiene scripts `mcp` en su `package.json` ni `@modelcontextprotocol/sdk` como dependencia. Presumiblemente no lo tiene, pero no fue verificado.
- **Activación del agente desde endpoints específicos**: El flujo del agente LangGraph fue trazado a nivel de componentes, pero no se verificó la ruta exacta del endpoint que dispara el supervisor.
- **Uso de Airflow**: Existe `Dockerfile.airflow` y carpeta `pipeline/` en `app-saas-service`, pero no se leyó el contenido. No está claro si Airflow está activo en producción.
