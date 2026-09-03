# Elevated: exhaustive read-only state capture of the live PD wedge before
# power removal destroys it. Avoids --smartbattery (hangs) and --console
# recent (corrupts the follower's cursor; follower is already streaming).
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$out = Join-Path $PSScriptRoot "wedge-state-$stamp"
New-Item -ItemType Directory -Path $out -Force | Out-Null
function Cap($name, $args2) {
    $f = Join-Path $out "$name.txt"
    "== framework_tool $($args2 -join ' ') @ $(Get-Date -Format o)" | Set-Content $f
    & framework_tool @args2 2>&1 | Add-Content $f
}
Cap 'versions'      @('--versions')
Cap 'power-vv'      @('--power','-vv')
Cap 'pd-info'       @('--pd-info')
Cap 'pdports'       @('--pdports')
Cap 'thermal'       @('--thermal')
Cap 'expansion-bay' @('--expansion-bay')
Cap 'uptimeinfo'    @('--uptimeinfo')
Cap 'charge-limit'  @('--charge-limit')
Cap 'gpio-all'      @('--get-gpio')
Cap 'intrusion'     @('--intrusion')
Cap 'inputdeck'     @('--inputdeck')
Cap 'nvidia'        @('--nvidia')
# host commands: throttle, port states 0-4, active charge chip, hw diag, cutoff
Cap 'hc-3E22-throttle'   @('--host-command','0x3E22','0')
0..4 | ForEach-Object { Cap "hc-3E23-port$_" @('--host-command','0x3E23','0',"$_") }
Cap 'hc-3E18-chargechip' @('--host-command','0x3E18','0')
Cap 'hc-3E1C-hwdiag'     @('--host-command','0x3E1C','0')
Cap 'hc-3E21-cutoff'     @('--host-command','0x3E21','0')
# standard EC memmap 0x00-0xFF in 4 chunks (EC_CMD_READ_MEMMAP 0x0007)
Cap 'memmap-00' @('--host-command','0x0007','0','0x00','0x3F')
Cap 'memmap-40' @('--host-command','0x0007','0','0x40','0x3F')
Cap 'memmap-80' @('--host-command','0x0007','0','0x80','0x3F')
Cap 'memmap-C0' @('--host-command','0x0007','0','0xC0','0x3F')
# Windows-side UCSI/battery view
$f = Join-Path $out 'windows-side.txt'
"== windows @ $(Get-Date -Format o)" | Set-Content $f
Get-PnpDevice | Where-Object FriendlyName -match 'UCSI|USB4|Type-C' | Format-Table Status,FriendlyName,InstanceId -AutoSize | Out-String -Width 200 | Add-Content $f
Get-CimInstance Win32_Battery | Format-List * | Out-String | Add-Content $f
Get-CimInstance -Namespace root/wmi -ClassName BatteryStatus | Format-List | Out-String | Add-Content $f
powercfg /batteryreport /output (Join-Path $out 'batteryreport.html') 2>&1 | Add-Content $f
"capture complete $(Get-Date -Format o)" | Add-Content $f
