# GPU/Power Watchdog — Framework Laptop 16

Also in this repo:
- [docs/fan-thermal-analysis.md](docs/fan-thermal-analysis.md) — fan control
  algorithm (verified from EC source + live tests), why the APU reads hot by
  design, suggested fixes.
- [docs/fan-thermal-fixes-fable51-viewpoint.md](docs/fan-thermal-fixes-fable51-viewpoint.md)
  — aggressively different viewpoint / fix ranking from a forked
  Claude Fable 5.1 agent.
- [agents/memories/](agents/memories/) — the assistant's persistent memory
  for this investigation.
- [incidents/20260903-221003/](incidents/20260903-221003/) — full capture of
  the 2026-09-03 22:01:33 incident.

Diagnoses the "whole PC goes super slow but keeps working" incidents that hit
while finishing a Battlefield match with a video playing on the other monitor.

## What the event logs already showed (why this focuses on power, not GPU)

5 forced resets in the last 30 days (Kernel-Power 41): 06/08 13:35, 22/08 21:29,
28/08 10:59, 31/08 00:05, 03/09 ~00:40–01:05.

- **03/09 incident**: EA AntiCheat died 00:34:55 → **two "Power source change"
  events 00:35:19/00:35:24** → slow state; a shutdown attempt at 00:40 hung for
  25+ min → forced reset. Mid-slowdown at 00:43:35: **"Active battery count
  change"** (battery dropped off the bus).
- **31/08 incident**: power source changes 23:34/23:42/00:03 → 00:05:13
  **Win32k 700 "Power Manager has requested suppression of all input"** ×2 →
  crash 00:05:38.
- **No display/TDR errors at all** in 30 days (one nvlddmkm 153 on 17/08).

Working hypothesis: under combined dGPU+iGPU+CPU load the power delivery flaps
(adapter PD renegotiation and/or battery BMS hiccup), the EC asserts hard
throttle (PROCHOT-style, CPU stuck at minimum clocks) and never releases it.

## What's running

Scheduled task **GpuPowerWatchdog** (elevated, hidden, at logon, restarts on
failure, keeps running on battery). Runs `logger.ps1`:

- every 5s → `logs/watchdog-YYYYMMDD.csv`:
  loop lag (detects slowdown itself), AC online, charge/discharge rate, battery
  voltage, CPU **% of max frequency** (the throttle signature), processor
  perf/utility, free RAM, NVIDIA pstate/temp/util/power/SM clock/**throttle
  reason flags** (`clocks_event_reasons.active` bitmask — 0x4 = idle, look for
  HW slowdown 0x8/0x40/0x80 and SW power cap 0x4, thermal 0x20/0x60).
- every 15s → `logs/framework-YYYYMMDD.log`: raw `framework_tool --power -vv`
  (verbose: charger V/A, input current, SoC, LFCC), `--thermal` (EC temps, fan
  RPM) and `--pdports` (per-USB-C-port PD contract/role/negotiated power —
  directly shows PD renegotiation flaps).
- every 60s → same log: `--expansion-bay` (dGPU module bay status/fault flag);
  and `logs/ec-console-YYYYMMDD.log`: the EC's own console ring buffer
  (`--console recent`) — already showing `SB-SMI: Mailbox transfer timeout` /
  `SB-RMI Error: 4` entries in normal operation, worth correlating at incident
  time. Read-only queries only; the tool never changes any EC settings.
  (`--smartbattery` must NOT be used in the logger: it prompts for an unseal
  key and hangs a hidden task; the collector pipes it empty stdin instead.)
- 14-day retention; also enabled the Kernel-Power Thermal-Operational event
  channel and bumped the System log to 64MB.

## Root-cause theory (from EC source, branch fwk-tulip-29169)

Charger is 240W EPR on rear port P4 (dGPU module; invisible to `--pdports`).
EPR enter/exit deliberately sets input current 0 + hard PROCHOT while
renegotiating; a failed flow latches the port ("EPR fail, do not retry",
`cypd_ccg8.c`) at ≤100W → battery discharge exceeds the −5.49A safety limit →
safety ladder ratchets to LEVEL_PROCHOT (hard GPIO, clamps BIOS too). All EC
RAM state — survives reboot, only unwinds on physical AC replug. Matches
SoftwareFirmwareIssueTracker #243 and #193.

Now logged every 15s (raw hex in framework-*.log):
- `0x3E22 GET_AP_THROTTLE_STATUS` — throttle source bitmasks. All zeros =
  healthy. Non-zero hard mask during an incident names the mechanism:
  bit0 THERMAL, bit1 BAT_DISCHG_CURRENT (safety ladder), bit2 BAT_VOLTAGE,
  bit3 AC, bit4 UPDATE_PMF (EPR transition).
- `0x3E23 port 4` — charge-port PD contract; healthy = `80bb 8813` at offset 8
  (48000mV, 5000mA = 240W EPR). Watch for it dropping to SPR values.

## Fan control (verified against source + live tests, 2026-09-03)

Algorithm (`lotus/src/thermal.c board_override_fan_control`, no PID): each
input maps linearly to a fan % between its fan_off and fan_max temps; final %
= max of inputs; both die temps are biquad low-pass filtered. With the RTX
5070 module installed, its EEPROM descriptor (dumped: gpu-descriptor.bin)
overrides:
- fan ceiling: **max 4700/4500 RPM** (min/start 1000) — yet 80% forced duty =
  6105 RPM, so hardware 100% ≈ 7600. Auto control never uses the top ~35-40%%
  of fan capacity; during gaming the fans pin at 4700 while the APU sits 91°C.
- APU board-sensor band: 47°C -> 0%%, 62°C -> 100%% (EEPROM block
  `0d 05 02 4001 4f01`; DT default was 45-60).
Other bands: APU die (filtered) 50->97°C, GPU VR 50->74°C, GPU die (filtered)
50->80°C. Verified live: apu_f75303 56°C -> predicted 57-60%% -> observed
3081/2987 RPM. Working as designed; the design just tolerates high APU temps.

**framework_tool 0.6.5 label bug (FW16):** sensor order confirmed via host-cmd
0x0070: id0 ambient, id1 charger, id2 apu_f75303, id3 cpu die, id4 gpu_amb,
id5 gpu_vr, id6 gpu_vram, id7 gpu_die. The tool prints id1 as "F75303_CPU"
(really charger), id2 as "F75303_DDR" (really APU board sensor), and shifts
the three dGPU F75303 labels by one. "APU" (id3) is the die — correct.

## Next time it happens

1. If at all possible, note the clock time it started (even roughly).
2. Let it sit in the slow state for a minute or two so the logger (which will
   also be running slow) catches a few samples.
3. Force reset as usual.
4. After reboot run:

   ```powershell
   powershell -ExecutionPolicy Bypass -File C:\Users\tyeth\Downloads\gh_madness\gpu-watchdog\collect-incident.ps1
   ```

   (elevated gets you the powercfg power report too), then bring the
   `incidents\<timestamp>\` folder to a Claude session for analysis.

## Managing it

- Stop:   `schtasks /End /TN GpuPowerWatchdog` (elevated)
- Remove: `Unregister-ScheduledTask -TaskName GpuPowerWatchdog` (elevated)
- Re-setup: run `setup-watchdog.ps1` elevated.

## Things worth trying independently of the logging

- Different / higher-wattage USB-C PSU or different port for the next sessions
  — if incidents stop, that's the answer.
- Framework BIOS/EC updates mention charger-flap throttle fixes in some
  releases; current: BIOS 04.01, EC tulip-4.0.1 (see framework log header).
