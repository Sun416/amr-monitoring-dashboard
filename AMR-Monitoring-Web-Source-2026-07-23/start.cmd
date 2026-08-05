@echo off
setlocal
cd /d "%~dp0"

if not exist ".env" (
  echo [AMR Monitor] Missing .env file.
  echo Copy .env.example to .env and configure the SQL Server connection first.
  exit /b 1
)

if not exist "node_modules" (
  echo [AMR Monitor] Installing project dependencies...
  call npm.cmd install
  if errorlevel 1 exit /b %errorlevel%
)

call npm.cmd start

