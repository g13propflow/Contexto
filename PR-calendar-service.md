# PR — calendar-service: avisar al SaaS para notificar al asesor en alta manual de visita

## Qué hace
Cuando se crea una visita **manual** desde la UI (`event_origin=control_manual`), dispara un
callback al SaaS para que notifique al asesor asignado por los canales que tenga configurados.
Los flujos de marketplace y agente ya notifican por su cuenta, así que aquí quedan excluidos
(evita doble aviso).

## Cambios
- Nuevo adapter `src/infrastructure/adapters/saas-service/send.advisor.visit.notification.js`
  (callback a `POST /api/v1/leads/notify-visit-advisor`).
- En `calendar_events.controller.js`, tras crear el evento: si es `control_manual`, tipo
  `visit`/`appointment` y trae `lead_id`, llama al adapter **fire-and-forget** (sin `await`,
  con `.catch`): no añade latencia ni puede romper el `201`.

## ⚠️ Dependencias entre PRs (mismo feature)
- **Depende del PR de `app-saas-service`**: el endpoint `/api/v1/leads/notify-visit-advisor`
  debe estar **ya desplegado** en el SaaS antes de que este callback sirva.
- Desplegar **después** de `app-saas-service`.

## Checklist pre-merge
- [ ] Code review aprobado.
- [ ] Confirmar que el endpoint del SaaS ya existe/está desplegado en el entorno destino.

## Checklist pre-deploy (prod)
- [ ] `SAAS_SERVICE_URL` apunta al SaaS correcto del entorno.
- [ ] `QUOTATION_API_KEY` **igual** a la del `app-saas-service` (en dev estaban desalineadas → 401).
      Esto también afecta los callbacks existentes (confirmación de visita, reagendado).

## Checklist post-deploy
- [ ] Crear una visita **manual** (control_manual) con un lead que tenga asesor asignado.
- [ ] Verificar en logs del SaaS el `advisor_notify` correspondiente (ruteo por canal).
- [ ] Confirmar que visitas de marketplace/agente **no** disparan doble notificación.

## Notas
- El adapter nunca lanza (captura internamente); el `.catch` es defensa extra.
- Si falta config (`SAAS_SERVICE_URL`/`QUOTATION_API_KEY`), el adapter loguea y omite (no rompe).
