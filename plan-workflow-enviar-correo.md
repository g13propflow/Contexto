# Plan — Acción "Enviar correo" dentro de un Workflow

> Trigger de estado del deal → acción `send_email` → servicio de Mailing (plantilla + datos del lead),
> con destino a el lead o a una lista de distribución resuelta **en vivo** al disparo.

---

## 1. Resumen ejecutivo

La buena noticia: **casi toda la infraestructura ya existe**. El módulo de Workflows tiene un motor
de acciones extensible y el módulo de Mailing ya expone un servicio de envío transaccional
reutilizable (`email_send_service.send`) que hace render de plantilla, supresión, idempotencia,
inserción en `email_messages`, envío vía SendGrid con `custom_args` para atribución del webhook, y
registro en el historial del lead (`track_email_sent`).

Además, el enum `EmailMessageOrigin` **ya incluye el valor `workflow`**, y
`email_send_service.send()` **ya acepta `origin="workflow"`**. El patrón "enviar a un lead o a una
lista de distribución" ya está implementado en `EmailStatusAutomation` (automatización por cambio de
estado) — la acción de workflow es esencialmente el mismo patrón expuesto desde el editor de
workflows.

Por tanto, esta tarea es mayormente **integración + UI**, no construcción de infraestructura nueva.

### Decisiones de alcance (confirmadas)
- **Observabilidad:** los envíos del workflow se tratan **igual que transaccional/automatización**:
  `origin="workflow"`, `email_campaign_id=NULL`. Reciben eventos del webhook de SendGrid (atribución
  por `email_message_id`), aparecen en el historial del lead y son consultables por origen. **No** se
  crea campaña sintética.
- **Listas dinámicas:** la acción **resuelve la lista en vivo al disparo** vía
  `DistributionListRepository.get_leads_with_email(list_id)` (no pre-materializada). Funciona hoy con
  listas estáticas; si más adelante el módulo de listas agrega listas por filtro/segmento, la acción
  las hereda sin cambios. **No** se construye el constructor de segmentos dinámicos en esta tarea.

---

## 2. Cómo encaja en lo existente

### Motor de workflows (sin cambios estructurales)
- `WorkflowActionExecutor.execute()` despacha por `action.action_type` mediante un dict
  (`app/services/workflow_action_executor.py:270`). Agregar `send_email` es añadir una entrada al
  dict + un handler `_send_email`.
- `WorkflowRuleService._run_execution()` recorre las acciones en orden, captura errores, escribe
  `WorkflowExecutionLog` y emite timeline. La acción `send_email` se beneficia de todo esto sin
  tocar el orquestador.

### Servicio de Mailing (reutilización total)
`app/services/email_send_service.py:20` — `EmailSendService.send()`:
```python
await email_send_service.send(
    tenant_id, template_id, lead_id,
    idempotency_key="workflow:{rule}:{action}:{lead}:{epoch}",
    source=f"workflow:{rule_id}",
    origin="workflow",          # ya soportado por _origin_enum → EmailMessageOrigin.WORKFLOW
)
```
Esto, por cada lead, ya hace:
1. Idempotencia (UQ `tenant_id`+`idempotency_key`) → no reenvía en re-evaluaciones.
2. Supresión (D-12) → registra `suppressed` sin enviar.
3. Render de plantilla con datos del lead (`build_lead_context` + `render_template_fields`).
4. Inserta `EmailMessage(origin=workflow, email_campaign_id=NULL)`.
5. Envía por SendGrid con `custom_args={tenant_id, lead_id, email_message_id, origin, source}`
   → el webhook de SendGrid atribuye `delivered/open/click/bounce` por `email_message_id`.
6. Registra `email_sent` en el historial del lead (`track_email_sent`) con `origin/source`.

### Mapeo trigger→plantilla en configuración, no en código
- Se cumple de forma natural: `template_id` (y `recipient_mode`/`distribution_list_id`) viven en
  `action.config_json`. Cada regla define su trigger y su plantilla en el editor. Mismo modelo que
  `message_template` en la acción de Slack.

### Resolución de lista en vivo
- `DistributionListRepository.get_leads_with_email(list_id)` ya devuelve los leads con email válido,
  excluyendo supresiones, leyendo la membresía **en el momento de la llamada** (al disparo). Es el
  mismo resolutor que usa la automatización por cambio de estado y la ejecución de campañas.
- Las listas de email se filtran por `channel='email'` (campo `DistributionList.channel`).

---

## 3. Cambios — Backend (`app-saas-service`)

### 3.1 `WorkflowActionExecutor` — nuevo handler `_send_email`
Archivo: `app/services/workflow_action_executor.py`

1. Registrar en el dict de `execute()` (`:270`): `"send_email": self._send_email`.
2. Implementar `_send_email(config, ctx, db, action_id)`:
   - Leer `config`:
     - `template_id: int` (requerido) → fallar si falta.
     - `recipient_mode: "lead" | "distribution_list"` (default `"lead"`).
     - `distribution_list_id: int` (requerido si `recipient_mode="distribution_list"`).
   - **Modo `lead`:** llamar `email_send_service.send(...)` para `ctx.lead_id` con
     `origin="workflow"`, `source=f"workflow:{ctx.source_workflow_id}"`,
     `idempotency_key=f"wf:{rule}:{action_id}:{ctx.lead_id}:{int(ctx.triggered_at.timestamp())}"`.
     - Resultado: `success` si `ok`, `skipped` si `suppressed`/`deduped`, `failed` si no.
   - **Modo `distribution_list`:** resolver `get_leads_with_email(list_id)` (canal `email`),
     iterar y enviar a cada lead con su propia `idempotency_key` (incluyendo `seg_lead.id`).
     Agregar contadores y devolver detalle resumido:
     `detail=f"Enviados {sent}, suprimidos {supp}, fallidos {failed} de {total} destinatarios"`.
     - `status`: `success` si `failed==0 and sent>0`; `partial` si hubo algunos fallos;
       `skipped` si la lista resolvió 0 destinatarios; `failed` si todos fallaron.
   - **Nota de sesión:** `email_send_service.send()` abre su **propia** `async_session_maker`
     (commit independiente). Esto es deseable: el envío se persiste aunque la transacción del
     workflow falle luego. No mezclar la sesión del executor con la del servicio de mailing.
   - **Importante (timeline):** NO añadir `send_email` a `TIMELINE_ACTION_TYPES` en
     `workflow_rule_service.py`. El historial ya lo escribe `track_email_sent` dentro de
     `email_send_service.send()` con `origin=workflow`; añadirlo duplicaría la entrada. El log de
     ejecución del workflow (`WorkflowExecutionLog.action_results`) sí captura el resultado.

### 3.2 Validación de schema
Archivo: `app/schemas/workflow_rule.py`
- `action_type` es `str` libre (validado por el dict de dispatch), así que no requiere cambio de
  enum. **Sí** conviene validar en `WorkflowActionSchema` que:
  - Para `action_type == "send_email"`: `delay_hours == 0` (regla del spec: el correo cuelga de un
    trigger de estado, **no** de un temporizador secuencial; no se usa en cadenas de espera).
    Rechazar con 422 si `delay_hours > 0`.
  - `config.template_id` presente; si `recipient_mode=="distribution_list"`,
    `config.distribution_list_id` presente.

### 3.3 Ejecución diferida (defensa)
- Como `send_email` no admite `delay_hours>0` (validado arriba), no entra al camino Temporal
  (`_enqueue_delayed_action`). Aun así, `workflow_delayed_executor.py` enruta por el mismo
  `WorkflowActionExecutor`, por lo que funcionaría si en el futuro se habilitara. No requiere cambio.

### 3.4 (Opcional) Validación de plantilla/lista al guardar la regla
- En `workflow_rule_service` / repositorio, al crear/actualizar una regla con acción `send_email`,
  verificar que `template_id` exista y esté activa, y que la lista exista y sea de canal `email`,
  para fallar temprano en el editor en vez de en runtime. Recomendado pero no bloqueante.

### Sin migraciones
No se requiere cambio de modelo ni migración Alembic: `EmailMessageOrigin.workflow` ya existe y la
acción se guarda como JSON en `workflow_actions.config_json`.

---

## 4. Cambios — Frontend (`app-saas-frontend`)

### 4.1 Tipos
Archivo: `src/types/workflow.ts`
- Añadir `'send_email'` a `WorkflowActionType` (`:22`).

### 4.2 Selector de acción
Archivo: `src/components/workflows/actions/ActionPickerModal.vue`
- Añadir la opción "Enviar correo" (icono de sobre, p.ej. lucide `Mail`).

### 4.3 Nuevo formulario `SendEmailForm.vue`
Archivo: `src/components/workflows/actions/forms/SendEmailForm.vue`
Campos:
- **Plantilla** (`template_id`): selector que consume el endpoint de plantillas de email
  (`GET /api/v1/email-templates`, filtrando activas). Reusar servicio existente si lo hay
  (`email-templates`/mailing); si no, añadir un fetch ligero en `workflowRules.service.ts`.
- **Destinatario** (`recipient_mode`): radio `El lead (deal)` | `Lista de distribución`.
- **Lista** (`distribution_list_id`): visible solo en modo lista; selector que consume
  `GET /api/v1/distribution-lists?channel=email`.
- Aviso inline: "El correo se envía al dispararse el trigger; esta acción no admite retraso"
  (deshabilitar/ocultar el `ActionDelayPicker` para `send_email`).
- (Opcional) vista previa del asunto de la plantilla.

### 4.4 Tarjeta de acción y editor
- `ActionCard.vue`: icono + etiqueta + resumen corto ("Enviar plantilla X al lead / a la lista Y").
- `ActionsBlock.vue` / `useWorkflowEditor.ts`: registrar el `config` por defecto de `send_email`
  (`{ template_id: null, recipient_mode: 'lead' }`) y forzar `delay_hours = 0`.
- `ActionDelayPicker.vue`: ocultar/deshabilitar cuando `action_type === 'send_email'`.

### 4.5 Resumen en lenguaje natural
Archivo: `src/components/workflows/WorkflowSummary.vue`
- Añadir frase: "→ enviar correo «{plantilla}» al lead" / "→ enviar correo «{plantilla}» a la lista
  «{lista}»".

### 4.6 i18n
Archivos: `src/locales/es/workflowsSettings.ts`, `src/locales/en/workflowsSettings.ts`
- Etiquetas de la acción, campos del formulario, aviso de "sin retraso", textos del resumen y del
  log para `send_email`.

---

## 5. Verificación / criterios de aceptación

Mapeo directo contra el spec:

| Requisito del spec | Cómo se cumple |
|---|---|
| Trigger de estado invoca "enviar correo" | Acción `send_email` en regla con trigger `lead_status_changed` (params `to_status`) |
| Llama al servicio de Mailing con plantilla + datos del deal | `email_send_service.send(template_id, lead_id, origin="workflow")` |
| Mapeo trigger→plantilla en config, no en código | `template_id` en `action.config_json`; editado en el editor |
| Lista dinámica resuelta en vivo al disparo | `get_leads_with_email(list_id)` en el handler, en tiempo de ejecución |
| Aparece en historial del lead | `track_email_sent` dentro de `email_send_service.send()` |
| Aparece en webhook SendGrid / métricas | `custom_args.email_message_id` + `origin=workflow` en `email_messages` |
| No cuelga de temporizador; no en cadenas de espera | Validación `delay_hours==0` para `send_email` (back + front) |

### Pruebas sugeridas
- **Unit (back):** `_send_email` modo lead → llama send con args correctos; modo lista → itera y
  agrega contadores; lista vacía → `skipped`; sin `template_id` → `failed`; mapea
  `suppressed/deduped` a `skipped`.
- **Validación:** crear regla `send_email` con `delay_hours>0` → 422.
- **Integración:** disparar `lead_status_changed` a "Cita Agendada" con regla activa → verificar
  `EmailMessage(origin=workflow)`, entrada `email_sent` en timeline, y `WorkflowExecutionLog` con la
  acción en `success`. Simular evento `delivered/open` del webhook → atribución por
  `email_message_id` y reflejo en `email_messages`.
- **Idempotencia:** re-evaluar el mismo trigger → no se duplica el envío (misma `idempotency_key`).
- **Frontend:** crear/editar/guardar regla con acción `send_email` (ambos modos); resumen y log
  muestran la acción; el delay aparece deshabilitado.

---

## 6. Orden de implementación

1. **Back — handler `_send_email`** + registro en dispatch (modo lead primero).
2. **Back — modo `distribution_list`** (resolución en vivo + agregación de resultados).
3. **Back — validación** `delay_hours==0` y presencia de `template_id`/`distribution_list_id`.
4. **Front — tipo + ActionPicker + SendEmailForm** (selector de plantilla y lista).
5. **Front — ActionCard, Summary, i18n, delay deshabilitado.**
6. **Pruebas** unit + integración + smoke manual con un trigger real.

---

## 7. Archivos a tocar (checklist)

**Backend**
- `app/services/workflow_action_executor.py` — dispatch + `_send_email` (núcleo).
- `app/schemas/workflow_rule.py` — validación de `send_email` (delay/config).
- (opcional) `app/services/workflow_rule_service.py` — validación temprana de plantilla/lista.

**Frontend**
- `src/types/workflow.ts`
- `src/components/workflows/actions/ActionPickerModal.vue`
- `src/components/workflows/actions/forms/SendEmailForm.vue` *(nuevo)*
- `src/components/workflows/actions/ActionCard.vue`
- `src/components/workflows/actions/ActionsBlock.vue` + `src/composables/useWorkflowEditor.ts`
- `src/components/workflows/actions/ActionDelayPicker.vue`
- `src/components/workflows/WorkflowSummary.vue`
- `src/locales/es/workflowsSettings.ts`, `src/locales/en/workflowsSettings.ts`
- (posible) `src/services/workflowRules.service.ts` — fetch de plantillas/listas de email

**Sin migraciones de base de datos.**
