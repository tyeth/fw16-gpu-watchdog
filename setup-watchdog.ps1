# One-time elevated setup for the GPU/Power watchdog.
# - Registers a scheduled task that runs logger.ps1 at logon (elevated, hidden)
# - Starts it immediately
# - Enables the kernel thermal event channel if present
# Writes a transcript to setup-result.txt so an unelevated session can verify.

$ErrorActionPreference = 'Continue'
$Result = Join-Path $PSScriptRoot 'setup-result.txt'
Start-Transcript -Path $Result -Force | Out-Null

$TaskName = 'GpuPowerWatchdog'
$LoggerPath = Join-Path $PSScriptRoot 'logger.ps1'
$UserId = "$env:USERDOMAIN\$env:USERNAME"

# Stop any previous instance
schtasks /End /TN $TaskName 2>$null | Out-Null
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$LoggerPath`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $UserId
$principal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 10 -RestartInterval (New-TimeSpan -Minutes 1) `
    -MultipleInstances IgnoreNew -Hidden

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null
Write-Output "Task '$TaskName' registered."

Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 3
$t = Get-ScheduledTask -TaskName $TaskName
Write-Output ("Task state: {0}" -f $t.State)

# Enable thermal/power diagnostic channels where available (best-effort)
foreach ($ch in @(
    'Microsoft-Windows-Kernel-Power/Thermal-Operational',
    'Microsoft-Windows-Thermal-Polite/Operational'
)) {
    try {
        wevtutil sl $ch /e:true 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Output "Enabled channel: $ch" }
        else { Write-Output "Channel not available: $ch" }
    } catch { Write-Output "Channel not available: $ch" }
}

# Bump System log size to 64MB so busy gaming sessions don't roll events off
try {
    wevtutil sl System /ms:67108864
    Write-Output 'System event log size set to 64MB.'
} catch { Write-Output "Could not resize System log: $_" }

Write-Output 'Setup complete.'
Stop-Transcript | Out-Null
