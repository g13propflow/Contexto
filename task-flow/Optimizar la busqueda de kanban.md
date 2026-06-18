#### Prompt:
En app-saas-frontend localiza la implementación de la ruta /dashboard/leads, especificamente el boton de Mas filtros

Devuelve únicamente:

- Archivo de la ruta
- Componente principal de la página
- Componentes hijos directos utilizados por la página
- Stores/composables utilizados directamente por la página
- Servicios API llamados directamente por la página

Formato:

ROUTE:
PAGE:
CHILD_COMPONENTS:
COMPOSABLES:
API_SERVICES:

No expliques el flujo.
No analices componentes hijos.
No propongas cambios.

### Response ia:
ROUTE:

Definición: src/router/index.ts:58-62 → path: 'leads'
Componente mapeado: @/views/LeadsView.vue
PAGE:

src/views/LeadsView.vue (contiene el botón "Más filtros": línea 120 en escritorio y línea 19 en móvil)
CHILD_COMPONENTS:

KanbanView — src/components/Leads/KanbanView.vue
ListView — src/components/Leads/ListView.vue
LeadTimelineModal — src/components/LeadTimelineModal.vue
ExpedienteModal — src/components/ExpedienteModal.vue
LeadContextSidebar — src/components/LeadContextSidebar.vue
LossReasonModal — src/components/LossReasonModal.vue
ExportFilterModal — src/components/Leads/ExportFilterModal.vue
MultiSelectDropdown — src/components/Leads/MultiSelectDropdown.vue
StarRating — src/components/Leads/StarRating.vue
EventModal — src/components/calendar/EventModal.vue
AttendeesModal — src/components/calendar/AttendeesModal.vue
ClosingModal — src/components/Leads/ClosingModal.vue
VueTelInput — paquete externo vue-tel-input
COMPOSABLES:

usePermission — @/composables/usePermission
useEventModal — @/composables/useEventModal
useAlert (store) — @/stores/alert
useLeadContextStore (store) — @/stores/leadContext
useConfirmedVisitsStore (store) — @/stores/confirmedVisits
useLeadStatusStore (store) — @/stores/leadStatus
maybePromptFollowUp (store) — @/stores/followUpPrompt
API_SERVICES:

leadsService — @/services/leads.service
advisorsService — @/services/advisors.service
campaignTrackingService — @/services/campaignTracking.service
leadCommentsService — @/services/leadComments.service
eventService — @/services/calendar.service
apiFetch — @/services/api.config

### Prompt:
Analiza únicamente lo que me diste de respuesta en el mensaje anterior:

Explícame:

1. Qué archivo debo modificar si [En el boton de Mas filtros, se necesita agregar un boton hasta abajo de ese dropdown, que dispare la busqueda al ser presionado, porque actualmente esta que cualquier filtro dispara la busqueda, este boton servira para que el usuario pueda el detonar la busqueda y no automaticamente como esta].



