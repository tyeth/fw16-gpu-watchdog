# Elevated: reset the LEFT PD controller (index 1, ports 2/3) while port 3
# is wedged (attach seen, no PD contract), then verify. USER-REQUESTED test.
$Result = Join-Path $PSScriptRoot 'pdreset-result.txt'
Set-Content $Result "== PRE state $(Get-Date -Format o)"
& framework_tool --pdports 2>&1 | Add-Content $Result
Add-Content $Result 'PRE power:'
& framework_tool --power 2>&1 | Select-Object -First 8 | Add-Content $Result

Add-Content $Result "== RESET PD1 (left) $(Get-Date -Format o)"
& framework_tool --pd-reset 1 2>&1 | Add-Content $Result

Start-Sleep -Seconds 12
Add-Content $Result "== POST state $(Get-Date -Format o)"
& framework_tool --pd-info 2>&1 | Add-Content $Result
& framework_tool --pdports 2>&1 | Add-Content $Result
Add-Content $Result 'POST power:'
& framework_tool --power 2>&1 | Select-Object -First 8 | Add-Content $Result
Add-Content $Result 'POST port3 raw (0x3E23):'
& framework_tool --host-command 0x3E23 0 3 2>&1 | Add-Content $Result
Add-Content $Result "done $(Get-Date -Format o)"
