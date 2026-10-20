# Elevated: capture EC console ring + bay/port state (the 12:01 dGPU-unpowered
# event traces), then restart all watchdog tasks. Follower is dead, so a
# one-shot --console recent is safe here.
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$out = Join-Path $PSScriptRoot "event-$stamp"
New-Item -ItemType Directory -Path $out -Force | Out-Null
& framework_tool --console recent 2>&1 | Out-File (Join-Path $out 'ec-console.txt') -Encoding utf8
& framework_tool --pd-info 2>&1        | Out-File (Join-Path $out 'pd-info.txt') -Encoding utf8
& framework_tool --pdports 2>&1        | Out-File (Join-Path $out 'pdports.txt') -Encoding utf8
& framework_tool --expansion-bay 2>&1  | Out-File (Join-Path $out 'expansion-bay.txt') -Encoding utf8
& framework_tool --thermal 2>&1        | Out-File (Join-Path $out 'thermal.txt') -Encoding utf8
& framework_tool --uptimeinfo 2>&1     | Out-File (Join-Path $out 'uptimeinfo.txt') -Encoding utf8
& framework_tool --host-command 0x3E23 0 4 2>&1 | Out-File (Join-Path $out 'port4.txt') -Encoding utf8
& framework_tool --host-command 0x3E1C 0 2>&1   | Out-File (Join-Path $out 'hwdiag.txt') -Encoding utf8
foreach ($t in 'GpuPowerWatchdog','GpuEcConsoleFollow','GpuFreeHeartbeat') {
    schtasks /End /TN $t 2>$null | Out-Null
    Start-ScheduledTask -TaskName $t
}
Start-Sleep -Seconds 5
Get-ScheduledTask -TaskName GpuPowerWatchdog,GpuEcConsoleFollow,GpuFreeHeartbeat |
    Select-Object TaskName, State | Format-Table -AutoSize | Out-File (Join-Path $out 'tasks.txt') -Encoding utf8
