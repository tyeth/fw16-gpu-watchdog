# GPU-free heartbeat: NEVER touches the NVIDIA stack, GPU perf counters,
# or framework_tool. Discriminator for stalls: if the main logger (which
# calls nvidia-smi every cycle) freezes while this keeps ticking, the GPU
# driver stack is wedged; if both freeze, the stall is system-wide (EC/power).
$ErrorActionPreference = 'Continue'
$LogDir = Join-Path $PSScriptRoot 'logs'
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$IntervalSec = 5
$Header = 'timestamp,loop_lag_ms,cpu_pct_max_freq,cpu_perf_pct,ac_online,discharge_rate_mW,mem_avail_mb'
$prevEnd = Get-Date

while ($true) {
    $start = Get-Date
    $lag = [int](($start - $prevEnd).TotalMilliseconds - ($IntervalSec * 1000))
    if ($lag -lt 0) { $lag = 0 }
    $ts = $start.ToString('yyyy-MM-dd HH:mm:ss.fff')

    $pctMax=''; $perf=''; $memMb=''
    try {
        $s = (Get-Counter -Counter @(
            '\Processor Information(_Total)\% of Maximum Frequency',
            '\Processor Information(_Total)\% Processor Performance',
            '\Memory\Available MBytes') -ErrorAction Stop).CounterSamples
        $pctMax = [math]::Round(($s | Where-Object Path -like '*maximum frequency*').CookedValue, 1)
        $perf   = [math]::Round(($s | Where-Object Path -like '*processor performance*').CookedValue, 1)
        $memMb  = [int]($s | Where-Object Path -like '*available mbytes*').CookedValue
    } catch {}

    $ac=''; $drate=''
    try {
        $b = Get-CimInstance -Namespace root/wmi -ClassName BatteryStatus -ErrorAction Stop | Select-Object -First 1
        $ac = [int]$b.PowerOnline; $drate = $b.DischargeRate
    } catch {}

    $csv = Join-Path $LogDir ("heartbeat-{0}.csv" -f (Get-Date -Format 'yyyyMMdd'))
    if (-not (Test-Path $csv)) { Set-Content -Path $csv -Value $Header }
    Add-Content -Path $csv -Value "$ts,$lag,$pctMax,$perf,$ac,$drate,$memMb"

    $prevEnd = Get-Date
    $sleepMs = ($IntervalSec * 1000) - ($prevEnd - $start).TotalMilliseconds
    if ($sleepMs -gt 0) { Start-Sleep -Milliseconds $sleepMs }
}
