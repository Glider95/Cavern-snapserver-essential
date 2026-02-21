#Requires -Version 5.1
<#
.SYNOPSIS
    Get status of Cavern-Snapcast streaming components.

.DESCRIPTION
    Displays the current status of snapserver, active connections,
    and named pipes.

.EXAMPLE
    .\Get-CavernStatus.ps1
#>
[CmdletBinding()]
param()

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $timestamp = Get-Date -Format "HH:mm:ss"
    $color = switch ($Status) {
        "ERROR" { "Red" }
        "WARN"  { "Yellow" }
        "SUCCESS" { "Green" }
        "HEADER" { "Cyan" }
        default { "White" }
    }
    Write-Host "[$timestamp] [$Status] $Message" -ForegroundColor $color
}

Clear-Host
Write-Host @"
╔═══════════════════════════════════════════════════════════╗
║          Cavern-Snapcast Status Check                     ║
╚═══════════════════════════════════════════════════════════╝
"@ -ForegroundColor Cyan

# Check snapserver process
Write-Status "Checking Snapserver..." "HEADER"
$snapProcess = Get-Process -Name "snapserver" -ErrorAction SilentlyContinue
if ($snapProcess) {
    Write-Status "Snapserver is RUNNING" "SUCCESS"
    Write-Status "  PID: $($snapProcess.Id)"
    Write-Status "  Started: $($snapProcess.StartTime)"
    Write-Status "  Memory: $([math]::Round($snapProcess.WorkingSet64 / 1MB, 2)) MB"
    
    # Check TCP port
    $port = 1704
    try {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
        $listener.Start()
        $listener.Stop()
        Write-Status "  Port $port : NOT LISTENING (available)" "WARN"
    }
    catch {
        Write-Status "  Port $port : LISTENING" "SUCCESS"
    }
}
else {
    Write-Status "Snapserver is NOT RUNNING" "WARN"
}

Write-Status ""
Write-Status "Checking Named Pipes..." "HEADER"
$pipes = Get-ChildItem -Path "\\.\pipe\" -ErrorAction SilentlyContinue | 
    Where-Object { $_.Name -like "*Cavern*" -or $_.Name -like "*snap*" }

if ($pipes) {
    foreach ($pipe in $pipes) {
        Write-Status "  Pipe: $($pipe.Name)"
    }
}
else {
    Write-Status "  No Cavern pipes found" "WARN"
}

Write-Status ""
Write-Status "Checking .NET Processes..." "HEADER"
$dotnetProcesses = Get-Process -Name "dotnet" -ErrorAction SilentlyContinue
if ($dotnetProcesses) {
    foreach ($proc in $dotnetProcesses) {
        try {
            $cmdLine = (Get-WmiObject Win32_Process -Filter "ProcessId = $($proc.Id)").CommandLine
            if ($cmdLine -like "*Cavern*") {
                Write-Status "  PID $($proc.Id): Cavern process" "SUCCESS"
            }
        }
        catch {
            # Ignore
        }
    }
}
else {
    Write-Status "  No .NET processes running" "WARN"
}

Write-Status ""
Write-Status "Network Connections..." "HEADER"
$connections = Get-NetTCPConnection -LocalPort 1704 -ErrorAction SilentlyContinue
if ($connections) {
    $established = $connections | Where-Object { $_.State -eq "Established" }
    Write-Status "  Snapcast port 1704: $($established.Count) established connections" "SUCCESS"
}
else {
    Write-Status "  No active connections on port 1704" "WARN"
}

Write-Status ""
Write-Status "═══════════════════════════════════════════════════════════"
Write-Status "Status check complete"
Write-Status "═══════════════════════════════════════════════════════════"
