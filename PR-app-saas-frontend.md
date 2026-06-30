# PR — app-saas-frontend: selección de canales de notificación en el perfil del asesor

## Qué hace
En `/dashboard/advisors`, al crear/editar un asesor se eligen los canales por los que se le
notifica una nueva visita (Email / WhatsApp / SMS). Mínimo 1 canal obligatorio.

## Cambios
- Sección "Canales de notificación" en el formulario (Email / WhatsApp / **SMS deshabilitado**, fase 2).
- Validación: **mínimo 1 canal** (bloquea guardar si no hay ninguno).
- `Advisor.notification_channels` en tipos + envío en create/update.
- Textos i18n (es/en).

## ⚠️ Dependencias entre PRs (mismo feature)
- **Depende del PR de `app-saas-service`**: el backend debe aceptar/retornar `notification_channels`.
- Desplegar **después** de `app-saas-service`.

## Checklist pre-merge
- [ ] Code review aprobado.
- [ ] `npm run build` OK (la feature no introduce errores nuevos de type-check en archivos de asesores).

## Checklist pre-deploy
- [ ] Confirmar que el backend del entorno ya soporta `notification_channels`.
- [ ] `VITE_API_BASE_URL` correcto para el entorno (en prod es el dominio real; el `127.0.0.1`
      fue solo un workaround local de Docker/IPv6, **no** se commitea).

## Checklist post-deploy
- [ ] `/dashboard/advisors` → editar asesor: la sección de canales aparece con los canales actuales.
- [ ] Desmarcar todos los canales → no deja guardar (mensaje de "mínimo 1").
- [ ] SMS se ve **deshabilitado** ("próximamente").
- [ ] Crear asesor nuevo arranca con Email marcado por defecto.

## Notas
- SMS queda inerte hasta fase 2 (cuando se implemente Twilio en el backend).
- El mensaje por WhatsApp usa la plantilla aprobada de Meta (sin teléfono/correo del lead);
  el correo sí lleva el mensaje completo.
