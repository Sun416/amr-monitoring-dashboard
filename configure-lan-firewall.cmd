@echo off
setlocal

netsh advfirewall firewall add rule name="AMR Dashboard TCP 3080" dir=in action=allow protocol=TCP localport=3080 profile=domain program="D:\nodejs\node.exe" enable=yes
set "result=%errorlevel%"

if "%result%"=="0" (
  echo.
  echo AMR Dashboard firewall rule created successfully.
) else (
  echo.
  echo Firewall rule creation failed. Confirm that this script is running as administrator.
)

pause
exit /b %result%
