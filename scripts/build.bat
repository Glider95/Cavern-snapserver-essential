@echo off
REM Build script for Windows (batch wrapper for PowerShell)
REM Usage: build.bat

powershell -ExecutionPolicy Bypass -File "%~dp0Build-Windows.ps1" %*
