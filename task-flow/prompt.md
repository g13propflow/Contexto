## Paso 1
human: Analizar la tarea e identificar la tarea

## Paso 2
ia_prompt: En app-saas-frontend localiza la implementación de la ruta /dashboard/properties.

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

## Paso 3
ia_prompt: Analiza únicamente los archivos que me diste de respuesta en el mensaje anterior:

Explícame:

1. Cómo se cargan las propiedades al entrar en la página.
2. De dónde vienen los datos.
3. Qué componente renderiza el listado principal.
4. Qué archivo debo modificar si quiero cambiar [EXPLICAR_LO_MAS_POSIBLE_EL_CAMBIO].

Máximo 10 puntos.