@echo off
rem Builds mpf_math.cpp alone as outmpfmath_test.dll, for mathtest.py (python mathtest.py <this folder>): MPFever's mathematics against this Windows' C runtime.
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
cl /nologo /c /O2 /GS- /Zl /EHs-c- /GR- /std:c++17 mpf_math.cpp /Fo:out\mpf_math.obj || exit /b 1
ml64 /nologo /c /Fo out\mpf_math_asm.obj mpf_math_asm.asm || exit /b 1
cl /nologo /c /Zl out\fltused_test.cpp /Fo:out\fltused_test.obj || exit /b 1
link /nologo /DLL /NODEFAULTLIB /NOENTRY /OUT:out\mpfmath_test.dll out\mpf_math.obj out\mpf_math_asm.obj out\fltused_test.obj /EXPORT:mpf_sin /EXPORT:mpf_cos /EXPORT:mpf_tan /EXPORT:mpf_asin /EXPORT:mpf_acos /EXPORT:mpf_atan /EXPORT:mpf_atan2 /EXPORT:mpf_sinh /EXPORT:mpf_cosh /EXPORT:mpf_tanh /EXPORT:mpf_exp /EXPORT:mpf_exp2 /EXPORT:mpf_log /EXPORT:mpf_log2 /EXPORT:mpf_log10 /EXPORT:mpf_pow /EXPORT:mpf_powf /EXPORT:mpf_expf /EXPORT:mpf_sinf /EXPORT:mpf_log2f /EXPORT:mpf_atan2f || exit /b 1
echo MATHDLL OK
