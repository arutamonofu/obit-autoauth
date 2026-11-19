@echo off
chcp 65001 >nul
setlocal EnableExtensions

set "APP_DIR=%LOCALAPPDATA%\ObitAutoAuth"

echo [1/3] Остановка ObitAutoAuth.exe...
taskkill /F /IM ObitAutoAuth.exe >nul 2>&1

echo [2/3] Удаление из автозагрузки и ярлыка...
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v "ObitAutoAuth" /f >nul 2>&1
del "%USERPROFILE%\Desktop\OBIT Auto-Auth.lnk" >nul 2>&1
powershell -NoProfile -Command "$p=Join-Path ([Environment]::GetFolderPath('Desktop')) 'OBIT Auto-Auth.lnk'; if (Test-Path $p) { Remove-Item -Force $p }" >nul 2>&1

echo [3/3] Удаление файлов программы...
if exist "%APP_DIR%" rmdir /S /Q "%APP_DIR%"

echo.
echo OBIT Auto-Auth полностью удалён.
timeout /t 3 >nul
