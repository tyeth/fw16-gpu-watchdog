# Add a 5-min repetition re-arm trigger to GpuFreeHeartbeat (IgnoreNew makes
# it a no-op while the process is alive; relaunches it if killed).
$logon = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$rearm = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 5)
Set-ScheduledTask -TaskName GpuFreeHeartbeat -Trigger $logon, $rearm | Out-Null
"Triggers: $((Get-ScheduledTask GpuFreeHeartbeat).Triggers.Count); State: $((Get-ScheduledTask GpuFreeHeartbeat).State)"
