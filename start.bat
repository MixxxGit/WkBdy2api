@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"

set "PORT=7891"
if exist ".env" (
  for /f "usebackq tokens=1,* delims==" %%a in (".env") do (
    if /i "%%~a"=="PORT" set "PORT=%%~b"
  )
)
set "HOST=127.0.0.1"
if exist ".env" (
  for /f "usebackq tokens=1,* delims==" %%a in (".env") do (
    if /i "%%~a"=="HOST" set "HOST=%%~b"
  )
)

if not exist "node_modules\tsx\dist\cli.mjs" (
  echo [wkbdy2api] dependencies are missing - run: pnpm install
  exit /b 1
)

for /f "tokens=5" %%p in ('netstat -ano ^| findstr /r /c:":%PORT% .*LISTENING"') do set "SERVER_PID=%%p"
if defined SERVER_PID (
  echo [wkbdy2api] already listening on port %PORT% ^(pid !SERVER_PID!^)
  exit /b 0
)

if not exist "logs" md "logs"

start "wkbdy2api" /min cmd /c node "%~dp0node_modules\tsx\dist\cli.mjs" "%~dp0src\main.ts" ^> "%~dp0logs\server.log" 2^>^&1

set "SERVER_PID="
for /l %%i in (1,1,40) do (
  if not defined SERVER_PID (
    for /f "tokens=5" %%p in ('netstat -ano ^| findstr /r /c:":%PORT% .*LISTENING"') do set "SERVER_PID=%%p"
  )
  if defined SERVER_PID goto started
  timeout /t 1 /nobreak >nul
)

echo [wkbdy2api] failed to start - see logs\server.log
exit /b 1

:started
>".server.pid" echo !SERVER_PID!
echo [wkbdy2api] started ^(pid !SERVER_PID!^)
echo [wkbdy2api] api:   http://%HOST%:%PORT%/v1/models
echo [wkbdy2api] admin: http://%HOST%:%PORT%/admin
echo [wkbdy2api] logs:  %~dp0logs\server.log
endlocal
