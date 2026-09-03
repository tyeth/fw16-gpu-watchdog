# Elevated: register the GPU-free heartbeat task + enable DxgKrnl channels.
$ErrorActionPreference = 'Continue'
$Result = Join-Path $PSScriptRoot 'setup-heartbeat-result.txt'
Start-Transcript -Path $Result -Force | Out-Null

$HbPath = Join-Path $PSScriptRoot 'heartbeat-lite.ps1'
$UserId = "$env:USERDOMAIN\$env:USERNAME"

Unregister-ScheduledTask -TaskName 'GpuFreeHeartbeat' -Confirm:$false -ErrorAction SilentlyContinue
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$HbPath`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $UserId
# deliberately NOT RunLevel Highest - it needs no admin, and a lower-priv
# process is one more independent observer during a stall
$principal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType Interactive
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 10 -RestartInterval (New-TimeSpan -Minutes 1) `
    -MultipleInstances IgnoreNew -Hidden
Register-ScheduledTask -TaskName 'GpuFreeHeartbeat' -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName 'GpuFreeHeartbeat'
Write-Output "GpuFreeHeartbeat: $((Get-ScheduledTask -TaskName 'GpuFreeHeartbeat').State)"

# GPU scheduler observability above the closed driver
foreach ($ch in @('Microsoft-Windows-DxgKrnl/Operational','Microsoft-Windows-DxgKrnl/Admin')) {
    wevtutil sl $ch /e:true 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Output "Enabled channel: $ch" }
    else { Write-Output "Channel not available: $ch" }
}
Stop-Transcript | Out-Null
