# FW16 (Ryzen AI 300 "tulip") EC reflash & recovery guide

Condensed from source-verified research (EC repo branch `fwk-tulip-29169`,
framework-system, FrameworkComputer/FrameworkDebugger, FW16 schematic PDFs).
Local schematic copies: see session scratchpad `fw16-schematics/`.

## Architecture facts

- EC = **Nuvoton NPCX9M3F**, firmware in the chip's **internal 512 KB flash**
  (`zephyr/program/framework/BUILD.py`; `zephyr,flash-controller = &int_flash`).
  The 32 MB Winbond SPI chip near the APU is the **BIOS**, not the EC.
- Layout: `0x00000` RO (256 KB) | `0x40000` RW (252 KB, FWID at 0x7EFE0) |
  `0x7F000` 4 KB EC settings store.
- **The FW16 EC always boots RO and stays there** (`VBOOT_EFS2=n`; the
  auto-jump-to-RW option is enabled only for the Desktop board). That's why
  `--versions` reports "Current image: RO" — normal. **RW is a dormant spare
  slot**: code there runs only after an explicit `--reboot-ec jump-rw`, and
  every EC reset lands back in stock RO. `SYSTEM_UNLOCKED=y`, `WP_DISABLE=y`
  — no write-protect obstacles.

## framework_tool flash flags

| Flag | Writes | Notes |
|---|---|---|
| `--dump-ec-flash f.bin` | nothing | full 512 KB backup — ALWAYS FIRST |
| `--flash-rw-ec f.bin` | RW only | safest; running RO untouched |
| `--flash-ro-ec f.bin` | RO only | risky — that's the live boot image |
| `--flash-ec f.bin` | RW then RO | preserves 4 KB settings |
| `--flash-full-ec f.bin` | all 512 KB | wipes EC settings — avoid |

All verify platform match (tulip image won't flash on lotus), read back and
compare, support `--dry-run`. RO can be written while running RO (EC executes
from code RAM); the brick case is power loss mid-RO-write.

`--reboot-ec jump-rw` sysjumps into RW **and crashes the OS immediately**
(close work first); `jump-ro` returns; `disable-jump` pins the current image
until next EC reset; `cancel-jump` clears a scheduled jump.

## Recovery ladder

1. **RW broken, RO stock** (the intended test posture): force power off,
   unplug AC ~30 s → EC boots stock RO. Reflash RW from the OS. Nothing lost.
2. EC alive but misbehaving: `--reboot-ec jump-ro` / `--reboot-ec reboot`.
3. Restore stock wholesale: run the **official BIOS 4.01 updater** — its
   bundle contains and flashes EC `ec_401_9b2a0b1` (Windows exe / EFI USB /
   LVFS). Works whenever the machine still powers on (RO intact).
4. State (not image) wedged: full power drain; official **Mainboard Reset**
   (chassis-intrusion switch below the RAM, press 10× for 2 s each, AC in,
   midplate off — resets BIOS settings, wipes Secure Boot/TPM config).
5. **RO corrupt / EC dead → hardware UART bootstrap** (below). No softer
   path exists: dead EC = no power sequencing at all.

## Hardware recovery (Nuvoton bootrom UART mode)

Official doc: github.com/FrameworkComputer/FrameworkDebugger. Mechanism: the
EC console UART TX pin doubles as the flash-program strap. **Pull EC UART TX
low with 4.7–10 kΩ while resetting the EC** → bootrom stays in UART-update
mode → load `npcx_monitor.bin` (built by every zephyr EC build) with
`uartupdatetool --port=<tty> --baudrate=115200 --opr=wr --addr=0x200C3020
--file=npcx_monitor.bin` (sources in `util/uut/`), then program `ec.bin`
(mimic `util/flash_ec`'s `npcx_uut` branch). Remove the strap before
transferring; pulse reset again afterwards. Any 3.3 V USB-UART adapter works;
no servo needed.

**Connector: JECDB** — 10-pin 0.5 mm FFC, usually **unpopulated pads**
(solder Hirose FH19C-10S-0.5SH, DigiKey H125812CT-ND; cable Molex 0151660111).
Location "bottom right area, near the keyboard connector / BIOS chip" per
Framework. Pinout: 1 3VL_EC · 2 CPU-RX · 3 EC_JTAG_TMS · 4 TCK · 5 TDO ·
**6 EC UART TX** · **7 EC UART RX** · 8 CPU-TX · **9 EC_RST# (open-drain —
pull low only, never drive high)** · 10 GND. Console 115200 8N1 @ 3.3 V.
Precedent: Pi Pico on JECDB of an AMD FW16 (coreboot-porting forum thread).

Closed-case option (diagnosis only): right-side USB-C ports expose EC/CPU
UART on SBU pins in debug-accessory mode (both CC → 5.1 kΩ → GND); tulip's
CPU UART is tabled as middle-right port, flipped, BIOS 3.00+; the EC-UART
port and strap-over-SBU behavior are undocumented.

**Do not confuse** with `JSPI` (6-pin, BIOS SPI — tulip SPI_VCC is **1.8 V**,
a 3.3 V programmer damages it) or `JUDC` (SoC UART/JTAG/HDT — irrelevant).

## Recommended workflow for a custom build

1. `--dump-ec-flash` backup + keep stock `ec.bin` from the BIOS 4.01 bundle.
2. `--flash-rw-ec build.bin --dry-run`, then for real. Custom code inert.
3. Close everything, `--reboot-ec jump-rw` (OS dies), verify
   `--versions` → Current image: RW + your version string. Soak-test.
4. Escape at any time: power off + AC out 30 s → stock RO.
5. Only after long RW soak: consider `--flash-ec`, on AC, with JECDB gear on
   the shelf. Never `--flash-full-ec`, never RO alone.

## Version caution (as of 2026-10-21)

Shipped EC is `tulip-4.0.1-9b2a0b1` (built 2026-06-11) — **those commits are
not public**. The public release branch `fwk-tulip-29169` ends at v3.2.0
(2026-03-19); our patched build is that + 23 lines. Flashing it therefore
*removes ~3 months of unpublished vendor fixes* while testing ours — another
reason to confine testing to the RW slot with stock RO underneath. Newer
unversioned public branches (`fwk-sakura-20260429`,
`fwk-sunflower-dahlia-2026-09-30`) carry a reworked EPR implementation
(`epr_active` → `epr_status` enum; failure path now clears the in-progress
port bit) — but the failure path still does not release the transition
throttle events, and the buck retry-exhaustion abandonment is unchanged, so
both reported defects remain in the newest public code.

## Open unknowns

- JECDB presence/position on the AI 300 board (LA-P071P) unverified — the
  public AI 300 PDF omits the debug page. Inspect before relying on it.
- Which right-side port carries EC UART over CCD; strap-over-SBU viability.
- EC_RST# pulse vs full power-cycle for latching the strap (doc implies both).
- Hand-driven uartupdatetool overwrites the settings region — restore from
  the dump afterwards.
