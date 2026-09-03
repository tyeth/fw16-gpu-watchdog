# GPU/Power watchdog logger — samples power + perf telemetry every 5s.
# Designed to capture the "PC goes super slow but keeps working" incidents:
# suspected EC/power-delivery hard-throttle triggered by AC power flaps under
# combined dGPU+iGPU load (see event log: Kernel-Power 105 immediately before
# each crash, Win32k 700 input suppression, battery-count-change mid-session).
#
# Runs fine unelevated, but framework_tool EC readouts (charger/PD/thermal)
# only work when elevated — the scheduled task runs it with highest privileges.

$ErrorActionPreference = 'Continue'
$LogDir = Join-Path $PSScriptRoot 'logs'
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

$IntervalSec = 5
$FrameworkEverySec = 15          # framework_tool fast cadence (power/thermal/PD)
$FrameworkSlowEverySec = 60      # slow cadence (smartbattery, expansion bay, EC console)
$RetentionDays = 14

$IsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Get-CsvPath { Join-Path $LogDir ("watchdog-{0}.csv" -f (Get-Date -Format 'yyyyMMdd')) }
function Get-FwPath  { Join-Path $LogDir ("framework-{0}.log" -f (Get-Date -Format 'yyyyMMdd')) }
function Get-EcPath  { Join-Path $LogDir ("ec-console-{0}.log" -f (Get-Date -Format 'yyyyMMdd')) }

$CsvHeader = 'timestamp,loop_lag_ms,ac_online,charging,discharging,charge_rate_mW,discharge_rate_mW,remaining_mWh,batt_mV,cpu_pct_max_freq,cpu_perf_pct,cpu_utility_pct,mem_avail_mb,nv_pstate,nv_temp_c,nv_util_pct,nv_power_w,nv_sm_mhz,nv_throttle_reasons'

# one-time environment snapshot
$startupNote = @(
    "=== logger start $(Get-Date -Format o) elevated=$IsElevated pid=$PID ==="
)
if ($IsElevated) {
    try { $startupNote += (& framework_tool --versions 2>&1) } catch { $startupNote += "framework_tool --versions failed: $_" }
}
Add-Content -Path (Get-FwPath) -Value $startupNote

$lastFw = [datetime]::MinValue
$lastFwSlow = [datetime]::MinValue
$prevLoopEnd = Get-Date

while ($true) {
    $loopStart = Get-Date
    # loop lag: how much longer than $IntervalSec the previous cycle took.
    # When the incident hits, this itself spikes — a signature in the data.
    $lagMs = [int](($loopStart - $prevLoopEnd).TotalMilliseconds - ($IntervalSec * 1000))
    if ($lagMs -lt 0) { $lagMs = 0 }

    $ts = $loopStart.ToString('yyyy-MM-dd HH:mm:ss.fff')

    # --- battery / AC (root\wmi BatteryStatus) ---
    $ac=''; $chg=''; $dis=''; $crate=''; $drate=''; $remain=''; $bmv=''
    try {
        $b = Get-CimInstance -Namespace root/wmi -ClassName BatteryStatus -ErrorAction Stop | Select-Object -First 1
        $ac = [int]$b.PowerOnline; $chg = [int]$b.Charging; $dis = [int]$b.Discharging
        $crate = $b.ChargeRate; $drate = $b.DischargeRate
        $remain = $b.RemainingCapacity; $bmv = $b.Voltage
    } catch {}

    # --- CPU freq/perf + memory (single Get-Counter call) ---
    $pctMax=''; $perf=''; $util=''; $memMb=''
    try {
        $c = Get-Counter -Counter @(
            '\Processor Information(_Total)\% of Maximum Frequency',
            '\Processor Information(_Total)\% Processor Performance',
            '\Processor Information(_Total)\% Processor Utility',
            '\Memory\Available MBytes'
        ) -ErrorAction Stop
        $s = $c.CounterSamples
        $pctMax = [math]::Round(($s | Where-Object Path -like '*maximum frequency*').CookedValue, 1)
        $perf   = [math]::Round(($s | Where-Object Path -like '*processor performance*').CookedValue, 1)
        $util   = [math]::Round(($s | Where-Object Path -like '*processor utility*').CookedValue, 1)
        $memMb  = [int]($s | Where-Object Path -like '*available mbytes*').CookedValue
    } catch {}

    # --- NVIDIA dGPU ---
    $nv = ''
    try {
        $nv = (& nvidia-smi --query-gpu=pstate,temperature.gpu,utilization.gpu,power.draw,clocks.sm,clocks_event_reasons.active --format=csv,noheader,nounits 2>$null | Select-Object -First 1)
    } catch {}
    if (-not $nv) { $nv = ',,,,,' } else { $nv = ($nv -replace '\s','') }

    $csv = Get-CsvPath
    if (-not (Test-Path $csv)) { Set-Content -Path $csv -Value $CsvHeader }
    Add-Content -Path $csv -Value "$ts,$lagMs,$ac,$chg,$dis,$crate,$drate,$remain,$bmv,$pctMax,$perf,$util,$memMb,$nv"

    # --- framework_tool EC snapshot (elevated only; read-only queries) ---
    if ($IsElevated -and (($loopStart - $lastFw).TotalSeconds -ge $FrameworkEverySec)) {
        $lastFw = $loopStart
        try {
            $fw = @("--- $ts ---")
            $fw += (& framework_tool --power -vv 2>&1)
            $fw += (& framework_tool --thermal 2>&1)
            $fw += (& framework_tool --pdports 2>&1)
            # Raw EC host commands (read-only status queries):
            # 0x3E22 GET_AP_THROTTLE_STATUS - soft/hard throttle source bitmasks
            #   (bit1 = safety-ladder battery-discharge clamp, bit4 = EPR-transition
            #    PROCHOT; see EmbeddedController include/throttle_ap.h)
            # 0x3E23 GET_PD_PORT_STATE port 4 - the rear charge port's PD contract
            #   (--pdports only covers ports 0-3, so this is our only view of it)
            $fw += 'AP_THROTTLE_STATUS (0x3E22):'
            $fw += (& framework_tool --host-command 0x3E22 0 2>&1)
            $fw += 'PD_PORT_STATE port4 (0x3E23):'
            $fw += (& framework_tool --host-command 0x3E23 0 4 2>&1)
            # 0x3E18 GET_ACTIVE_CHARGE_PD_CHIP (which controller the EC charges
            # from), 0x3E1C GET_HW_DIAG (diag bitmask: GPU module fault, PGOOD)
            $fw += 'ACTIVE_CHARGE_PD_CHIP (0x3E18):'
            $fw += (& framework_tool --host-command 0x3E18 0 2>&1)
            $fw += 'HW_DIAG (0x3E1C):'
            $fw += (& framework_tool --host-command 0x3E1C 0 2>&1)
            # The literal PROCHOT wire to the APU, active-low (0 = asserted).
            $fw += 'GPIO h_prochot_l:'
            $fw += (& framework_tool --get-gpio h_prochot_l 2>&1)
            Add-Content -Path (Get-FwPath) -Value $fw
        } catch {
            Add-Content -Path (Get-FwPath) -Value "--- $ts --- framework_tool failed: $_"
        }

        # slow-cadence extras: dGPU bay status, full GPIO dump (PROCHOT, power
        # goods, OC lines), EC uptime (anchors EC timestamps to wall clock),
        # charge-limit state. EC console is now streamed continuously by the
        # GpuEcConsoleFollow task (ec-follow.ps1) — do NOT call --console
        # recent here, it corrupts the follower's shared snapshot cursor.
        if (($loopStart - $lastFwSlow).TotalSeconds -ge $FrameworkSlowEverySec) {
            $lastFwSlow = $loopStart
            try {
                # NOTE: never call --smartbattery here — it prompts for an
                # unseal key and hangs forever without a console/stdin.
                $fw2 = @("--- $ts (slow) ---")
                $fw2 += (& framework_tool --expansion-bay 2>&1)
                $fw2 += (& framework_tool --uptimeinfo 2>&1)
                $fw2 += (& framework_tool --charge-limit 2>&1)
                $fw2 += 'GPIO dump:'
                $fw2 += (& framework_tool --get-gpio 2>&1)
                Add-Content -Path (Get-FwPath) -Value $fw2
            } catch {
                Add-Content -Path (Get-FwPath) -Value "--- $ts --- framework_tool slow-cadence failed: $_"
            }
        }
    }

    # --- housekeeping: purge old logs once/day (cheap check) ---
    if ($loopStart.Hour -eq 12 -and $loopStart.Minute -eq 0 -and $loopStart.Second -lt $IntervalSec) {
        Get-ChildItem $LogDir -File | Where-Object LastWriteTime -lt (Get-Date).AddDays(-$RetentionDays) | Remove-Item -Force -ErrorAction SilentlyContinue
    }

    $prevLoopEnd = Get-Date
    $sleepMs = ($IntervalSec * 1000) - ($prevLoopEnd - $loopStart).TotalMilliseconds
    if ($sleepMs -gt 0) { Start-Sleep -Milliseconds $sleepMs }
}
