#### Prompt:
En app-saas-frontend localiza la implementación de la ruta /dashboard/advisor-chat, flujo: Omnicanalidad &IA -> Chat Asesores

Devuelve únicamente:

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
ROUTE: /dashboard/advisor-chat → app-saas-frontend/src/router/index.ts:70-72

PAGE: app-saas-frontend/src/views/advisor-chat/index.vue

CHILD_COMPONENTS:

ConnectionStatus — ./components/ConnectionStatus.vue
ChatList — ./components/ChatList.vue
ChatMessages — ./components/ChatMessages.vue
LeadContextSidebar — @/components/LeadContextSidebar.vue
EventModal — @/components/calendar/EventModal.vue
AttendeesModal — @/components/calendar/AttendeesModal.vue
COMPOSABLES:

useEventModal — @/composables/useEventModal
useNotificationsStore — @/stores/notifications
useAlert — @/stores/alert
useI18n (vue-i18n)
API_SERVICES:

advisorsService — getAdvisors
advisorChatService — getStatus, getPersistedChats, getChats, getMessages, getPersistedMessages
leadsService — getLeadById

### Prompt:
Analiza únicamente los archivos que me diste de respuesta en el mensaje anterior:

Explícame:

1. Cómo se cargan las propiedades al entrar en la página.
2. De dónde vienen los datos.
3. Qué componente renderiza el listado principal.
4. Qué archivo debo modificar si quiero [Cambiar de canal slack para notificaciones de mensajes sin responder].

