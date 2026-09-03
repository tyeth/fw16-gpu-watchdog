# Run this AFTER rebooting from an incident (forced reset).
# Gathers everything needed for analysis into gpu-watchdog\incidents\<timestamp>\
# Works unelevated; grabs extra power reports if elevated.

$ErrorActionPreference = 'Continue'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$out = Join-Path $PSScriptRoot "incidents\$stamp"
New-Item -ItemType Directory -Path $out -Force | Out-Null
Write-Output "Collecting into $out ..."

# Watchdog CSVs + framework logs from the last 3 days
Get-ChildItem (Join-Path $PSScriptRoot 'logs') -File -ErrorAction SilentlyContinue |
    Where-Object LastWriteTime -gt (Get-Date).AddDays(-3) |
    Copy-Item -Destination $out

# Event logs (last 48h, XML export for full detail)
$since = (Get-Date).AddHours(-48).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.000Z')
wevtutil qe System  /q:"*[System[TimeCreated[@SystemTime>='$since']]]" /f:xml > (Join-Path $out 'system-48h.xml')
wevtutil qe Application /q:"*[System[TimeCreated[@SystemTime>='$since']]]" /f:xml > (Join-Path $out 'application-48h.xml')
foreach ($ch in @('Microsoft-Windows-Kernel-Power/Thermal-Operational','Microsoft-Windows-Thermal-Polite/Operational')) {
    $safe = ($ch -replace '[/\\]','-') + '.xml'
    wevtutil qe $ch /q:"*[System[TimeCreated[@SystemTime>='$since']]]" /f:xml 2>$null > (Join-Path $out $safe)
}

# Quick timeline of the interesting events for eyeballing
powershell -NoProfile -Command {
    Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=(Get-Date).AddHours(-48)} -ErrorAction SilentlyContinue |
    Where-Object { $_.Level -le 3 -or $_.Id -in 41,105,521,700,4101,4113,6008 -or $_.ProviderName -match 'nvlddmkm|amdkmdag|WHEA|Thermal' } |
    Sort-Object TimeCreated |
    Select-Object TimeCreated, ProviderName, Id, LevelDisplayName, @{n='Msg';e={($_.Message -replace "`r`n",' ')}} |
    Format-Table -Wrap -AutoSize | Out-String -Width 300
} | Out-File (Join-Path $out 'timeline-48h.txt') -Encoding utf8

# System snapshot
dxdiag /whql:off /t (Join-Path $out 'dxdiag.txt')

$IsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($IsElevated) {
    powercfg /systempowerreport /output (Join-Path $out 'power-report.html') 2>$null
    powercfg /sleepstudy /output (Join-Path $out 'sleepstudy.html') 2>$null
    # NOTE: --smartbattery is deliberately absent — it insists on reading an
    # unseal key from a real console (fails/hangs with redirected stdin).
    & framework_tool --versions 2>&1 | Out-File (Join-Path $out 'framework-versions.txt') -Encoding utf8
    & framework_tool --power -vv 2>&1 | Out-File (Join-Path $out 'framework-versions.txt') -Encoding utf8 -Append
    & framework_tool --pd-info 2>&1 | Out-File (Join-Path $out 'pd-info.txt') -Encoding utf8
    & framework_tool --pdports 2>&1 | Out-File (Join-Path $out 'pd-info.txt') -Encoding utf8 -Append
    & framework_tool --console recent 2>&1 | Out-File (Join-Path $out 'ec-console.txt') -Encoding utf8
}

# dxdiag runs async; give it a moment
Start-Sleep -Seconds 15
Write-Output "Done. Contents:"
Get-ChildItem $out | Select-Object Name, Length | Format-Table -AutoSize
