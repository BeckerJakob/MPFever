@echo off
rem Builds the native module as winhttp.dll (freestanding C++: no CRT, no Windows SDK needed).
rem Requires Visual Studio 2022 or later with the "Desktop development with C++" workload.
setlocal
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" (echo vswhere.exe not found: install Visual Studio with C++ tools & exit /b 1)
for /f "usebackq delims=" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSDIR=%%i"
if not defined VSDIR (echo Visual Studio C++ tools not found & exit /b 1)
set /p VCVER=<"%VSDIR%\VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt"
set "VC=%VSDIR%\VC\Tools\MSVC\%VCVER%"
set "PATH=%VC%\bin\Hostx64\x64;%PATH%"
set "INCLUDE=%VC%\include"
set "LIB=%VC%\lib\x64"
cd /d "%~dp0"
if not exist out mkdir out
lib /nologo /def:kernel32.def /out:out\kernel32.lib /machine:x64 || exit /b 1
cl /nologo /c /O2 /GS- /Zl /EHs-c- /GR- /std:c++17 mpfever_native.cpp /Fo:out\mpfever_native.obj || exit /b 1
cl /nologo /c /O2 /GS- /Zl /EHs-c- /GR- /std:c++17 winhttp_proxy.cpp /Fo:out\winhttp_proxy.obj || exit /b 1
rem the module takes the name winhttp.dll: the game loads it by itself from its folder
link /nologo /DLL /NODEFAULTLIB /ENTRY:DllMain /DEF:winhttp.def /OUT:out\winhttp.dll out\mpfever_native.obj out\winhttp_proxy.obj out\kernel32.lib || exit /b 1
echo BUILD OK
