#Requires -Version 5.1
<#
.SYNOPSIS
    Quick test of the full Cavern-Snapcast pipeline
#>

Write-Host "╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║     Cavern Pipeline Test                                  ║" -ForegroundColor Cyan
Write-Host "╚═══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# Check components
$checks = @()

# 1. Check CavernPipeServer
$cavern = Get-Process | Where-Object {$_.Name -like "*CavernPipe*"}
$checks += [PSCustomObject]@{Component="CavernPipeServer"; Status=$(if($cavern){"✅ Running (PID $($cavern.Id))"}else{"❌ Not running"})}

# 2. Check Snapserver
$snap = Get-Process | Where-Object {$_.Name -like "*snap*"}
$checks += [PSCustomObject]@{Component="Snapserver"; Status=$(if($snap){"✅ Running (PID $($snap.Id))"}else{"❌ Not running"})}

# 3. Check VlcAudioBridge
$vlc = Get-Process | Where-Object {$_.Name -like "*VlcAudio*"}
$checks += [PSCustomObject]@{Component="VlcAudioBridge"; Status=$(if($vlc){"✅ Running (PID $($vlc.Id))"}else{"❌ Not running"})}

# 4. Check pipe
$pipes = [System.IO.Directory]::GetFiles("\\.\pipe\") | Where-Object { $_ -match "Cavern" }
$checks += [PSCustomObject]@{Component="Named Pipes"; Status=$(if($pipes){"✅ $($pipes.Count) pipe(s)"}else{"❌ None found"})}

# 5. Check network
$listeners = Get-NetTCPConnection -LocalPort 1704 -ErrorAction SilentlyContinue
$checks += [PSCustomObject]@{Component="Network (Port 1704)"; Status=$(if($listeners){"✅ Listening"}else{"❌ Not listening"})}

$checks | Format-Table -AutoSize

Write-Host ""
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Yellow
Write-Host "To complete the setup:" -ForegroundColor Yellow
Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Yellow
Write-Host ""
Write-Host "1. MUTE YOUR PC SPEAKERS (or use Virtual Audio Cable)" -ForegroundColor Red
Write-Host ""
Write-Host "2. For VLC integration:" -ForegroundColor White
Write-Host "   - Open VLC" -ForegroundColor Gray
Write-Host "   - Go to View → Cavern Spatial Audio" -ForegroundColor Gray
Write-Host "   - Click 'Enable Spatial Audio'" -ForegroundColor Gray
Write-Host "   - Play any Dolby Atmos file" -ForegroundColor Gray
Write-Host ""
Write-Host "3. For direct file streaming (no VLC):" -ForegroundColor White
Write-Host "   .\Simple-Stream.ps1 -Path `"C:\path\to\movie.mkv`"" -ForegroundColor Gray
Write-Host ""
Write-Host "4. Check web UI for speaker control:" -ForegroundColor White
Write-Host "   File: speaker-ui\index.html" -ForegroundColor Gray
Write-Host ""
