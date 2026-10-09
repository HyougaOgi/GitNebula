@echo off
if not exist "%~dp0Install.ps1" (
    echo GitNebula installer files are missing. Extract the complete ZIP before running install.cmd.
    exit /b 1
)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1" %*
exit /b %errorlevel%
