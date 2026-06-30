# Validación de Roles — Checklist para Product Owner

> **Objetivo:** confirmar en el navegador que la consolidación de roles funciona, **antes de subir la última fase**.
> **Cómo usarlo:** entra con un usuario de cada rol y ve marcando. Al final hay un criterio simple de **GO / NO-GO**.

**Necesitas 4 usuarios de prueba (uno por rol):** Owner · Supervisor · Asesor · Asesor Externo
**Tip:** usa una ventana de incógnito distinta por rol y refresca (F5) después de entrar.

**Preparación rápida:** que el **Asesor** tenga al menos 1 lead asignado, y que exista al menos 1 lead de **otro** asesor (para comprobar que NO lo ve).

---

## 1. ¿Cada rol ve el menú correcto? (lo más visible)

Entra con cada rol y mira el menú lateral.

### 👑 Owner — debe ver TODO
- [ ] Ve todos los menús, incluyendo **Usuarios**, **Roles** y **Agentes de llamada**.
- [ ] No perdió ningún acceso que tenía antes.

### 🧑‍💼 Supervisor — ve casi todo, MENOS administración del sistema
- [ ] Ve: Leads, Contactos, Proyectos, Asesores, Cotizaciones, Calendario, Tareas, Llamadas, Correos, Chat, Marketing, Postventa, Workflows, Usuarios.
- [ ] **NO** ve **Roles** (no puede cambiar roles de otros).
- [ ] **NO** ve **Agentes de llamada**.

### 🧑‍💻 Asesor — solo sus herramientas de venta
- [ ] Ve: Leads, Contactos, Proyectos, Cotizaciones, Calendario, Tareas, Llamadas, Correos, Chat, Postventa.
- [ ] **NO** ve: Asesores, Marketing/Campañas, Usuarios, Roles, Workflows, Rendimiento de asesores.

### 🤝 Asesor Externo — el más limitado
- [ ] Prácticamente solo ve **Leads** (y puede crear uno).
- [ ] **NO** ve: Correos, Llamadas, Contactos, Proyectos, Calendario, Cotizaciones, Postventa.

---

## 2. 🚨 La prueba más importante: un Asesor NO puede ver datos de otros

> Este es el corazón de la tarea. Si algo de esto falla → **NO subir la última fase.**

Entra como **Asesor** y revisa:
- [ ] En **Correos**: solo aparecen correos de SUS leads. No ve correos de leads de otro asesor.
- [ ] En **Correos**: **no** le aparece el selector para filtrar por "Asesor" (eso es solo para jefes).
- [ ] En **Llamadas**: solo ve llamadas de SUS leads.
- [ ] En **Leads**: solo ve sus leads asignados, no los del resto del equipo.
- [ ] En **Tareas**: solo ve sus tareas.

Ahora entra como **Supervisor** u **Owner** y confirma lo contrario:
- [ ] En Correos / Llamadas / Leads **sí** ve los de **todos** los asesores (y aparece el selector de asesor).

---

## 3. No basta con ocultar el menú: la puerta también está cerrada

Estando logueado con un rol que NO debería entrar, pega la dirección directo en el navegador y confirma que **te saca / redirige** (no te deja entrar):

- [ ] **Asesor** intenta entrar a **Campañas/Marketing** → lo redirige.
- [ ] **Asesor** intenta entrar a **Usuarios** → lo redirige.
- [ ] **Asesor** intenta entrar a **Asesores** → lo redirige.
- [ ] **Supervisor** intenta entrar a **Roles** → lo redirige.
- [ ] **Owner** entra a cualquiera de esas → entra normal (comprobación de que sí funciona).

---

## 4. Proyectos: el Asesor mira pero no toca

- [ ] **Asesor** abre Proyectos/Propiedades → puede **ver** la información.
- [ ] **Asesor** **no** ve botones de crear / editar / eliminar proyectos.
- [ ] **Supervisor** **sí** puede editar proyectos.

---

## 5. Solo el Owner administra el sistema

- [ ] **Supervisor** no puede cambiar roles de usuarios (no ve la pantalla de Roles).
- [ ] **Supervisor** puede invitar usuarios, pero no asignarles roles.
- [ ] **Owner** sí puede todo lo de administración.

---

## 6. Revisión final de sanidad (todos los roles)

- [ ] Ningún rol ve un menú que, al abrirlo, dé un error de "sin permiso" (eso sería una desincronización → reportar).
- [ ] Ningún rol se queda con pantallas en blanco o errores raros.
- [ ] Nadie perdió accesos que necesita para su trabajo diario.

---

## ✅ Criterio GO / NO-GO

**GO (puedes subir la última fase) si:**
- Las secciones **1 a 5 pasan para los 4 roles**, y
- La **sección 2 pasa sin excepción** (ningún asesor ve datos ajenos).

**NO-GO (no subas todavía) si:**
- Un asesor ve correos / llamadas / leads de otro asesor → 🚨 problema de seguridad.
- Un menú abre y luego da error de permiso (front y back desincronizados).
- Algún rol perdió un acceso que necesita.

> Si encuentras un fallo, anota: **qué rol**, **qué pantalla** y **qué pasó** (vio de más / vio de menos / dio error). Con eso se corrige rápido antes de la última fase.
