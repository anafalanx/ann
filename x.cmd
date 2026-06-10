@echo off
rem ============================================================================
rem  ann ignition — the ONE non-Tcl tooling file.
rem
rem  Puts the vendored toolchain (relative to THIS script, so the project folder
rem  is copy-paste portable to any Windows 11+ machine) on PATH, then hands off
rem  to the Tcl task runner.  Everything else is Tcl (or C built by the vendored
rem  gcc).  Usage:  x <command> [args]   (run `x help`)
rem
rem  Double-clicking x.cmd in Explorer (or `x shell`) drops you into a shell with
rem  the toolchain on PATH, so you can run `x test`, gcc, tclsh, etc. directly.
rem ============================================================================
setlocal
set "ANN_ROOT=%~dp0"
set "TC=%ANN_ROOT%.toolchain"
rem Tcl/Tk 9 FIRST, ahead of msys64 (which ships its own Tcl/Tk 8.6 we must not
rem use).  Our tooling calls tclsh90.exe/wish90.exe explicitly anyway.
set "PATH=%TC%\tcl9\bin;%TC%\msys64\ucrt64\bin;%PATH%"
if exist "%TC%\git\cmd" set "PATH=%TC%\git\cmd;%PATH%"
set "MSYSTEM=UCRT64"
if exist "%TC%\appfull\tcl_library\init.tcl" set "TCL_LIBRARY=%TC%\appfull\tcl_library"
if exist "%TC%\appfull\tk_library\tk.tcl" set "TK_LIBRARY=%TC%\appfull\tk_library"

rem Open a shell when double-clicked (no arguments) or when asked explicitly via
rem `x shell`.  Normal commands like `x help` must dispatch to tools\x.tcl.
set "ANN_SHELL="
if "%~1"=="" set "ANN_SHELL=1"
if /i "%~1"=="shell" set "ANN_SHELL=1"

if defined ANN_SHELL (
  if not exist "%TC%\tcl9\bin\tclsh90.exe" echo [ann] Warning: toolchain not found at %TC%\tcl9
  echo.
  echo   ann toolchain shell - the vendored toolchain is on PATH.
  echo   Try:  x help   x toolcheck   x build     ^(or 'exit' to leave^)
  echo.
  cmd /k prompt ann$G$S
  exit /b
)

if not exist "%TC%\tcl9\bin\tclsh90.exe" (
  echo [ann] Tcl toolchain not found under %TC%\tcl9 - this folder is not provisioned.
  echo        Restore .toolchain\ ^(copy-paste^), or rebuild it, then run: x toolcheck
  exit /b 1
)
"%TC%\tcl9\bin\tclsh90.exe" "%ANN_ROOT%tools\x.tcl" %*
exit /b %errorlevel%
