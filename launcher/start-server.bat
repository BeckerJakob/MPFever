@echo off
rem MPFever dedicated server: Transport Fever 3 runs the world on this PC and the players join it.
rem The settings are in mpfever_server.properties, written next to MPFever.exe at the first start. See SERVER.txt.
cd /d "%~dp0"
start "" "%~dp0MPFever.exe" --server
