@echo off
REM Start Cavern streaming pipeline (batch wrapper for PowerShell)
REM Usage: run.bat [options]

powershell -ExecutionPolicy Bypass -File "%~dp0Start-CavernStreaming.ps1" %*
