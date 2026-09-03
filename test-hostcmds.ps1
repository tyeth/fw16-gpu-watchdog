# Elevated probe: raw EC host commands via framework_tool --host-command
# All read-only status queries (no EC state changes):
#   0x3E22 GET_AP_THROTTLE_STATUS  - soft/hard throttle source bitmasks
#   0x3E23 GET_PD_PORT_STATE       - per-port PD contract, incl. port 4 (charge port!)
$Result = Join-Path $PSScriptRoot 'test-hostcmds-result.txt'
Set-Content $Result "probe start $(Get-Date -Format o)"

$cmds = @(
    @{name='ap-throttle-status (0x3E22)'; args=@('--host-command','0x3E22','0')},
    @{name='pd-port-state p0 (0x3E23)';   args=@('--host-command','0x3E23','0','0')},
    @{name='pd-port-state p4 (0x3E23)';   args=@('--host-command','0x3E23','0','4')},
    @{name='charge-state get-state (0xA0)'; args=@('--host-command','0x00A0','0','0')}
)
foreach ($c in $cmds) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $job = Start-Job -ScriptBlock { param($a) & framework_tool @a 2>&1 | Out-String } -ArgumentList (,$c.args)
    if (Wait-Job $job -Timeout 15) {
        $out = (Receive-Job $job | Out-String).Trim()
        Add-Content $Result ("[OK  {0,5:n1}s] {1}`n{2}`n" -f $sw.Elapsed.TotalSeconds, $c.name, $out)
    } else {
        Stop-Job $job
        Add-Content $Result ("[HANG >15s] {0}" -f $c.name)
        Get-Process framework_tool -ErrorAction SilentlyContinue | Stop-Process -Force
    }
    Remove-Job $job -Force -ErrorAction SilentlyContinue
}
Add-Content $Result 'probe done'
