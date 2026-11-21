# EcoFlow E980 (R33, productType 80) BLE Protocol — COMPLETE VERIFICATION

Status: ✅ BIDIRECTIONAL BLE COMMUNICATION ACHIEVED — device streams telemetry to our client.
Verified: 2026-11-22 via (a) the official app's own live session (Frida-instrumented) and
(b) our independent Swift client completing the same handshake + auth against the device.

## Frame format (all values little-endian)

Plaintext (handshake):  5a5a 00 01 <len> <payload> <crc16>
Encrypted (session):    5a5a 10 01 <len> AES-128-CBC(sessionKey, iv, INNER+PKCS-pad) <crc16>
  crc16 = reflected poly 0xA001, init 0, over header+payload (verified vs 752+ frames).

## Handshake
1. app → dev:  5a5a 00 01 <01 00 pub40>          (secp160r1, curve type 0)
2. dev → app:  5a5a 00 01 <01 00 00 devPub40>
3. share = X(priv * devPub)  (20B)   key16 = share[0:16]   iv = MD5(share[0:20])
4. app → dev:  5a5a 00 01 <02>                      (getKeyInfoReq)
5. dev → app:  5a5a 00 01 <02 ct32>   → AES-CBC(key16, iv, ct) = sRand16 || seed2 || pad
6. sessionKey = MD5( login_key[ seed[0]*16 + (seed[1]-1)*256 .. +16 ] || sRand )[0:16]
   — brute-force confirmed from the app session: seed 05 02 → offset 336 → key 2a7e6a52…

## Inner session frame ("AA-frame") — inside the encryption
aa 02 <len> <flags> <ctr 4B> <ctr2 4B> <src> <dst> <cmd_func> <cmd_id> <payload len B> <crc16>

## Auth sequence (app-verified)
1. getAuthStatus: aa 02 00 00 b50d0000 00000000 21 35 35 89
   → dev: aa 02 02 00 … 35 21 35 89 <01 00>   (payload[0]=1 → already authed)
2. checkAuth:     aa 02 20 00 1b0d0000 00000000 21 35 35 86 <secretKey32>
   secretKey = MD5hex(userId + sn)   (userId "<USER_ID>" + "<SN>")
             = <AUTH_SECRET>
   → dev: aa 02 01 00 … 35 21 35 86 <00>     (00 = success)
3. heartbeat:     aa 02 00 00 b50d0000 00000000 21 02 20 59  (every 20 s)
4. Device streams telemetry: src=03 dst=21 cmd=03/0e and src=02 dst=21 cmd=20/02
   — 2000+ data frames captured; payload = device property data (TLV-ish, live values).

## Key facts
- login_key table: 65280B at .so offset 0x2a73ec (symbol login_key, 4080×16B).
- The 8-byte-unit scaling in generateSessionKey.c was an artifact — the device uses
  plain byte offsets: seed[0]*16 + (seed[1]-1)*256.
- Secret key is per-user+device: MD5(userId + SN), not HMAC'd.

## Client
ble/ecoflow-session.swift — working client (handshake + auth + telemetry).
