# PLAN — Ampliar modal de "Lead ganado" para captura de datos de cierre

> Estado: **PROPUESTA (sin código)**. Pendiente de aprobación antes de implementar.
> Fecha: 2026-07-08

---

## 1. Hallazgos de la exploración (estado actual)

### 1.1 El modal de "lead ganado" YA existe

No hay un componente nuevo que crear desde cero. El modal de cierre es **`app-saas-frontend/src/components/Leads/ClosingModal.vue`**, un modal unificado reutilizado para varias transiciones de cierre (`negociacion`, `cita_completada`, `cerrado_ganado`, etc.). Los campos que muestra se deciden por la prop `requiredFields`, que viene del catálogo del backend.

**Ya captura hoy (cuando la transición es `cerrado_ganado`):**
- ✅ **Selección de modelo** — cascada Proyecto→Modelo (`selectedModelId`, `loadPropertyModels`).
- ✅ **Selección de propiedad** — cascada Modelo→Propiedad disponible (`selectedPropertyId`, `loadProperties`).
- ✅ **Monto de reserva** (GTQ, `reservationAmountValue`) + fecha de reserva.
- ✅ Fecha estimada de cierre + probabilidad de compra (otros estados).

**NO captura hoy (el gap real de esta HU):**
- ❌ **Tipo de pago**
- ❌ **Carga de imagen de recibo**
- ❌ El **monto NO viene prellenado** (decisión previa "D-5: monto sin prefill en v1", `ClosingModal.vue:391-395`). La HU pide prellenar **Q 5,000**.
- ❌ El confirm **no crea la reserva/expediente en collection-service** — solo hace `PATCH /leads/{id}`.

### 1.2 Cómo se dispara la transición a ganado

Botón "Ganado" en la card del kanban (`LeadCard.vue`, emit `mark-as-won`), `<select>` en la vista de lista, drag&drop del kanban y el `<select>` del sidebar. Todos convergen en `LeadsView.vue → openClosingModal(lead, 'cerrado_ganado')` (y su gemelo en `LeadContextSidebar.vue`).

- **Al confirmar:** `submitClosingTransition` arma un único `PATCH /api/v1/leads/{id}` con `{ status:'cerrado_ganado', reservation_amount, reservation_date, property_id, property_model_id, ... }` vía `leadsService.updateLead`.
- **Al cancelar:** **no se envía nada**; el lead se queda en su estado anterior (`negociacion`) y el `<select>`/kanban revierte visualmente. → El criterio "qué pasa al cancelar" ya está resuelto correctamente y **no cambia**.

### 1.3 Ya existe un flujo con tipo de pago + recibo (a reutilizar)

**`app-saas-frontend/src/components/ExpedienteModal.vue`** (flujo de reserva desde el módulo de descargas/expedientes) ya implementa exactamente lo que falta:
- Select de **tipo de pago** (hardcoded: `CASH, CARD, TRANSFER, CHECK, DEPOSIT`).
- **Monto prellenado** desde `reservationsService.getReservationConfig(projectId)` → `{ amount, prefix }` (mínimo por proyecto/tenant/default).
- **Uploader de recibo** (drag&drop, `accept="image/*,.pdf"`, **opcional** — así lo marca este flujo análogo).
- Al enviar: `reservationsService.generateFileToken(form)` → **multipart** `POST /api/v1/files/generate-token`.

Este modal **bloquea** si el lead ya tiene `file_id` ("Este lead ya tiene un expediente"): **un expediente/reserva por lead**.

### 1.4 Backend disponible (sin cambios necesarios para la opción recomendada)

- **`POST /api/v1/files/generate-token`** (`files.py:31`, multipart): campos `lead_id`, `property_id`, `payment_type` (enum `PaymentType` = CASH/CARD/TRANSFER/CHECK/DEPOSIT), `reservation_amount` (opcional), `client_name` (opcional), `receipt_file` (opcional). Crea el `File` (expediente) + reserva en collection-service (sube el recibo a Azure, `status=CONFIRMED`, devuelve `reservation_number`). El **default de monto** es `Project.reservation_amount > TenantConfig.reservation_amount > settings.DEFAULT_RESERVATION_AMOUNT = 5000.0`.
- **`PATCH /api/v1/leads/{id}`** (`leads.py:2960`): aplica campos de cierre y delega en `LeadService.update_status_with_lead`, que al pasar a `cerrado_ganado` **abre el expediente de postventa** (`PostventaService.get_or_create_expediente`, hook PV-101) + notificaciones + sync.
- **Idempotencia verificada:** `PostventaService._create_expediente` (`postventa_service.py:125-127`) hace `get_active_file_by_lead(lead.id)` y **reutiliza** el `File` existente; solo crea uno si no hay. → Si `generate-token` corre **antes** del PATCH, no se duplican `File` y el "Día 0" del expediente se resuelve de la reserva real.
- **`GET /api/v1/projects/{id}/reservation-config`** → `{ amount, prefix, ... }`: fuente del prellenado del monto (respeta override por proyecto; cae a Q5,000).
- **Campos obligatorios por estado**: tabla per-tenant `lead_status_required_fields` (`lead_required_fields.py`). El catálogo (`GET /lead-status → required_fields`) es quien decide si `reservation_amount` / `property_id` se exigen (y por tanto si el modal muestra la sección de reserva/propiedad).
- **Límites del uploader** (collection-service `multer.middleware.js`): MIME `image/jpeg, image/png, image/gif, application/pdf` (+doc/docx), **máx 10 MB, 1 archivo**.

### 1.5 Dudas de la HU resueltas desde el código

| Duda | Respuesta encontrada |
|---|---|
| Obligatoriedad de cada campo | En el flujo análogo (`ExpedienteModal`): tipo de pago **requerido**, monto **requerido** (≥ mínimo), propiedad **requerida**; **recibo OPCIONAL**. Se replica ese criterio. |
| ¿La lista de propiedades depende del modelo? | **Sí, cascada**: `Property.model_id` → `PropertyModel`. Proyecto (del lead) → Modelo → Propiedad `status='available'`. Ya implementado en `ClosingModal`. |
| Validaciones del monto | Positivo (`min=0.01, step=0.01`) y **≥ mínimo** de `reservation-config`. |
| Formato/peso de imagen | `image/*,.pdf`, **≤ 10 MB**, 1 archivo (backend collection-service). |
| Comportamiento al cancelar | No hay transición; el lead permanece en su estado previo. **Ya correcto.** |

---

## 2. Plan de implementación propuesto

### 2.1 Enfoque recomendado — Opción A: orquestación en frontend (2 llamadas), **cero cambios de backend**

Extender `ClosingModal.vue` para agregar **tipo de pago** + **recibo** y prellenar el monto, y que el padre (`LeadsView` / `LeadContextSidebar`) orqueste al confirmar, **solo cuando la transición es `cerrado_ganado`**:

1. **`POST /files/generate-token`** (multipart) con `lead_id, property_id, payment_type, reservation_amount, client_name, receipt_file` → crea `File` + reserva en collection-service + sube el recibo a Azure.
2. **`PATCH /leads/{id}`** con `status='cerrado_ganado', property_id, property_model_id, reservation_amount, reservation_date` → transiciona a ganado y **abre el expediente de postventa reutilizando el `File`** ya creado (Día 0 = fecha de reserva real).

**Por qué este orden:** `generate-token` primero garantiza que el expediente de postventa reutilice el `File` y que el Día 0 salga de la reserva. Invertirlo crearía el expediente con Día 0 estimado y arriesga un segundo `File`.

**Ventajas:** reutiliza dos endpoints ya probados sin tocar backend; máximo reuso de UI existente.
**Riesgo a mitigar:** fallo parcial (reserva creada pero PATCH falla, p.ej. `PROPERTY_ALREADY_TAKEN`). Mitigación: la propiedad del cascade ya viene filtrada a `available`; ante fallo del PATCH tras crear la reserva, ofrecer reintento y/o liberar la reserva (`PATCH /v1/reservations/:id/release`) — a definir el nivel de compensación.

### 2.2 Alternativa — Opción B: nuevo endpoint de backend `POST /leads/{id}/win`

Un endpoint multipart que internamente llame a `generate_token_with_reservation` y luego a `update_status_with_lead`, encapsulando orden + compensación server-side (más robusto y testeable, pero más trabajo y toca una zona central). *No recomendado para v1 salvo que se priorice robustez transaccional.*

### 2.2-bis Correcciones de la revisión de experto (2026-07-08)

**C1 (BLOQUEANTE) — Render garantizado para `cerrado_ganado`, independiente del catálogo.**
El render actual de la sección reserva/propiedad depende de `lead_status_required_fields` del tenant (`openMarkAsWon → openClosingModal`, `LeadsView.vue:2522-2524,1254-1256`). Si el tenant no tiene `reservation_amount`+`property_id` como requeridos, la HU **no se cumple** (el modal abre sin esos campos) y, desde lista/kanban/sidebar, el modal **ni abre** (usan `computeMissingClosingFields`).
→ Para `cerrado_ganado`: renderizar el bloque **modelo + propiedad + monto + tipo de pago + recibo de forma FIJA** (no gated por catálogo), y **forzar que toda transición a ganado pase por el modal** en los 4 puntos de entrada (botón, `<select>` lista, drag kanban, `<select>` sidebar). Los demás campos de cierre (fecha estimada, probabilidad) siguen gated por catálogo.

**C2 — Path "ya tiene expediente/`file_id`": ocultar tipo de pago + recibo.**
Como se decidió saltar `generate-token` (solo PATCH) y el PATCH **no** transporta `payment_type`/`receipt_file`, esos campos se perderían. → En ese caso deshabilitar/ocultar tipo de pago + recibo (ya se capturaron en la reserva original) y mostrar aviso "este lead ya tiene reserva/expediente".

**C3 — Notificación al cliente: ✅ MANTENER.** `generate-token` dispara `send_reservation_notification_task` (`files.py:92-95`); el aviso de reserva al lead se conserva igual que el flujo actual de `ExpedienteModal`. Sin cambios de código (comportamiento por defecto).

**C4 — Alcance de "asociado al expediente": ✅ basta ligado a la reserva.** `payment_type`+monto+recibo viven en la reserva de collection-service (`payment_reservations`), ligados por `file_id`, y el expediente de postventa referencia ese `file_id`. El recibo **no** se sube como documento del checklist de postventa (sin alcance adicional).

**C5 — Otros caminos a ganado:** agentes IA / webhooks / cambio masivo llaman a `update_status_with_lead` sin modal → no crean reserva. Fuera de alcance de esta HU (centrada en el modal); documentado para no asumir "todo ganado tiene reserva".

### 2.3 Archivos a modificar (Opción A)

**Frontend (`app-saas-frontend`):**
- `src/components/Leads/ClosingModal.vue`
  - Añadir, dentro del bloque `isRequired('property_id')` / sección de reserva:
    - `<select>` **tipo de pago** (opciones CASH/CARD/TRANSFER/CHECK/DEPOSIT, i18n) — requerido.
    - **Uploader de recibo** (portar el bloque drag&drop de `ExpedienteModal.vue`: `accept="image/*,.pdf"`, validación ≤10 MB, preview + quitar) — **opcional**.
  - **Prellenar el monto**: al abrir con `cerrado_ganado`, cargar `getReservationConfig(projectId)` y setear `reservationAmountValue` = `config.amount` (fallback Q5,000). Revierte la decisión D-5 (documentar el cambio).
  - Validar `reservation_amount ≥ config.amount`.
  - Ampliar el payload de `confirm` con `payment_type` y `receipt_file` (o exponer estos por un emit/estado que el padre pueda leer).
- `src/views/LeadsView.vue` y `src/components/LeadContextSidebar.vue`
  - En `submitClosingTransition` / `confirmSidebarClosing`: cuando el target es `cerrado_ganado`, ejecutar la secuencia generate-token → PATCH; manejar errores (`PROPERTY_ALREADY_TAKEN`, `INVALID_PROPERTY_SELECTION`, config de monto) reabriendo/manteniendo el modal.
  - Pasar `projectId`/`projectName` (ya se pasan) y el `client_name` por defecto (nombre del lead).
- `src/locales/*` — claves i18n para tipo de pago, label/ayuda del recibo, textos de validación (reusar las de `downloads.reservation.*` donde aplique).
- (Sin cambios de tipos de backend; reusar `GenerateFileTokenRequest` de `types/reservations.ts`.)

**Backend:** **ninguno** en Opción A (endpoints ya existen).

### 2.4 Estrategia de validación
- Manual (convención del repo: no hay vee-validate/zod). Asterisco rojo en requeridos, `required`/`min`/`step` nativos, botón deshabilitado y textos de error inline `text-red-600`.
- Requeridos para `cerrado_ganado`: modelo, propiedad, monto (≥ mínimo), tipo de pago. **Recibo opcional.**
- Reutilizar `CLOSING_FIELD_DEFS` (`utils/closingFields.ts`) para monto/propiedad; añadir la validación de tipo de pago en el gate del botón.

### 2.5 Decisiones tomadas (justificadas desde el código)
1. **Reutilizar `ClosingModal`** en lugar de crear un modal nuevo — es el modal real de "ganado".
2. **Recibo opcional**, resto requerido — espejo del flujo análogo `ExpedienteModal` + backend (`receipt_file` opcional).
3. **Prellenar monto vía `reservation-config`** (no hardcodear 5,000) — respeta override por proyecto y cae a Q5,000 (`DEFAULT_RESERVATION_AMOUNT`).
4. **Cascada Proyecto→Modelo→Propiedad** — confirmada por `Property.model_id`; ya implementada.
5. **Orden generate-token → PATCH** — por la idempotencia de `File` y el Día 0 correcto del expediente.
6. **Cancelar no transiciona** — ya es el comportamiento; se mantiene.
7. **Tipo de pago + recibo se renderizan junto a la sección de reserva** (gated por `isRequired('property_id')`), no se agregan al catálogo `lead_status_required_fields` (que solo cubre columnas del lead).

---

## 3. Decisiones confirmadas por el usuario (2026-07-08)

1. ✅ **Enfoque de orquestación: Opción A** — frontend, 2 llamadas (`generate-token` → `PATCH`), cero cambios de backend.
2. ✅ **Lead que ya tiene reserva/`file_id`:** **saltar `generate-token`** y hacer solo el `PATCH` (reutiliza el expediente existente, evita el 409 de collection-service).
3. ✅ **Convivencia con `ExpedienteModal`: mantener ambos** — el modal de ganado agrega la captura; `ExpedienteModal` sigue disponible para reservas fuera del flujo de ganado.

## 3.1 Verificaciones/decisiones pendientes menores (no bloqueantes)

- **Catálogo del tenant:** confirmar en `lead_status_required_fields` que `reservation_amount` + `property_id` están marcados como requeridos para `cerrado_ganado` (dato per-tenant en SQL Server Azure). Si no lo están, el modal no mostraría la sección de reserva/propiedad → sembrar esos campos o forzar su render para `cerrado_ganado`. *Verificación operativa antes de probar.*
- **Nivel de compensación** ante fallo parcial (reserva creada + PATCH falla): propuesta por defecto = **mantener el modal abierto con reintento** (la reserva ya existe; el segundo intento salta `generate-token` por la regla del punto 2). Liberación automática de la reserva queda como mejora futura si se requiere.

---

## 4. Confirmación de NO desarrollo

Este documento es solo el plan (pasos 1 y 2 de la HU). **No se ha escrito ni modificado código de implementación.** A la espera de aprobación explícita para codificar.
