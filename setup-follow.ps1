# Elevated: register+start the EC console follower task and restart the logger.
$ErrorActionPreference = 'Continue'
$Result = Join-Path $PSScriptRoot 'setup-follow-result.txt'
Start-Transcript -Path $Result -Force | Out-Null

$FollowPath = Join-Path $PSScriptRoot 'ec-follow.ps1'
$UserId = "$env:USERDOMAIN\$env:USERNAME"

Unregister-ScheduledTask -TaskName 'GpuEcConsoleFollow' -Confirm:$false -ErrorAction SilentlyContinue
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$FollowPath`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $UserId
$principal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 10 -RestartInterval (New-TimeSpan -Minutes 1) `
    -MultipleInstances IgnoreNew -Hidden
Register-ScheduledTask -TaskName 'GpuEcConsoleFollow' -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null

# Restart logger so it picks up new telemetry and stops using --console recent
schtasks /End /TN GpuPowerWatchdog 2>$null | Out-Null
Start-Sleep -Seconds 2
Start-ScheduledTask -TaskName 'GpuPowerWatchdog'
Start-ScheduledTask -TaskName 'GpuEcConsoleFollow'
Start-Sleep -Seconds 3
Get-ScheduledTask -TaskName 'GpuPowerWatchdog','GpuEcConsoleFollow' |
    Select-Object TaskName, State | Format-Table -AutoSize
Stop-Transcript | Out-Null
