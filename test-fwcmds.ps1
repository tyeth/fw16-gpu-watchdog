# Elevated probe: which framework_tool read-only commands hang when run
# non-interactively? Each gets 15s via a job.
$Result = Join-Path $PSScriptRoot 'test-fwcmds-result.txt'
Set-Content $Result "probe start $(Get-Date -Format o)"

$cmds = @(
    @{name='power-vv';      args=@('--power','-vv')},
    @{name='smartbattery';  args=@('--smartbattery')},
    @{name='expansion-bay'; args=@('--expansion-bay')},
    @{name='console-recent';args=@('--console','recent')},
    @{name='pd-info';       args=@('--pd-info')}
)
foreach ($c in $cmds) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $job = Start-Job -ScriptBlock {
        param($a)
        & framework_tool @a 2>&1 | Out-String
    } -ArgumentList (,$c.args)
    if (Wait-Job $job -Timeout 15) {
        $out = Receive-Job $job
        Add-Content $Result ("[OK  {0,6:n1}s] {1}: {2} chars" -f $sw.Elapsed.TotalSeconds, $c.name, ($out|Out-String).Length)
        Add-Content $Result (($out | Out-String).Substring(0, [Math]::Min(400, ($out|Out-String).Length)))
    } else {
        Stop-Job $job
        Add-Content $Result ("[HANG >15s] {0}" -f $c.name)
        # kill any stray framework_tool
        Get-Process framework_tool -ErrorAction SilentlyContinue | Stop-Process -Force
    }
    Remove-Job $job -Force -ErrorAction SilentlyContinue
}
Add-Content $Result 'probe done'
