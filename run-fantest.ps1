# Elevated wrapper: 1) sensor-name probe (settles memmap order),
# 2) user's too_hot.ps1 1 80 (forced 80% duty for 1 min, auto-restored).
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'test-sensornames.ps1')
& powershell -NoProfile -ExecutionPolicy Bypass -File "$HOME\too_hot.ps1" 1 80 *> (Join-Path $PSScriptRoot 'fantest-80pct.txt')
