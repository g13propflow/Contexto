@echo off

start "Frontend" cmd /k "cd /d \"C:\Users\Johanna Gamboa\OneDrive - PropFlow\Documentos\Projects\app-saas-frontend\" && npm run dev"

start "Collection Service" cmd /k "cd /d \"C:\Users\Johanna Gamboa\OneDrive - PropFlow\Documentos\Projects\collection-service\" && npm run start"

start "" code "C:\Users\Johanna Gamboa\OneDrive - PropFlow\Documentos\Projects"

exit