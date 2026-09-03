# Elevated, USER-REQUESTED: reset PD controllers 0 (right) and 1 (left),
# NOT 2 (dGPU/back). Verify negotiation state after.
$Result = Join-Path $PSScriptRoot 'pdreset-all-result.txt'
Set-Content $Result "== PRE $(Get-Date -Format o)"
& framework_tool --pdports 2>&1 | Add-Content $Result
& framework_tool --power 2>&1 | Select-Object -First 8 | Add-Content $Result

Add-Content $Result "== RESET PD0 (right) $(Get-Date -Format o)"
& framework_tool --pd-reset 0 2>&1 | Add-Content $Result
Start-Sleep -Seconds 6
Add-Content $Result "== RESET PD1 (left) $(Get-Date -Format o)"
& framework_tool --pd-reset 1 2>&1 | Add-Content $Result
Start-Sleep -Seconds 15

Add-Content $Result "== POST $(Get-Date -Format o)"
& framework_tool --pd-info 2>&1 | Add-Content $Result
& framework_tool --pdports 2>&1 | Add-Content $Result
& framework_tool --power 2>&1 | Select-Object -First 8 | Add-Content $Result
Add-Content $Result 'POST port3 raw (0x3E23):'
& framework_tool --host-command 0x3E23 0 3 2>&1 | Add-Content $Result
Add-Content $Result "done $(Get-Date -Format o)"
