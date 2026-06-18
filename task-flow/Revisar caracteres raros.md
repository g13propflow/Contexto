#### Prompt:
En app-saas-frontend localiza la implementación de /dashboard/loss-reason-catalog, flujo: Configuracion -> Motivos de descarte

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
ROUTE:

/dashboard/loss-reason-catalog → router/index.ts:215-219
PAGE:

LossReasonCatalogView.vue
CHILD_COMPONENTS:

Ninguno (no usa componentes hijos propios; solo iconos de @heroicons/vue y elementos HTML/modales inline)
COMPOSABLES:

useAlertStore — stores/alert.ts
useI18n (vue-i18n)
API_SERVICES:

lossReasonCatalogService — services/lossReasonCatalog.service.ts (métodos usados: list, create, update, toggleActive, deleteEntry)

### Prompt:
Analiza únicamente los archivos que me diste de respuesta en el mensaje anterior:

Explícame:
1. Qué archivo debo modificar si quiero [verificar porque hay texto que aparece como CatÃ¡logo, saber la causa raiz y como arreglarlo, tanto en locale en como en es].

