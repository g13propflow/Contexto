# Despliegue — Consolidación de Roles (SCRUM-1206)

> Mapa de PRs, orden de solicitud y deploy. **El deploy lo hace otra persona** (no tú): tú solicitas los PRs en orden; esa persona mergea, corre `alembic upgrade` y despliega. Última actualización: 2026-06-25.

---

## Quién hace qué

| Rol | Responsabilidad |
|---|---|
| **Tú** | Solicitar los PRs **en orden** (uno a la vez), y avisar a quien despliega cuándo cada uno está listo para mergear. |
| **Persona de deploy** | Mergear el PR, correr `alembic upgrade <revisión>` en prod cuando aplique, y desplegar back/front. |

---

## Ramas (cómo quedaron, apiladas)
```
BACKEND (app-saas-service)
  main
   └─ feature/SCRUM-1206        (Fase 1-2: permisos nuevos + sets asesor/supervisor)   ← migración r2
       └─ feature/SCRUM-1206-2   (Fase 3: enforcement en endpoints)                     ← solo código
           └─ feature/SCRUM-1206-3 (Fase 4: borrar roles + supervisor wf.manage + tests) ← migración r5

FRONTEND (app-saas-frontend)
  main
   └─ feature/SCRUM-1206-4      (Fase 5: gating UI + fixes)                              ← solo código
```

---

## Los 4 PRs — todos con base `main`, **secuenciales en el backend**

> Como las ramas del back están **apiladas**, el diff de cada una solo queda limpio cuando la anterior YA está en `main`. Por eso solicitas **de a uno**: A → (merge) → B → (merge) → C.

| PR | Rama | Base | Cuándo lo solicitas | Contenido | Riesgo |
|---|---|---|---|---|---|
| **PR-A** | `feature/SCRUM-1206` | `main` (back) | **Primero** | permisos nuevos + sets asesor/supervisor | INERTE (seguro) |
| **PR-B** | `feature/SCRUM-1206-2` | `main` (back) | **Después** de mergear PR-A | enforcement en endpoints | cambia comportamiento |
| **PR-F** | `feature/SCRUM-1206-4` | `main` (front) | Junto con PR-B (mismo momento) | gating UI + fixes | acompaña a PR-B |
| **PR-C** | `feature/SCRUM-1206-3` | `main` (back) | **Después** de mergear PR-B, **tras observar 1-2 días** | borrar roles + supervisor wf.manage | DESTRUCTIVO (al final) |

**Frontend (PR-F):** repo independiente, su rama ya parte de `main` del front, así que **no depende** del orden de los PRs del back. Pero se **mergea/despliega junto con PR-B**, ni antes ni después:
- Si el front sube **antes** que los permisos de PR-A → `can('projects.view')` daría falso para todos y se ocultarían menús de más.
- Si el front sube **después** del enforcement (PR-B) → el usuario vería menús que el backend ya bloquea (403) → mala UX.
- → Por eso: **PR-F va en la misma ronda que PR-B**, una vez que PR-A (permisos) ya está en prod.

---

## Secuencia de deploy — 3 rondas

```
RONDA 1  ── Tú: solicitas PR-A (SCRUM-1206 → main)
            Deploy: mergea PR-A
                    alembic upgrade r2redefasessup01   (PROD)
                    despliega backend
            Resultado: permisos nuevos existen + asesor/supervisor redefinidos. INERTE.
               │
RONDA 2  ── Tú: (ya con PR-A en main) solicitas PR-B (SCRUM-1206-2 → main)
                + PR-F (SCRUM-1206-4 → main, front)
            Deploy: mergea PR-B y PR-F
                    despliega backend + frontend juntos
                    (NO hay migración en esta ronda)
            Resultado: enforcement activo + UI gateada. Los permisos ya existen de la ronda 1.
               │
            ⏳ OBSERVAR 1-2 días (que nadie pierda accesos indebidos).
               │
RONDA 3  ── Tú: (ya con PR-B en main) solicitas PR-C (SCRUM-1206-3 → main)
            Deploy: mergea PR-C
                    alembic upgrade r5supervisorwf01   (PROD)
                    despliega backend
            Resultado: borra roles vacíos + supervisor gana workflows.manage. DESTRUCTIVO, al final.
```

> **Regla de oro:** nunca solicites PR-B antes de que PR-A esté en `main`, ni PR-C antes de que PR-B esté en `main`. Si no, el diff arrastra cambios de la fase anterior.

---

## Instrucciones para quien despliega (resumen accionable)

> **Antes de cada migración**, verificar el árbol de Alembic en prod (read-only):
> ```
> alembic heads      # ¿cuántas puntas hay?
> alembic current    # ¿en qué revisión está prod ahora?
> ```
> - Si `alembic heads` muestra **una sola** línea y nuestra migración está en esa cadena → `upgrade head` sería inofensivo.
> - Si muestra **varias** → **obligatorio** nombrar la revisión exacta (`r2redefasessup01` / `r5supervisorwf01`), **NO** `upgrade heads`.

```
RONDA 1 (tras mergear PR-A — rama feature/SCRUM-1206):
  cd app-saas-service
  alembic heads ; alembic current        # verificar árbol (ver nota arriba)
  alembic upgrade r2redefasessup01        # NO usar "upgrade heads" si hay varios heads
  # desplegar imagen del backend          # INERTE: nadie debe perder acceso

RONDA 2 (tras mergear PR-B [feature/SCRUM-1206-2] + PR-F [feature/SCRUM-1206-4]):
  # desplegar backend y frontend JUNTOS — sin migración
  # verificar: asesor con GET /calls y GET /emails directo NO ve leads ajenos
  # ⏳ observar 1-2 días

RONDA 3 (tras mergear PR-C [feature/SCRUM-1206-3], después de observar):
  cd app-saas-service
  alembic heads ; alembic current        # verificar árbol (ver nota arriba)
  alembic upgrade r5supervisorwf01        # auto-reasigna usuarios y borra roles vacíos
  # desplegar imagen del backend
  # huérfanos (si los hubiera): arreglar por /dashboard/users, NO por script
```

---

## Cero scripts en PROD ✅

La consolidación entera se aplica con **`alembic upgrade`** (comando estándar de migración) + merge de PRs + deploy. **No hay que correr ningún script ad-hoc.**

- La migración de **Fase 4** (`r5supervisorwf01`/`r4cleanuproles01`) **reasigna sola** a los usuarios antes de borrar: `admin→owner`, `manager/gerencia/administrativo/gestion_creditos→supervisor`, `viewer/user→asesor`. No requiere paso manual previo.
- Las queries de abajo son **read-only y opcionales** (solo para mirar antes de la ronda destructiva). No mutan nada.
- **Usuarios huérfanos** (sin rol moderno, ej. javier/javierantoneo/propflowuser): es un bug **pre-existente, independiente** de esta tarea. Ninguna migración los toca. Se arreglan por la **pantalla de Usuarios** (`/dashboard/users`, un owner asigna el rol con clicks) o se dejan para después. **Sin script.**

---

## ⚠️ Riesgos a controlar (de proceso, no de código)
1. **Orden de los PRs**: enforcement (PR-B) NO debe subir antes que permisos (PR-A) → 403 masivo.
2. **Front junto a PR-B**: ni antes (oculta de más) ni después (menús que dan 403).
3. **18 heads de Alembic** — usar `alembic upgrade <revisión>` (ej. `r5supervisorwf01`), **NO** `upgrade heads`.
4. **Fase 4 destructiva e irreversible** (downgrade no-op) → al final, tras observar 1-2 días.
5. **PROD ≠ `PropFlow_Gerardo` (dev)** — la verificación de usuarios se hizo en dev. Conviene una mirada read-only en prod antes de la ronda 3 (queries abajo), aunque la migración se auto-encarga de reasignar.
6. Endpoints gateados (projects/properties/marketing): confirmar que ningún worker/cron los llame por HTTP sin token.

## Queries de verificación EN PROD (read-only, opcionales, antes de RONDA 3)
```sql
-- usuarios por rol a eliminar (la migración los reasigna sola; esto es solo para verlo)
SELECT r.name, COUNT(DISTINCT ur.user_id) usuarios
FROM roles r LEFT JOIN user_roles ur ON ur.role_id=r.id
WHERE r.name IN ('admin','manager','gerencia','gestion_creditos','administrativo','viewer')
GROUP BY r.name;

-- usuarios sin rol moderno (huérfanos → arreglar por la pantalla de Usuarios)
SELECT u.id, u.email FROM users u
WHERE NOT EXISTS (SELECT 1 FROM user_roles ur WHERE ur.user_id=u.id);
```

---

## Levantar ambientes en LOCAL (probar antes de subir)
```
BACKEND (app-saas-service)
  git checkout feature/SCRUM-1206-3
  docker compose up -d --build api          # imagen CON los cambios
  #  → http://localhost:8000  ·  Swagger: /docs

FRONTEND (app-saas-frontend)
  git checkout feature/SCRUM-1206-4
  npm install && npm run dev                # Vite ; .env VITE_API_BASE_URL=http://localhost:8000
```

## Pruebas por rol (en navegador)
Login como **owner / asesor / supervisor / asesor_externo / aprobacion_meta** y revisar menú + rutas.
**Caso crítico de seguridad:** un **asesor** que pega `GET /calls` y `GET /emails` directo → **NO** debe ver datos de leads ajenos.

## Estado verificado (dev)
Matriz de permisos 56/56 OK · app arranca · migraciones encadenan (c5d6→r1→r2→r4→r5) · 0 regresiones en tests · `test_rbac_postventa` actualizado (10/10).
