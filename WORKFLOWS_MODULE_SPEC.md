# PropFlow — Especificación Técnica: Módulo de Workflows

**Versión:** 1.0  
**Fecha:** 2026-06-20  
**Estado:** Borrador para revisión

---

## Índice

1. [Objetivo del módulo](#1-objetivo-del-módulo)
2. [Análisis funcional](#2-análisis-funcional)
3. [Casos de uso](#3-casos-de-uso)
4. [UX y comportamiento responsive](#4-ux-y-comportamiento-responsive)
5. [Arquitectura frontend](#5-arquitectura-frontend)
6. [Arquitectura backend](#6-arquitectura-backend)
7. [Modelo de datos](#7-modelo-de-datos)
8. [Workflow Engine](#8-workflow-engine)
9. [Eventos requeridos](#9-eventos-requeridos)
10. [Endpoints requeridos](#10-endpoints-requeridos)
11. [Jobs / Workers requeridos](#11-jobs--workers-requeridos)
12. [Estrategia de permisos y roles](#12-estrategia-de-permisos-y-roles)
13. [Validaciones de negocio](#13-validaciones-de-negocio)
14. [Auditoría y trazabilidad](#14-auditoría-y-trazabilidad)
15. [Impacto sobre módulos existentes](#15-impacto-sobre-módulos-existentes)
16. [Riesgos técnicos](#16-riesgos-técnicos)
17. [Plan de implementación por fases](#17-plan-de-implementación-por-fases)
18. [Preguntas abiertas y supuestos](#18-preguntas-abiertas-y-supuestos)

---

## 1. Objetivo del módulo

El módulo de **Workflows** permite a usuarios con rol Owner configurar reglas de automatización para el CRM sin necesidad de código. Un workflow define: cuándo se activa (trigger), bajo qué condiciones adicionales aplica (conditions), y qué acciones ejecuta (actions).

**Diferencia con `BusinessRule` existente:** El modelo `BusinessRule` en la base de datos actual es un constructor canvas-orientado a flujos de agente IA (canvas_data + nodes JSON), activado únicamente por cambio de `trigger_lead_status`. El módulo de Workflows es una capa independiente de automatizaciones user-facing con estructura declarativa, múltiples tipos de trigger, condiciones evaluables, y acciones tipadas (tareas, Slack, cambio de fase, reasignación de asesor). **No reemplaza ni modifica `BusinessRule`; coexiste junto a él.**

---

## 2. Análisis funcional

### 2.1 Entidades del módulo

| Entidad | Descripción |
|---|---|
| `WorkflowRule` | El workflow completo: nombre, estado, trigger, condiciones, acciones |
| `WorkflowCondition` | Filtros adicionales evaluados con AND antes de ejecutar |
| `WorkflowAction` | Acciones ordenadas a ejecutar cuando trigger + condiciones se cumplen |
| `WorkflowExecutionLog` | Registro de cada ejecución: lead, timestamp, estado, errores por acción |

### 2.2 Estados de un workflow

```
BORRADOR → ACTIVO ⇄ INACTIVO
```

- **BORRADOR**: Recién creado o en edición. No se ejecuta aunque se cumpla el trigger.
- **ACTIVO**: Se evalúa y ejecuta al cumplirse el trigger.
- **INACTIVO**: Desactivado manualmente. No se ejecuta. El toggle en la lista lo cambia entre ACTIVO/INACTIVO sin entrar al editor.

### 2.3 Estructura del editor (tres bloques en secuencia)

```
[ TRIGGER ] → [ CONDICIONES (opcionales) ] → [ ACCIONES ]
```

Los tres bloques se muestran siempre visibles en el editor. Las condiciones están claramente marcadas como opcionales con un indicador visual.

### 2.4 Triggers disponibles

#### Grupo: Estado del lead
| Trigger | Parámetros adicionales |
|---|---|
| `lead_status_changed` | `from_status` (opcional), `to_status` (requerido) |
| `lead_created` | — |
| `lead_assigned` | — |

#### Grupo: Actividad de tareas
| Trigger | Parámetros adicionales |
|---|---|
| `task_completed` | `task_type` (opcional, filtra por tipo) |
| `task_overdue` | `task_type` (opcional) — detectado por job diario 8:00 a.m. |
| `task_cancelled` | `task_type` (opcional) |

#### Grupo: Visitas
| Trigger | Parámetros adicionales |
|---|---|
| `visit_scheduled` | — |
| `visit_confirmed` | — |
| `visit_no_show` | — |
| `visit_no_answer` | — |

#### Grupo: Inactividad
| Trigger | Parámetros adicionales |
|---|---|
| `lead_inactive_days` | `days` (int ≥ 1) — sin tareas completadas, sin mensajes, sin cambio de fase |
| `lead_same_status_days` | `days` (int ≥ 1) — sin cambio de fase |

### 2.5 Condiciones disponibles

Todas las condiciones se evalúan con **AND** (deben cumplirse todas).

| Grupo | Campo | Operadores |
|---|---|---|
| Lead | `project_id` | es / no es (multiselect) |
| Lead | `status` | es |
| Lead | `source` | es |
| Lead | `has_scheduled_visit` | sí / no |
| Asesor | `advisor_id` | es (multiselect) |
| Asesor | `advisor_group_id` | pertenece a |
| Tarea (solo si trigger es de tarea) | `task_type` | es |
| Tarea (solo si trigger es de tarea) | `task_source` | sistema / manual |

### 2.6 Acciones disponibles

| Acción | Descripción |
|---|---|
| `create_task` | Crea una tarea individual con nombre, tipo, prioridad, asignado, fecha vencimiento |
| `create_task_series` | Crea N tareas en secuencia con intervalo configurable |
| `send_slack_notification` | Envía mensaje a canal de Slack del tenant |
| `change_lead_status` | Cambia la fase del lead automáticamente |
| `assign_advisor` | Asigna o reasigna asesor al lead |

Cada acción puede configurarse con un **delay**: ejecutar inmediatamente o X horas/días después del trigger.

### 2.7 Variables dinámicas (template tokens)

| Variable | Resolución |
|---|---|
| `{{lead.nombre}}` | `lead.name` |
| `{{lead.telefono}}` | `lead.phone` |
| `{{lead.proyecto}}` | Nombre del proyecto del lead |
| `{{lead.fase}}` | Label de la fase actual |
| `{{lead.fuente}}` | Fuente del lead |
| `{{asesor.nombre}}` | Nombre del asesor asignado al lead |
| `{{fecha.hoy}}` | Fecha de ejecución en formato legible |
| `{{workflow.trigger}}` | Descripción en lenguaje natural del trigger que disparó |
| `{{crm.link_lead}}` | URL directa al perfil del lead |
| `{{n}}` | (solo en `create_task_series`) Número de tarea en la serie |

La resolución ocurre en el backend al momento de ejecutar la acción, no en la configuración.

### 2.8 Regla de duplicado para `create_task`

| Opción | Comportamiento |
|---|---|
| `always` | Crea siempre (puede duplicar) |
| `skip_if_pending` | No crea si ya hay una tarea pendiente del mismo tipo para ese lead |
| `replace` | Cancela la existente y crea una nueva |

### 2.9 Duplicación de workflows

Un workflow se puede duplicar desde la lista. El duplicado se crea en estado **BORRADOR** con el prefijo `"Copia de"` en el nombre.

---

## 3. Casos de uso

### UC-01: Crear workflow de seguimiento post-fase
**Actor:** Owner  
**Flujo:** Entra a Configuración > Workflows > Nuevo workflow. Selecciona trigger "Lead cambia de fase" con destino "Negociación". Agrega condición "Proyecto es Las Palmas". Agrega acción `create_task_series`: 7 tareas de Seguimiento, cada 1 día, a las 09:00 a.m., asignadas al asesor del lead. Activa el workflow.  
**Resultado:** Cada vez que un lead pase a Negociación en el proyecto Las Palmas, se crean 7 tareas de seguimiento consecutivas para el asesor.

### UC-02: Notificación Slack cuando se agenda visita
**Actor:** Owner  
**Flujo:** Nuevo workflow. Trigger: "Visita es agendada". Sin condiciones. Acción `send_slack_notification` al canal `#visitas-agendadas` con mensaje: "🏠 Nueva visita agendada: {{lead.nombre}} ({{lead.telefono}}) - Proyecto {{lead.proyecto}}. {{crm.link_lead}}".  
**Resultado:** Cada visita agendada genera un mensaje automático en Slack.

### UC-03: Detección de inactividad
**Actor:** Owner  
**Flujo:** Trigger: "Lead lleva 7 días sin actividad". Condición: "Fase actual es Calificado". Acción `create_task` + acción `send_slack_notification` al canal `#alerta-inactividad`.  
**Resultado:** Job diario detecta leads en Calificado sin actividad por 7 días y genera tarea + alerta Slack.

### UC-04: Reasignación automática post-visita sin respuesta
**Actor:** Owner  
**Flujo:** Trigger: "Visita marcada como No show". Acción `assign_advisor` en modo round-robin del grupo "Asesores Senior". Acción `create_task`: "Revisión post No Show - {{lead.nombre}}".  
**Resultado:** Automáticamente reasigna y crea tarea de seguimiento cuando un lead no asiste.

### UC-05: Ver log de ejecuciones
**Actor:** Owner  
**Flujo:** En la lista de workflows, hace clic en el botón "Log" de un workflow. Ve la tabla de ejecuciones con: lead afectado, fecha, estado (éxito/fallo/parcial), detalle de errores por acción.

---

## 4. UX y comportamiento responsive

### 4.1 Vista principal: Lista de workflows

**Estructura de la tabla:**

| Columna | Detalle |
|---|---|
| Nombre | Texto + badge de estado (Activo/Inactivo/Borrador) |
| Trigger | Descripción en lenguaje natural: "Cuando un lead pase a fase Negociación" |
| Acciones | Chips: "Crear tarea", "Notificar Slack" (máx 2 visibles, luego "+N más") |
| Creado | Fecha relativa: "hace 3 días" |
| Toggle | Switch para activar/desactivar sin entrar al editor |
| Opciones | Menú: Editar, Duplicar, Ver log, Eliminar |

**Botón principal:** "Nuevo workflow" (arriba a la derecha, azul primario)

**Estado vacío:** Ilustración + "Aún no tienes workflows configurados. Los workflows automatizan acciones en tu CRM cuando ocurren eventos específicos." + botón "Crear primer workflow"

**Estado de carga:** Skeleton de tabla (5 filas)

**Estado de error:** Toast de error + botón "Reintentar"

### 4.2 Editor de workflow

**Layout general:** Panel lateral derecho (drawer de pantalla completa en mobile, columna de ~640px en desktop dentro de SettingsView).

El editor sigue un flujo visual top-down con tres secciones bien diferenciadas:

```
┌─────────────────────────────────────┐
│  [←] Nombre del workflow   [Guardar] │
├─────────────────────────────────────┤
│  ① TRIGGER                           │
│    [Selector de grupo y evento]      │
│    [Parámetros del trigger]          │
├─────────────────────────────────────┤
│  ② CONDICIONES (opcionales)          │
│    [+ Agregar condición]             │
│    [Lista de condiciones]            │
├─────────────────────────────────────┤
│  ③ ACCIONES                          │
│    [+ Agregar acción]                │
│    [Lista de acciones drag-drop]     │
├─────────────────────────────────────┤
│  RESUMEN EN LENGUAJE NATURAL         │
│  "Cuando un lead pase a Negociación  │
│   y el proyecto sea Las Palmas,      │
│   crear 7 tareas de seguimiento..."  │
├─────────────────────────────────────┤
│  [Guardar borrador]  [Activar]       │
└─────────────────────────────────────┘
```

**Resumen en lenguaje natural:** Se actualiza en tiempo real a medida que el usuario configura el workflow. Es un bloque de texto generado en el frontend (sin IA) a partir de las selecciones del usuario.

### 4.3 Bloque: Trigger

- Primer selector: Grupo de trigger (5 grupos con íconos)
- Segundo selector: Evento específico dentro del grupo (aparece al seleccionar grupo)
- Parámetros: Campos adicionales que aparecen según el trigger seleccionado
  - `lead_status_changed`: Dos selectores "Desde fase" (opcional) y "Hasta fase" (requerido)
  - `task_completed` / `overdue` / `cancelled`: Selector de tipo de tarea (opcional)
  - `lead_inactive_days` / `lead_same_status_days`: Input numérico de días (mínimo 1)
  
**Progreso bloqueado:** Si el trigger requiere parámetros y no están completos, el bloque de condiciones y acciones muestran un mensaje "Completa el trigger para continuar" y no son interactuables.

### 4.4 Bloque: Condiciones

- Cada condición es una fila: [Campo] [Operador] [Valor]
- El campo usa `SearchableSelect.vue` (componente existente)
- El operador y valor cambian dinámicamente según el campo seleccionado
- Botón "× Eliminar" al final de cada fila
- Límite sugerido: 5 condiciones máximo (validación soft con warning, no bloqueo)

**Aviso si no hay condiciones:**
```
ℹ️ Este workflow aplicará a todos los leads del tenant.
   ¿Deseas agregar condiciones?
```
Es informativo, no bloquea la activación.

### 4.5 Bloque: Acciones

- Cada acción es una tarjeta expandible
- Las tarjetas son reordenables con drag-and-drop (usar `@vueuse/integrations/useSortable` o librería nativa de HTML5 drag)
- El encabezado de la tarjeta muestra: ícono de tipo + nombre de acción + delay configurado + botón eliminar
- El cuerpo de la tarjeta (expandido) muestra el formulario de configuración
- El botón "Agregar acción" abre un modal selector de tipo de acción

**Formulario de nombre de tarea con variables dinámicas:**
- Input de texto enriquecido (no WYSIWYG, solo texto plano con tokens)
- Botón "{{·}}" al lado del campo abre un menú desplegable con las variables disponibles
- Las variables se insertan como texto `{{lead.nombre}}` en el input (comportamiento de chip visual, pero guardado como string)
- Idéntico comportamiento en: nombre de tarea, descripción, mensaje de Slack

**Fecha de vencimiento dinámica:**
```
[ Referencia base ▾ ] + [ N ] [ horas/días ▾ ] a las [ HH:MM ▾ ]
```
- Referencia base: "Fecha del trigger" / "Fecha de visita agendada" / "Fecha de reserva"
- El campo de hora fija es opcional y aparece si el usuario quiere especificarlo

**Preview en tiempo real (Slack):**
Debajo del textarea del mensaje de Slack, un bloque colapsable "Vista previa" muestra el mensaje con variables sustituidas por datos ficticios: `{{lead.nombre}}` → "María García", `{{lead.telefono}}` → "+502 5555-1234".

### 4.6 Modal: Selector de acción

Cuadrícula de 2×3 con tarjetas:

| Ícono | Nombre | Descripción corta |
|---|---|---|
| ✓ | Crear tarea | Asigna una tarea al asesor del lead |
| ≡ | Crear serie de tareas | Múltiples tareas en secuencia |
| 💬 | Notificar en Slack | Envía mensaje a un canal |
| ⇄ | Cambiar fase | Mueve el lead a otra etapa |
| 👤 | Asignar asesor | Cambia el asesor del lead |

### 4.7 Modal: Log de ejecuciones

- Tabla paginada (20 por página)
- Columnas: Lead (nombre + ID), Fecha, Estado (badge: Éxito / Fallo / Parcial), Acciones ejecutadas (N/M)
- Fila expandible: detalle de cada acción (nombre, estado, mensaje de error si falló, timestamp)
- Filtro de estado: Todas / Éxito / Fallo / Parcial
- Botón "Exportar CSV"

### 4.8 Comportamiento responsive

| Breakpoint | Comportamiento |
|---|---|
| `< 768px` (mobile) | Lista de workflows en cards apiladas (no tabla). Editor en pantalla completa. Log como lista de cards. Variables dinámicas en menú de fondo completo. |
| `768px–1024px` (tablet) | Editor en panel lateral de 100% ancho del content area. Tabla con columnas reducidas (oculta "Creado"). |
| `> 1024px` (desktop) | Layout estándar: tabla completa + editor en panel lateral de 640px. |

**Drag-and-drop en mobile:** Reemplazado por botones de ↑ ↓ para reordenar acciones.

### 4.9 Estados de UI transversales

| Estado | Implementación |
|---|---|
| Loading lista | `LoadingTable.vue` (existente) |
| Loading editor | Skeleton de las 3 secciones |
| Error al cargar | Toast error + botón "Reintentar" |
| Guardando | Botón "Guardar" con spinner + disabled |
| Activando | Botón "Activar" con spinner, toast de éxito |
| Toggle activando | Switch en estado indeterminado mientras la request vuela |
| Workflow sin acciones al activar | Bloqueo con mensaje inline: "Agrega al menos una acción para activar el workflow" |

### 4.10 Jerarquía visual

1. **Lista de workflows:** La columna Nombre tiene el mayor peso visual. El badge de estado (verde/amarillo/gris) es el indicador de salud más importante.
2. **Editor:** Los tres bloques tienen numeración (①②③) y color de fondo diferenciado: trigger (azul claro), condiciones (amarillo claro), acciones (verde claro).
3. **Resumen en lenguaje natural:** Siempre visible al pie del editor (sticky en desktop), es la "fuente de verdad" visual de lo que hace el workflow.

---

## 5. Arquitectura frontend

### 5.1 Ruta

```ts
// src/router/index.ts — dentro del bloque /dashboard
{
  path: 'settings',
  component: SettingsView,
  meta: { requiresAuth: true }
}
```

La ruta ya existe. El módulo se integra como un nuevo tab en `SettingsView.vue`. No requiere ruta nueva; el tab se activa vía `activeTab === 'workflows'`.

**Ruta de acceso URL con hash (opcional, deep linking):**
```
/dashboard/settings?tab=workflows
/dashboard/settings?tab=workflows&id=123
```

### 5.2 Estructura de carpetas

```
src/
├── views/
│   └── SettingsView.vue               # ← agregar tab 'workflows'
│
├── components/
│   └── workflows/
│       ├── WorkflowList.vue           # Lista principal con tabla
│       ├── WorkflowEditor.vue         # Shell del editor (3 bloques)
│       ├── WorkflowEditorDrawer.vue   # Wrapper drawer/panel lateral
│       ├── trigger/
│       │   ├── TriggerBlock.vue       # Bloque trigger completo
│       │   ├── TriggerGroupSelector.vue
│       │   ├── TriggerEventSelector.vue
│       │   └── TriggerParamsForm.vue  # Parámetros dinámicos por tipo
│       ├── conditions/
│       │   ├── ConditionsBlock.vue
│       │   ├── ConditionRow.vue       # Una condición: campo + operador + valor
│       │   └── ConditionValueInput.vue # Input dinámico según tipo de campo
│       ├── actions/
│       │   ├── ActionsBlock.vue       # Lista drag-drop de acciones
│       │   ├── ActionCard.vue         # Tarjeta expandible de acción
│       │   ├── ActionPickerModal.vue  # Modal selector de tipo de acción
│       │   ├── ActionDelayPicker.vue  # Selector de delay
│       │   ├── DynamicTokenInput.vue  # Input de texto con variables {{}}
│       │   ├── DueDatePicker.vue      # Selector de fecha vencimiento dinámica
│       │   └── forms/
│       │       ├── CreateTaskForm.vue
│       │       ├── CreateTaskSeriesForm.vue
│       │       ├── SlackNotificationForm.vue
│       │       ├── ChangeStatusForm.vue
│       │       └── AssignAdvisorForm.vue
│       ├── WorkflowSummary.vue        # Resumen en lenguaje natural
│       ├── WorkflowLogModal.vue       # Modal de log de ejecuciones
│       └── WorkflowStatusBadge.vue    # Badge Activo/Inactivo/Borrador
│
├── stores/
│   └── workflows.ts                   # Store Pinia nuevo
│
├── services/
│   └── workflows.service.ts           # HTTP service nuevo
│
├── composables/
│   ├── useWorkflowEditor.ts           # Lógica del editor (estado y validaciones)
│   ├── useWorkflowSummary.ts          # Generador de texto en lenguaje natural
│   └── useDynamicTokens.ts            # Inserción/parseo de variables dinámicas
│
├── types/
│   └── workflow.ts                    # Interfaces TypeScript
│
└── locales/
    ├── es/workflows.ts
    └── en/workflows.ts
```

### 5.3 Store Pinia: `workflows.ts`

```ts
// src/stores/workflows.ts
export const useWorkflowsStore = defineStore('workflows', () => {
  // State
  const workflows = ref<WorkflowRule[]>([])
  const currentWorkflow = ref<WorkflowRuleDetail | null>(null)
  const loading = ref(false)
  const saving = ref(false)
  const editorOpen = ref(false)
  const editorMode = ref<'create' | 'edit'>('create')

  // Selectors
  const activeWorkflows = computed(() => 
    workflows.value.filter(w => w.status === 'active')
  )

  // Actions
  async function fetchWorkflows(): Promise<void>
  async function createWorkflow(data: WorkflowRuleCreate): Promise<WorkflowRule>
  async function updateWorkflow(id: number, data: WorkflowRuleUpdate): Promise<WorkflowRule>
  async function toggleWorkflowStatus(id: number, newStatus: 'active' | 'inactive'): Promise<void>
  async function duplicateWorkflow(id: number): Promise<WorkflowRule>
  async function deleteWorkflow(id: number): Promise<void>
  function openEditor(workflow?: WorkflowRuleDetail): void
  function closeEditor(): void

  return {
    workflows, currentWorkflow, loading, saving,
    editorOpen, editorMode, activeWorkflows,
    fetchWorkflows, createWorkflow, updateWorkflow,
    toggleWorkflowStatus, duplicateWorkflow, deleteWorkflow,
    openEditor, closeEditor
  }
})
```

### 5.4 Composable: `useWorkflowEditor.ts`

Centraliza toda la lógica del editor:
- Estado del formulario (trigger, conditions, actions)
- Validaciones por bloque
- Computed del botón "Activar" (¿puede activarse?)
- Reset del estado al cerrar

```ts
export function useWorkflowEditor(workflowId?: number) {
  const trigger = ref<WorkflowTriggerConfig>({ type: '', params: {} })
  const conditions = ref<WorkflowCondition[]>([])
  const actions = ref<WorkflowActionConfig[]>([])
  const name = ref('')

  const isTriggerComplete = computed(...)
  const canActivate = computed(() => 
    isTriggerComplete.value && actions.value.length > 0 && allActionsValid.value
  )

  function addCondition(): void
  function removeCondition(index: number): void
  function addAction(type: WorkflowActionType): void
  function removeAction(index: number): void
  function reorderActions(from: number, to: number): void

  async function save(status: WorkflowStatus): Promise<void>
  
  return { trigger, conditions, actions, name, isTriggerComplete, canActivate, ... }
}
```

### 5.5 Composable: `useWorkflowSummary.ts`

Genera el texto en lenguaje natural a partir del estado del editor:

```ts
export function useWorkflowSummary(trigger, conditions, actions) {
  const summary = computed(() => {
    const parts: string[] = []
    
    // Trigger
    if (trigger.value.type === 'lead_status_changed') {
      const to = getStatusLabel(trigger.value.params.to_status)
      parts.push(`Cuando un lead pase a la fase "${to}"`)
    }
    // ... otros triggers
    
    // Condiciones
    if (conditions.value.length > 0) {
      const condText = conditions.value.map(c => formatCondition(c)).join(' y ')
      parts.push(`si ${condText}`)
    }
    
    // Acciones
    const actionTexts = actions.value.map(a => formatAction(a))
    parts.push(actionTexts.join(', luego '))
    
    return parts.join(', ')
  })
  
  return { summary }
}
```

### 5.6 Composable: `useDynamicTokens.ts`

Maneja la inserción y resolución de variables en inputs:

```ts
export function useDynamicTokens() {
  const AVAILABLE_TOKENS = [
    { key: '{{lead.nombre}}', label: 'Nombre del lead' },
    { key: '{{lead.telefono}}', label: 'Teléfono del lead' },
    // ...
  ]

  function insertToken(inputRef: Ref<HTMLInputElement>, token: string): void {
    // Inserta el token en la posición del cursor
  }

  function resolvePreview(text: string): string {
    // Sustituye tokens con datos ficticios para preview
    return text
      .replace('{{lead.nombre}}', 'María García')
      .replace('{{lead.telefono}}', '+502 5555-1234')
      // ...
  }

  return { AVAILABLE_TOKENS, insertToken, resolvePreview }
}
```

### 5.7 Servicio HTTP: `workflows.service.ts`

```ts
// src/services/workflows.service.ts
import { apiFetch } from './api.config'

export const workflowsService = {
  getAll: () => apiFetch('/workflow-rules'),
  getById: (id: number) => apiFetch(`/workflow-rules/${id}`),
  create: (data: WorkflowRuleCreate) => apiFetch('/workflow-rules', { method: 'POST', body: data }),
  update: (id: number, data: WorkflowRuleUpdate) => apiFetch(`/workflow-rules/${id}`, { method: 'PUT', body: data }),
  updateStatus: (id: number, status: WorkflowStatus) => 
    apiFetch(`/workflow-rules/${id}/status`, { method: 'PATCH', body: { status } }),
  duplicate: (id: number) => apiFetch(`/workflow-rules/${id}/duplicate`, { method: 'POST' }),
  delete: (id: number) => apiFetch(`/workflow-rules/${id}`, { method: 'DELETE' }),
  getLogs: (id: number, params: LogQueryParams) => 
    apiFetch(`/workflow-rules/${id}/execution-logs`, { params }),
  exportLogs: (id: number) => apiFetch(`/workflow-rules/${id}/execution-logs/export`),
}
```

### 5.8 Tipos TypeScript: `workflow.ts`

```ts
// src/types/workflow.ts

export type WorkflowStatus = 'draft' | 'active' | 'inactive'

export type WorkflowTriggerType =
  | 'lead_status_changed' | 'lead_created' | 'lead_assigned'
  | 'task_completed' | 'task_overdue' | 'task_cancelled'
  | 'visit_scheduled' | 'visit_confirmed' | 'visit_no_show' | 'visit_no_answer'
  | 'lead_inactive_days' | 'lead_same_status_days'

export type WorkflowActionType =
  | 'create_task' | 'create_task_series'
  | 'send_slack_notification'
  | 'change_lead_status'
  | 'assign_advisor'

export type WorkflowConditionField =
  | 'project_id' | 'status' | 'source' | 'has_scheduled_visit'
  | 'advisor_id' | 'advisor_group_id'
  | 'task_type' | 'task_source'

export interface WorkflowTriggerConfig {
  type: WorkflowTriggerType
  params: Record<string, any>
}

export interface WorkflowCondition {
  id: string // uuid local para la UI
  field: WorkflowConditionField
  operator: 'is' | 'is_not' | 'in' | 'not_in' | 'yes' | 'no' | 'belongs_to'
  value: any
}

export interface WorkflowActionBase {
  id: string // uuid local
  type: WorkflowActionType
  delay_hours: number // 0 = inmediato
  config: Record<string, any>
}

export interface WorkflowRule {
  id: number
  tenant_id: string
  name: string
  status: WorkflowStatus
  trigger_type: WorkflowTriggerType
  trigger_params: Record<string, any>
  created_at: string
  updated_at: string
}

export interface WorkflowRuleDetail extends WorkflowRule {
  conditions: WorkflowCondition[]
  actions: WorkflowActionBase[]
}
```

### 5.9 Integración en SettingsView.vue

Se agregan dos cambios en el archivo existente:

**1. Nuevo tab en la lista `tabs` (computed):**
```ts
{ id: 'workflows', name: t('settings.workflows.tabName'), icon: BoltIcon }
```

**2. Nueva sección condicional en el template:**
```html
<div v-if="activeTab === 'workflows'" class="space-y-6">
  <WorkflowList />
</div>
```

El componente `WorkflowList` gestiona internamente su propio estado de editor (drawer/modal).

---

## 6. Arquitectura backend

### 6.1 Estructura de archivos nuevos

```
app-saas-service/
├── app/
│   ├── api/v1/
│   │   └── workflow_rules.py          # Router CRUD + ejecuciones
│   ├── db/
│   │   ├── models_workflow_rules.py   # Modelos SQLAlchemy nuevos
│   │   └── repositories/
│   │       └── workflow_rule_repository.py
│   ├── schemas/
│   │   └── workflow_rule.py           # Pydantic schemas
│   ├── services/
│   │   ├── workflow_rule_service.py   # Lógica del engine de evaluación
│   │   └── workflow_action_executor.py # Ejecución de cada tipo de acción
│   └── tasks/
│       └── workflow_inactivity_checker.py  # Job diario para triggers de inactividad
├── alembic/versions/
│   └── xxxx_add_workflow_rules.py     # Migración nueva
```

### 6.2 Archivos existentes a modificar

| Archivo | Cambio |
|---|---|
| `app/api/v1/__init__.py` | Registrar `workflow_rules.router` |
| `app/services/lead_service.py` | Llamar al engine en `update_status_with_lead()` para trigger `lead_status_changed` |
| `app/services/lead_service.py` | Llamar al engine al crear lead (`lead_created`) |
| `app/services/lead_service.py` | Llamar al engine al asignar asesor (`lead_assigned`) |
| `app/services/auto_task_service.py` | Llamar al engine al completar/cancelar tarea (`task_completed`, `task_cancelled`) |
| `app/temporal/workflows.py` | Llamar al engine para `task_overdue` desde el job diario |
| `app/temporal/worker.py` | Registrar nuevo workflow/activity de inactividad |

### 6.3 Servicio: `workflow_rule_service.py`

El servicio central del engine. Tiene dos responsabilidades:

**A. Evaluación (triggered desde eventos):**

```python
class WorkflowRuleService:
    async def evaluate_trigger(
        self,
        session: AsyncSession,
        tenant_id: str,
        trigger_type: str,
        event_context: dict,  # lead_id, advisor_id, task_id, etc.
    ) -> None:
        """
        Llamado desde los puntos de integración (lead_service, etc.).
        1. Busca workflows activos del tenant con el trigger_type dado
        2. Para cada workflow, evalúa si trigger_params coinciden con el evento
        3. Para cada workflow que pasa trigger, evalúa conditions
        4. Para cada workflow que pasa conditions, encola las actions
        """
```

**B. Ejecución (puede ser inmediata o con delay):**

```python
    async def execute_workflow(
        self,
        session: AsyncSession,
        workflow_rule_id: int,
        lead_id: int,
        tenant_id: str,
        triggered_at: datetime,
    ) -> WorkflowExecutionLogEntry:
        """
        1. Carga el workflow y sus acciones (ordenadas)
        2. Para cada acción, verifica delay y ejecuta o encola con Celery
        3. Registra resultado en workflow_execution_logs
        4. Si una acción falla, registra el error pero continúa con la siguiente
        """
```

### 6.4 Servicio: `workflow_action_executor.py`

Un método por tipo de acción:

```python
class WorkflowActionExecutor:
    async def execute(
        self,
        action_type: str,
        action_config: dict,
        context: WorkflowExecutionContext,  # lead, advisor, tenant, triggered_at
    ) -> ActionResult:
        dispatch = {
            'create_task': self._create_task,
            'create_task_series': self._create_task_series,
            'send_slack_notification': self._send_slack_notification,
            'change_lead_status': self._change_lead_status,
            'assign_advisor': self._assign_advisor,
        }
        return await dispatch[action_type](action_config, context)
    
    async def _create_task(self, config: dict, ctx: WorkflowExecutionContext):
        # 1. Resolver variables en title y description
        # 2. Calcular due_date según due_date_config
        # 3. Aplicar duplicate_rule
        # 4. Crear tarea via TaskRepository con source=TaskSource.AUTO
        ...
    
    async def _send_slack_notification(self, config: dict, ctx: WorkflowExecutionContext):
        # 1. Resolver variables en message
        # 2. Llamar a slack_service.send_message(channel, message)
        ...
    
    async def _change_lead_status(self, config: dict, ctx: WorkflowExecutionContext):
        # 1. Llamar a lead_service.update_status()
        # IMPORTANTE: marcar el cambio con source='workflow' para evitar loops
        ...
```

### 6.5 Resolución de variables (template tokens)

```python
class WorkflowTokenResolver:
    async def resolve(
        self,
        template: str,
        context: WorkflowExecutionContext
    ) -> str:
        replacements = {
            '{{lead.nombre}}': context.lead.name or '',
            '{{lead.telefono}}': context.lead.phone or '',
            '{{lead.proyecto}}': context.project_name or '',
            '{{lead.fase}}': context.status_label or '',
            '{{lead.fuente}}': context.source_label or '',
            '{{asesor.nombre}}': context.advisor_name or '',
            '{{fecha.hoy}}': context.triggered_at.strftime('%d/%m/%Y'),
            '{{workflow.trigger}}': context.trigger_description,
            '{{crm.link_lead}}': f"{settings.APP_BASE_URL}/dashboard/leads?lead={context.lead.id}",
        }
        result = template
        for token, value in replacements.items():
            result = result.replace(token, value)
        return result
```

### 6.6 Evaluación de condiciones

```python
class WorkflowConditionEvaluator:
    async def evaluate_all(
        self,
        conditions: list[WorkflowConditionRow],
        lead: Lead,
        advisor: Optional[Advisor],
        task: Optional[Task],
    ) -> bool:
        """Retorna True solo si TODAS las condiciones pasan (AND lógico)"""
        for condition in conditions:
            if not await self._evaluate_one(condition, lead, advisor, task):
                return False
        return True
    
    async def _evaluate_one(self, condition, lead, advisor, task) -> bool:
        field = condition.field
        operator = condition.operator
        value = condition.value
        
        if field == 'project_id':
            actual = lead.project_id
            if operator == 'in': return actual in value
            if operator == 'not_in': return actual not in value
        
        elif field == 'status':
            return lead.status == value
        
        elif field == 'has_scheduled_visit':
            has_visit = bool(lead.scheduled_visit_date)
            return has_visit if value == 'yes' else not has_visit
        
        # ... demás campos
```

---

## 7. Modelo de datos

### 7.1 Tablas nuevas

#### `workflow_rules`

```sql
CREATE TABLE workflow_rules (
    id              INT IDENTITY(1,1) PRIMARY KEY,
    tenant_id       NVARCHAR(100)   NOT NULL,
    name            NVARCHAR(255)   NOT NULL,
    description     NVARCHAR(MAX)   NULL,
    status          NVARCHAR(20)    NOT NULL DEFAULT 'draft',
    -- status: 'draft' | 'active' | 'inactive'

    trigger_type    NVARCHAR(50)    NOT NULL,
    trigger_params  NVARCHAR(MAX)   NULL,   -- JSON: parámetros del trigger

    execution_count INT             NOT NULL DEFAULT 0,
    last_executed_at DATETIME       NULL,

    created_by      INT             NULL,   -- FK → users.id
    created_at      DATETIME        NOT NULL DEFAULT GETUTCDATE(),
    updated_at      DATETIME        NOT NULL DEFAULT GETUTCDATE(),

    CONSTRAINT chk_workflow_status CHECK (status IN ('draft', 'active', 'inactive'))
);

CREATE INDEX idx_wf_tenant ON workflow_rules (tenant_id);
CREATE INDEX idx_wf_tenant_status ON workflow_rules (tenant_id, status);
CREATE INDEX idx_wf_tenant_trigger ON workflow_rules (tenant_id, trigger_type, status);
```

#### `workflow_conditions`

```sql
CREATE TABLE workflow_conditions (
    id                  INT IDENTITY(1,1) PRIMARY KEY,
    workflow_rule_id    INT             NOT NULL REFERENCES workflow_rules(id) ON DELETE CASCADE,
    tenant_id           NVARCHAR(100)   NOT NULL,

    field               NVARCHAR(50)    NOT NULL,
    -- 'project_id' | 'status' | 'source' | 'has_scheduled_visit' |
    -- 'advisor_id' | 'advisor_group_id' | 'task_type' | 'task_source'

    operator            NVARCHAR(20)    NOT NULL,
    -- 'is' | 'is_not' | 'in' | 'not_in' | 'yes' | 'no' | 'belongs_to'

    value_json          NVARCHAR(MAX)   NOT NULL,  -- JSON: valor(es) del filtro

    display_order       INT             NOT NULL DEFAULT 0,

    created_at          DATETIME        NOT NULL DEFAULT GETUTCDATE()
);

CREATE INDEX idx_wf_cond_rule ON workflow_conditions (workflow_rule_id);
```

#### `workflow_actions`

```sql
CREATE TABLE workflow_actions (
    id                  INT IDENTITY(1,1) PRIMARY KEY,
    workflow_rule_id    INT             NOT NULL REFERENCES workflow_rules(id) ON DELETE CASCADE,
    tenant_id           NVARCHAR(100)   NOT NULL,

    action_type         NVARCHAR(50)    NOT NULL,
    -- 'create_task' | 'create_task_series' | 'send_slack_notification' |
    -- 'change_lead_status' | 'assign_advisor'

    execution_order     INT             NOT NULL DEFAULT 0,
    delay_hours         INT             NOT NULL DEFAULT 0,  -- 0 = inmediato
    config_json         NVARCHAR(MAX)   NOT NULL,  -- JSON: configuración de la acción

    created_at          DATETIME        NOT NULL DEFAULT GETUTCDATE(),
    updated_at          DATETIME        NOT NULL DEFAULT GETUTCDATE()
);

CREATE INDEX idx_wf_action_rule ON workflow_actions (workflow_rule_id);
CREATE INDEX idx_wf_action_rule_order ON workflow_actions (workflow_rule_id, execution_order);
```

#### `workflow_execution_logs`

```sql
CREATE TABLE workflow_execution_logs (
    id                  INT IDENTITY(1,1) PRIMARY KEY,
    tenant_id           NVARCHAR(100)   NOT NULL,
    workflow_rule_id    INT             NOT NULL REFERENCES workflow_rules(id) ON DELETE CASCADE,
    lead_id             INT             NULL REFERENCES leads(id) ON DELETE SET NULL,

    status              NVARCHAR(20)    NOT NULL,
    -- 'success' | 'partial' | 'failed' | 'skipped'

    trigger_type        NVARCHAR(50)    NOT NULL,
    trigger_context     NVARCHAR(MAX)   NULL,  -- JSON: contexto del evento

    actions_total       INT             NOT NULL DEFAULT 0,
    actions_succeeded   INT             NOT NULL DEFAULT 0,
    actions_failed      INT             NOT NULL DEFAULT 0,

    action_results      NVARCHAR(MAX)   NULL,  -- JSON: array de resultados por acción

    executed_at         DATETIME        NOT NULL DEFAULT GETUTCDATE(),
    duration_ms         INT             NULL  -- milisegundos de ejecución total
);

CREATE INDEX idx_wf_log_tenant ON workflow_execution_logs (tenant_id);
CREATE INDEX idx_wf_log_rule ON workflow_execution_logs (workflow_rule_id);
CREATE INDEX idx_wf_log_lead ON workflow_execution_logs (lead_id);
CREATE INDEX idx_wf_log_date ON workflow_execution_logs (tenant_id, executed_at DESC);
CREATE INDEX idx_wf_log_rule_date ON workflow_execution_logs (workflow_rule_id, executed_at DESC);
```

### 7.2 Schema JSON de `trigger_params`

```json
// lead_status_changed
{ "from_status": "nuevo", "to_status": "negociacion" }

// task_completed / task_overdue / task_cancelled
{ "task_type": "llamada" }  // null = cualquier tipo

// lead_inactive_days / lead_same_status_days
{ "days": 7 }
```

### 7.3 Schema JSON de `config_json` por tipo de acción

**`create_task`:**
```json
{
  "title_template": "Seguimiento cierre - {{lead.nombre}} - {{lead.telefono}}",
  "description_template": null,
  "task_type": "seguimiento",
  "priority": "alta",
  "assign_to": "lead_advisor",  // o { "type": "specific_advisor", "advisor_id": 12 }
  "due_date_config": {
    "base": "trigger_date",  // "trigger_date" | "visit_date" | "reservation_date"
    "offset_days": 1,
    "offset_hours": 0,
    "fixed_time": "09:00"
  },
  "duplicate_rule": "skip_if_pending"  // "always" | "skip_if_pending" | "replace"
}
```

**`create_task_series`:**
```json
{
  "title_template": "Seguimiento {{n}}/7 - {{lead.nombre}}",
  "task_type": "seguimiento",
  "priority": "media",
  "assign_to": "lead_advisor",
  "series_count": 7,
  "interval_days": 1,
  "fixed_time": "09:00",
  "start_offset_days": 1
}
```

**`send_slack_notification`:**
```json
{
  "channel": "C0123456789",  // ID del canal de Slack
  "channel_name": "#visitas-agendadas",  // Solo para display
  "message_template": "🏠 Nueva visita: {{lead.nombre}} ({{lead.telefono}}) - {{crm.link_lead}}",
  "include_action_button": true  // Botón "Ver lead" en el mensaje
}
```

**`change_lead_status`:**
```json
{
  "target_status": "en_negociacion",
  "auto_note": "Fase cambiada automáticamente por inactividad de 7 días"
}
```

**`assign_advisor`:**
```json
{
  "mode": "round_robin",  // "specific" | "round_robin" | "least_leads"
  "advisor_id": null,     // solo si mode = "specific"
  "group_id": 3           // para round_robin y least_leads
}
```

### 7.4 Schema JSON de `action_results` en el log

```json
[
  {
    "action_id": 1,
    "action_type": "create_task",
    "status": "success",
    "detail": "Task #456 created: 'Seguimiento cierre - María García'",
    "duration_ms": 45
  },
  {
    "action_id": 2,
    "action_type": "send_slack_notification",
    "status": "failed",
    "error": "Slack channel not found: C9999999",
    "duration_ms": 120
  }
]
```

### 7.5 Modelos SQLAlchemy

```python
# app/db/models_workflow_rules.py

class WorkflowRule(Base):
    __tablename__ = "workflow_rules"
    
    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    tenant_id: Mapped[str] = mapped_column(String(100), nullable=False, index=True)
    name: Mapped[str] = mapped_column(String(255), nullable=False)
    description: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    status: Mapped[str] = mapped_column(String(20), nullable=False, default='draft')
    trigger_type: Mapped[str] = mapped_column(String(50), nullable=False)
    trigger_params: Mapped[Optional[dict]] = mapped_column(JSON, nullable=True)
    execution_count: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    last_executed_at: Mapped[Optional[datetime]] = mapped_column(DateTime, nullable=True)
    created_by: Mapped[Optional[int]] = mapped_column(Integer, ForeignKey("users.id"), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, server_default=func.getutcdate())
    updated_at: Mapped[datetime] = mapped_column(DateTime, server_default=func.getutcdate(), onupdate=func.getutcdate())
    
    conditions: Mapped[list["WorkflowCondition"]] = relationship(
        "WorkflowCondition", back_populates="workflow_rule",
        cascade="all, delete-orphan", order_by="WorkflowCondition.display_order"
    )
    actions: Mapped[list["WorkflowAction"]] = relationship(
        "WorkflowAction", back_populates="workflow_rule",
        cascade="all, delete-orphan", order_by="WorkflowAction.execution_order"
    )
    execution_logs: Mapped[list["WorkflowExecutionLog"]] = relationship(
        "WorkflowExecutionLog", back_populates="workflow_rule",
        cascade="all, delete-orphan"
    )


class WorkflowCondition(Base):
    __tablename__ = "workflow_conditions"
    # id, workflow_rule_id, tenant_id, field, operator, value_json, display_order, created_at


class WorkflowAction(Base):
    __tablename__ = "workflow_actions"
    # id, workflow_rule_id, tenant_id, action_type, execution_order, delay_hours, config_json


class WorkflowExecutionLog(Base):
    __tablename__ = "workflow_execution_logs"
    # id, tenant_id, workflow_rule_id, lead_id, status, trigger_type,
    # trigger_context, actions_total, actions_succeeded, actions_failed,
    # action_results, executed_at, duration_ms
```

### 7.6 Migración Alembic

```
alembic revision --autogenerate -m "add_workflow_rules_tables"
```

Genera las cuatro tablas nuevas. Sin cambios a tablas existentes. La migración es totalmente aditiva (no destructiva).

---

## 8. Workflow Engine

### 8.1 Diagrama de flujo de evaluación

```
Evento ocurre en el sistema
    ↓
workflow_rule_service.evaluate_trigger(tenant_id, trigger_type, event_context)
    ↓
SELECT workflow_rules WHERE tenant_id = ? AND trigger_type = ? AND status = 'active'
    ↓
Para cada workflow_rule:
    ├── Evaluar trigger_params (ej: ¿la fase destino coincide?)
    │       ↓ No coincide → Skip
    ├── Cargar conditions del workflow
    ├── condition_evaluator.evaluate_all(conditions, lead, advisor, task)
    │       ↓ No pasan → Skip → Log con status='skipped'
    ├── Cargar actions del workflow (ordenadas)
    ├── Para cada action:
    │   ├── Si delay_hours == 0: ejecutar inmediatamente
    │   └── Si delay_hours > 0: encolar en Celery con eta = ahora + delay
    └── Crear WorkflowExecutionLog
```

### 8.2 Anti-ciclo para `change_lead_status`

El cambio de fase disparado por un workflow **no debe re-disparar otros workflows** de tipo `lead_status_changed` indefinidamente.

**Solución:** El contexto de ejecución incluye un flag `source='workflow'`. En el hook de `lead_service.update_status_with_lead()`, cuando `source == 'workflow'`, se pasan los workflow triggers normalmente — pero el `evaluate_trigger` lleva un parámetro `source_workflow_id` y cada workflow activo verifica que no sea él mismo el que está disparando.

**Además:** El editor muestra una advertencia explícita cuando la acción `change_lead_status` está configurada.

**Límite de seguridad:** Máximo 3 encadenamientos de workflow por evento (campo `chain_depth` en el contexto). Si se supera, se registra en el log y se detiene la cadena.

### 8.3 Triggers por inactividad (job-based)

Los triggers `lead_inactive_days` y `lead_same_status_days` no son event-driven; requieren un job periódico.

**Implementación:** Temporal workflow nuevo `workflow_inactivity_checker` que se ejecuta diariamente a las 08:00 a.m. (hora del tenant, usando el timezone configurado en `TenantConfig`).

```python
# app/temporal/workflows_workflow_checker.py

@workflow.defn
class WorkflowInactivityCheckerWorkflow:
    @workflow.run
    async def run(self, tenant_id: str) -> None:
        """
        1. Carga todos los workflows activos con triggers de inactividad del tenant
        2. Para cada workflow, calcula el threshold de días
        3. Busca leads que cumplan el criterio (última actividad > N días)
        4. Para cada lead encontrado, dispara evaluate_trigger
        """
```

**Query de inactividad:**
```sql
-- Lead sin actividad en N días
SELECT l.id FROM leads l
WHERE l.tenant_id = ?
  AND l.status NOT IN ('ganado', 'perdido')
  AND NOT EXISTS (
    SELECT 1 FROM lead_activity_timeline lat
    WHERE lat.lead_id = l.id
      AND lat.created_at > DATEADD(day, -N, GETUTCDATE())
  )
```

### 8.4 Trigger para `task_overdue`

El job diario de Temporal `task_reminders` ya existe (ver `workflows.py`). Se extiende para llamar también al workflow engine con trigger `task_overdue` para cada tarea vencida encontrada.

### 8.5 Acciones con delay

Las acciones con `delay_hours > 0` se encolan en **Celery**:

```python
# Al encolar
from app.tasks.workflow_tasks import execute_delayed_workflow_action

execute_delayed_workflow_action.apply_async(
    args=[workflow_action_id, lead_id, tenant_id, execution_log_id],
    eta=datetime.utcnow() + timedelta(hours=action.delay_hours)
)
```

**Consideración:** Si el lead cambia de estado o el workflow se desactiva entre el encolamiento y la ejecución del delay, la tarea Celery debe verificar al ejecutar que el workflow sigue activo y el lead sigue en el estado esperado (validación defensiva).

---

## 9. Eventos requeridos

### 9.1 Puntos de integración en código existente

| Archivo | Punto | Trigger que dispara |
|---|---|---|
| `lead_service.py` → `update_status_with_lead()` | Después de commit exitoso | `lead_status_changed` |
| `lead_service.py` → `create_lead()` | Después de commit exitoso | `lead_created` |
| `lead_service.py` → `assign_advisor()` | Después de commit exitoso | `lead_assigned` |
| `leads.py` API → `PATCH /{id}/assign` | Después de asignación exitosa | `lead_assigned` |
| `auto_task_service.py` → `_complete_task()` o desde tasks API | Al marcar tarea completada | `task_completed` |
| `tasks.py` API → `PATCH /{id}` (status → cancelled) | Al cancelar tarea | `task_cancelled` |
| `temporal/activities_task_reminders.py` | Job diario 8:00 a.m. | `task_overdue` |
| Nuevo Temporal activity | Job diario 8:00 a.m. | `lead_inactive_days`, `lead_same_status_days` |

### 9.2 Patrón de integración (fire-and-forget)

```python
# En lead_service.py — ejemplo de integración

async def update_status_with_lead(self, ...):
    # ... lógica existente ...
    
    # NUEVO: disparar engine de workflows (fire and forget)
    asyncio.create_task(
        workflow_rule_service.evaluate_trigger(
            session=db,
            tenant_id=tenant_id,
            trigger_type='lead_status_changed',
            event_context={
                'lead_id': lead.id,
                'from_status': old_status,
                'to_status': new_status,
                'advisor_id': lead.advisor_id,
                'project_id': lead.project_id,
            }
        )
    )
```

**Importante:** El engine se llama como fire-and-forget (`asyncio.create_task`) para no bloquear el path crítico existente. Los errores del engine se registran en el log pero no afectan la operación original del CRM.

---

## 10. Endpoints requeridos

Todos bajo `GET /api/v1/workflow-rules`.

### 10.1 CRUD de workflows

| Método | Ruta | Descripción | Permiso |
|---|---|---|---|
| `GET` | `/workflow-rules` | Lista todos los workflows del tenant (paginados) | `workflows.view` |
| `GET` | `/workflow-rules/{id}` | Detalle completo con condiciones y acciones | `workflows.view` |
| `POST` | `/workflow-rules` | Crear nuevo workflow (state: draft) | `workflows.manage` |
| `PUT` | `/workflow-rules/{id}` | Actualizar workflow completo (reemplaza condiciones y acciones) | `workflows.manage` |
| `PATCH` | `/workflow-rules/{id}/status` | Cambiar estado (active/inactive/draft) | `workflows.manage` |
| `POST` | `/workflow-rules/{id}/duplicate` | Duplicar workflow (crea en draft) | `workflows.manage` |
| `DELETE` | `/workflow-rules/{id}` | Eliminar workflow (soft-delete recomendado) | `workflows.manage` |

### 10.2 Logs

| Método | Ruta | Descripción | Permiso |
|---|---|---|---|
| `GET` | `/workflow-rules/{id}/execution-logs` | Logs de ejecuciones (paginados, filtrable por status/fecha) | `workflows.view` |
| `GET` | `/workflow-rules/{id}/execution-logs/export` | CSV de logs | `workflows.view` |

### 10.3 Datos auxiliares (para selectores del editor)

| Método | Ruta | Descripción | Reutiliza |
|---|---|---|---|
| `GET` | `/api/v1/lead-status` | Fases configuradas del tenant | Endpoint existente `lead_status` |
| `GET` | `/api/v1/projects` | Proyectos del tenant | Endpoint existente |
| `GET` | `/api/v1/advisors` | Asesores activos del tenant | Endpoint existente |
| `GET` | `/api/v1/workflow-rules/meta/slack-channels` | Canales Slack del tenant disponibles | Nuevo (llama a `slack_service`) |

### 10.4 Schemas Pydantic

```python
# app/schemas/workflow_rule.py

class WorkflowConditionSchema(BaseModel):
    field: str
    operator: str
    value: Any

class WorkflowActionSchema(BaseModel):
    action_type: str
    execution_order: int
    delay_hours: int = 0
    config: dict

class WorkflowRuleCreate(BaseModel):
    name: str = Field(..., min_length=1, max_length=255)
    description: Optional[str] = None
    trigger_type: str
    trigger_params: Optional[dict] = None
    conditions: list[WorkflowConditionSchema] = []
    actions: list[WorkflowActionSchema] = []

class WorkflowRuleUpdate(WorkflowRuleCreate):
    pass

class WorkflowRuleStatusUpdate(BaseModel):
    status: Literal['active', 'inactive', 'draft']

class WorkflowRuleResponse(BaseModel):
    id: int
    name: str
    description: Optional[str]
    status: str
    trigger_type: str
    trigger_params: Optional[dict]
    conditions: list[WorkflowConditionSchema]
    actions: list[WorkflowActionSchema]
    execution_count: int
    last_executed_at: Optional[datetime]
    created_at: datetime
    updated_at: datetime
    
    model_config = ConfigDict(from_attributes=True)

class WorkflowRuleListItem(BaseModel):
    id: int
    name: str
    status: str
    trigger_type: str
    trigger_summary: str  # Generado en backend: "Cuando lead pase a Negociación"
    action_types: list[str]
    execution_count: int
    created_at: datetime

class WorkflowExecutionLogResponse(BaseModel):
    id: int
    workflow_rule_id: int
    lead_id: Optional[int]
    lead_name: Optional[str]  # Join con leads
    status: str
    actions_total: int
    actions_succeeded: int
    actions_failed: int
    action_results: Optional[list[dict]]
    executed_at: datetime
    duration_ms: Optional[int]
```

---

## 11. Jobs / Workers requeridos

### 11.1 Temporal: `WorkflowInactivityCheckerWorkflow`

| Parámetro | Valor |
|---|---|
| Archivo | `app/temporal/workflows_workflow_checker.py` |
| Cron | Diario a las 08:00 a.m. (por tenant, usando timezone del tenant) |
| Task queue | `propflow-default` (misma que todos los workflows) |
| Trigger | Llamado desde `temporal_service.py` como scheduled workflow |

**Responsabilidades:**
1. Para cada tenant con workflows activos de tipo `lead_inactive_days` o `lead_same_status_days`
2. Calcula qué leads cumplen el criterio usando las queries de inactividad definidas en §8.3
3. Llama a `workflow_rule_service.evaluate_trigger()` para cada lead encontrado
4. Evita re-procesamiento: lleva timestamp del último check en el log

**Registro en `worker.py`:** Agregar el nuevo workflow y sus activities al worker existente.

### 11.2 Celery: `execute_delayed_workflow_action`

| Parámetro | Valor |
|---|---|
| Archivo | `app/tasks/workflow_tasks.py` (nuevo) |
| Queue | `default` (cola Celery existente) |
| Retry | 3 reintentos con exponential backoff |

```python
@celery_app.task(
    bind=True,
    max_retries=3,
    default_retry_delay=60,
    name='workflow_tasks.execute_delayed_workflow_action'
)
def execute_delayed_workflow_action(
    self,
    workflow_action_id: int,
    lead_id: int,
    tenant_id: str,
    execution_log_id: int
):
    ...
```

### 11.3 Extensión de jobs existentes

| Job existente | Extensión requerida |
|---|---|
| `task_reminders` (Temporal) | Al detectar tareas vencidas, llamar a `workflow_rule_service.evaluate_trigger('task_overdue', ...)` |

---

## 12. Estrategia de permisos y roles

### 12.1 Nuevos permisos a registrar

| Permiso | Descripción |
|---|---|
| `workflows.view` | Ver la lista de workflows y sus logs |
| `workflows.manage` | Crear, editar, activar, desactivar, eliminar workflows |

### 12.2 Asignación por rol

| Rol | `workflows.view` | `workflows.manage` |
|---|---|---|
| Owner | ✅ | ✅ |
| Admin | ✅ | ✅ |
| Manager | ❌ | ❌ |
| Asesor interno | ❌ | ❌ |
| Asesor externo | ❌ | ❌ |

**Los asesores (internos y externos) no tienen acceso al módulo.**

### 12.3 Implementación frontend

**Tab en SettingsView** — visible solo si tiene permiso:
```ts
const tabs = computed(() => [
  // ... tabs existentes ...
  ...(can('workflows.view') ? [
    { id: 'workflows', name: t('settings.workflows.tabName'), icon: BoltIcon }
  ] : []),
])
```

**Router guard:** La ruta `/dashboard/settings` no requiere cambio (el tab es interno a la vista). Sin embargo, si se implementa deep linking por URL (`?tab=workflows`), agregar verificación de permiso al activar el tab.

**API backend:**
```python
@router.get("/")
async def list_workflow_rules(
    user_ctx: UserContext = Depends(require_permission("workflows.view")),
    ...
):
```

### 12.4 Seed de permisos

En `rbac_service.py`, agregar los dos nuevos permisos al seed inicial del sistema. Al desplegar la migración, ejecutar el seed para que los roles Owner y Admin reciban los permisos automáticamente.

---

## 13. Validaciones de negocio

### 13.1 Validaciones en el editor (frontend)

| Regla | Mensaje |
|---|---|
| Nombre requerido (min 3 chars) | "El nombre es requerido" |
| Trigger requerido | "Selecciona un trigger para continuar" |
| Trigger con parámetros incompletos | "Completa los parámetros del trigger" |
| `lead_inactive_days` con days < 1 | "El mínimo es 1 día" |
| `lead_status_changed` sin `to_status` | "Selecciona la fase destino" |
| Acciones vacías al intentar activar | "Agrega al menos una acción para activar el workflow" |
| Acción con configuración incompleta | Mensaje inline en la tarjeta de la acción |
| `create_task`: sin title_template | "El nombre de la tarea es requerido" |
| `create_task_series`: series_count < 1 | "Mínimo 1 tarea en la serie" |
| `create_task_series`: interval_days < 1 | "El intervalo mínimo es 1 día" |
| `send_slack_notification`: sin channel | "Selecciona un canal de Slack" |
| `send_slack_notification`: sin message | "El mensaje es requerido" |
| `change_lead_status`: sin target_status | "Selecciona la fase destino" |
| `assign_advisor` round_robin sin group | "Selecciona un grupo de asesores" |

### 13.2 Validaciones en el backend (Pydantic + Service)

| Regla | Comportamiento |
|---|---|
| `trigger_type` no reconocido | HTTP 422 |
| `action_type` no reconocido | HTTP 422 |
| `status` solo puede ser `active` si hay al menos una acción | HTTP 400: "Cannot activate workflow without actions" |
| Workflow en `active` con trigger incompleto | HTTP 400: "Trigger configuration is incomplete" |
| Condición con `field` no permitido para el trigger_type | HTTP 400: "Condition field not applicable for this trigger" |
| Más de 10 condiciones por workflow | HTTP 400: "Maximum 10 conditions per workflow" (límite duro) |
| Más de 10 acciones por workflow | HTTP 400: "Maximum 10 actions per workflow" |
| `series_count > 30` | HTTP 400: "Maximum 30 tasks per series" |

### 13.3 Validaciones en tiempo de ejecución (engine)

| Situación | Comportamiento |
|---|---|
| Workflow se desactivó entre el encolamiento de delay y la ejecución | La tarea Celery verifica y aborta silenciosamente. Log: `status='skipped'`. |
| Lead fue eliminado antes de la ejecución | Acción abortada. Log con status `'skipped'`. |
| Canal de Slack ya no existe | Acción falla. Log `'failed'`. Workflow continúa con siguiente acción. |
| Fase destino de `change_lead_status` ya no existe en el tenant | Acción falla con log de error. |
| `assign_advisor` round_robin con grupo vacío | Acción falla con log de error. |
| Tarea duplicada con `skip_if_pending` detecta duplicado | Acción registra `'skipped'` en el log. No es un error. |
| Cadena de workflows > 3 niveles de profundidad | Ejecución detenida. Log: `'failed: max chain depth exceeded'`. |

---

## 14. Auditoría y trazabilidad

### 14.1 Log de ejecuciones (`workflow_execution_logs`)

Cada ejecución del engine crea un registro con:
- Qué workflow se ejecutó (ID)
- Para qué lead (ID)
- Qué trigger lo disparó y con qué contexto
- Estado general (success/partial/failed/skipped)
- Resultado de cada acción individual (array JSON)
- Duración total en ms

### 14.2 Lead Activity Timeline

Cuando un workflow ejecuta acciones que afectan a un lead, se registra en `lead_activity_timeline`:

```python
# En cada acción exitosa que afecta al lead:
await timeline_service.add_entry(
    lead_id=context.lead_id,
    tenant_id=context.tenant_id,
    event_type='workflow_action',
    description=f"Workflow '{workflow.name}': {action_description}",
    metadata={ 'workflow_id': workflow.id, 'action_type': action.action_type }
)
```

### 14.3 Audit Log de cambios de configuración

Los cambios de configuración del módulo (crear, editar, activar, desactivar, eliminar un workflow) se registran en la tabla `audit_logs` existente (`app/db/models_auth.py`):

```python
# En el router workflow_rules.py
await audit_log_service.log(
    tenant_id=tenant_id,
    user_id=user_ctx.user_id,
    entity_type='workflow_rule',
    entity_id=workflow.id,
    action='created' | 'updated' | 'activated' | 'deactivated' | 'deleted',
    changes=diff_data
)
```

### 14.4 Visibilidad para el usuario

- El log de ejecuciones es accesible directamente desde la lista de workflows (botón "Log" en cada fila)
- El timeline del lead refleja las acciones ejecutadas automáticamente por workflows
- En las tareas creadas automáticamente, el campo `source = TaskSource.AUTO` ya muestra el badge "Auto" en la UI existente de tareas

---

## 15. Impacto sobre módulos existentes

### 15.1 `lead_service.py` — Impacto: BAJO-MEDIO

- **Cambio:** Agregar 3 llamadas fire-and-forget al engine en `update_status_with_lead()`, `create_lead()`, y cuando se asigna asesor.
- **Riesgo:** Mínimo. Son llamadas `asyncio.create_task()` que no bloquean el path crítico.
- **Tests afectados:** Los tests existentes de `lead_service` no deben romperse. Los nuevos tests cubren la integración con el engine.

### 15.2 `auto_task_service.py` / `tasks.py` API — Impacto: BAJO

- **Cambio:** Al marcar una tarea como completada o cancelada, llamar al engine con `task_completed` o `task_cancelled`.
- **Riesgo:** Bajo. Fire-and-forget.
- **Considerar:** Si la tarea fue creada por un workflow (`source = AUTO`), ¿debe disparar el trigger? **Supuesto actual: Sí.** Una tarea completada por el sistema puede disparar otro workflow. Validar con el equipo.

### 15.3 `temporal/activities_task_reminders.py` — Impacto: BAJO

- **Cambio:** Después de detectar tarea vencida, llamar al engine con `task_overdue`.
- **Riesgo:** Bajo.

### 15.4 `SettingsView.vue` — Impacto: BAJO

- **Cambio:** Agregar tab "Workflows" a la lista de tabs y su bloque `v-if` en el template.
- **Riesgo:** Mínimo. El patrón ya existe para todos los otros tabs.

### 15.5 `BusinessRule` / `business_rules.py` — Impacto: NINGUNO

- No se modifica. El nuevo módulo es completamente independiente.
- Los modelos `BusinessRule`, `BusinessRuleNode`, `BusinessRuleExecution` permanecen sin cambios.

### 15.6 Router principal `app/api/v1/__init__.py` — Impacto: MÍNIMO

- Solo se agrega una línea: `api_router.include_router(workflow_rules.router)`.

### 15.7 Sistema de tareas (`Task`, `TaskRepository`) — Sin cambio

- El executor de workflows usa los repositorios existentes para crear tareas con `source=AUTO`.
- No se requieren campos nuevos en la tabla `tasks`.

### 15.8 Slack integration — Sin cambio

- El executor llama a `slack_service.py` existente.
- El nuevo endpoint `GET /workflow-rules/meta/slack-channels` recupera los canales de Slack disponibles del tenant desde la configuración existente.

---

## 16. Riesgos técnicos

### 16.1 ALTO — Loops de workflows

**Descripción:** Un workflow que ejecuta `change_lead_status` puede disparar otro workflow de `lead_status_changed`, creando un ciclo infinito.

**Mitigación:**
- Warning visual en el editor al agregar acción `change_lead_status`
- Parámetro `chain_depth` en el contexto de ejecución (máximo 3)
- Verificación en el engine antes de each evaluación

### 16.2 ALTO — Impacto en rendimiento del path crítico de leads

**Descripción:** Si el engine tiene un bug o tarda demasiado, podría afectar `update_status_with_lead()`.

**Mitigación:**
- Ejecutar el engine como `asyncio.create_task()` (fire-and-forget) para no bloquear
- Timeout interno en el engine de 10s por workflow
- El engine nunca lanza excepciones hacia el caller; las atrapa y loguea internamente

### 16.3 MEDIO — Acumulación de ejecuciones en triggers de inactividad

**Descripción:** Un tenant con 1,000 leads inactivos y 5 workflows de inactividad podría generar 5,000 ejecuciones en un solo job diario.

**Mitigación:**
- Rate limiting por tenant: máximo 100 ejecuciones por minuto del job de inactividad
- Procesamiento en batches de 50 leads
- Índice optimizado en `lead_activity_timeline` para la query de inactividad

### 16.4 MEDIO — Desfase de acciones con delay

**Descripción:** Si Celery está caído o la cola está congestionada, las acciones con delay no se ejecutarán a tiempo.

**Mitigación:**
- Las acciones con delay no son time-critical por naturaleza (el usuario configura "+1 día")
- Monitor de Celery existente
- Si una acción con delay no se ejecuta en `delay_hours * 2`, se marca como `failed` automáticamente

### 16.5 MEDIO — Datos obsoletos en acciones con delay

**Descripción:** Un lead puede cambiar de proyecto, asesor o fase entre el momento del trigger y la ejecución de una acción con delay.

**Mitigación:**
- El executor recarga el lead desde la DB en el momento de ejecución (no usa el contexto del encolamiento)
- Validación defensiva: si el lead ya no existe o el workflow fue desactivado, abortar silenciosamente

### 16.6 BAJO — Variables dinámicas con valores nulos

**Descripción:** `{{asesor.nombre}}` resuelve a cadena vacía si el lead no tiene asesor asignado.

**Mitigación:**
- El resolver nunca lanza excepción por token no resuelto; sustituye con cadena vacía o valor por defecto
- Documentar el comportamiento en la UI (tooltip junto a cada variable)

### 16.7 BAJO — Conflicto de naming con `/api/v1/workflows/`

**Descripción:** Ya existe un router registrado en `workflows.py` bajo el prefijo `/workflows`. El nuevo módulo usará `/workflow-rules`.

**Mitigación:** Usar `/workflow-rules` como prefijo del nuevo router (ya considerado en el diseño).

---

## 17. Plan de implementación por fases

### Fase 1 — Fundamentos (3-5 días)

**Backend:**
- Crear `models_workflow_rules.py` con las 4 tablas
- Generar y aplicar migración Alembic
- Crear `workflow_rule_repository.py` (CRUD básico)
- Crear `workflow_rules.py` API (CRUD endpoints: GET list, GET by id, POST, PUT, PATCH status, DELETE, duplicate)
- Crear schemas Pydantic
- Seed de permisos `workflows.view` y `workflows.manage`
- Registrar router en `__init__.py`

**Frontend:**
- Crear tipos TypeScript en `workflow.ts`
- Crear `workflows.service.ts` (solo CRUD, sin logs)
- Crear `workflows.ts` store
- Crear `WorkflowList.vue` (tabla básica + toggle de estado)
- Agregar tab "Workflows" en `SettingsView.vue` (con `v-permission`)
- Crear `WorkflowStatusBadge.vue`

**Entregable:** Lista de workflows funcional con CRUD básico. No hay editor completo aún.

---

### Fase 2 — Editor completo (5-7 días)

**Frontend:**
- `WorkflowEditorDrawer.vue` + `WorkflowEditor.vue` (shell)
- `TriggerBlock.vue` + `TriggerGroupSelector.vue` + `TriggerEventSelector.vue` + `TriggerParamsForm.vue`
- `ConditionsBlock.vue` + `ConditionRow.vue` + `ConditionValueInput.vue`
- `ActionsBlock.vue` + `ActionCard.vue` + `ActionPickerModal.vue` + `ActionDelayPicker.vue`
- `DynamicTokenInput.vue` + `useDynamicTokens.ts`
- Formularios de cada acción: `CreateTaskForm.vue`, `CreateTaskSeriesForm.vue`, `SlackNotificationForm.vue`, `ChangeStatusForm.vue`, `AssignAdvisorForm.vue`
- `DueDatePicker.vue`
- `WorkflowSummary.vue` + `useWorkflowSummary.ts`
- `useWorkflowEditor.ts` con todas las validaciones
- Drag-and-drop para reordenar acciones
- i18n (ES/EN)

**Backend:**
- Endpoint `GET /workflow-rules/meta/slack-channels`
- Validaciones Pydantic completas del esquema de acciones

**Entregable:** Editor completo. Se pueden crear, editar y activar workflows. No hay ejecución real aún.

---

### Fase 3 — Engine de ejecución (4-6 días)

**Backend:**
- `workflow_action_executor.py` con las 5 acciones implementadas
- `WorkflowTokenResolver` (resolución de variables dinámicas)
- `WorkflowConditionEvaluator`
- `workflow_rule_service.py` (`evaluate_trigger` + `execute_workflow`)
- Integración en `lead_service.py` (3 puntos: status_change, create, assign)
- Integración en tasks (completed, cancelled)
- Protección anti-ciclo con `chain_depth`

**Entregable:** Los triggers de estado de lead, creación, asignación y tareas funcionan. Los workflows se ejecutan correctamente.

---

### Fase 4 — Triggers de inactividad y delay (3-4 días)

**Backend:**
- `WorkflowInactivityCheckerWorkflow` (Temporal)
- Registro en `temporal/worker.py`
- Integración del trigger `task_overdue` en `activities_task_reminders.py`
- `execute_delayed_workflow_action` Celery task
- Lógica de delay en el engine

**Entregable:** Todos los triggers funcionan, incluyendo inactividad y tareas vencidas. Las acciones con delay se ejecutan asincrónicamente.

---

### Fase 5 — Logs y pulido (2-3 días)

**Backend:**
- Endpoints de logs (GET paginado, export CSV)
- Integración de `lead_activity_timeline` en el executor

**Frontend:**
- `WorkflowLogModal.vue` con tabla paginada y filtros
- Botón "Log" en la lista de workflows
- Estados de error y empty refinados
- Tests: al menos happy-path para el editor y el servicio

**Entregable:** Módulo completo con auditoría. Ready for QA.

---

### Resumen de estimaciones

| Fase | Backend | Frontend | Total |
|---|---|---|---|
| 1 — Fundamentos | 2 días | 2 días | ~3-4 días (paralelo) |
| 2 — Editor completo | 1 día | 5-6 días | ~6 días |
| 3 — Engine | 4-5 días | — | ~4-5 días |
| 4 — Inactividad + delay | 3 días | — | ~3 días |
| 5 — Logs + pulido | 1 día | 2 días | ~2-3 días |
| **Total** | **~11 días** | **~9 días** | **~18-20 días hábiles** |

---

## 18. Preguntas abiertas y supuestos

### Preguntas que requieren validación

1. **Triggers de tareas completadas por workflows propios:** Si un workflow crea una tarea y el asesor la completa, ¿debe disparar el trigger `task_completed` de otros workflows? **Supuesto actual: Sí.** ¿Confirmado?

2. **Slack — Gestión de canales:** ¿El selector de canales de Slack solo muestra los canales a los que el bot está suscrito? ¿Hay un endpoint o SDK configurado en `slack_service.py` que permita listar canales? → Se necesita revisar la implementación actual de Slack para validar que `list_channels()` existe.

3. **Grupos de asesores:** El modelo `Advisor` existe en la base de datos. ¿Existe un modelo `AdvisorGroup` o tabla de grupos de asesores? No fue encontrado en el análisis de código. Si no existe, la condición "Asesor pertenece al grupo" y la acción `assign_advisor` en modo round_robin/least_leads sobre un grupo deberán posponerse o crease una tabla nueva `advisor_groups`.

4. **Timezone para el job de inactividad:** ¿El job de inactividad debe ejecutarse a las 8:00 a.m. de la zona horaria del tenant (configurada en `TenantConfig`)? **Supuesto actual: Sí.** ¿O en una hora fija UTC?

5. **¿Se permite a Manager ver los logs (no editar)?** La especificación original dice solo Owner. El documento de permisos asigna `workflows.view` a Owner y Admin. ¿Se incluye Manager con solo `workflows.view`?

6. **`lead_assigned` trigger:** ¿Aplica tanto cuando se asigna manualmente desde la UI como cuando el sistema hace una asignación automática (round-robin del agente IA)? **Supuesto: Aplica en ambos casos.** ¿Confirmado?

7. **Soft delete vs hard delete:** ¿Los workflows eliminados deben borrarse físicamente o mantenerse en la base de datos con un flag `deleted_at`? **Supuesto: Soft delete** para preservar la referencia histórica en los logs. ¿Confirmado?

8. **Límite de workflows por tenant:** ¿Se establece algún límite de número de workflows activos por tenant (ej: plan de suscripción)? **Supuesto: Sin límite en esta fase.**

9. **`visit_no_show` y `visit_no_answer`:** ¿Estos estados se marcan desde el CRM frontend actual? ¿Existe ya un campo o estado en `CalendarEvent` o `LeadTourAppointment` para estos estados? Se necesita confirmar el punto exacto en el código donde se marcan para saber dónde integrar el trigger.

10. **Notificación al usuario cuando un workflow falla:** ¿El Owner debe recibir una notificación (SSE, email, Slack) cuando una acción de un workflow falla? **Supuesto: No en la fase inicial. Solo registro en el log.**

### Supuestos realizados

- El módulo vive dentro de la sección "Configuración" existente (`/dashboard/settings`) como un nuevo tab, no como una ruta separada.
- La variable `{{n}}` en `create_task_series` se resuelve a `1`, `2`, ..., `N` (número ordinal de la tarea en la serie).
- El campo `delay_hours` acepta valores fraccionarios (ej: 0.5 = 30 minutos) o solo enteros. **Supuesto: Solo enteros.** Si se necesita granularidad de minutos, el campo se renombraría a `delay_minutes`.
- La integración con Slack del tenant ya está configurada en `slack_config.py`. El executor puede llamar a `slack_service` directamente sin nueva configuración.
- El prefijo del nuevo router es `/workflow-rules` (no `/workflows`) para evitar colisión con el router existente en `workflows.py`.
- Las tareas creadas por workflows usan `source=TaskSource.AUTO` (ya existe en el enum), sin agregar un nuevo valor `WORKFLOW`. Si se necesita distinguir entre tareas automáticas del sistema y las de workflows, se puede agregar `TaskSource.WORKFLOW = "workflow"` como mejora.
- Los workflows no tienen acceso a datos de cobranza (`collection-service`) ni a cotizaciones en esta fase.
- Los workflows solo actúan sobre el lead en el contexto del tenant. No hay workflows cross-tenant.
- La selección de fases en el editor (para trigger y condición) usa el catálogo `LeadStatusCatalog` ya cargado por el store `leadStatus.ts` existente.
- En la acción `create_task`, `assign_to: "lead_advisor"` usa el asesor en el momento de ejecución, no en el momento de configuración del workflow.
