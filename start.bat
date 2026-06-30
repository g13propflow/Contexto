@echo off

:: Abre los dos servicios en pestañas de una misma ventana de Windows Terminal
wt -w 0 new-tab -p "Command Prompt" --title "Frontend" -d "C:\Users\Johanna Gamboa\OneDrive - PropFlow\Documentos\Projects\app-saas-frontend" cmd /k "npm run dev" ; new-tab -p "Command Prompt" --title "Collection Service" -d "C:\Users\Johanna Gamboa\OneDrive - PropFlow\Documentos\Projects\collection-service" cmd /k "npm run start"; new-tab -p "Command Prompt" --title "Calendar Service" -d "C:\Users\Johanna Gamboa\OneDrive - PropFlow\Documentos\Projects\calendar-service" cmd /k "npm run start";

:: Abre Visual Studio Code en la carpeta raíz de tus proyectos
code "C:\Users\Johanna Gamboa\OneDrive - PropFlow\Documentos\Projects"

exit