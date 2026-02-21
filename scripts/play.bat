@echo off
REM Play a movie through Cavern-Snapcast (batch wrapper for PowerShell)
REM Usage: play.bat <movie_file> [options]

if "%~1"=="" (
    echo Usage: play.bat ^<movie_file^> [options]
    echo.
    echo Examples:
    echo   play.bat "C:\Movies\movie.mkv"
    echo   play.bat movie.mkv -Channels 8
    exit /b 1
)

powershell -ExecutionPolicy Bypass -File "%~dp0Play-AtmosMovie.ps1" -Path "%~1" %2 %3 %4 %5 %6 %7 %8 %9
