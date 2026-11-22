# EcoFlow E980 (R33) BLE Reverse-Engineering — Full Knowledge Base

**Status: ✅ Bidirectional BLE communication achieved.** Our independent Swift client performs the
complete handshake, authenticates to the device, and receives its live telemetry stream
(2,084 data frames in the final session).

- Date of final verification: 2026-11-22
- Device: EcoFlow E980 solar generator — productType 80, model R33, SN `<SN>`
- BLE: peripheral name `Ecoflow-dev`, identifier `<PERIPHERAL_UUID>`,
  address `<MAC>`, GATT service `0x0001`, write char `0x0002`, notify char `0x0003`
  (16-bit UUIDs)
- App versions analyzed: 6.16.8.24 and 6.18.0.132 (Android phone, Android 12)
- Account/userId used in the session: `<USER_ID>`

---

## 1. Wire protocol (fully verified)

### 1.1 Outer frame (both directions, all little-endian)

```
5a5a <flags> <ver> <len u16> <payload len-2 bytes> <crc16 u16>
```

- `flags`: `0x00` = plaintext (handshake phase), `0x10` = encrypted (session phase)
- `ver`: `0x01` (always, on this device)
- `len`: payload length + 2 (i.e. covers payload + crc)
- `crc16`: reflected polynomial `0xA001`, init `0`, over header + payload
  (verified against 752+ captured frames and the app's `chk_crc16`)

### 1.2 ECDH handshake (plaintext)

```
app → dev:  5a5a 00 01 2c00  01 00 <pub40>            crc
dev → app:  5a5a 00 01 2d00  01 00 00 <devPub40>      crc
app → dev:  5a5a 00 01 0300  02                        crc   (getKeyInfoReq)
dev → app:  5a5a 00 01 2300  02 <ct32>                 crc   (getKeyInfoResp)
```

- Curve: secp160r1, curve type byte `0`. Key sizes: private 20 B, public 40 B.
- Both sides generate ephemeral keypairs per session.
- `share = X(priv * devPub)` — the 20-byte X coordinate.
- `key16 = share[0:16]`, `iv = MD5(share[0:20])`.
- The keyInfo response decrypts with `AES-128-CBC(key16, iv)` →
  `sRand16 || seed2 || padding` (padding = PKCS-style, value = pad length).

### 1.3 Session key

```
sessionKey = MD5( login_key[ seed[0]*16 + (seed[1]-1)*256  .. +16 ] || sRand )[0:16]
```

- `login_key` = 65,280-byte table (4,080 × 16 B) inside `libnative-lib.so`,
  ELF symbol `login_key` at file VA `0x2a73ec` (extracted byte-exact, verified via the
  GOT relocation `PTR_login_key_003a68a8` → symbol → 0x2a73ec).
- **The offset formula is plain byte-based** (`seed[0]*16 + (seed[1]-1)*256`).
  Brute-force-confirmed from the app's own live session: seed `05 02` → offset `336` →
  key `2a7e6a52e5fc55937631bfd127e18ad5`, matching the app exactly.
- Session IV = `MD5(share[0:20])` (the same IV as the keyInfo stage).

### 1.4 Encrypted session frame

```text
outer: 5a5a 10 01 <len> AES-128-CBC(sessionKey, iv, INNER + PKCS-pad) <crc16>
inner (AA-frame, 16-byte header — disassembly-verified):
  [0]    0xAA
  [1]    frame type (low nibble 2) | version (high nibble 0)
  [2:4]  payload length, u16 LE
  [4]    header CRC8 (reflected 0x07, init 0) over bytes [0..3]
  [5]    flags: bit0 need_ack, bit1 queue, bits2-4 data-check type (3 = CRC16),
         bits5-6 enc-type, bit7 unused   (app outbound: 0x0d; device data: 0x2f)
  [6:10] counter/opaque u32 LE  ← byte[6] doubles as the payload-obfuscation key
  [10:12] seq/flags u16 LE       (0x2000 on many obfuscated frames)
  [12]   src addr    [13] dst addr   [14] cmd_func   [15] cmd_id
  [16:]  payload
  [-2:]  CRC16 (reflected 0xA001, init 0) over bytes [0 .. len-2]
```

- PKCS padding: `pad = 16 - (inner.count % 16)`, bytes = pad value.
- Header CRC8 verified against app + device frames: `crc8(aa022000)=0x1b`,
  `crc8(aa020000)=0xb5`, `crc8(aa02bc00)=0x06` (poly 0x07 reflected, init 0,
  table at .so 0x1fe884).
- Data CRC16 verified against the app's own checkAuth frame (0x4b92) and the
  outer frame of our client's pubkey exchange (0x836c). Dispatcher table
  (.so 0x1fcbf0): check type 0=invalid, 1=sum8, 2=CRC8, 3=CRC16(0xA001,
  table at .so 0x1fce00).
- **Payload obfuscation** (verified across 4 sessions, 0 mismatches on
  strictly-stable positions): only the BMS-style frames use it. Header byte [6]
  is the marker — `[6] == 0x04` (BMS clear frames) or `[6] == 0x00` (all other
  modules: EMS/INV/MPPT/83B) means the payload is clear; any other value k means
  the payload is XOR-masked with `k ^ 0x04`. Observed keys on BMS frames:
  0xF1 ([6]=0xf5), 0xBC ([6]=0xb8), 0x85 ([6]=0x81). Obfuscated frames arrive in
  pairs (BMS 55B + 188B) every ~3–5 s, interleaved with clear frames.

### 1.5 Auth sequence (exactly what the app does)

```
1. getAuthStatus:  aa 02 00 00 b50d0000 00000000 21 35 35 89
   dev responds:   aa 02 02 00 9f0e0000 00000000 35 21 35 89 <01 00>
                  payload[0]=1 → device considers this user already authenticated
2. checkAuth:      aa 02 20 00 1b0d0000 00000000 21 35 35 86 <secretKey 32 ASCII hex>
   secretKey = MD5hex(userId + SN)          (userId from your own account,
             e.g. uppercase hex, 32 chars)   SN from the device label)
   dev responds:   aa 02 01 00 a00e0000 00000000 35 21 35 86 <00>   (00 = success)
3. heartbeat (every 20 s):  aa 02 00 00 b50d0000 00000000 21 02 20 59
4. device streams telemetry on its own.
```

Error codes observed: checkAuth with a wrong key → `06`; setAuth (0x85) when not
authed → `04`. `f0 01` (plaintext, 2-byte payload) is the device's generic NAK for
undecryptable/unparseable session frames.

### 1.6 Telemetry frames (received, decrypted, deobfuscated)

Module address map (from TreatyConstants: `EMS_ADDR`/`BMS_ADDR`=3, `INV_ADDR`=4,
`MPPT_ADDR`=5, `CP307_EMS_ADDR`=2 — plus our observed src values):

| group | direction | n (capture) | payload | content |
|---|---|---|---|---|
| `EMS → APP cmd=20/02` | src 0x02 | 307 | 147 B | EMS heartbeat, CONSTANT (device info snapshot) |
| `EMS → APP cmd=20/59` | src 0x02 | 6 | 223 B | EMS status dump; starts `50` (productType 80) and contains a **timestamp** at [12..17]: `ea 07 02 12 14 3b` = 2026-02-18 20:59 (BCD-style y m d h m s — offset 18 = seconds) |
| `BMS → APP cmd=03/0e` | src 0x03 | 250 | 83 B | BMS query result, CONSTANT |
| `BMS → APP cmd=20/02` | src 0x03 | 138 | 55 B | BMS heartbeat |
| `BMS → APP cmd=20/32` | src 0x03 | 144 | 188 B | BMS detailed report |
| `INV → APP cmd=20/02` | src 0x04 | 145 | 70 B | Inverter heartbeat; 2 live fields at [14..15] |
| `MPPT → APP cmd=20/02` | src 0x05 | 91 | 121 B | MPPT heartbeat; live at [8..9], [18], [28], [106] |
| `BLE-APP → MCU cmd=35/20` | src 0x35 | 3 | 8 B | app-side ack |
| acks: `35→21 35/89` `01 00`, `35→21 35/86` `00` | | | | auth handshake replies |

- The device pushes data continuously once authenticated; BMS reports arrive in
  pairs (55B + 188B) every ~1–2 s.
- ~25 % of frames are XOR-obfuscated (see 1.4); ~5/138 have a rare extra data
  state (e.g. BMS 55B [3..4] flips from `67 d0` to `f1 d7`) — not a second XOR
  layer, the bytes genuinely differ.
- **Confirmed semantic fields** (offsets verified against the app's own live session;
  anchored by the E980's published specs — 980 Wh LiFePO₄, 500 W AC/X-Boost 650 W,
  48 V-class pack, "DELTA 2 E980" regional variant, productType 80, model R33):
  | frame | offset | type | meaning | observed |
  |---|---|---|---|---|
  | BMS 55B | [26..29] | f32 LE | **SOC × 256** (displayed SOC) | 12117.8 → 47.3 % |
  | BMS 188B | [53..56] | f32 LE | SOC × 256 (copy 2) | tracks copy 1 exactly |
  | BMS 188B | [150..153] | f32 LE | SOC × 256 (copy 3) | tracks ±0.2 |
  | BMS 188B | [12..13] | u16 LE | **pack voltage, mV** | 51 379 → 51.26–51.38 V, drifts down under load |
  | BMS 55B | [3..4] | u16 LE | voltage tap 2, mV | 53 351 → 53.35 V (rare frames: 55.28 V — charge state?) |
  | BMS 55B | [35..36] | u16 LE | voltage tap 3, mV | 52 543 → 52.39 V, drifts down |
  | BMS 55B | [39..40] | u16 LE | voltage tap 4, mV | 54 543 → 54.68 V, drifts up |
  | INV 70B | [14..15] | u16 LE | **AC output watts × 100** | 31 454/34 077 → 314.5/340.8 W (two load states) |
  - SOC × 256 as a float32 is what the app's `bms_bmsStatus.f32ShowSoc` (Float)
    field corresponds to; the app displays value/256. SOC trajectory during the
    capture: 47.3 % → 47.0 % (steady, ≈100 W draw) then a recalibration jump to
    44.9 % — classic LFP coulomb-count correction.
  - The MPPT 121B fields ([8..9], [18], [106]) are noisy in both captures —
    dusk/no-sun conditions; needs a sunny-day or AC-charging capture.
  - The EMS 147B frame (constant during the app capture) showed live fields in
    the 2 h-later client capture: [14..15], [19], [114] — worth a cross-session
    correlation once more captures exist.
- **Not yet fully mapped**: blob offsets → semantic names (watts in/out, remain
  time, temperatures). Definitive mapping = hook the app's R33 property receiver
  (Frida) while driving the device UI, or run a controlled load test and watch
  which fields move. Tooling: `ble/decode-telemetry.py` decodes + diffs any
  capture (works on both `efhook-capture.txt` and `session-test.log`).

---

## 2. What worked (chronological wins)

1. **APK acquisition & decompilation**: base + 3 splits pulled from `/data/app` via adb;
   jadx decompiled the Java; Ghidra 12.2 (with a locally built macos_arm64 decompiler
   native) decompiled `libnative-lib.so`.
2. **Plaintext handshake against the real device**: ECDH + keyInfo exchange worked from
   the first attempt; the device responded correctly to plaintext frames.
3. **CRC16 identification**: reflected 0xA001, init 0, verified against the app's HCI
   capture (`att-stream2.txt`).
4. **login_key table extraction**: located via the `.dynsym` symbol + GOT relocation,
   byte-exact (65,280 B).
5. **EcoFlow cloud login** (in-app, via the Frida-instrumented app): endpoints
   `api-a.ecoflow.com` / `api-s.ecoflow.com`, `/auth/login` with
   `password=MD5(pass)`, `password2=hex(HMAC-SHA256(k2, hex(HMAC-SHA1(k1, md5))))`.
6. **Frida-gadget instrumentation of the official app** (the decisive breakthrough):
   repackage as debuggable + inject `libfrida-gadget.so` via `wrap.sh`/smali, then hook
   `TreatyEngine` to dump `generateShareKey`, `aesDecryptKey`, `generateSessionKey`,
   `aesEncryptFrame`, `aesDecryptFrame`. This produced the app's session key, IV, and
   **every frame in plaintext** — the ground truth that solved everything.
7. **Session-key brute force**: given (seed, sRand, sessionKey) from the hooks, scanning
   the 65 KB table found the offset in seconds → byte-based formula proven.
8. **Offline decryption** of the captured frames (openssl AES-CBC) → the device's
   telemetry readable.
9. **The final Swift client** (`ble/ecoflow-session.swift`): handshake → auth →
   heartbeats → telemetry stream. Verified end-to-end against the device.

---

## 3. What didn't work (dead ends and why)

1. **`generateSessionKey` with 8-byte-unit offsets** (`seed[0]*128 + (seed[1]-1)*2048`):
   the Ghidra decompile showed pointer arithmetic through an `undefined8*` — the ×8
   scaling looked real but the device actually uses byte offsets. Result: silent NAKs.
2. **`share[0:16]` as the session key**: an "empirically confirmed" guess from a time
   when the frame format was ALSO wrong; any result derived from it was unreliable.
3. **Nested-`5a5a` inner frames**: we wrapped the inner as a full `5a5a 00 01 …` frame.
   The device's real inner format is the `aa 02 …` frame. **This single mistake caused
   every `f0 01` NAK** across dozens of test sessions.
4. **Direct cloud API login from the sandbox**: `/api/v1/login` (404) and `/auth/login`
   on `api.ecoflow.com` (rejected) — the app actually uses `api-a`/`api-s` hosts and a
   specific payload; also the sandbox had no direct network, so everything was relayed
   through `adb shell curl` on the phone.
5. **macOS mock peripheral**: macOS CoreBluetooth **cannot transmit manufacturer data**
   in advertisements (empirically proven: name+service adv visible, mfr-only adv absent
   from the phone's HCI capture). The app's add-device scan requires the mfr-data SN, so
   the mock was never seen. Also hit: a Swift `@main` lazy-static bug (the peripheral was
   never constructed) and repeated BT-stack resets from re-adding the service on every
   state callback.
6. **xlog decryption**: the app's logs are mars-xlog, ECDH+TEA-encrypted with a
   public key whose private half lives server-side → not decryptable offline.
7. **Decrypting the old btsnoop capture**: needs the app's ephemeral ECDH private key —
   unavailable.
8. **apktool full decode + rebuild**: rebuilding the 39 MB `resources.arsc` re-encoded
   IDs and dropped/mangled entries → `NotFoundException` crashes. (Fixed later by
   `apktool d -r` + zip-level assembly + installing the original splits alongside.)
9. **wrap.sh + LD_PRELOAD gadget**: worked once, then became unreliable (logwrapper
   forks the app after the gadget initializes; SELinux blocks the app process from
   reading `/data/local/tmp` scripts).
10. **Smali `System.loadLibrary("frida-gadget")` in attachBaseContext/onCreate**:
    the gadget dlopen'd mid-app-start hung in D-state and never ran its script.
11. **Forcing BLE by cutting the phone's network**: the app would not fall back to BLE
    automatically; a user tap was required.
12. **UI automation of the phone**: the screen kept re-locking (wireless adb also kept
    dropping), burning many cycles; eventually handed the driving to the user.
13. **Bluetooth over wireless-debugging adb**: port rotations + network cuts cost
    several reconnect rounds; **USB debugging is strictly better for this work**.

---

## 4. Mistakes made (honest log)

1. **Trusting the decompiler's pointer typing** (the ×8 scaling) — the device firmware's
   table indexing is byte-based. Lesson: verify any critical constant against runtime
   data; here a single captured (input → output) triple cracked it.
2. **Concluding "share[0:16] is the session key" from an experiment that also had a
   broken frame format** — two confounded variables. The NAKs were caused by the frame
   format, not the key.
3. **Using a nested `5a5a` inner frame for months of testing** — the real inner format
   (`aa 02 …`) was hiding in plain sight: `process.c` checks the first byte for `0xAA`,
   and the app's own capture showed `aa…` inner frames, but we never decrypted them until
   the Frida hooks.
4. **Mis-transcribing the captured secret key twice** (`A8AB1D06…`, then `A8ABD1D0…`
   instead of `AA8B1D06…`). The original derivation `MD5(userId + SN)` from the very
   first analysis was *correct* all along.
5. **The "protobuf field 71 tag fix" (`0xF8 0x04` → `0xB8 0x04`)** — we fixed a command
   (full-display-upload) the device never needed for this product.
6. **Reading the auth response wrongly** ("payload[1]==1 → OMOS") when the real
   response (`01 00`) simply means "already authenticated, normal path".
7. **Assuming productType 80 skips auth** — it doesn't; the app runs the standard
   getAuthStatus → checkAuth flow.
8. **Burning time on the mock-peripheral approach** before verifying the macOS
   manufacturer-data limitation.
9. **Reading the wrong arsc chunk** (TYPE_SPEC vs TYPE) while hunting the missing
   drawable → chased a wrong resource name for a while.
10. **My own aa-frame parser offset bug** (8-byte vs 12-byte header) after the big
    breakthrough — caught by decrypting and byte-diffing our outbound frame against the
    app's.
11. **`svc wifi disable` without an on-device restore timer** — killed adb twice and
    cost reconnection rounds.
12. **`@main` static property never referenced** in the mock — Swift lazily initializes
    statics, so the peripheral never started.
13. **Frida hook API misuse**: `Java.classExists` (absent in gadget 16.5.9) and
    `method.overload.apply` (not a function there) — killed scripts silently until
    rewritten with try/catch + explicit arity calls.
14. **Relative frida-gadget config paths** — resolved against the process CWD (`/`),
    not the config file's directory.
15. **Reading the aa-frame `len` as 1 byte and calling byte 3 "flags"** — the real
    layout is `len u16 LE` at [2..3]; the "ctr = 0x0db5/0x0d1b" values were actually
    `[hdr-crc8]=0x1b` + `[flags]=0x0d`. Our frames still worked because the device
    doesn't validate the header CRC8 or the ctr — but the corrected layout (with a
    real header CRC8) is what the app sends and is now implemented.
16. **Initial "0xF5-heavy frame" confusion** — those are the device's XOR-obfuscated
    telemetry frames (key = header[6] ^ 0x04), not a different encoding. Polluted
    the first varying-field analysis until the deobfuscation rule was found.

---

## 5. Debugging infrastructure that proved decisive

| Tool / technique | Use |
|---|---|
| jadx (two output trees: full + targeted) | Java-side protocol & auth flow (`EFBleEncryptHelper`, `BleAuthCommand`, `EFBleAuthNoDialogHelper`, `r1.getSecretKey`, …) |
| Ghidra 12.2 + locally built macos_arm64 decompiler | `generateSessionKey`, `aesEncryptFrame`, `xf_sscmd_v2_data_pack`, `xf_protocol_frame_unpack`, `unpack_encrypt_data` |
| `parse_btsnoop.py` + `att-stream2.txt` | the app's original BLE session (frame sizes, sequencing) |
| ELF/GOT/symbol inspection (python) | byte-exact `login_key` extraction & verification |
| **Frida gadget in a debuggable repackaged app** | THE ground truth: live session keys, IVs, and every frame in plaintext |
| `apktool d -r` + zip-level reassembly + `install-multiple` with signed splits | keeping `resources.arsc` intact while patching smali + manifest |
| `axml_patch.py` (custom binary-AXML editor) | adding `android:debuggable` — including the **attribute order fix** (sorted by resource id) and the **RES_XML_RESOURCE_MAP extension** (map entry → `0x0101000f`) |
| `aapt2 dump resources/xmltree` | authoritative resource table queries |
| openssl CLI | offline AES-CBC decrypt of captured ciphertexts |
| adb (USB!) + `run-as` + `uiautomator` | device control, app data access, UI inspection |
| Phone-side `curl` (via adb) | downloads when the sandbox had no network (apktool.jar, frida-gadget, build-tools) |

## 6. Telemetry state of knowledge

- **COMPLETE**: the app's own parser chain is decompiled and verified —
  `kt.a` (MR330BleCallBack) dispatches frames to `eu.t` (MR330ParseHelper),
  which fills the `Direct*HeartbeatPack` beans. Full field maps (every offset,
  size, name, and cross-session observed values) in **TELEMETRY-MAP.md**.
- Verified layers: outer 5a5a frame (crc16 0xA001), inner aa-frame 16-byte
  header with header-CRC8 (0x07) + trailing CRC16, payload XOR-obfuscation
  (`key = header[6] ^ 0x04` when `header[6] != 0x04`).
- Confirmed live metrics: SOC (f32×256, two synchronized copies), pack voltage
  (u16 mV), input/output watts, pack current, temps, cycles, sub-pack SNs.
- The definitive-mapping experiment: Frida v4 hook (`repack/efhook-v4.js`)
  revealed the parser class names at runtime; decompiling those classes gave
  the exact structs. Lesson: the v3 hook's `assemblePacket` interception broke
  the app's auth matching loop (getAuthStatus retry storm) — don't hook the
  parse chain's assembly step.
- **Device control (sending instructions)**: commands are the same encrypted
  AA-frames with src=0x21 and the module as dst. The client supports `--ac on|off`
  and `--set-time` (both captured byte-exact from the app) plus a generic
  `--send-cmd <src> <dst> <func> <id> <payloadhex>`. **Verified end-to-end**:
  `--ac off` → device relay clicked off, and the device's own MPPT telemetry
  reported `cfgAc=0` in every subsequent frame; `--ac on` also works (the relay
  engages with a soft-start delay and the cfgAc report flag lags behind). Auth nuance observed: after
  `getAuthStatus` the device may answer `05 04` (not `01 00`); the app then does
  setAuth (0x85) → success, and the telemetry stream starts after a checkAuth
  (0x86) — the client mirrors that sequence and always sends SET RTC after auth
  (as the app does).

## 7. Key file artifacts

```
ble/ecoflow-session.swift      working Swift client (handshake → auth → telemetry,
                               true header layout + payload deobfuscation + live
                               semantic decoding: SOC %, pack voltage, AC watts)
ble/SessionHandshake.swift     frame builders, CRC8+CRC16, aa-frame parse + deobfuscation,
                               key derivation
ble/Secp160.swift              secp160r1 EC math
ble/CryptoHelpers.swift        MD5 + AES-CBC
ble/decode-telemetry.py        capture decoder: outer decrypt → aa-parse → deobfuscate
                               → group + live-field diff with int/float hints
ble/capture-props.sh           one-shot Frida property-capture run (pushes repack/
                               efhook-v4.js, restarts the app, grabs logcat)
repack/efhook-v4.js            Frida hook: frame logs + onEvent class revelation
                               (the hook that cracked the parser identity)
jadx-pr708/                    decompiled MR330 parser chain: kt.a dispatcher,
                               eu.t parse helper, eu.* beans, Direct*HeartbeatPacks
TELEMETRY-MAP.md               DEFINITIVE field map (offset/size/name per frame)
ble/login-key-table.bin        65 KB session-key table
ble/att-stream2.txt            the app's original HCI session (pre-Frida)
ble/efhook-capture.txt         Frida hook log — app's keys + plaintext frames (gold)
ble/session-test.log           final successful run (719 KB, 2,084 DATA frames)
ble/decomp/*.c                 decompiled native functions
ble/decomp/*.so disassembly    (this analysis) header codec, CRC8/CRC16 tables+dispatch
ble/btsnoop-*.log              phone-side HCI captures
ble/mock-ecoflow.swift         (failed) mock peripheral experiment
ble/capture-app-session.sh     logcat + btsnoop capture helper
repack/                        APK repackaging pipeline (apktool, axml_patch.py,
                               efhook.js, debug keystore, signed splits)
repack/h5js/                   extracted H5 dashboard JS (product catalog; no R33 schema)
REPORT.md                      protocol spec (short form)
PROTOCOL-NOTES.md              this knowledge base
```

## 8. Current client usage

```bash
cd ble && swiftc -O -o ecoflow-session ecoflow-session.swift Secp160.swift \
  SessionHandshake.swift CryptoHelpers.swift
./ecoflow-session run --sn <SN> \
  --id <PERIPHERAL_UUID> \
  --seconds 120 --logfile session-test.log
```
(Requires macOS Bluetooth permission for the terminal running it.)
