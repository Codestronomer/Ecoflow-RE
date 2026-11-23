# EcoFlow E980 (R33 / MR330 / PR708) BLE Protocol Reverse Engineering

Full-stack reverse engineering of the EcoFlow E980 portable power station's
Bluetooth Low Energy protocol, **without the official app**, ending in:

- a working independent **Swift BLE client** (macOS) that authenticates to the
  device and streams live telemetry;
- a **complete, verified field map** for every telemetry frame (SOC, pack
  voltage, current, input/output watts, temperatures, cycle counts, sub-pack
  serials…);
- **verified device control**: AC output on/off and RTC set, byte-identical to
  the frames the official app sends.

| | |
|---|---|
| Device | EcoFlow E980 — 980 Wh LiFePO₄, 500 W AC (X-Boost 650 W), 48 V-class pack |
| Model / productType | R33 / 80 (module: MR330, product tree `pr708`) |
| App analyzed | EcoFlow Android 6.18.0.132 |
| BLE | `Ecoflow-dev`, service 0x0001, write 0x0002, notify 0x0003 |

## Protocol at a glance

```
outer : 5a5a 10 01 <len u16> AES-128-CBC(sessionKey, MD5(share)) PKCS <crc16>
inner : aa 02 <len u16> <crc8> <flags 0x0d> <ctr u32> <seq u16>
        <src> <dst> <cmd_func> <cmd_id> <payload> <crc16>
        (payload XOR-masked when header[6] ∉ {0x00, 0x04}: key = [6] ^ 0x04)
```

- ECDH on secp160r1 → `share` → `key16 = share[0:16]`, `iv = MD5(share)`
- `sessionKey = MD5(login_key[seed0*16 + (seed1-1)*256] || sRand)[0:16]`
- CRC16 = reflected 0xA001, init 0; header CRC8 = MSB-first poly 0x07, init 0
- Auth: getAuthStatus `0x35/0x89` → setAuth/checkAuth `0x35/0x85|0x86`
  (`secretKey = MD5hex(userId + SN)`), then 20 s heartbeat `0x20/0x59`

## Telemetry (verified live)

| Frame | Key fields |
|---|---|
| BMS 55B (`03:20/02`) | `f32_lcd_show_soc` (SOC×256), `chg_vol`, `para_vol_min/max` |
| BMS 188B (`03:20/32`) | `soc`, `vol` (pack mV), `amp`, `temp`, `cycles`, `in/out watts`, `remain_time` |
| INV 70B (`04:20/02`) | `input_watts`, `output_watts`, temps, AC config |
| MPPT 121B (`05:20/02`) | `inVol` (PV), `in/out watts`, `mpptTemp`, `cfgAc`, `xboost` |
| Sub-packs 83B (`03:03/0e`) | N × 39-byte records incl. 16-byte pack serial numbers |

Full tables: **[TELEMETRY-MAP.md](TELEMETRY-MAP.md)**. Protocol knowledge base:
**[PROTOCOL-NOTES.md](PROTOCOL-NOTES.md)**. Engineering learnings:
**[LEARNINGS.md](LEARNINGS.md)**.

## Repo layout

```
ble/        Swift client + Python decoder + capture scripts
repack/     Frida hook scripts (app instrumentation) + binary AXML patcher
*.md        protocol notes, telemetry map, report, learnings
```

## Build & run (macOS)

```bash
cd ble
swiftc -O -o ecoflow-session ecoflow-session.swift Secp160.swift \
       SessionHandshake.swift CryptoHelpers.swift

# close the official app first (one BLE connection at a time)
./ecoflow-session run --sn <YOUR_SN> --id <PERIPHERAL_UUID> --seconds 60 \
    --logfile session.log
# auth secret (MD5hex of your userId + SN) — pass it explicitly:
#   --secret <32 hex chars>   or   export ECOFLOW_AUTH_SECRET=<32 hex chars>
# options: --ac on|off  --set-time  --send-cmd <src> <dst> <func> <id> <payloadhex>
```

The peripheral UUID is assigned by macOS per machine — the client scans for
`Ecoflow-dev` if no `--id` is supplied.

## Method

1. Static analysis: jadx (Java), Ghidra (native `libnative-lib.so`), ELF symbol
   and data-table extraction (login-key table, CRC tables, codec dispatch).
2. **Ground truth**: repackaged the official app as debuggable with a Frida
   gadget (`wrap.sh` LD_PRELOAD), hooked the crypto primitives and captured the
   app's entire live BLE session in plaintext.
3. Runtime class revelation: hooked `EcoActiveEventListener.onEvent` across all
   loaded classes → identified the parser chain
   `kt.a "MR330BleCallBack"` → `eu.t "MR330ParseHelper"` → `Direct*HeartbeatPack`
   → decompiled it for the exact struct layouts.
4. Cross-session validation (47 % vs 89 % SOC captures) + device specs to pin
   units (e.g. SOC = float32 / 256).

## Notes

- No proprietary binaries (APK, `.so`, `dex`) are redistributed here; only
  original analysis, source, and protocol documentation. Reproduce the APK-based
  steps with your own legally obtained copy.
- All personal/device identifiers (SN, account id, auth secret, peripheral
  ids) have been removed from this repository and its history.
- This project is for interoperability research on hardware owned by the author.
