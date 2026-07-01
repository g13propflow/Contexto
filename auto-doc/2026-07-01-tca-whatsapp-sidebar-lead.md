# TCA de WhatsApp en el sidebar del lead (sustituye Email)

## Fecha
2026-07-01

## Tarea solicitada (en concreto)
En el sidebar del lead, sustituir el TCA (botón de acción rápida) de **Email** por
uno de **WhatsApp** en color **verde**, y cambiar el color del TCA de
**Conversación** a **gris**. El botón de WhatsApp debe abrir el chat con el número
del lead: WhatsApp Web en escritorio y la app de WhatsApp en móvil.

## Rama
`main` (pendiente de commit por el usuario)

## Módulo(s) afectado(s)
`app-saas-frontend` — sidebar de contexto del lead
- `src/components/LeadContextSidebar.vue` (único archivo)

---

## Resumen de lo que se hizo
- **Botón Conversación:** color cambiado de verde (`bg-green-500`/`hover:bg-green-600`)
  a gris (`bg-slate-500`/`hover:bg-slate-600`). Conserva ícono **y texto**; `flex-1`.
- **Botón Email → WhatsApp:** el TCA de Email fue reemplazado por uno de WhatsApp
  en verde (`bg-green-500`), con el ícono oficial de WhatsApp. Se deshabilita si el
  lead no tiene teléfono (`:disabled="!...phone"`).
- **Solo íconos:** por pedido del usuario, **Llamar** y **WhatsApp** quedaron como
  botones compactos solo-ícono (`shrink-0`, sin `flex-1` ni etiqueta), con `title` y
  `aria-label`. Solo **Conversación** mantiene el texto.
- **Lógica:** `sendEmail()` (usaba `mailto:`) se sustituyó por `openWhatsApp()`, que
  normaliza el teléfono y abre `https://wa.me/<numero>` en una pestaña nueva
  (`noopener,noreferrer`).

## Decisiones tomadas
- **Se usó `https://wa.me/<numero>`** como enlace universal: en escritorio redirige a
  WhatsApp Web y en móvil abre la app nativa, sin necesidad de detectar el dispositivo.
- **Normalización del número:** `wa.me` exige solo dígitos con código de país, sin `+`,
  espacios ni signos; por eso se hace `replace(/\D/g, '')` antes de construir la URL.
- **Fuente del número:** se usa `leadData.phone` (el mismo que ya usaba el TCA de
  Llamar). No se usó `entry_whatsapp_number` porque ese es el canal de entrada del
  tenant, no el número del lead.
- **No hubo helper previo de WhatsApp** en el frontend (se buscó `wa.me`/`whatsapp`),
  así que la URL se construye inline en el componente.

---

## Bug encontrado y corregido (pre-entrega)
- **Número local sin código de país no abría el chat.** La primera versión de
  `openWhatsApp` solo quitaba no-dígitos. El backend
  (`advisor_evolution_service._format_phone_number`) antepone `502` a los números
  locales "pelados" (≤8 dígitos) para el mercado Guatemala; el frontend no replicaba
  esa regla, así que un lead con teléfono local (ej. `1234-5678`) generaba
  `wa.me/12345678` → WhatsApp no abría el chat correcto.
- **Fix:** se replicó la misma regla (≤8 dígitos → prefijo `502`), quedando alineado
  con el backend. Un número ya internacional se respeta tal cual.

## ¿Se tocó trabajo de otros desarrolladores?
No. Todo el cambio está contenido en `LeadContextSidebar.vue`.

## Pruebas realizadas
- `vue-tsc --noEmit` sin errores nuevos en `LeadContextSidebar.vue` (los errores del
  type-check son preexistentes en otros archivos, no en este).
- Suite Vitest: 94/96 pasan. Los 2 fallos (`postventaConfigHelpers.test.ts`) existen
  igual en `main` sin el cambio (verificado con `git stash`) → pre-existentes y ajenos.
- Normalización de `wa.me` validada con casos: internacional GT/US se respeta; local
  8 dígitos recibe `502`; sin dígitos no abre nada.

## Notas / pendientes
- **Verificación en navegador pendiente del lado del usuario.** Re-test sugerido:
  botón verde de WhatsApp abre el chat correcto; solo-ícono en Llamar/WhatsApp;
  Conversación gris con texto; botones deshabilitados sin teléfono.
- Falta `git commit` / `git push` (lo hace el usuario).
