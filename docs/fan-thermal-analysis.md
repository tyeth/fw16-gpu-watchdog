# Framework 16 (Ryzen AI 300 + RTX 5070) — fan control & APU thermal analysis

*2026-09-03. All findings verified against EC firmware source (branch
`fwk-tulip-29169` of [FrameworkComputer/EmbeddedController](https://github.com/FrameworkComputer/EmbeddedController)),
the GPU module's EEPROM descriptor dumped from this machine
([gpu-descriptor.bin](../gpu-descriptor.bin)), live EC queries,
and a forced-duty fan test.*

## The user observation that started this

> The APU is usually running too hot (according to `--thermal`). It sits at
> 85–91°C during gaming with the fans audibly not maxed, and even at light
> load the die reads in the 60s–70s while fans sit near 30%.

That observation is **correct, and it is by design** — the numbers below show
exactly why, and why it is not a control-loop bug.

## How the auto fan control actually works

`board_override_fan_control()` in
[`lotus/src/thermal.c`](https://github.com/FrameworkComputer/EmbeddedController/blob/fwk-tulip-29169/zephyr/program/framework/lotus/src/thermal.c)
(shared by the AI 300 "tulip" board). There is **no PID and no fan table** —
each input maps linearly to a fan percentage between its `fan_off` and
`fan_max` temperatures (`pct = 100·(T−off)/(max−off)`, clamped 0–100), and the
final command is simply the **max** of the inputs:

| # | Input | 0% fan at | 100% fan at | Filtering | Source of thresholds |
|---|-------|-----------|-------------|-----------|----------------------|
| 1 | APU board sensor `apu_f75303` | **47°C** | **62°C** | none (raw) | **GPU module EEPROM** (`0d 05 02 4001 4f01` = idx 2, 320K→335K); devicetree default was 45→60°C |
| 2 | APU die (SB-TSI `cpu@4c`) | 50°C | **97°C** | biquad low-pass | `lotus/overlay.dtsi` |
| 3 | GPU VR sensor `gpu_vr_f75303` | 50°C | 74°C | none | `dsc_nv_temp_gpu_table` (thermal.c) |
| 4 | GPU die (NV GN22) | 50°C | 80°C | biquad low-pass | `dsc_nv_temp_gpu_die_table` (thermal.c) |

RPM mapping: `rpm ≈ min + pct·(max−min)`, where min/start/max come from the
**GPU module EEPROM descriptor** when a module is installed:

| Fan | min/start | max (auto ceiling) | Hardware capability |
|-----|-----------|--------------------|---------------------|
| Left (fan0) | 1000 | **4700** (EEPROM `5C 12`) | ~7600 RPM (80% duty measured **6105 RPM**) |
| Right (fan1) | 1000 | **4500** (EEPROM `94 11`) | ~7600 RPM |

Plus: 5s stop-delay, 0.5°C off-hysteresis, and a start-kick to `rpm_start`.
The die inputs are heavily smoothed (deliberate anti-oscillation), which is
why the fan ignores the die bouncing 54→74°C over seconds.

### Live verification

- Idle-ish state: `apu_f75303` = 56°C → input 1 gives (56−47)/15 = **60%**;
  die 63°C → input 2 gives 28%; GPU cold → 0%. Predicted ≈ 3100/3000 RPM,
  observed **3081/2987 RPM**. Model matches measurement.
- Gaming (Battlefield): fans pinned at 4703/4551 RPM (= the EEPROM ceiling)
  with APU die at **91°C**. The controller was saturated, not lazy.

### Which sensor actually asserted `thermal WARN` (corrected 2026-09-03)

The 21:44:54 `thermal WARN` → soft AP throttle → PMF power-limit application
was tripped by **`gpu_vr_f75303` crossing the NVIDIA GPU table's 71°C warn
threshold** (it rose 55→65°C in the preceding 30s, crossed ~71°C at the WARN
timestamp, climbed to 81°C, and never fell below the 60°C release — the soft
thermal throttle stayed asserted for the remaining ~17 minutes until the
freeze). The APU die (82°C at that moment, warn threshold 105°C) tripped
nothing — die peakiness is irrelevant here since the tripping sensors are
slow thermal-mass board sensors. By 21:59 **chassis ambient (`ambient_f75303`)
reached 87°C**, its own warn threshold. In other words: the overtemp
assertions were real, system-level measurements — a VR sensor 10°C past its
warn point and near-90°C air inside the chassis — while 40% of fan capacity
sat unused. (Beware the label bug below when reading the raw logs: `gpu_vr`
prints as "dGPU VRAM" and `ambient` prints as "F75303_Local".)

## Why the APU "reads too hot most of the time"

Three compounding design choices:

1. **The auto-control ceiling wastes ~35–40% of fan capacity.** The RTX 5070
   module's descriptor caps thermal control at 4700/4500 RPM while the fans
   demonstrably run 6100+ at 80% duty. Full thermal demand never gets full
   airflow.
2. **The die band runs to 97°C.** The only input that tracks the die maps
   91°C to just 87% — the firmware is *content* with a 90°C+ die.
3. **The board-sensor band saturates early and low.** `apu_f75303` hits 100%
   at 62°C, so under sustained load it saturates and stops adding pressure;
   past that point only the slow filtered die input matters, and it asks for
   less than the board sensor already did.

Net effect: at heavy combined load the system crosses real board-sensor warn
thresholds (GPU VR at 71°C within minutes of the fans saturating, chassis
ambient climbing monotonically to 87°C — exactly its own warn threshold —
with the NVIDIA driver itself thermal-throttling from 21:59) and holds a soft
thermal throttle asserted indefinitely, rather than spend the fan headroom
that exists in hardware.

*(Correction, after cross-examination by the Fable 5.1 fork: an earlier
revision claimed the sustained throttle implied continuous SB-RMI mailbox
traffic. That was wrong — `set_pl_limits` fires on change, the 45W clamp was
written once, successfully, and zero SB-RMI errors occurred during the WARN
window. The structural risk is narrower: any future limit *change or release*
depends on that mailbox. Likewise, battery-assist discharge in this incident
peaked at ~4.6W ≈ 0.26A — ~20× below the 5.49A safety-ladder threshold — so
the EPR/safety-ladder mechanism was NOT demonstrated by the 2026-09-03 stall;
it remains the leading theory only for the earlier power-event-preceded
reboots. See the fork's Round 2 section for the full incident re-classification.)*

Related bug found on the way: **framework_tool v0.6.5 mislabels the FW16
sensors** (verified via `EC_CMD_TEMP_SENSOR_GET_INFO` 0x0070): the line
printed as `F75303_CPU` is really the **charger** sensor, `F75303_DDR` is
really the **APU board sensor**, and the three dGPU F75303 labels are shifted
by one (VR→ambient, VRAM→VR, AMB→VRAM). `APU` (id 3) is genuinely the die.

## Suggested fixes (measured viewpoint)

Ranked by value ÷ risk:

1. **Framework-side (file with the evidence in this repo):** raise the
   descriptor fan ceilings toward hardware capability (e.g. 4700→6000+) *or*
   honor a user fan-curve override in EC; widen the die band's influence
   (e.g. fan_max 97→85°C) so the die actually drives airflow before PMF
   starts cutting power. The descriptor is Framework-signed data on the
   module EEPROM — this is a one-line tuning change for them.
2. **Report the framework_tool FW16 label bug** (framework-system repo) —
   trivial fix, and it actively misleads thermal debugging.
3. **User-space assist (no firmware changes, reversible):** a small service
   that watches the die temp and applies `--fansetduty` above a threshold
   (e.g. die >80°C → duty 80%), returning to `--autofanctrl` below it with
   hysteresis. Must fail safe: any exit path restores auto (the pattern
   already proven by `too_hot.ps1`). Trade-off: noise, and it fights nothing
   — the EC accepts manual duty and keeps its own safety thresholds.
4. **PMF/Windows power-slider tuning:** the 45W SPL clamp arrives via AMD PMF
   when thermal WARN trips; "Best performance" slider + PMF policy affects
   STT limits. Worth measuring, limited upside.
5. **Physical:** repaste / pad check only if per-sensor deltas suggest poor
   transfer (board sensor 87°C with die 91°C actually suggests the heat *is*
   spreading — the limit is airflow, not contact).
6. **Not recommended without Framework guidance:** flashing a modified GPU
   descriptor (`--flash-gpu-descriptor-file`) to raise the fan caps. It's
   *technically* the direct fix and the tool exists, but it writes the
   module's EEPROM — see the Fable 5.1 counter-viewpoint document
   ([fan-thermal-fixes-fable51-viewpoint.md](fan-thermal-fixes-fable51-viewpoint.md))
   for the aggressive version of this argument.

## Relationship to the crash investigation

This thermal behavior is the *backdrop* to the separate EPR/PROCHOT crash
documented in [../README.md](../README.md): running
at the thermal edge keeps the machine in battery-assist (AC + battery
simultaneously) under load, which is precisely the regime where the EC's EPR
renegotiation + safety-ladder code can latch a system-wide PROCHOT that
survives reboot. Cooler operation = less battery assist = less exposure to
the crash path, independent of the firmware fix.
