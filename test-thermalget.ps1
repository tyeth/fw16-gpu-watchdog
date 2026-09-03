# Elevated: read LIVE thermal config for each sensor via EC_CMD_THERMAL_GET_THRESHOLD (0x0053) v1.
# Request: uint32 sensor_num. Response: struct ec_thermal_config
#   uint32 temp_host[3] (warn/high/halt, Kelvin), temp_host_release[3], temp_fan_off, temp_fan_max.
$Result = Join-Path $PSScriptRoot 'test-thermalget-result.txt'
Set-Content $Result "probe start $(Get-Date -Format o)"
$names = @('0 ambient_f75303','1 charger_f75303','2 apu_f75303','3 apu_die','4 gpu_amb','5 gpu_vr','6 gpu_vram','7 gpu_die')
for ($i = 0; $i -lt 8; $i++) {
    $out = (& framework_tool --host-command 0x0053 1 $i 0 0 0 2>&1 | Out-String).Trim()
    Add-Content $Result ("== sensor {0} ==`n{1}" -f $names[$i], $out)
}
# Dump the GPU module's EEPROM descriptor (read-only) - holds the fan
# min/start/max the EC actually uses while the module is installed.
$desc = Join-Path $PSScriptRoot 'gpu-descriptor.bin'
$out = (& framework_tool --dump-gpu-descriptor-file $desc 2>&1 | Out-String).Trim()
Add-Content $Result ("== gpu descriptor dump ==`n{0}" -f $out)
Add-Content $Result 'probe done'
