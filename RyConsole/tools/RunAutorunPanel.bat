@echo off
setlocal enableextensions
title RyConsole Autorun - PC Console

rem ---- locate python (managed runtime, resolved at runtime: no hardcoded user path) ----
set "PY=%USERPROFILE%\.workbuddy\binaries\python\versions\3.13.12\python.exe"
set "PYW=%USERPROFILE%\.workbuddy\binaries\python\versions\3.13.12\pythonw.exe"
set "GUI=%~dp0ryc_gui.py"

if not exist "%PY%" goto nopython
if not exist "%GUI%" goto nogui

rem ---- quick dependency probe (visible errors instead of a silent pythonw exit) ----
"%PY%" -c "import tkinter, json, threading" 2>nul
if errorlevel 1 goto nolib

set "PYEXE=%PY%"
if exist "%PYW%" set "PYEXE=%PYW%"

start "" "%PYEXE%" "%GUI%" %*
exit /b 0

:nopython
echo [ERR] Python not found:
echo        %PY%
echo        Install the managed runtime, or edit PY at the top of this file.
pause
exit /b 1

:nogui
echo [ERR] ryc_gui.py not found next to this script:
echo        %GUI%
pause
exit /b 1

:nolib
echo [ERR] tkinter is missing in this Python build:
echo        %PY%
echo        Reinstall the managed runtime with tkinter support.
pause
exit /b 1
