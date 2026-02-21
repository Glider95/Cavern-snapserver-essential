#Requires -Version 5.1
<#
.SYNOPSIS
    Add Windows Firewall rules for Snapcast/Snapserver emulator.

.DESCRIPTION
    Adds inbound firewall rules to allow snapclients to connect.
    Must be run as Administrator.
#>
[CmdletBinding()]
param()

$ports = @(1704, 1705, 1780)

# Check if running as admin
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ERROR: This script must be run as Administrator!" -ForegroundColor Red
    Write-Host "Right-click PowerShell and select 'Run as Administrator'" -ForegroundColor Yellow
    exit 1
}

Write-Host "Adding Windows Firewall rules for Snapcast..." -ForegroundColor Cyan

foreach ($port in $ports) {
    $ruleName = "Snapcast - Port $port"
    
    # Remove existing rule if present
    netsh advfirewall firewall delete rule name="$ruleName" 2>&1 | Out-Null
    
    # Add new rule
    $result = netsh advfirewall firewall add rule name="$ruleName" dir=in action=allow protocol=tcp localport=$port
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ✓ Port $port opened" -ForegroundColor Green
    } else {
        Write-Host "  ✗ Failed to open port $port" -ForegroundColor Red
    }
}

Write-Host "`nFirewall rules added!" -ForegroundColor Green
Write-Host "Snapclients should now be able to connect." -ForegroundColor Cyan
