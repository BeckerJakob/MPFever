@echo off
rem Builds mpf_steamnet.cpp with steamnet_mock.cpp (a stand-in for steam_api64.dll) as out\steamnet_mock.dll, for
rem steamnet_test.py mock: the Steam core checked without the game.
setlocal
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
for /f "usebackq delims=" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSDIR=%%i"
set /p VCVER=<"%VSDIR%\VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt"
set "VC=%VSDIR%\VC\Tools\MSVC\%VCVER%"
set "PATH=%VC%\bin\Hostx64\x64;%PATH%"
set "INCLUDE=%VC%\include"
set "LIB=%VC%\lib\x64"
cd /d "%~dp0"
if not exist out mkdir out
lib /nologo /def:kernel32.def /out:out\kernel32.lib /machine:x64 || exit /b 1
cl /nologo /c /WX /O2 /GS- /Zl /EHs-c- /GR- /std:c++17 mpf_steamnet.cpp /Fo:out\steamnet_core_test.obj || exit /b 1
cl /nologo /c /WX /O2 /GS- /Zl /EHs-c- /GR- /std:c++17 steamnet_mock.cpp /Fo:out\steamnet_mock.obj || exit /b 1
ml64 /nologo /c /Fo out\steamnet_mock_asm.obj steamnet_mock_asm.asm || exit /b 1
ml64 /nologo /c /Fo out\chkstk.obj chkstk.asm || exit /b 1
link /nologo /WX /DLL /NODEFAULTLIB /ENTRY:MockMain /OUT:out\steamnet_mock.dll out\steamnet_mock.obj out\steamnet_mock_asm.obj out\steamnet_core_test.obj out\chkstk.obj out\kernel32.lib /EXPORT:SteamAPI_SteamNetworkingMessage_t_Release || exit /b 1
echo STEAMNET MOCK OK
