@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher.ps1"
if errorlevel 1 (
  echo.
  echo Не вдалося відкрити n8n Course Kit.
  echo Перевірте повідомлення вище або запустіть launcher.ps1 у PowerShell.
  pause
)
endlocal
