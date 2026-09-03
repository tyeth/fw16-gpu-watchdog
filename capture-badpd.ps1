# Elevated snapshot of PD controller state while left port (PD1) is refusing
# to negotiate. Read-only.
$Result = Join-Path $PSScriptRoot 'badpd-snapshot.txt'
Set-Content $Result "snapshot $(Get-Date -Format o) - charger in bad LEFT port"
& framework_tool --pd-info 2>&1     | Add-Content $Result
& framework_tool --pdports 2>&1     | Add-Content $Result
& framework_tool --power -vv 2>&1   | Add-Content $Result
Add-Content $Result 'AP_THROTTLE(0x3E22):'
& framework_tool --host-command 0x3E22 0 2>&1 | Add-Content $Result
Add-Content $Result 'PD_PORT_STATE p2(0x3E23):'
& framework_tool --host-command 0x3E23 0 2 2>&1 | Add-Content $Result
Add-Content $Result 'PD_PORT_STATE p3(0x3E23):'
& framework_tool --host-command 0x3E23 0 3 2>&1 | Add-Content $Result
