@echo off
rem ============================================================================
rem  ann ignition - the ONE non-Tcl tooling file.
rem
rem  ann lives INSIDE the mal folder and pins a shared, read-only toolchain
rem  bundle by name (toolchain.pin, one line, e.g. tika26b). This script
rem  DISCOVERS that bundle in mal's store by walking ancestors for
rem    <ancestor>\X\<pin>\BUNDLE.manifest
rem  so the whole tree is location-agnostic (mal can sit anywhere and be renamed),
rem  puts the bundle's Tcl/Tk 9 + gcc on PATH, then hands off to the Tcl task
rem  runner. Everything else is Tcl (or C built by the bundle's gcc).
rem  Usage:  x <command> [args]   (run `x help`)
rem
rem  Double-clicking x.cmd (or `x shell`) drops you into a shell with the bundle
rem  on PATH. The bundle is read ONLY; ann writes nothing outside this folder.
rem
rem  Flow is goto-based on purpose: no parenthesized blocks wrap %PATH% vars, so a
rem  ')' in the folder path (e.g. an Explorer "ann (1)" copy) can't break parsing.
rem ============================================================================
setlocal
set "ANN_ROOT=%~dp0"
if "%ANN_ROOT:~-1%"=="\" set "ANN_ROOT=%ANN_ROOT:~0,-1%"

rem --- the pinned bundle name (one line in toolchain.pin) ---
set "PIN="
if exist "%ANN_ROOT%\toolchain.pin" set /p PIN=<"%ANN_ROOT%\toolchain.pin"
for /f "tokens=* delims= " %%P in ("%PIN%") do set "PIN=%%P"
if not defined PIN goto no_pin

rem --- discover the store: walk ancestors for <dir>\X\<pin>\BUNDLE.manifest ---
set "TC="
set "D=%ANN_ROOT%"
:find_store
if exist "%D%\X\%PIN%\BUNDLE.manifest" set "TC=%D%\X\%PIN%"
if defined TC goto store_found
set "ND=%D%\.."
for %%I in ("%ND%") do set "ND=%%~fI"
if /i "%ND%"=="%D%" goto store_missing
set "D=%ND%"
goto find_store

:store_found
rem Tcl/Tk 9 FIRST, ahead of msys64 (which ships its own Tcl/Tk 8.6 we must not
rem use). Our tooling calls tclsh90.exe/wish90.exe explicitly anyway.
set "PATH=%TC%\tcl9\bin;%TC%\msys64\ucrt64\bin;%PATH%"
set "MSYSTEM=UCRT64"
if exist "%TC%\tcllib\tcl_library\init.tcl" set "TCL_LIBRARY=%TC%\tcllib\tcl_library"
if exist "%TC%\tcllib\tk_library\tk.tcl" set "TK_LIBRARY=%TC%\tcllib\tk_library"

rem Open a shell when double-clicked (no args) or `x shell`; else dispatch to Tcl.
if "%~1"=="" goto shell
if /i "%~1"=="shell" goto shell

if not exist "%TC%\tcl9\bin\tclsh90.exe" goto incomplete
"%TC%\tcl9\bin\tclsh90.exe" "%ANN_ROOT%\tools\x.tcl" %*
exit /b %errorlevel%

:shell
echo.
echo   ann toolchain shell - the pinned bundle "%PIN%" is on PATH.
echo   Try:  x help   x toolcheck   x build     ^(or 'exit' to leave^)
echo.
cmd /k prompt ann$G$S
exit /b

:no_pin
echo [ann] no toolchain.pin in "%ANN_ROOT%" - a mal project pins its bundle by name
echo        (one line, e.g. tika26b). Is this project inside the mal folder?
exit /b 1

:store_missing
echo [ann] bundle "%PIN%" not found in any ancestor X\ store from "%ANN_ROOT%".
echo        Is this project inside the mal folder, and is the bundle present + sealed?
exit /b 1

:incomplete
echo [ann] tclsh90.exe missing under "%TC%\tcl9\bin" - the bundle looks incomplete.
echo        Run `mal verify %PIN%` from the mal folder.
exit /b 1
