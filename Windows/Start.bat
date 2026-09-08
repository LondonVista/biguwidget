@echo off
cd /d "%~dp0"

where npm >nul 2>nul
if errorlevel 1 (
  echo Node.js 20+ is required. Install it from https://nodejs.org/ then run this again.
  pause
  exit /b 1
)

if not exist "node_modules\electron" (
  echo Installing BigUwidget 1.0.4 for Windows (first run only)...
  call npm install
)

if not exist "node_modules\electron\dist\electron.exe" (
  if exist "node_modules\electron\install.js" (
    node node_modules\electron\install.js
  )
)

call npm start
if errorlevel 1 pause
