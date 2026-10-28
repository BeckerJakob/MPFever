@echo off
rem Stops and removes the MPFever server list service and its firewall rule. Run as administrator.
setlocal
net session >nul 2>&1 || (echo Run this file as administrator. & pause & exit /b 1)
sc stop MPFeverServerList >nul 2>&1
sc delete MPFeverServerList
netsh advfirewall firewall delete rule name="MPFever server list" >nul
pause
