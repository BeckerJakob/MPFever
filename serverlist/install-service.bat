@echo off
rem Installs the MPFever server list as a Windows service that starts with Windows, opens its port in the Windows firewall
rem and starts it. Run as administrator (right click, "Run as administrator"). The port: port.txt next to the exe, else 28100.
setlocal
cd /d "%~dp0"
net session >nul 2>&1 || (echo Run this file as administrator. & pause & exit /b 1)
set "PORT=28100"
if exist port.txt set /p PORT=<port.txt
sc query MPFeverServerList >nul 2>&1 && (echo Already installed: run uninstall-service.bat first to install again. & pause & exit /b 1)
sc create MPFeverServerList binPath= "\"%~dp0MPFeverServerList.exe\" --service" start= auto DisplayName= "MPFever server list" || (pause & exit /b 1)
sc description MPFeverServerList "Public list of MPFever dedicated servers (HTTP, port %PORT%)." >nul
sc failure MPFeverServerList reset= 86400 actions= restart/60000/restart/60000/restart/60000 >nul
netsh advfirewall firewall add rule name="MPFever server list" dir=in action=allow protocol=TCP localport=%PORT% >nul
sc start MPFeverServerList
echo.
echo Installed. The list answers on http://this-pc:%PORT%/api/servers (forward TCP %PORT% on the router for the Internet).
pause
