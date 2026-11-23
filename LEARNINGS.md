# Session Learnings — EcoFlow E980 BLE Reverse-Engineering

Extracted 2026-11-22 from the full project session (protocol capture → client
build → telemetry decoding). Written for reuse in future embedded-device
reverse-engineering work.

---

## Patterns Discovered

### Pattern: Instrument the official app for ground truth
- **Context**: When a device protocol is encrypted/obfuscated and static analysis
  stalls, the official companion app already contains a working, complete
  implementation of the protocol. Hook it.
- **Implementation**: Repackage the APK as debuggable + embed Frida gadget via
  `wrap.sh` (LD_PRELOAD — NOT smali `System.loadLibrary`, which hung in D-state).
  Hook the crypto primitives (`aesEncryptFrame`/`aesDecryptFrame`/`generateSessionKey`)
  and **log key+iv in every hook line** so the capture is self-decryptable offline.
- **Example**:
  ```js
  TE.aesDecryptFrame.overload('[B', '[B', '[B').implementation = function (key, iv, data) {
      var r = this.aesDecryptFrame(key, iv, data);
      console.log(TAG + "aesDecryptFrame key=" + toHex(key) + " iv=" + toHex(iv) + " frame=" + toHex(data));
      return r;
  };
  ```

### Pattern: Runtime class revelation via dynamic hook enumeration
- **Context**: In heavily obfuscated apps, static analysis can't find the class
  that consumes the data. Enumerate loaded classes at runtime and hook a known
  interface method on every match — log `this.getClass().getName()` to reveal
  which concrete class handles each event.
- **Implementation**: `Java.enumerateLoadedClasses` + `cls.onEvent.overload(...)`
  with try/catch per class; **rescan periodically** (classes load after connect),
  guarding with a `hookedNames` map so late scans only hook new classes.
- **Example** (from repack/efhook-v4.js — this pattern cracked the whole parser):
  ```js
  var m = cls.onEvent.overload('int', 'com.ecoflow.cbb.smartdevice.bean.EcoPacket');
  m.implementation = function (i, pkt) {
      console.log(TAG + "onEvent cls=" + name + " payload=" + toHex(pkt.getPayLoad()));
      return m.call(this, i, pkt);
  };
  ```
  Result: one log line identified `com.ecoflow.energyStorageModule.pr708.PR708EnergyManageActivity$a`
  → decompiling its superclass chain (`kt.a` → `eu.t` → `Direct*HeartbeatPack`)
  produced the complete field map.

### Pattern: XOR-obfuscation detection via value-state clustering
- **Context**: A payload byte-stream where ~25% of frames look "corrupted" with
  high bytes (0xF0+). This is often whole-payload XOR masking with a rotating key.
- **Implementation**: For each offset, collect the per-frame value distribution
  (`Counter`). Normal frames form one cluster; obfuscated frames form a second
  cluster at `value ^ key`. Test candidate keys = `(obf_value ^ normal_value)`.
  Then hunt the key source in the frame header — here it was `header[6] ^ 0x04`
  (byte[6] == 0x04 = "no masking" sentinel).
- **Example**:
  ```python
  key = p[0] ^ ref[0]          # candidate from first byte
  dec = bytes(b ^ key for b in p)
  match = sum(a == b for a, b in zip(dec, ref))
  # validate against strictly-stable positions only (real data varies!)
  ```

### Pattern: Validate decompiler output against captured runtime data
- **Context**: Ghidra/Ghidra decompilations of pointer arithmetic are frequently
  wrong (type confusion, extra derefs, wrong scaling). Any formula that matters
  must be confirmed against observed (input → output) pairs from a live capture.
- **Implementation**: Brute-force/scan candidate interpretations against the
  table and one known triple. A single (seed, sRand, sessionKey) triple from the
  app's live session proved `offset = seed[0]*16 + (seed[1]-1)*256` and disproved
  the decompiler's ×8 scaling.
- **Example** (session key discovery):
  ```python
  for off in range(0, 65280, 16):
      key = md5(table[off:off+16] + sRand)[:16]
      if key == captured_key: found(off)
  ```

### Pattern: Cross-session correlation to confirm field semantics
- **Context**: Field units are ambiguous from a single capture (12.1V vs 47.3% SOC).
  Two captures at different device states (SOC 47% vs 89%) disambiguate: values
  that scale with state = the metric.
- **Implementation**: Diff the same frame type across sessions; classify each
  changed offset; anchor with published product specs (980 Wh LiFePO4 ⇒ 48 V
  class ⇒ a float32 of 12118 **cannot** be mV ⇒ it's SOC×256).
- **Example**: pack voltage `u16@12` 51379→52160 mV between the two sessions ✓;
  the "12.1V" interpretation was killed by the spec.

### Pattern: ELF data-table location via symbol + program headers
- **Context**: Locating byte-exact embedded tables (login keys, CRC tables) in a
  stripped-ish native lib without running it.
- **Implementation**: `nm -C` for the symbol (e.g. `login_key`, `crc16_table`),
  then walk ELF64 program headers (PT_LOAD) for VA→file-offset mapping, then dump.
  CRC8/CRC16 table entry[1] reveals the reflected polynomial directly
  (table[1] = poly for reflected, init-0 table generation).
- **Example**:
  ```python
  def va_to_off(va):
      for ph in program_headers:
          if ph.p_type == 1 and ph.p_vaddr <= va < ph.p_vaddr + ph.p_filesz:
              return ph.p_offset + (va - ph.p_vaddr)
  ```

### Pattern: Derive the TLV/struct layout from the app's OWN parser
- **Context**: Guessing wire formats (TLV walks) is a rabbit hole. The app that
  displays the data contains the authoritative struct: field name, size, order.
- **Implementation**: Find the dispatch class (tag string often survives
  obfuscation: "MR330BleCallBack", "MR330ParseHelper"), decompile it, then follow
  the bean classes. `rk.i.r(buf, off, field)` calls + `byte[] field = new byte[N]`
  declarations give offset+size+name for every field.

---

## Best Practices Applied

1. **Log key+iv inside crypto hooks**
   - Why: makes every capture independently decryptable later, no re-capture needed.
   - When: any Frida hook of crypto functions.

2. **Bisect the hook set when the target misbehaves**
   - Why: v2 hooks worked (1,255 frames); v3 broke auth (getAuthStatus retry storm);
     v4 = v2 + minimal addition worked → isolated the culprit (assemblePacket hook).
   - When: the instrumented app stalls after a hook change.

3. **Never hook the middle of a request/response matching loop**
   - Why: a hook on `assemblePacket` (parse chain assembly) silently broke ack
     matching → infinite retry. Hook at boundaries; keep call-throughs trivial.
   - When: instrumenting task/ack protocols.

4. **Salvage from the phone's logcat buffer after failed captures**
   - Why: adb logcat ring buffer retains minutes of logs; a USB drop kills your
     capture file but not the device-side buffer (`adb logcat -d`).
   - When: capture interrupted.

5. **Resolve launcher activities dynamically**
   - Why: hardcoded `com.ecoflow/.launch.LaunchActivity` didn't exist in the
     installed version (SplashActivity did) → silent zero-byte captures.
   - When: scripting app relaunches. Use
     `adb shell cmd package resolve-activity --brief <pkg>`.

6. **Anchor units with published product specs before concluding**
   - Why: "f32 = 12118" was ambiguous until specs (980Wh LFP, 48V-class) ruled
     out voltage and confirmed SOC×256.
   - When: interpreting numeric telemetry fields.

7. **Keep every raw capture; re-parse later**
   - Why: the morning capture (17:35) was the reference for cross-session diffs
     hours later; old logcats answered new questions.
   - When: RE sessions that span days.

8. **USB adb over wireless adb for device work**
   - Why: `svc wifi disable` killed wireless adb twice; USB survives network
     changes and is stable for long logcat captures.
   - When: any phone-assisted RE.

---

## Mistakes to Avoid

1. **Hooking the parse-chain assembly step (assemblePacket)**
   - What went wrong: the hook installed fine but the call-through/log threw
     before the log line, killing ack→task matching silently → the app retried
     getAuthStatus forever; no error surfaced anywhere.
   - Prevention: never hook request/response assembly; if you must, wrap the
     call-through in try/catch and log hook-install success explicitly; bisect
     hook sets after any behavioral change.

2. **Piping a long capture script through `head`**
   - What went wrong: `bash capture.sh | head -20` → SIGPIPE killed the script
     early; near-zero-byte capture.
   - Prevention: never pipe orchestration scripts through early-exiting consumers.

3. **Hardcoded launcher activity**
   - What went wrong: `am start -n com.ecoflow/.launch.LaunchActivity` failed
     (Error type 3) and the monkey fallback didn't fire → app never launched →
     two wasted capture rounds.
   - Prevention: resolve dynamically (see best practice 5), and echo the resolved
     component so failures are visible.

4. **USB disconnection mid-capture with no recovery**
   - What went wrong: capture file was 0 bytes; the salvage only worked because
     the device-side buffer hadn't rotated yet (it had, that time).
   - Prevention: write the capture in chunks (`logcat >> file` with periodic
     flushes), verify byte count grows after the first seconds, and pull the
     device buffer immediately on reconnect.

5. **Reading multi-byte values across struct boundaries**
   - What went wrong: my u16@[39..40] "54.54V" field was actually two 1-byte
     fields (close_oil_eb_soc + padding); the real layout came from the app's
     struct definitions.
   - Prevention: don't finalize multi-byte reads before having the authoritative
     struct; cross-check against the app's field sizes.

6. **Filtering logcat to only the gadget tag**
   - What went wrong: `logcat -s wrap.sh` captured the hooks but dropped the
     app's own diagnostic logs ("Before parseData", "包含sn") which would have
     shortcut hours of work.
   - Prevention: capture the full logcat; filter later. Disk is cheap.

7. **Trusting obfuscated-name guesses over runtime evidence**
   - What went wrong: I assumed `kt.k` was the 55B parser (jadx "class not found")
     when the same-package `eu.k` was the real one — found only by following the
     actual call graph in the decompiled dispatcher.
   - Prevention: trace call sites, don't guess class names.

8. **Lengthy manual TLV-guessing before finding the parser**
   - What went wrong: multiple TLV-walk attempts on payloads that were fixed
     structs; the answer was one decompile away.
   - Prevention: time-box blind format guessing; pivot to the app's parser early.

---

## Reusable Snippets

### ELF VA → file offset (Python, ELF64)
```python
import struct
def va_to_off(so, va):
    e_phoff = struct.unpack_from('<Q', so, 0x20)[0]
    e_phentsize = struct.unpack_from('<H', so, 0x36)[0]
    e_phnum = struct.unpack_from('<H', so, 0x38)[0]
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type = struct.unpack_from('<I', so, off)[0]
        p_offset, p_vaddr = struct.unpack_from('<QQ', so, off + 8)
        p_filesz = struct.unpack_from('<Q', so, off + 32)[0]
        if p_type == 1 and p_vaddr <= va < p_vaddr + p_filesz:
            return p_offset + (va - p_vaddr)
    return None
```

### Reflected CRC16 (0xA001) / CRC8 (0x07) — the EcoFlow frame checks
```python
def crc16(data, poly=0xA001):
    c = 0
    for b in data:
        c ^= b
        for _ in range(8):
            c = (c >> 1) ^ poly if c & 1 else c >> 1
    return c & 0xFFFF

def crc8(data, poly=0xE0):          # 0xE0 = reflected 0x07
    c = 0
    for b in data:
        c ^= b
        for _ in range(8):
            c = (c >> 1) ^ poly if c & 1 else c >> 1
    return c & 0xFF
```

### Batch AES-CBC decrypt of captured frames via openssl CLI
```python
r = subprocess.run(['openssl', 'enc', '-d', '-aes-128-cbc',
                    '-K', key.hex(), '-iv', iv.hex(), '-nopad'],
                   input=ciphertext, capture_output=True)
plain = r.stdout
pad = plain[-1]
if 0 < pad <= 16 and plain.endswith(bytes([pad]) * pad):
    plain = plain[:-pad]
```

### Frida periodic class-enumeration hook (safe, re-scanning)
```js
function scan() {
    Java.enumerateLoadedClasses({
        onMatch: function (name) {
            if (hookedNames[name]) return;
            try {
                var m = Java.use(name).onEvent.overload('int', 'com.ecoflow.cbb.smartdevice.bean.EcoPacket');
                m.implementation = function (i, pkt) {
                    console.log("onEvent cls=" + name + " payload=" + toHex(pkt.getPayLoad()));
                    return m.call(this, i, pkt);
                };
                hookedNames[name] = 1;
            } catch (e) {}
        }
    });
}
scan();                        // immediately
var pass = 1;
var iv = setInterval(function () { if (++pass <= 8) scan(); else clearInterval(iv); }, 20000);
```

### adb capture harness (with dynamic launcher resolution)
```bash
LAUNCH=$(adb -s "$ID" shell cmd package resolve-activity --brief "$PKG" | tail -1)
adb -s "$ID" shell am force-stop "$PKG"
adb -s "$ID" logcat -c
adb -s "$ID" shell am start -n "$LAUNCH"
adb -s "$ID" logcat -v time > capture.txt &   # NO -s filter; no head pipe
```

### Stable-position field diff (separate data from noise)
```python
from collections import Counter
norm = [p for p in payloads if clear(p)]
ref = norm[0]
stable = [i for i in range(L) if all(p[i] == ref[i] for p in norm)]
# only validate deobfuscation / diff sessions on `stable` positions
```

---

## Instincts

```json
[
  {"trigger": "Device protocol is encrypted and static analysis stalls",
   "action": "Repackage the official companion app with a Frida gadget (wrap.sh LD_PRELOAD) and hook its crypto primitives, logging key+iv with every frame so captures are self-decryptable",
   "confidence": 0.95, "source": "session-extraction", "timestamp": "2026-11-22T23:00:00Z"},
  {"trigger": "Payloads show a bimodal byte distribution where one mode is ~value XOR key",
   "action": "Cluster per-offset value distributions; candidate key = obf_value XOR normal_value; validate on strictly-stable positions only; then find the key source in the frame header",
   "confidence": 0.85, "source": "session-extraction", "timestamp": "2026-11-22T23:00:00Z"},
  {"trigger": "Decompiler-derived offset formula or scaling matters for correctness",
   "action": "Verify against at least one captured runtime (input → output) triple before implementing; brute-force the constant space if needed",
   "confidence": 0.9, "source": "session-extraction", "timestamp": "2026-11-22T23:00:00Z"},
  {"trigger": "Instrumented target app misbehaves after adding hooks",
   "action": "Bisect the hook set (revert to last-known-good, add back one at a time); never hook request/response assembly methods",
   "confidence": 0.9, "source": "session-extraction", "timestamp": "2026-11-22T23:00:00Z"},
  {"trigger": "Cannot find the data-consuming class in an obfuscated app",
   "action": "Enumerate loaded classes at runtime and hook a known interface method on all matches, logging this.getClass().getName(); rescan periodically for late-loaded classes",
   "confidence": 0.85, "source": "session-extraction", "timestamp": "2026-11-22T23:00:00Z"},
  {"trigger": "Telemetry field units are ambiguous from one capture",
   "action": "Take a second capture in a different device state and diff; anchor interpretations with published product specs (voltage class, rated watts)",
   "confidence": 0.85, "source": "session-extraction", "timestamp": "2026-11-22T23:00:00Z"},
  {"trigger": "Scripting an Android app relaunch for instrumentation",
   "action": "Resolve the launcher activity dynamically with 'cmd package resolve-activity --brief'; never hardcode it",
   "confidence": 0.9, "source": "session-extraction", "timestamp": "2026-11-22T23:00:00Z"},
  {"trigger": "Long adb logcat capture or device-driven test",
   "action": "Prefer USB adb (wireless dies when WiFi is toggled); capture the FULL logcat without tag filters; write the output with >> and verify it grows before waiting",
   "confidence": 0.9, "source": "session-extraction", "timestamp": "2026-11-22T23:00:00Z"},
  {"trigger": "Blind TLV/format guessing on a device payload",
   "action": "Time-box guessing; pivot early to decompiling the app that displays the data and follow its parser chain to the authoritative struct definitions",
   "confidence": 0.8, "source": "session-extraction", "timestamp": "2026-11-22T23:00:00Z"}
]
```

---

## Suggested Skill Updates

This project has no `skills/` or `rules/` tree (standalone RE workspace). If the
learnings were to be promoted:

- **`skills/ble-protocol-re/SKILL.md`** (new): the ground-truth-via-instrumented-app
  pattern, aa-frame/CRC/XOR-obfuscation specifics, the capture harness, and the
  runtime-class-revelation hook — directly reusable for the next EcoFlow device
  (DELTA/RIVER families share this protocol).
- **`rules/reverse-engineering.md`** (new): "verify decompiled constants against
  runtime data", "never hook assembly steps of match loops", "USB adb only",
  "save every capture".
- `continuous-learning-v2` instincts: the 9 entries above.
