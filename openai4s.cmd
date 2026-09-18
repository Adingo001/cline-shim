@echo off
rem Double-click entry point for the OpenAI4S daemon (WSL-backed).
rem Pass an action as the first argument: start | stop | restart | status |
rem doctor | logs | url | shell.  Defaults to start.
setlocal
set "HERE=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%HERE%openai4s.ps1" %*
if errorlevel 1 (
    echo.
    echo [openai4s] launcher exited with an error.
    pause
)
endlocal
