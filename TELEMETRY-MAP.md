# EcoFlow E980 (R33 / MR330 / PR708) — Definitive Telemetry Field Map

Source of truth: the app's own parser chain, decompiled from the installed
6.18.0.132 build and confirmed against 2 live captures (17:35 session @47% SOC,
21:06–21:54 sessions @89% SOC) plus our independent Swift client.

Parser chain (all classes from `com.ecoflow` / obfuscated packages):
```
BLE notify → TreatyEngine.aesDecryptFrame → EcoProtocolParseTypeSession.parse
→ assemblePacket → EcoPacket → EcoProtocol.ecoProtocolCallback
→ EcoActiveEventListener.onEvent(int, EcoPacket)
→ kt.a  (tag "MR330BleCallBack")   — dispatches on (src, cmdSet, cmdId)
→ eu.t  (tag "MR330ParseHelper")   — parses payload → beans
→ eu.q  (MR330 data store) / i1.q() (common device store) → UI
```

## Routing (kt.a — MR330BleCallBack)

| (src, cmdSet, cmdId) | parser | pack / bean | notes |
|---|---|---|---|
| (2, 0x20, 0x02) | t.z() | w/y bean | EMS heartbeat (147B) |
| (3, 0x20, 0x02) | t.k() | DirectEmsDeltaHeartbeatPack | BMS heartbeat (55B) |
| (3, 0x20, 0x32) | t.d() | DirectBmsMDeltaHeartbeatPack | BMS detailed (188B) |
| (4, 0x20, 0x02) | t.n() | DirectInvDeltaHeartbeatPack | INV heartbeat (70B) |
| (5, 0x20, 0x02) | t.q() | v/x bean | MPPT heartbeat (121B) |
| (7, 0x20, 0x02) | t.j() | b bean | DC module |
| (8, 0x20, 0x32) | t.y() | d bean | 48V module |
| (66, 0x20, 0x32) | t.p() | u bean | extra battery module |
| (3, 0x03, 0x0e) | t.m() | a bean + s records | "从包生态信息" sub-pack info (83B) |
| (3|6, 0x20, 0x58) | BatteryInfoUtil.u | — | battery info request result |
| (2, 0x20, 0x59) | t.a() | AutomationBean | time-task list (223B) |
| (2, 0x20, 0x55) | — | AutomationConflictBean | conflicts |
| (2, 0x20, 0x56/0x57/0x5C) | — | — | del task / set task / PV-priority acks |
| (3, 0x03, 0x40) | — | — | set-RTC ack |

## BMS heartbeat — 55B (src=3, cmd 0x20/0x02) → DirectEmsDeltaHeartbeatPack

| off | size | field | value seen (47% / 89% sessions) |
|---|---|---|---|
| 0 | 1 | chg_state | 0x05 |
| 1 | 1 | chg_cmd | 0x05 |
| 2 | 1 | dsg_cmd | 0x05 |
| 3 | 4 | chg_vol (read as u16 LE, mV) | 53351 → 54071 = 53.35 V → 54.07 V |
| 7 | 4 | chg_amp | — |
| 11 | 1 | fan_level | 0x04 |
| 12 | 1 | max_charge_soc | — |
| 13 | 1 | bms_model | — |
| 14 | 1 | lcd_show_soc | 0x2a = 42 % |
| 15 | 1 | open_ups_flag | — |
| 16 | 1 | bms_warning_state | — |
| 17 | 4 | chg_remain_time | — |
| 21 | 4 | dsg_remain_time | — |
| 25 | 1 | ems_is_normal_flag | — |
| 26 | 4 | **f32_lcd_show_soc** (float32 LE = SOC×256) | 12117.8 → 47.34 % / 22750.9 → 88.87 % |
| 30 | 3 | bms_is_connt | — |
| 33 | 1 | max_available_num | — |
| 34 | 1 | open_bms_idx | — |
| 35 | 4 | para_vol_min (u16 LE, mV) | 52543 = 52.54 V |
| 39 | 4 | para_vol_max (u16 LE, mV) | 54543 = 54.54 V |
| 43 | 1 | min_dsg_soc | — |
| 44 | 1 | open_oil_eb_soc | — |
| 45 | 1 | close_oil_eb_soc | — |
| 46..54 | 9 | padding | |

`f32_lcd_show_soc / 256` = the SOC shown on the LCD/app (47.3 %, 88.9 %).

## BMS detailed — 188B (src=3, cmd 0x20/0x32) → DirectBmsMDeltaHeartbeatPack

| off | size | field | notes |
|---|---|---|---|
| 0 | 1 | num | pack number |
| 1 | 1 | type | |
| 2 | 1 | cell_id | |
| 3 | 4 | err_code | |
| 7 | 4 | sys_ver | |
| 11 | 1 | soc | 1-byte SOC |
| 12 | 4 | **vol** (u16 LE @12..13, mV) | 51379 → 52160 = 51.38 V → 52.16 V (pack voltage) |
| 16 | 4 | amp | pack current |
| 20 | 1 | temp | |
| 21 | 1 | open_bms_idx | |
| 22 | 4 | design_cap | |
| 26 | 4 | remain_cap | |
| 30 | 4 | full_cap | |
| 34 | 4 | cycles | |
| 38 | 1 | soh | |
| 39 | 2 | max_cell_vol | |
| 41 | 2 | min_cell_vol | |
| 43 | 1 | max_cell_temp | |
| 44 | 1 | min_cell_temp | |
| 45 | 1 | max_mos_temp | |
| 46 | 1 | min_mos_temp | |
| 47 | 1 | bms_fault | |
| 48 | 1 | bq_sys_stat_reg | |
| 49 | 4 | tag_chg_amp | |
| 53 | 4 | **f32_show_soc** (float32 LE = SOC×256) | 12118.3 → 47.34 % / 88.9 % |
| 57 | 4 | input_watts | |
| 61 | 4 | output_watts | |
| 65 | 4 | remain_time | |
| 69..187 | — | (tail: second SOC float copy at 150..153, etc.) | |

## INV heartbeat — 70B (src=4, cmd 0x20/0x02) → DirectInvDeltaHeartbeatPack

| off | size | field | value seen |
|---|---|---|---|
| 0 | 4 | err_code | 0 |
| 4 | 4 | sys_ver | 0x0501007e |
| 8 | 1 | charger_type | |
| 9 | 2 | **input_watts** (u16 LE) | 0 W (morning) / 0 W (evening) |
| 11 | 2 | **output_watts** (u16 LE) | 88 W (morning) / 60 W (evening — matches SOC drain rate) |
| 13 | 1 | inv_type | |
| 14 | 4 | inv_out_vol | |
| 18 | 4 | inv_out_amp | |
| 22 | 1 | inv_out_freq | |
| 23 | 4 | ac_in_vol | |
| 27 | 4 | ac_in_amp | |
| 31 | 1 | ac_in_freq | |
| 32 | 1 | out_temp | |
| 33 | 4 | dc_in_vol | |
| 37 | 4 | dc_in_amp | |
| 41 | 1 | dc_in_temp | |
| 42 | 1 | fan_state | |
| 43 | 1 | cfg_ac_enabled | |
| 44 | 1 | cfg_ac_xboost | |
| 45 | 4 | cfg_ac_out_voltage | |
| 49 | 1 | cfg_ac_out_freq | |
| 50 | 1 | cfg_ac_work_mode | |
| 51 | 1 | cfg_pause_flag | |
| 52 | 1 | ac_dip_switch | |
| 53 | 2 | cfg_fast_chg_watts | |
| 55 | 2 | cfg_slow_chg_watts | |
| 57 | 2 | standby_mins | |
| 59 | 1 | discharge_type | |
| 60 | 1 | ac_passby_auto_en | |
| 61 | 1 | pr_balance_mode | |
| 62 | 2 | ac_chg_rated_power | |
| 64 | 1 | cfg_gfci_enable | |
| 65..69 | — | tail | |

## Sub-pack info — 83B (src=3, cmd 0x03/0x0e) → eu.a + eu.s records

```
[0]     a.c  (1B)
[1..2]  a.a  (2B)
[3..4]  a.d  (2B) = record count
then count × 39B records (eu.s):
  [0]   1B
  [1..16] 16B = sub-pack serial number (ASCII)
  [17..18] 2B
  [19..20] 2B
  [21]  1B
  [22..25] 4B
  [26..29] 4B
  [30..33] 4B
  [34..37] 4B
  [38]  1B
```
83 = 5 + 2×39 → the captured device reports 2 packs (main + one expansion).

## MPPT heartbeat — 121B (src=5, cmd 0x20/0x02) → eu.c base + eu.v/eu.x variant

Field order/sizes match the classic `DirectMpptHeartbeatPack` exactly (25 base
fields, parse order confirmed in `eu.t.t()` via `eu.t.f()`); verified by
`inVol` = 0x07dc = 20.12 V at dusk with inAmp/inWatts = 0.

| off | size | field |
|---|---|---|
| 0 | 4 | fault_code |
| 4 | 4 | sw_ver |
| 8 | 4 | **in_vol** (solar input voltage, 0.01 V units: 2012 → 20.12 V) |
| 12 | 4 | in_amp |
| 16 | 2 | **in_watts** (2B) |
| 18 | 4 | out_vol |
| 22 | 4 | out_amp |
| 26 | 2 | out_watts (2B) |
| 28 | 2 | mppt_temp (2B) |
| 30 | 1 | xt60_chg_type |
| 31 | 1 | cfg_chg_type |
| 32 | 1 | chg_type |
| 33 | 1 | chg_state |
| 34 | 4 | dcdc12v_vol |
| 38 | 4 | dcdc12v_amp |
| 42 | 2 | dcdc12v_watts |
| 44 | 4 | car_out_vol |
| 48 | 4 | car_out_amp |
| 52 | 2 | car_out_watts |
| 54 | 2 | car_temp |
| 56 | 1 | car_state |
| 57 | 2 | dc24v_temp |
| 59 | 1 | dc24v_state |
| 60 | 1 | chg_pause_flag |
| 61 | 1 | dc_dip_switch |
| 62..121 | — | variant fields (cfgFast/SlowChgWatts, cfgDcChgCurrent, beepMode, cfgAc*, standby mins…; eu.v adds 29B, eu.x adds 27B) |

## EMS heartbeat — 147B (src=2, cmd 0x20/0x02) → eu.d base + eu.y/eu.w variant

- Starts `50` = productType 80. Base bean `eu.d` = 45 fields
  (1,4,4,4,1,1,2,2,4, then 13×1, 2,2,1, then 11×4 in the variant).
- Live fields observed: [14..15] and the mirrored pair [114..115] (same value),
  plus [19]; cross-session 0x2a5c→0x5f36 and 0xdc→0x87 between 47 % and 89 % SOC.
- Field **names pending** one more UI-accessor cross-reference (structure and
  sizes are mapped; the essential metrics — SOC, volts, watts, temps — all live
  in the BMS/INV frames already fully decoded).

## Device control (sending instructions)

Every command is the SAME encrypted AA-frame as the telemetry path — just with
src=0x21 (app) and the target module as dst:

```
aa 02 <len u16> <hdr-crc8> <flags 0x0d> <ctr u32> <seq u16> 21 <dst> <cmd_func> <cmd_id> <payload> <crc16>
   → AES-128-CBC(sessionKey, MD5(share)) → 5a5a 10 01 …
```

So our client can already send anything the app can. Verified against the app's
own captured traffic:

| command | src→dst | cmd_func/cmd_id | payload |
|---|---|---|---|
| **AC output on/off** (captured verbatim) | 21→05 (MPPT) | 20/42 (0x42=66) | `01 ff ff ff ff ff ff` = on, `00 ff ff ff ff ff ff` = off |
| SET RTC (captured verbatim; app sends on every connect) | 21→03 | 03/40 (0x40=64) | `ea 07 0b 16 17 2f 34 07` = year u16 LE, month, day, hour, min, sec, ISO weekday |
| get time tasks | 21→02 | 20/59 | empty |
| set time task | 21→02 | 20/57 | task struct (see `eu.t.b` AutomationBean layout) |
| delete time task | 21→02 | 20/56 | index |
| get task conflicts | 21→02 | 20/55 | empty |
| PV priority | 21→02 | 20/5C (92) | value |
| AC always-on | — | MR330_AC_ALWAYS_ON = 74 (0x4A) | — |
| AC charge limit | — | MR330_AC_CHARGE = 90 (0x5A) | — |
| PV charge limit | — | MR330_PV_CHARGE = 91 (0x5B) | — |
| heartbeat | 21→02 | 20/59 | empty, every 20 s |

Client usage (after auth succeeds, commands are sent automatically):

```bash
./ecoflow-session run --sn R701ZKB59GCR0496 --id <UUID> --seconds 60 --set-time
./ecoflow-session run ... --send-cmd 21 03 03 40 ea070b1611231e07
```
`--set-time` builds the RTC frame from the Mac's clock; `--send-cmd` is the
generic escape hatch for any (src, dst, func, id, payload) quadruple.
Read-only commands (get time tasks, get conflicts) are safe to explore; write
commands are reversible but deliberate.

**Verified live (2026-11-23):** `--ac off` switched the AC output off — the
device's own MPPT telemetry then reported `cfgAc=0` in every frame, and the
relay audibly clicked. `--ac on` also works (relay engaged with a soft-start
delay; the `cfgAc` report flag lags the physical state by more than the run
window). `--set-time` uses the same 8-byte datetime layout the app sends on
every connect (`21→03, 03/40`).

Auth nuance observed on the device: `getAuthStatus` may answer `05 04` (instead
of `01 00`); the correct flow is setAuth (`0x85`) → `00` → checkAuth (`0x86`)
→ then the telemetry stream starts. The client mirrors this and always sends
SET RTC after auth, exactly like the app.

## Verified cross-session values

| metric | 47% session | 89% session |
|---|---|---|
| f32_lcd_show_soc / 256 | 47.34 % → 44.82 % | 88.87 % → 88.53 % |
| pack vol (188B@12) | 51.38 V | 52.16 V |
| chg_vol (55B@3) | 53.35 V | 54.07 V |
| INV output_watts | 88 W | 60 W |
| INV input_watts | 0 W | 0 W |
