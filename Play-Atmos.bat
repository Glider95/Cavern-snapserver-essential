@echo off
chcp 65001 >nul
title Cavern Atmos Player - %~nx1

REM Check if file provided
if "%~1"=="" (
    echo Usage: Play-Atmos.bat "path\to\movie.mkv"
    pause
    exit /b 1
)

set "MOVIE_FILE=%~1"
set "FFMPEG=ffmpeg-8.0.1-essentials_build\bin\ffmpeg.exe"
set "CAVERN_PIPE=CavernPipe"
set "SCRIPT_DIR=%~dp0"

cd /d "%SCRIPT_DIR%"

echo ╔═══════════════════════════════════════════════════════════╗
echo ║      Cavern Dolby Atmos Player                           ║
echo ╚═══════════════════════════════════════════════════════════╝
echo.
echo File: %MOVIE_FILE%
echo.

REM Check prerequisites
if not exist "%FFMPEG%" (
    echo ❌ FFmpeg not found!
    exit /b 1
)

REM Check if CavernPipeServer is running
tasklist | findstr "CavernPipeServer" >nul
if errorlevel 1 (
    echo ⚠️  CavernPipeServer not running!
    echo Start it first, then press any key...
    pause >nul
)

echo 🔊 Extracting audio and sending to Cavern...
echo.

REM FFmpeg extracts audio, sends raw to stdout which gets piped to CavernPipe
REM -vn = no video
REM -acodec copy = copy audio without re-encoding (preserves Atmos)
REM -f data = output as raw data

"%FFMPEG%" -hide_banner -loglevel warning -stats -i "%MOVIE_FILE%" -vn -acodec copy -f data - 2>ffmpeg.log | ^
    .\src\Cavern\CavernPipeClient.exe pipe://stdin

if errorlevel 1 (
    echo.
    echo ❌ Error occurred. Check ffmpeg.log for details.
    type ffmpeg.log
    pause
)

echo.
echo Done!
pause
