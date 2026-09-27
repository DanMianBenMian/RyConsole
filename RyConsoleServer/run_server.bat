@echo off
rem RyConsole Server launcher (pure ASCII, paths resolved at runtime)
"%USERPROFILE%\.workbuddy\binaries\python\envs\default\Scripts\python.exe" "%~dp0server.py" %*
if errorlevel 1 pause
