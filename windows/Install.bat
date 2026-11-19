@echo off
chcp 65001 >nul
setlocal EnableExtensions

set "APP_DIR=%LOCALAPPDATA%\ObitAutoAuth"
set "EXE_PATH=%APP_DIR%\ObitAutoAuth.exe"
set "SRC_DIR=%~dp0src"
set "PREBUILT_EXE=%~dp0ObitAutoAuth.exe"
set "CSC="

if not exist "%PREBUILT_EXE%" (
    if exist "%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe" (
        set "CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    ) else if exist "%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe" (
        set "CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe"
    )

    if not exist "%SRC_DIR%\TrayApp.cs" (
        echo [ERROR] Рядом с Install.bat не найден ObitAutoAuth.exe или папка src\.
        echo Сначала распакуйте ВСЕ файлы из ZIP-архива в отдельную папку, затем запустите Install.bat.
        pause
        exit /b 1
    )

    if "%CSC%"=="" (
        echo [ERROR] Не найден системный компилятор .NET Framework 4.x (csc.exe).
        pause
        exit /b 1
    )
)

echo [1/4] Остановка старой версии (если запущена)...
taskkill /F /IM ObitAutoAuth.exe >nul 2>&1
if not errorlevel 1 ping -n 2 127.0.0.1 >nul

if not exist "%APP_DIR%" mkdir "%APP_DIR%"
if exist "%PREBUILT_EXE%" (
    echo [2/4] Установка ObitAutoAuth.exe...
    copy /Y "%PREBUILT_EXE%" "%EXE_PATH%" >nul
    if errorlevel 1 (
        echo [ERROR] Не удалось скопировать ObitAutoAuth.exe.
        pause
        exit /b 1
    )
    powershell -NoProfile -Command "Unblock-File -Path $env:EXE_PATH" >nul 2>&1
) else (
    echo [2/4] Сборка ObitAutoAuth.exe...
    "%CSC%" /nologo /target:winexe /optimize+ /utf8output /codepage:65001 /out:"%EXE_PATH%" ^
        /r:System.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll "%SRC_DIR%\*.cs"

    if errorlevel 1 (
        echo [ERROR] Ошибка компиляции.
        pause
        exit /b 1
    )
)

echo [3/4] Добавление в автозагрузку Windows...
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v "ObitAutoAuth" /t REG_SZ /d "\"%EXE_PATH%\"" /f >nul

echo [4/4] Создание ярлыка на Рабочем столе и запуск...
powershell -NoProfile -Command "$s=(New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'OBIT Auto-Auth.lnk')); $s.TargetPath=$env:EXE_PATH; $s.WorkingDirectory=$env:APP_DIR; $s.Save()" >nul 2>&1
start "" "%EXE_PATH%"

echo.
echo Готово! Иконка OBIT Auto-Auth появилась в трее возле часов.
echo Программа будет автоматически запускаться при входе в Windows.
timeout /t 4 >nul
