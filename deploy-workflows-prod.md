# Deploy a producción — Módulo de Workflows

> **Tiempo estimado:** 15–20 minutos  
> **Downtime:** ninguno (cambios aditivos, sin modificar tablas existentes)

---

## 1. Push de los repos

En la máquina de desarrollo, correr antes del deploy:

```bash
# Frontend
cd app-saas-frontend
git push origin <rama>

# Backend
cd app-saas-service
git push origin <rama>
```

---

## 2. Backend — `app-saas-service`

### 2.1 Pull en el servidor

```bash
cd app-saas-service
git pull origin <rama>
```

### 2.2 Migraciones de base de datos

> ⚠️ **No usar `alembic upgrade head`** — el proyecto tiene múltiples heads. Aplicar las migraciones explícitamente en este orden:

```bash
# Migración 1: crea tablas workflow_rules, workflow_conditions, workflow_actions
# + siembra permisos en todos los tenants existentes
alembic upgrade aa01bb02cc03

# Migración 2: crea tabla workflow_execution_logs
alembic upgrade bb02cc03dd04
```

**Verificar que quedaron aplicadas:**
```bash
alembic current
# Debe mostrar bb02cc03dd04 (head)
```

**Si aparece un error de "head ya existe" o estado contradictorio:**
```bash
alembic stamp --purge aa01bb02cc03
alembic upgrade bb02cc03dd04
```

### 2.3 Rebuild y deploy del contenedor

```bash
docker-compose build api
docker-compose up -d api
```

**Verificar que levantó:**
```bash
docker-compose logs -f api | head -50
# Esperar "Application startup complete"

curl https://api.gopropflow.com/api/v1/workflow-rules/ \
  -H "Authorization: Bearer <token>" \
  -H "X-Tenant-ID: <tenant_id>"
# Debe responder 200
```

### 2.4 Restart del worker de Temporal (si corre como proceso separado)

```bash
docker-compose restart temporal-worker
# o el nombre del contenedor que corresponda
```

---

## 3. Frontend — `app-saas-frontend`

```bash
cd app-saas-frontend
git pull origin <rama>
npm ci
npm run build
```

Subir la carpeta `dist/` al servidor / CDN según el proceso habitual del equipo.

---

## 4. Smoke test (5 min)

Una vez desplegado:

- [ ] Abrir **Configuración → Workflows**
- [ ] Crear un workflow nuevo → seleccionar trigger → agregar condición → agregar acción → "Guardar borrador" → funciona sin error
- [ ] Activar el workflow con "Activar" → el badge cambia a verde
- [ ] Abrir "Ver log" → carga sin error (puede estar vacío)
- [ ] Verificar que workflows activos anteriores siguen apareciendo (no hay regresión)

---

## 5. Rollback (si algo falla)

```bash
# Backend: revertir las dos migraciones en orden inverso
alembic downgrade aa01bb02cc03   # revierte bb02cc03dd04
alembic downgrade base            # o el revision anterior a aa01bb02cc03

# Volver al commit anterior
git revert HEAD
docker-compose build api && docker-compose up -d api
```

> Las migraciones son aditivas (solo crean tablas nuevas), así que el rollback no afecta datos existentes.
