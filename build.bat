@echo off
rem Builds the whole MPFever release from source: native DLL, launcher, then the zip in release\.
rem Requires Visual Studio 2022 or later with the "Desktop development with C++" and ".NET desktop" workloads
rem (.NET Framework 4.8 targeting pack).
setlocal
cd /d "%~dp0"
echo MPFever build %date% %time%
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" (echo vswhere.exe not found: install Visual Studio & exit /b 1)
for /f "usebackq delims=" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.Component.MSBuild -find MSBuild\**\Bin\MSBuild.exe`) do set "MSBUILD=%%i"
if not defined MSBUILD (echo MSBuild not found & exit /b 1)

echo === 1/4 native module
call native\build.bat || exit /b 1

echo === 2/4 launcher
"%MSBUILD%" launcher\MPFever.csproj -restore -p:Configuration=Release -v:minimal -nologo || exit /b 1

rem (the signatures next to the launcher of the build folder too: without them, on a game build the module does not know,
rem every hook stays off and the games drift apart)
if exist native\mpfever_sigs.txt copy /y native\mpfever_sigs.txt launcher\bin\Release\ >nul

rem every check that needs no game (tests\run_all.py): one failure and no archive is made
echo === 3/4 tests
where python >nul 2>&1 || (echo Python not found: install Python 3 and lupa ^(pip install lupa^) & exit /b 1)
python tests\run_all.py --exe launcher\bin\Release\MPFever.exe || (echo TESTS FAILED: no archive made & exit /b 1)

echo === 4/4 package
set "VERSION=0.5.8"
set "DIST=release\dist\MPFever"
if exist release\dist rmdir /s /q release\dist
mkdir "%DIST%" || exit /b 1
copy /y launcher\bin\Release\MPFever.exe "%DIST%\" >nul || exit /b 1
copy /y launcher\bin\Release\MPFever.exe.config "%DIST%\" >nul || exit /b 1
copy /y native\out\winhttp.dll "%DIST%\" >nul || exit /b 1
rem the native module's places by signature (tools\mksigs.py), for a game build it does not know
if exist native\mpfever_sigs.txt copy /y native\mpfever_sigs.txt "%DIST%\" >nul
for %%f in (README INSTALL ROADMAP CHANGELOG) do copy /y docs\%%f.txt "%DIST%\" >nul || exit /b 1
copy /y LICENSE "%DIST%\LICENSE.txt" >nul || exit /b 1
copy /y NOTICE.txt "%DIST%\" >nul || exit /b 1
xcopy /e /i /q /y mod\mpfever_1 "%DIST%\mod\mpfever_1" >nul || exit /b 1
if exist "release\MPFever-%VERSION%.zip" del "release\MPFever-%VERSION%.zip"
rem standard zip entries (forward slashes), unlike Compress-Archive of Windows PowerShell 5
powershell -NoProfile -Command "Add-Type -AssemblyName System.IO.Compression.FileSystem; [IO.Compression.ZipFile]::CreateFromDirectory((Resolve-Path 'release\dist\MPFever'), (Join-Path (Resolve-Path 'release') 'MPFever-%VERSION%.zip'), 'Optimal', $true)" || exit /b 1
echo BUILD OK: release\MPFever-%VERSION%.zip

rem the dedicated server's archive: the same MPFever, plus start-server.bat, SERVER.txt and server-edition.txt (its MPFever.exe
rem opens the server's window), in a folder of its own name (players do not need them)
set "SDIST=release\dist-server\MPFever-Server"
if exist release\dist-server rmdir /s /q release\dist-server
xcopy /e /i /q /y "%DIST%" "%SDIST%" >nul || exit /b 1
copy /y docs\SERVER.txt "%SDIST%\" >nul || exit /b 1
copy /y docs\server-edition.txt "%SDIST%\" >nul || exit /b 1
copy /y launcher\start-server.bat "%SDIST%\" >nul || exit /b 1
if exist "release\MPFever-%VERSION%-server.zip" del "release\MPFever-%VERSION%-server.zip"
powershell -NoProfile -Command "Add-Type -AssemblyName System.IO.Compression.FileSystem; [IO.Compression.ZipFile]::CreateFromDirectory((Resolve-Path 'release\dist-server\MPFever-Server'), (Join-Path (Resolve-Path 'release') 'MPFever-%VERSION%-server.zip'), 'Optimal', $true)" || exit /b 1
echo BUILD OK: release\MPFever-%VERSION%-server.zip
