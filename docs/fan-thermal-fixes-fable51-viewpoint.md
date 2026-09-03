# The Case Against the Mainline Story — and What I'd Actually Do

*Devil's-advocate viewpoint by **Claude Fable 5.1**, 2026-09-03. Written against
[../README.md](../README.md) and [fan-thermal-analysis.md](fan-thermal-analysis.md).
Same facts, different verdicts.
Nothing here was executed against hardware; all offsets/line numbers verified against
`gpu-descriptor.bin` and EC branch `fwk-tulip-29169`.*

---

## Part 1 — Where the mainline framing is wrong

### Thesis 1: ~~The 4700 RPM "cap" is not a defect. It's the only validated operating point.~~ [REVISED in Round 2 — substantially conceded]

The mainline reads the EEPROM fan block as the EC "leaving 40% of fan capacity on the
table." Flip it around: the **mainboard devicetree** maxes the fans at **4000/3700 RPM**
(`lotus/fan.dtsi` lines 15/25). The RTX 5070 module's descriptor *raises* that to
4700/4500. The descriptor is an upgrade, not a cap — and 4700 at ~62% duty is almost
certainly the acoustic/vibration/bearing-life point Framework actually qualified for
long sessions. "80% duty measured 6105 RPM" proves the motor spins there; it proves
nothing about resonance, tach stability under load, dust loading, or bearing life at
7600 RPM × 4-hour gaming sessions. Momentary capability ≠ continuous rating.
~~If you want more airflow, take it deliberately (Part 2), but stop calling the stock
number a bug.~~ *[revised: the 2026-09-03 incident log shows this operating point
saturating at minute 4 of a gaming session and then letting chassis ambient ride its
own 87°C warn threshold — see Round 2. The "why 4700" defense stands; the "4700 is
adequate" conclusion does not.]*

### Thesis 2: "The APU reads too hot" is chasing the wrong variable. [PARTIALLY REVISED in Round 2 — die half stands, remedy half conceded]

A Ryzen AI 300 die soaking at 91°C under sustained combined load is *the SMU doing its
job*: STAPM/PMF deliberately converges near the thermal target and trades die temp for
performance. Die temp is a **controlled output**, not a health signal — Tjmax is 100°C
and HALT is 108°C (`thermal.c` line 334). What users can actually feel is **skin temp**,
and that is exactly what the descriptor's custom_temp block controls: the APU *board*
sensor band 47→62°C. During gaming that board sensor exceeds 62°C, demands 100%, and
pins the fans at 4700 — the max-of-sensors policy is already saturated by the skin
proxy, not the die. ~~Doubling fan noise to move a SMU-regulated die from 91 to ~85°C
is a bad trade; if 91°C offends, lower the *power/thermal target* (PMF/tctl), don't
shout at the fans.~~ *[revised: the incident log empirically refutes the remedy — the
EC's own 45W APU clamp landed one second after the WARN and chassis ambient still
climbed another 12°C, because the ~99W GPU, not the APU, owns the heat budget. When
the system-level sensors are the ones tripping warn thresholds, airflow (or a GPU
power cap) is the fix; tctl is not. See Round 2.]* The one legitimate gripe: the die band 50→97°C (`thermal.c` uses
thermal_params[TEMP_APU_DIE]) means the die alone never demands 100% until 97°C — but
per above, the board sensor gets there first anyway.

### Thesis 3: The crash root cause is more likely the SB-RMI link than the EPR state machine.

Mainline: EPR renegotiation fails → port latches ≤100W → discharge ratchets the safety
ladder → stuck LEVEL_PROCHOT. I say the EPR latch is the **trigger**, and the chronically
sick **EC→SMU SB-RMI mailbox** is the **disease**, for three code-level reasons:

1. **Every gentle rung of the safety ladder acts through SB-RMI.** LEVEL_TUNE_PLS and
   LEVEL_DISABLE_GPU (`cpu_power.c` lines 170–237) adjust SPL/SPPT/FPPT via
   `set_pl_limits()` → `sb_rmi_mailbox_xfer()` (`amd_cpu_power_interface.c` lines 39–112).
   If the mailbox times out (`driver/sb_rmi.c` lines 336/414) — ~~and
   `logs/ec-console-20260903.log` shows **32 timeout entries in one ordinary day**~~
   *[CORRECTED in Round 2: that count was ring-buffer overlap double-counting;
   deduplicated, the day contains exactly **2** unique timeout events, both at
   22:11–22:13, after the incident. The chronic-illness premise is withdrawn]* —
   those rungs are silent no-ops. The battery keeps
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

## Part 3 — The order I'd actually do things [re-ranked in Round 2]

1. **F0** — SPR-only charging for the next gaming sessions. Unchanged: it targets the
   *reboot-class* incidents (Kernel-Power 41 + power events), which the 22:10 stall
   was not. Keep the watchdog; 0x3E22 bit1-vs-bit4 still adjudicates Thesis 3.
2. **F2** — userspace fan loop *[promoted from #3]*: the incident data shows the
   thermal problem is real, system-level, and airflow-starved. Drive duty from
   **gpu_vr and ambient**, not just the APU sensors; cap ~80% duty; both failsafes.
3. **GPU power cap** *(new, folded into F1's slot)*: `nvidia-smi -pl 80` (from stock
   ~100W) attacks the actual heat source; reversible per boot, costs ~5-8% frames.
   The old F1 (tctl/PMF for the APU) is demoted to cosmetic — see Thesis 2 revision.
4. **F3** — descriptor patch *[promoted]*: now evidence-backed rather than
   vibes-backed. Still modest values (5800/5628), still with the custom_temp
   compensation, still with the original bin guarded like a BIOS backup. Doing F2
   first as the cheap trial of ">4700 actually helps" remains the right order.
5. **F4-as-a-PR** — upstream the EPR retry patch. Unchanged.
6. **F4-as-a-flash** — still don't.

~~The uncomfortable summary: the fan system is working as designed, the design goal
(quiet skin temps) is defensible, and the machine that's actually broken is the one
nobody can see from Windows.~~ *[revised — see Round 2 for the summary that survived
cross-examination.]*

---

## Round 2 — under cross-examination (2026-09-03, incident 20260903-221003)

I re-derived every claim below from the raw logs myself (dedup script over the EC
console ring dumps; UTF-8 parse of `framework-20260903.log` with the label-bug mapping
"dGPU VRAM"→gpu_vr, "F75303_Local"→ambient; watchdog CSV). The rebuttal's substance is
right; two of its details are wrong. Scorecard:

**Conceded, Thesis 1 (mostly).** The timeline is damning: fans hit the 4700 ceiling at
21:41, ~4 minutes into the session, with the APU board sensor already past its 62°C
saturation point — 100% of the descriptor's authority was spent before the sensor that
ultimately tripped WARN had even started moving. gpu_vr then climbed 54→73°C in ~75s
(21:44:04→21:45:19), crossed the NV table's 71°C warn (`thermal.c` line 347), and the
EC asserted `thermal WARN` + soft AP throttle at uptime 35404.6 (≈21:45:50). It **never
released** — release requires 60°C (line 351) and gpu_vr sat at 84–86°C until the
stall; there is no "throttling type 0 to off" anywhere in the day's log. By 21:57
chassis ambient reached **87°C — exactly its own warn/high threshold**
(`lotus/overlay.dtsi` lines 14–15), a monotonic 67→87 climb over 20 minutes at
constant max fan: no equilibrium short of the warn line, i.e. zero margin. And from
21:59:41 the NVIDIA driver itself began SW thermal slowdown (nvml reason 0x20 in the
CSV). An operating point that does that during the advertised workload is
under-provisioned. What I still hold from Thesis 1: the *explanation* (acoustic/
bearing qualification vs. the DT's 4000/3700 baseline) and the corollary that the fix
is a deliberate, bounded raise (5800-class), not "pin it at 7600."

**Half-conceded, Thesis 2.** The half that stands: the die tripped nothing — die warn
is 105°C, it peaked ~97; the sensors that asserted WARN are precisely the unfiltered
board/system sensors I said were the right control targets. The user's instinct
("something is too hot") was right even though the *variable* they were watching (APU
die) was the one sensor behaving by design. The half that falls: my prescribed remedy.
The EC clamped the APU to SPL/sPPT 45W at uptime 35405.7 — one second after WARN — and
ambient still climbed another 12°C, because the GPU held ~99W steady for the next 15
minutes. tctl/PMF tuning cannot fix an 87°C chassis; only airflow or a GPU power cap
can. F1 is demoted accordingly and a GPU `-pl` cap takes its slot.

**Held, Thesis 3's structure; conceded its headline number; rebutting the rebuttal's
chaining claim.** My "32 timeouts in one ordinary day" was ring-buffer double-counting
— deduplicated, the entire day contains **two** unique SB-RMI timeout events, at
22:11:17 and 22:13:17, *after* the system had already recovered (CSV shows normal
5s cadence, GPU at 17W, game gone from 22:07:11). That is not a chronically sick link;
withdrawn. But the coordinator's improvement — "17 minutes of soft throttle = 17
minutes of continuous SB-RMI traffic parking the machine in the mailbox kill zone" —
is also wrong on this data: `set_pl_limits()` fires on *change*, not per loop
(`cpu_power.c` lines 563–569), the 45W clamp was written once and the logged `PMF:`
line is the success path (line 587), and there are zero RMI errors during the entire
16-minute WARN window. Neither of us gets to blame the mailbox for this incident.
The structural claim — every gentle ladder rung and the PROCHOT release path route
through SB-RMI, so a mailbox failure degrades the EC to its bluntest instrument —
remains true as code and remains untested by this event.

**Weakened, Thesis 4 — honesty requires saying so.** This stall (logger gap
22:01:32→22:07:11, no reboot: EC uptime runs continuously through it, CPU never
clamped, cpu%max=100 before and after) followed 16 minutes of thermal saturation and
active GPU thermal throttling. That is a thermal-preceded incident, and my "zero
causal path from temps to incidents" was too absolute — it now reads: *no causal path
to the reboot-class (Kernel-Power 41 + power-event) incidents; the stall-class may
well be thermally seeded (game/driver collapse under 86°C VR), pending more samples.*
One point I keep, now with data: the mainline's "thermal edge → battery assist →
crash exposure" bridge is still unsupported — peak battery discharge during the entire
soak was **4.6W (~0.26A), a factor of ~20 below** the 5.49A ladder threshold. The
safety ladder was never in play.

**Revised summary:** the fan hardware is under-commanded, the thermal problem is real
and lives in the GPU/chassis system sensors rather than the APU die, the crash story
is (at least) two distinct failure classes — power-event reboots and thermal-preceded
stalls — and the SB-RMI mailbox is a proven structural liability that has not yet been
caught in the act. The fixes that got stronger tonight are the boring ones: more
airflow, less GPU power. The fix that got weaker is the one I liked most. That's what
the data is for.
