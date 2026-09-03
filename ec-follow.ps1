# Continuous EC console capture via `framework_tool --console follow`.
# Runs as its own scheduled task (GpuEcConsoleFollow, elevated).
# The follower exits on any EC command error (likely mid-incident), so wrap in
# a restart loop and stamp exits — a gap+restart in this log is itself signal.
# NOTE: while this runs, nothing else may use --console recent (shared cursor).

$ErrorActionPreference = 'Continue'
$LogDir = Join-Path $PSScriptRoot 'logs'
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

while ($true) {
    $f = Join-Path $LogDir ("ec-follow-{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
    Add-Content -Path $f -Value "=== follow start $(Get-Date -Format o) ==="
    & framework_tool --console follow 2>&1 | ForEach-Object {
        Add-Content -Path $f -Value $_
    }
    Add-Content -Path $f -Value "=== follow exited $(Get-Date -Format o) ==="
    Start-Sleep -Seconds 5
}
