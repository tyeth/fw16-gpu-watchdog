# The Case Against the Mainline Story — and What I'd Actually Do

*Devil's-advocate viewpoint by **Claude Fable 5.1**, 2026-09-03. Written against
[../README.md](../README.md) and [fan-thermal-analysis.md](fan-thermal-analysis.md).
Same facts, different verdicts.
Nothing here was executed against hardware; all offsets/line numbers verified against
`gpu-descriptor.bin` and EC branch `fwk-tulip-29169`.*

---

## Part 1 — Where the mainline framing is wrong

### Thesis 1: The 4700 RPM "cap" is not a defect. It's the only validated operating point.

The mainline reads the EEPROM fan block as the EC "leaving 40% of fan capacity on the
table." Flip it around: the **mainboard devicetree** maxes the fans at **4000/3700 RPM**
(`lotus/fan.dtsi` lines 15/25). The RTX 5070 module's descriptor *raises* that to
4700/4500. The descriptor is an upgrade, not a cap — and 4700 at ~62% duty is almost
certainly the acoustic/vibration/bearing-life point Framework actually qualified for
long sessions. "80% duty measured 6105 RPM" proves the motor spins there; it proves
nothing about resonance, tach stability under load, dust loading, or bearing life at
7600 RPM × 4-hour gaming sessions. Momentary capability ≠ continuous rating. If you
want more airflow, take it deliberately (Part 2), but stop calling the stock number a bug.

### Thesis 2: "The APU reads too hot" is chasing the wrong variable.

A Ryzen AI 300 die soaking at 91°C under sustained combined load is *the SMU doing its
job*: STAPM/PMF deliberately converges near the thermal target and trades die temp for
performance. Die temp is a **controlled output**, not a health signal — Tjmax is 100°C
and HALT is 108°C (`thermal.c` line 334). What users can actually feel is **skin temp**,
and that is exactly what the descriptor's custom_temp block controls: the APU *board*
sensor band 47→62°C. During gaming that board sensor exceeds 62°C, demands 100%, and
pins the fans at 4700 — the max-of-sensors policy is already saturated by the skin
proxy, not the die. Doubling fan noise to move a SMU-regulated die from 91 to ~85°C is
a bad trade; if 91°C offends, lower the *power/thermal target* (PMF/tctl), don't shout
at the fans. The one legitimate gripe: the die band 50→97°C (`thermal.c` uses
thermal_params[TEMP_APU_DIE]) means the die alone never demands 100% until 97°C — but
per above, the board sensor gets there first anyway.

### Thesis 3: The crash root cause is more likely the SB-RMI link than the EPR state machine.

Mainline: EPR renegotiation fails → port latches ≤100W → discharge ratchets the safety
ladder → stuck LEVEL_PROCHOT. I say the EPR latch is the **trigger**, and the chronically
sick **EC→SMU SB-RMI mailbox** is the **disease**, for three code-level reasons:

1. **Every gentle rung of the safety ladder acts through SB-RMI.** LEVEL_TUNE_PLS and
   LEVEL_DISABLE_GPU (`cpu_power.c` lines 170–237) adjust SPL/SPPT/FPPT via
   `set_pl_limits()` → `sb_rmi_mailbox_xfer()` (`amd_cpu_power_interface.c` lines 39–112).
   If the mailbox times out — and `logs/ec-console-20260903.log` shows **32
   `SB-SMI: Mailbox transfer timeout` / `SB-RMI Error: 4` entries in one ordinary day**
   (`driver/sb_rmi.c` lines 336/414) — those rungs are silent no-ops. The battery keeps
   over-discharging, and the ladder falls through to the only SB-RMI-independent lever
   it has: the hard PROCHOT GPIO (`cpu_power.c` line 241). The ladder isn't vicious;
   it's *blind*, because its hands don't work.
2. **PROCHOT release is gated on a successful SB-RMI write.** The UPDATE_PMF prochot is
   deasserted via `clear_prochot()` only after `set_pl_limits()` returns success
   (`cpu_power.c` lines 576–592). A flaky mailbox during the incident turns a 5-second
   EPR blip into a latched crawl. (Mainline overstates one thing, by the way: there *is*
   a 3-second failsafe, `force_clear_pmf_prochot`, `cpu_power.c` line 291 — so the
   forever-stuck state is the ladder's `THROTTLE_SRC_BAT_DISCHG_CURRENT`, not the EPR
   PMF event. The 0x3E22 bitmask logging will settle this; bit1 vs bit4 is the whole
   argument. That logging is the best thing in the mainline plan.)
3. The EPR failure itself needs a cause. A PD contract that renegotiates fine for weeks
   and then fails mid-game smells like the same I2C/SMBus neighborhood misbehaving under
   load — an electrical/timing integrity problem, not a state-machine design problem.
   The no-retry latch (`cypd_ccg8.c` line 763, `epr_active = 0xff`, never refreshed
   again per `cypress_pd_common.c` lines 1207–1208 until `clear_port_state()` on
   physical replug) is genuinely bad *failure handling*, but it's the second domino.

Also: `input current 0 + PROCHOT` during EPR transition is **correct behavior** — you
cannot draw 240W through a contract gap. Don't fix that; fix the retry policy around it.

### Thesis 4: Stop letting the fan work masquerade as crash mitigation.

Every Kernel-Power 41 in the logs correlates with *power events* (source change,
battery-count change, input suppression), zero with thermal events, zero TDRs. The fan
cap and the 91°C die have **no causal path** to the crashes. The mainline analysis
closes with "cooler operation = less battery assist = less exposure to the crash path"
— a two-hop hypothesis with no supporting sample: the ladder trips on discharge
> 5.49A, which is a function of *total system draw vs. negotiated input power*, and
the PMF thermal clamp actually **reduces** draw when hot. If anything, a cooler,
unclamped machine pulls harder. Until a watchdog CSV shows battery assist scaling with
temperature, treat fan work as comfort engineering, not crash mitigation.

---

## Part 2 — Concrete fixes, mechanism first, ranked at the end

### F0. Take EPR off the table: charge via an SPR port/PSU — DO THIS TONIGHT

- **Mechanism:** 240W is EPR-only. A 100W (20V/5A SPR) charger, or the 240W brick on a
  side port that only negotiates SPR, never enters `enter_epr_mode()` at all — no input-
  current-0 windows, no latch, no ladder trigger from renegotiation. Bonus: it stops
  routing charging through the GPU module's CCG8S PD, which is also the crash-adjacent
  component.
- **Cost:** at ~180W sustained system draw, ~80W comes from battery; the 85Wh pack drains
  in ~1 hour of gaming, then the ladder bites *legitimately*. So: fine for diagnosis and
  evenings, not a forever fix. If incidents stop, Thesis 3 vs. mainline gets decided by data.
- **Risk:** zero. **Reversibility:** unplug/replug.

### F1. Lower the die target instead of raising the fans (PMF/tctl)

- **Mechanism:** the correct knob for "91°C bothers me" is the SMU's thermal target, not
  RPM. Options in descending cleanliness: Windows power slider "Balanced" (EC PMF tables
  are mode-indexed — see `update_thermal_power_limit(... EC_AC_BALANCED ...)`,
  `cpu_power.c` line 514); AMD Adrenalin per-game power tuning; `ryzenadj --tctl-temp=85`
  (support on Strix-class silicon must be verified first — if ryzenadj doesn't know the
  SMU, don't force it).
- **Effect:** die soaks at the new target, fans *drop below* 4700 because the board
  sensor cools too. A few percent performance, silence instead of noise.
- **Risk:** low. **Reversibility:** resets on reboot (ryzenadj) or a slider click.

### F2. Userspace closed-loop fan controller (`fansetduty`) — the honest overclock

- **Mechanism:** `framework_tool --fansetrpm` is clamped by the EC table
  (`fan_set_rpm_target`, `thermal.c` lines 99–103), but `--fansetduty` is raw. Loop:
  poll `--thermal` every 2s; map APU board sensor (the real saturating input, id2 —
  mind the 0.6.5 label bug) 47→62°C onto duty 15→80% (≈6100 RPM ceiling, deliberately
  not 100%); add die-temp override above 93°C → 90%; hysteresis 2°C.
- **Failsafe design (non-negotiable):** (a) `try/finally` → `--autofanctrl` on any exit;
  (b) a second scheduled watchdog task that runs `--autofanctrl` if the controller's
  heartbeat file is >30s stale; (c) note the EC's host-halt protections
  (`temp_host HALT` 105/100°C, `thermal.c` lines 320/362) stay armed regardless — worst
  case is a hot shutdown, not damage.
- **Risk:** medium-low (stuck-duty window bounded by the watchdog); unknown bearing-life
  cost at >4700 sustained — you are now the qualification lab. **Reversibility:** kill
  the task; EC auto control returns.

### F3. Patch the GPU descriptor EEPROM — surgical, persistent, and the scariest failure mode

Verified against `gpu-watchdog/gpu-descriptor.bin` (201 bytes; both stored CRCs
reproduced exactly, so the layout below is certain):

| Offset | Bytes now | Meaning | Aggressive value |
|---|---|---|---|
| 0x3D–0x3E | `5C 12` | fan0 max_rpm = 4700 | `A8 16` = 5800 (~76% duty; not 7600) |
| 0x4B–0x4C | `94 11` | fan1 max_rpm = 4500 | `FC 15` = 5628 (keep ratio) |
| 0xAE–0xAF | `40 01` | custom_temp fan_off = 320K (47°C) | leave |
| 0xB0–0xB1 | `4F 01` | custom_temp fan_max = 335K (62°C) | `54 01` = 340K (67°C) *if* you want quieter, not cooler |
| 0x28–0x2B | `87 BF B9 A5` | body CRC32 over 0x30..0xC8 | recompute |
| 0x2C–0x2F | `39 27 9C 0D` | header CRC32 over 0x00..0x2B | recompute |

- **Checksum law** (`gpu_configuration.c`): standard CRC-32 (poly 0xEDB88320, init/xor
  0xFFFFFFFF — `binascii.crc32` matches). Body CRC = blocks region 0x30..end, checked at
  lines 1060–1064; header CRC = bytes 0x00..0x2B, checked in `parse_gpu_header()` lines
  860–872. Patch data → recompute body CRC into 0x28 → recompute header CRC into 0x2C,
  in that order (descriptor_crc32 is inside the header CRC's coverage).
- **Flash:** `framework_tool --flash-gpu-descriptor-file <patched.bin>` (newer builds;
  the installed 0.6.5 only exposes `--flash-gpu-descriptor <hw-ver> <serial>`, which
  would *regenerate a stock image* — do not confuse them).
- **The real risk, from source:** if either CRC is wrong, `parse_gpu_eeprom()` falls
  back to device detection (lines 919–938): it probes for an Etron PD at 0x60 — absent
  on the NV module — then finds a readable EEPROM at 0x50 and **defaults to the dual-SSD
  config**: PCIe mux 4x2, no GPU power rails. Your 5070 becomes an imaginary SSD bay
  until you reflash a valid image. Recoverable (EEPROM stays writable), but only because
  you kept `gpu-descriptor.bin`. Guard that file like a BIOS backup.
- **Also note:** raising max_rpm changes the *slope* of `fan_percent_to_rpm()` (`thermal.c`
  line 131) — every temperature now maps to a higher RPM, not just the top end. Raising
  custom_temp fan_max to 67°C partially compensates. And Framework never validated any
  of it. **Reversibility:** reflash the original dump. Persists across EC updates —
  which is also a way to forget you did it.

### F4. Patched EC firmware — mostly theater, one exception

- **Worthwhile change:** kill the no-retry latch. In `cypd_ccg8.c` line 763 replace
  `epr_active = 0xff` with scheduling `enter_epr_mode` retry via
  `hook_call_deferred` with exponential backoff (30s/60s/5min, cap 3 per connect —
  reuse `epr_retry_count`, reset in `clear_port_state()` as today). Add an EPR watchdog:
  if `pd_epr_in_progress` is nonzero >10s, clear it and force
  `cypd_update_port_state()`. Optionally raise `fan.dtsi` rpm_max instead of F3.
- **Build:** Zephyr EC, program `framework/lotus` (tulip branch), Framework's
  EmbeddedController fork: `zmake build lotus` / `west build` per repo README.
- **Why it's theater for you:** flashing a self-built EC on your daily-driver FW16 risks
  a brick whose recovery is an external programmer on the mainboard; the EPR latch fires
  rarely; F0 avoids it entirely; and the *right* venue is a PR against
  SoftwareFirmwareIssueTracker #243/#193 so it ships signed in the next BIOS. Write the
  patch, submit it, don't run it.
- **Risk:** highest here. **Reversibility:** only if it still boots.

### Explicit theater list
- Raising fan caps *to address the crashes* — no causal link (Thesis 4).
- Repasting/undervolting to "fix" a 91°C STAPM-managed soak — the SMU will spend the
  headroom and land at the same temperature, faster.
- Registry-level PMF/STT table fiddling on Windows — fragile, undocumented, and the EC
  re-sends its own tables on every mode change (`EC_HOST_EVENT_STT_UPDATE`).

---

## Part 3 — The order I'd actually do things

1. **F0** — SPR-only charging for the next gaming sessions. It's the experiment *and*
   the mitigation. Keep the watchdog logging; 0x3E22 bit1-vs-bit4 during any incident
   adjudicates Thesis 3.
2. **F1** — tctl/PMF target if the 91°C soak genuinely bothers you. It's the correct
   knob and it also unpins the fans.
3. **F2** — userspace fan loop, only if after F1 you still want more airflow, and only
   with both failsafes. Cap at ~80% duty.
4. **F4-as-a-PR** — upstream the EPR retry patch. High leverage, zero personal risk.
5. **F3** — descriptor patch, last, only if F2 proved sustained >4700 RPM is actually
   worth the noise and you want it EC-native. Modest values (5800), original bin backed up.
6. **F4-as-a-flash** — don't.

The uncomfortable summary: the fan system is working as designed, the design goal
(quiet skin temps) is defensible, and the machine that's actually broken is the one
nobody can see from Windows — an EC that asks the SMU to throttle politely over a
mailbox that times out 32 times a day, then panics with a GPIO when nobody answers.
