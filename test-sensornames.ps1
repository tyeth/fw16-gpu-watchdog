# Elevated: EC_CMD_TEMP_SENSOR_GET_INFO (0x0070) for ids 0..9 -
# returns the EC's own name string per sensor index; settles memmap order.
$Result = Join-Path $PSScriptRoot 'test-sensornames-result.txt'
Set-Content $Result "probe start $(Get-Date -Format o)"
for ($i = 0; $i -lt 10; $i++) {
    $out = (& framework_tool --host-command 0x0070 0 $i 2>&1 | Out-String).Trim()
    Add-Content $Result ("== id {0} ==`n{1}" -f $i, $out)
}
Add-Content $Result 'probe done'
