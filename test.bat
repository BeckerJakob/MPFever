@echo off
rem MPFever tests - one entry point for every level (docs/dev/TESTING.md).
rem   test.bat                 unit + sim (default, no game needed, ~2 min)
rem   test.bat unit            L1  single modules
rem   test.bat sim             L1 + L2  mocked games running the real Lua files
rem   test.bat native          L3  installed game executable vs the native module (read only)
rem   test.bat e2e [pytest -k] L4  two real game instances on this PC (needs MPFever.exe built)
rem   test.bat soak            L5  long runs (MPF_SOAK_SECONDS, default 1800 per speed)
rem   test.bat gate 0          everything Phase 0 requires (unit + sim + native; e2e/soak when MPFever.exe exists)
rem   test.bat report          opens the newest report
rem Extra pytest arguments go after the level, e.g.  test.bat sim -k 3games
setlocal
cd /d "%~dp0"
set "PY=%~dp0.venv\Scripts\python.exe"
if not exist "%PY%" (
    echo Creating the test environment .venv ...
    python -m venv .venv || (echo Python 3.11+ is needed & exit /b 1)
    "%PY%" -m pip install -q -r tests\requirements.txt || exit /b 1
)

set "LEVEL=%~1"
if "%LEVEL%"=="" set "LEVEL=default"
if not "%~1"=="" shift

if /i "%LEVEL%"=="report" (
    for /f "delims=" %%d in ('dir /b /ad /o-n reports 2^>nul') do (start "" "reports\%%d\report.html" & exit /b 0)
    echo No report yet.
    exit /b 1
)
if /i "%LEVEL%"=="default" ( "%PY%" -m pytest -m "unit or sim" %1 %2 %3 %4 %5 %6 & exit /b )
if /i "%LEVEL%"=="unit"    ( "%PY%" -m pytest -m unit %1 %2 %3 %4 %5 %6 & exit /b )
if /i "%LEVEL%"=="sim"     ( "%PY%" -m pytest -m "unit or sim" %1 %2 %3 %4 %5 %6 & exit /b )
if /i "%LEVEL%"=="native"  ( "%PY%" -m pytest -m native %1 %2 %3 %4 %5 %6 & exit /b )
if /i "%LEVEL%"=="e2e"     ( "%PY%" -m pytest -m e2e --run-e2e %1 %2 %3 %4 %5 %6 & exit /b )
if /i "%LEVEL%"=="soak"    ( "%PY%" -m pytest -m soak --run-soak %1 %2 %3 %4 %5 %6 & exit /b )
if /i "%LEVEL%"=="gate" (
    if "%~1"=="0" ( "%PY%" -m pytest -m "unit or sim or native or e2e" --run-e2e %2 %3 %4 %5 %6 & exit /b )
    echo Unknown gate "%~1" - gates are added phase by phase ^(docs/dev/PLAN.md^)
    exit /b 2
)
echo Unknown level "%LEVEL%". Levels: unit, sim, native, e2e, soak, gate ^<n^>, report
exit /b 2
