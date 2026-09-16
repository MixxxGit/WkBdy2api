@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"

set "PORT=7891"
if exist ".env" (
  for /f "usebackq tokens=1,* delims==" %%a in (".env") do (
    if /i "%%~a"=="PORT" set "PORT=%%~b"
  )
)

set "SERVER_PID="
if exist ".server.pid" set /p SERVER_PID=<".server.pid"

if not defined SERVER_PID (
  for /f "tokens=5" %%p in ('netstat -ano ^| findstr /r /c:":%PORT% .*LISTENING"') do set "SERVER_PID=%%p"
)

if not defined SERVER_PID (
  echo [wkbdy2api] nothing is listening on port %PORT%
  if exist ".server.pid" del /q ".server.pid"
  exit /b 0
)

taskkill /pid !SERVER_PID! /f /t >nul 2>&1
if errorlevel 1 (
  echo [wkbdy2api] failed to stop pid !SERVER_PID!
  exit /b 1
)

if exist ".server.pid" del /q ".server.pid"
echo [wkbdy2api] stopped ^(pid !SERVER_PID!^)
endlocal
