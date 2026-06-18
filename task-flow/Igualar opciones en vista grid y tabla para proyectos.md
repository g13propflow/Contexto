#### Prompt:
En app-saas-frontend localiza la implementación de la ruta /dashboard/properties.

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
src/router/index.ts → path: 'properties' (name: 'properties'), bajo el layout /dashboard
→ resuelve a /dashboard/properties

PAGE:
src/views/properties/ProjectsView.vue

CHILD_COMPONENTS:
- ProjectsListView  (@/components/projects/ProjectsListView.vue)
- AlertModal        (@/components/AlertModal.vue)
- LoadingCard       (@/components/LoadingCard.vue)

COMPOSABLES:
- useRouter (vue-router)
- useI18n   (vue-i18n)

API_SERVICES:
- projectsService              (@/services/projects.service)
- financingTypeCatalogService  (@/services/financingTypeCatalog.service)
- apiFetch, apiUpload          (@/services/api.config)

### Prompt:
Analiza únicamente los archivos que me diste de respuesta en el mensaje anterior:

Explícame:

1. Cómo se cargan las propiedades al entrar en la página.
2. De dónde vienen los datos.
3. Qué componente renderiza el listado principal.
4. Qué archivo debo modificar si quiero cambiar [el cambio es que se necesita igualar las opciones, porque salen diferentes en la tabla y el grid: Tabla: Modelos, Propiedades, Conocimiento, Plano, Amenidades, HITL, Hitos, Fotos Cotización, Videos, Master plan mkt, Webhook API Key
Grid: Modelos, Propiedades, Conocimiento, Plano, Amenidades, HITL, Hitos, Fotos Cotización, Videos, Brochure, Landing Page, El set final es que necesito todas las opciones, en las 2, tabla y grid:
Opciones: Modelos, Propiedades, Conocimiento, Plano, Amenidades, HITL, Hitos, Fotos Cotización, Videos, Brochure, Landing Page, Master plan mkt, Webhook API Key].

