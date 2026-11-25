// EcoFlowKit self-tests — run with `swift run EcoFlowKitTests`.
// Covers: golden frames vs the app's own bytes, CRC8/16, obfuscation,
// the full session state machine with REAL crypto (secp160r1 + AES +
// login_key table), heartbeat timing, busy-device timeout, reconnect backoff.
// Exits 0 when everything passes, 1 otherwise.
import Foundation
import EcoFlowKit

setbuf(stdout, nil)   // unbuffered — see prints even if a test crashes

var passed = 0
var failures: [String] = []

func check(_ cond: Bool, _ label: String) {
    if cond {
        passed += 1
        print("  ✔ \(label)")
    } else {
        failures.append(label)
        print("  ✘ \(label)")
    }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ label: String) {
    check(a == b, "\(label)\(a == b ? "" : "  [got \(a), want \(b)]")")
}

// MARK: shared fixtures

let deviceID = UUID(uuidString: "AA000000-0000-4000-8000-00000000E980")!

final class FakeTransport: Transport {
    weak var delegate: TransportDelegate?
    private(set) var writes: [(id: UUID, hex: String)] = []
    private(set) var scanned = false
    private(set) var connected: [UUID] = []
    private(set) var shutdowns = 0
    var displayName: String?

    func start() {}
    func scan() { scanned = true }
    func stopScan() {}
    func connect(id: UUID) {
        connected.append(id)
        delegate?.transport(self, didConnect: id, name: displayName)
        delegate?.transport(self, characteristicsReady: id, withoutResponse: false)
    }
    func shutdown() { shutdowns += 1 }
    func write(id: UUID, data: Data) { writes.append((id, [UInt8](data).hex)) }
    func displayName(id: UUID) -> String? { displayName }

    func powerOn() { delegate?.transport(self, didUpdateState: .poweredOn) }
    func discover(_ name: String?, id: UUID, rssi: Int = -48) {
        delegate?.transport(self, didDiscover: DiscoveredDevice(name: name, id: id, rssi: rssi))
    }
    func deliver(_ bytes: [UInt8], id: UUID) {
        delegate?.transport(self, didReceive: id, data: bytes)
    }
    func drop(id: UUID) { delegate?.transport(self, didDisconnect: id, error: nil) }
}

// Manual scheduler — tests fire timers by interval.
final class ManualScheduler {
    struct Entry { let interval: TimeInterval; let block: () -> Void }
    private(set) var entries: [Entry] = []
    func makeScheduler() -> Scheduler {
        { interval, block in
            let c = NoopCancellable()
            self.entries.append(Entry(interval: interval, block: block))
            return c
        }
    }
    func fire(_ interval: TimeInterval) {
        let blocks = entries.filter { $0.interval == interval }.map { $0.block }
        guard !blocks.isEmpty else { return }
        entries.removeAll { $0.interval == interval }
        blocks.forEach { $0() }
    }
    func has(_ interval: TimeInterval) -> Bool { entries.contains { $0.interval == interval } }
}

func makeSession(fake: FakeTransport, scheduler ms: ManualScheduler? = nil) -> EcoFlowSession {
    var config = EcoFlowSession.Config()
    config.authSecret = Array("0123456789ABCDEF0123456789ABCDEF".utf8)  // non-personal placeholder
    let session = EcoFlowSession(transport: fake, config: config, log: { _ in })
    if let ms { session.scheduler = ms.makeScheduler() }
    return session
}

/// Drive: start → discover → connect → pubkey → keyInfo. Device responses use
/// real crypto (a generated device keypair, chosen sRand/seed).
func driveToAuthRequest(fake: FakeTransport, session: EcoFlowSession) {
    session.start()
    fake.powerOn()
    check(fake.scanned, "session scans when no target id filter")
    fake.discover("Ecoflow-dev", id: deviceID)
    check(fake.connected.contains(deviceID), "connects to discovered device")
    check(fake.writes.count == 1, "pubkey exchange sent")
    check(fake.writes[0].hex.hasPrefix("5a5a00012c000100"), "pubkey frame header")

    // device pubkey response — real curve point from a generated keypair
    var devPrivBytes = [UInt8](repeating: 0, count: 20)
    devPrivBytes[19] = 0x2A                                   // small valid scalar
    let devPub40 = Curve160.publicKey(priv: Big(devPrivBytes))
    fake.deliver(Array(SessionHandshake.buildPlaintext([0x01, 0x00, 0x00] + devPub40)), id: deviceID)
    check(fake.writes.count == 2, "getKeyInfoReq sent")
    check(fake.writes[1].hex == "5a5a000103000286c2", "getKeyInfoReq bytes match the app's")

    // keyInfo response: AES(key16, iv, sRand || seed || pad)
    let sRand = [UInt8](repeating: 0x11, count: 16)
    let seed: [UInt8] = [0x05, 0x02]                          // login_key offset 336
    let plain = sRand + seed + [UInt8](repeating: 0x00, count: 14)
    guard let ct = aesCBCEncrypt(plain, key: session.hs.aesKey, iv: session.hs.aesIv) else {
        failures.append("keyInfo ct encrypt"); print("  ✘ keyInfo ct encrypt"); return
    }
    fake.deliver(Array(SessionHandshake.buildPlaintext([0x02] + ct)), id: deviceID)
    check(fake.writes.count == 3, "getAuthStatus sent")
}

/// Deliver the auth status + set/checkAuth acks until live.
func driveAuthToLive(fake: FakeTransport, session: EcoFlowSession, authed: Bool) {
    let authAck = SessionHandshake.buildAaEncrypted(src: 0x35, dst: 0x21, cmdFunc: 0x35, cmdId: 0x89,
                                                    payload: authed ? [0x01, 0x00] : [0x05, 0x04],
                                                    ctr: 0, ctr2: 0,
                                                    key: session.hs.sessionKey, iv: session.hs.aesIv)
    fake.deliver(Array(authAck), id: deviceID)
    if !authed {
        let setAck = SessionHandshake.buildAaEncrypted(src: 0x35, dst: 0x21, cmdFunc: 0x35, cmdId: 0x85,
                                                       payload: [0x00], ctr: 0, ctr2: 0,
                                                       key: session.hs.sessionKey, iv: session.hs.aesIv)
        fake.deliver(Array(setAck), id: deviceID)
    }
    let ok = SessionHandshake.buildAaEncrypted(src: 0x35, dst: 0x21, cmdFunc: 0x35, cmdId: 0x86,
                                               payload: [0x00], ctr: 0, ctr2: 0,
                                               key: session.hs.sessionKey, iv: session.hs.aesIv)
    fake.deliver(Array(ok), id: deviceID)
    check(session.phase == .live, "reached live phase")
}

func decryptLastWrite(fake: FakeTransport, session: EcoFlowSession) -> AaFrame? {
    guard let hex = fake.writes.last?.hex, let full = hexBytes(hex) else { return nil }
    let ct = Array(full[6..<(full.count - 2)])
    guard let plain = SessionHandshake.decryptBody(ct, key: session.hs.sessionKey, iv: session.hs.aesIv) else { return nil }
    return AaFrame.parse(plain)
}

func loadLoginKeyTable() -> [UInt8]? {
    for p in ["../ble/login-key-table.bin", "ble/login-key-table.bin"] {
        if let d = FileManager.default.contents(atPath: p) { return [UInt8](d) }
    }
    return nil
}

// MARK: tests

func testGoldenFrames() {
    print("golden frames (vs the app's own bytes):")
    let auth = SessionHandshake.buildAaFrame(len: 0, flags: 0x0d, ctr: 0, ctr2: 0,
                                             src: 0x21, dst: 0x35, cmdFunc: 0x35, cmdId: 0x89, payload: [])
    expectEqual(auth.hex, "aa020000b50d00000000000021353589c584", "getAuthStatus frame")
    let hb = SessionHandshake.buildAaFrame(len: 0, flags: 0x0d, ctr: 0, ctr2: 0,
                                           src: 0x21, dst: 0x02, cmdFunc: 0x20, cmdId: 0x59, payload: [])
    expectEqual(hb.hex, "aa020000b50d000000000000210220597b46", "heartbeat frame")
    let ac = SessionHandshake.buildAaFrame(len: 7, flags: 0x0d, ctr: 0, ctr2: 0,
                                           src: 0x21, dst: 0x05, cmdFunc: 0x20, cmdId: 0x42,
                                           payload: [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    expectEqual(ac[0...15].hex, "aa020700de0d00000000000021052042", "AC frame header")
    expectEqual(ac[16...22].hex, "01ffffffffffff", "AC frame payload")
}

func testCrc() {
    print("crc:")
    expectEqual(SessionHandshake.crc8([0xAA, 0x02, 0x00, 0x00]), UInt8(0xb5), "crc8 aa020000")
    expectEqual(SessionHandshake.crc8([0xAA, 0x02, 0x20, 0x00]), UInt8(0x1b), "crc8 aa022000")
    expectEqual(SessionHandshake.crc8([0xAA, 0x02, 0xBC, 0x00]), UInt8(0x06), "crc8 aa02bc00")
    expectEqual(SessionHandshake.crc8([0xAA, 0x02, 0x07, 0x00]), UInt8(0xde), "crc8 aa020700")
    let frame = SessionHandshake.buildAaFrame(len: 7, flags: 0x0d, ctr: 0, ctr2: 0,
                                              src: 0x21, dst: 0x05, cmdFunc: 0x20, cmdId: 0x42,
                                              payload: [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    let stored = UInt16(frame[frame.count - 2]) | (UInt16(frame[frame.count - 1]) << 8)
    expectEqual(stored, SessionHandshake.crc16(Array(frame[0..<(frame.count - 2)])), "crc16 round-trip")
}

func testObfuscation() {
    print("obfuscation:")
    for ctr in [UInt32(4), UInt32(0)] {
        let built = SessionHandshake.buildAaFrame(len: 7, flags: 0x0d, ctr: ctr, ctr2: 0,
                                                  src: 0x21, dst: 0x05, cmdFunc: 0x20, cmdId: 0x42,
                                                  payload: [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        let parsed = SessionHandshake.parseAaFrame(built)
        check(parsed?.obfuscated == false && parsed?.payload == [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
              "clear frame (hdr[6]=0x\(String(format: "%02x", ctr)))")
    }
    let plain: [UInt8] = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]
    for (ctr, key) in [(UInt32(0xf5), UInt8(0xf1)), (UInt32(0xb8), UInt8(0xbc))] {
        let built = SessionHandshake.buildAaFrame(len: 7, flags: 0x0d, ctr: ctr, ctr2: 0,
                                                  src: 0x21, dst: 0x05, cmdFunc: 0x20, cmdId: 0x42,
                                                  payload: plain)
        let parsed = SessionHandshake.parseAaFrame(built)
        check(parsed?.obfuscated == true && parsed?.payload == plain.map { $0 ^ key },
              "masked frame (hdr[6]=0x\(String(format: "%02x", ctr)), key 0x\(String(format: "%02x", key)))")
    }
}

func testSessionKeyDerivation() {
    print("session key derivation (real crypto chain):")
    let fake = FakeTransport()
    let session = makeSession(fake: fake)
    driveToAuthRequest(fake: fake, session: session)
    guard let table = loadLoginKeyTable() else {
        check(false, "login-key-table.bin present"); return
    }
    check(true, "login-key-table.bin loaded")
    let expectedKey = [UInt8](md5(Data(Array(table[336..<352])) + Data([UInt8](repeating: 0x11, count: 16))).prefix(16))
    expectEqual(session.hs.sessionKey, expectedKey, "sessionKey = MD5(login_key[336..] || sRand)")
}

func testAuthedSequence() {
    print("authed sequence → live:")
    let fake = FakeTransport()
    let ms = ManualScheduler()
    let session = makeSession(fake: fake, scheduler: ms)
    driveToAuthRequest(fake: fake, session: session)
    driveAuthToLive(fake: fake, session: session, authed: true)
    check(session.phase == .live, "phase == live")
    check(session.failure == nil, "no failure")
    check(ms.has(20.0), "heartbeat scheduled at 20 s")
}

func testUnauthedPath() {
    print("unauthed path (05 04 → setAuth → checkAuth):")
    let fake = FakeTransport()
    let ms = ManualScheduler()
    let session = makeSession(fake: fake, scheduler: ms)
    driveToAuthRequest(fake: fake, session: session)
    let before = fake.writes.count
    driveAuthToLive(fake: fake, session: session, authed: false)
    check(session.phase == .live, "reached live via setAuth path")
    check(fake.writes.count == before + 3, "setAuth + checkAuth + RTC sent")
    // the second write after the ack must be the checkAuth frame (0x86, ack 00)
    if let hex = fake.writes[before + 1].hex as String?, let full = hexBytes(hex),
       let plain = SessionHandshake.decryptBody(Array(full[6..<(full.count - 2)]),
                                                key: session.hs.sessionKey, iv: session.hs.aesIv),
       let frame = AaFrame.parse(plain) {
        check(frame.cmdFunc == 0x35 && frame.cmdId == 0x86, "checkAuth frame sent after setAuth ack")
    } else {
        check(false, "checkAuth frame sent after setAuth ack")
    }
}

func testCommandQueueAndDecode() {
    print("command queue + frame decode:")
    let fake = FakeTransport()
    let ms = ManualScheduler()
    let session = makeSession(fake: fake, scheduler: ms)
    session.sendCommand(src: 0x21, dst: 0x05, cmdFunc: 0x20, cmdId: 0x42,
                        payload: [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    check(fake.writes.isEmpty, "command queued before live")
    driveToAuthRequest(fake: fake, session: session)
    driveAuthToLive(fake: fake, session: session, authed: true)
    check(session.phase == .live, "live")
    guard let frame = decryptLastWrite(fake: fake, session: session) else {
        check(false, "last write decrypts"); return
    }
    check(frame.src == 0x21 && frame.dst == 0x05, "AC frame routing (21→05)")
    check(frame.cmdFunc == 0x20 && frame.cmdId == 0x42, "AC frame cmd 0x20/0x42")
    check(frame.payload == [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF], "AC frame payload")
}

func testHeartbeat() {
    print("heartbeat:")
    let fake = FakeTransport()
    let ms = ManualScheduler()
    let session = makeSession(fake: fake, scheduler: ms)
    driveToAuthRequest(fake: fake, session: session)
    driveAuthToLive(fake: fake, session: session, authed: true)
    let before = fake.writes.count
    ms.fire(20.0)
    check(fake.writes.count == before + 1, "heartbeat sent on tick")
    guard let frame = decryptLastWrite(fake: fake, session: session) else {
        check(false, "heartbeat decrypts"); return
    }
    check(frame.src == 0x21 && frame.dst == 0x02, "heartbeat routing (21→02)")
    check(frame.cmdFunc == 0x20 && frame.cmdId == 0x59, "heartbeat cmd 0x20/0x59")
    check(frame.payload.isEmpty, "heartbeat payload empty")
    check(ms.has(20.0), "heartbeat reschedules itself")
}

func testBusyTimeout() {
    print("busy-device timeout:")
    let fake = FakeTransport()
    let ms = ManualScheduler()
    let session = makeSession(fake: fake, scheduler: ms)
    session.config.authTimeout = 10
    driveToAuthRequest(fake: fake, session: session)   // stage 2, ack never arrives
    check(ms.has(10.0), "auth timeout armed")
    ms.fire(10.0)
    check(session.failure == .busyDevice, "failure = busyDevice")
    check(fake.shutdowns >= 1, "transport shut down")
    check(session.phase == .idle, "phase idle after failure")
}

func testReconnectBackoff() {
    print("reconnect backoff:")
    let fake = FakeTransport()
    let ms = ManualScheduler()
    let session = makeSession(fake: fake, scheduler: ms)
    driveToAuthRequest(fake: fake, session: session)
    driveAuthToLive(fake: fake, session: session, authed: true)

    // drops WITHOUT re-reaching live grow the backoff; entering live resets it
    var expectedDelay: TimeInterval = 1
    for attempt in 1...5 {
        fake.drop(id: deviceID)
        check(ms.has(expectedDelay), "backoff attempt \(attempt) scheduled at \(expectedDelay)s")
        ms.fire(expectedDelay)
        check(fake.connected.count == attempt + 1, "reconnect attempt \(attempt) connected")
        expectedDelay = min(16, expectedDelay * 2)
    }
    fake.drop(id: deviceID)
    check(session.failure == .linkLost, "gives up after 5 attempts with linkLost")
}

func testEventStream() {
    print("event stream (onEvent):")
    let fake = FakeTransport()
    let session = makeSession(fake: fake)
    var events: [EcoFlowSession.Event] = []
    session.onEvent = { events.append($0) }
    driveToAuthRequest(fake: fake, session: session)
    driveAuthToLive(fake: fake, session: session, authed: true)
    // deliver one telemetry frame (BMS heartbeat, 55B) → .frame event
    var bms = [UInt8](repeating: 0x00, count: 55)
    bms[26] = 0x20; bms[27] = 0x2F   // SOC float32 bytes → 47.0 %
    let bmsFrame = SessionHandshake.buildAaEncrypted(src: 0x03, dst: 0x21, cmdFunc: 0x20, cmdId: 0x02,
                                                     payload: bms, ctr: 0x04, ctr2: 0,
                                                     key: session.hs.sessionKey, iv: session.hs.aesIv)
    fake.deliver(Array(bmsFrame), id: deviceID)
    let phases = events.compactMap { if case .phase(let p) = $0 { return p }; return nil }
    check(phases.contains(.handshake), "event: handshake phase")
    check(phases.contains(.auth), "event: auth phase")
    check(phases.contains(.live), "event: live phase")
    check(events.contains { if case .frame = $0 { return true } else { return false } }, "event: frames emitted")
}

// MARK: cloud auth (pure parts — no network)

func testCloudAuth() {
    print("cloud auth")
    let auth = EcoFlowCloudAuth(region: .global)

    // email login request: shape + base64 password
    let req = try! auth.loginRequest(identifier: "user@example.com", password: "s3cret")
    check(req.url?.absoluteString == "https://api.ecoflow.com/auth/login", "login: global host URL")
    expectEqual(req.httpMethod, "POST", "login: POST method")
    let body = String(data: req.httpBody!, encoding: .utf8)!
    check(body.contains("\"scene\":\"IOT_APP\""), "login: scene IOT_APP")
    check(body.contains("\"userType\":\"ECOFLOW\""), "login: userType ECOFLOW")
    check(body.contains("\"password\":\"\(Data("s3cret".utf8).base64EncodedString())\""),
          "login: password is base64")
    check(body.contains("\"email\":\"user@example.com\""), "login: email field")
    check(body.contains("\"phone\"") == false, "login: no phone field for email")

    // phone identifiers route to the CN host
    let phoneReq = try! auth.loginRequest(identifier: "+8613800138000", password: "pw")
    check(phoneReq.url?.host == "api-cn.ecoflow.com", "login: phone routes to CN host")
    check(String(data: phoneReq.httpBody!, encoding: .utf8)!.contains("\"phone\":\"13800138000\""),
          "login: phone field, +86 stripped")

    // userId extraction: success shape used by the official app
    let ok = #"{"code":"0","message":"Success","data":{"token":"tok","user":{"userId":"1234567890123456789"}}}"#
    let uid = try! EcoFlowCloudAuth.userId(fromResponse: Data(ok.utf8))
    expectEqual(uid, "1234567890123456789", "parse: userId extracted")

    // API-level failure surfaces code+message
    let fail = #"{"code":"401","message":"密码错误"}"#
    var threw: Error?
    do { _ = try EcoFlowCloudAuth.userId(fromResponse: Data(fail.utf8)) }
    catch { threw = error }
    expectEqual(threw as? EcoFlowCloudError,
                EcoFlowCloudError.apiError(code: "401", message: "密码错误"),
                "parse: api error surfaced")

    // garbage → invalidResponse
    threw = nil
    do { _ = try EcoFlowCloudAuth.userId(fromResponse: Data("not json".utf8)) }
    catch { threw = error }
    expectEqual(threw as? EcoFlowCloudError, EcoFlowCloudError.invalidResponse,
                "parse: garbage rejected")

    // secret derivation: MD5hex(userId + SN), uppercase — matches the
    // device-verified auth packet bytes
    expectEqual(EcoFlowCloudAuth.bleSecret(userId: "u", deviceSN: "s"),
                md5(Data("us".utf8)).map { String(format: "%02X", $0) }.joined(),
                "secret: MD5hex(userId+SN) uppercase")
}

// MARK: run all

testGoldenFrames()
testCrc()
testObfuscation()
testSessionKeyDerivation()
testAuthedSequence()
testUnauthedPath()
testCommandQueueAndDecode()
testHeartbeat()
testBusyTimeout()
testReconnectBackoff()
testEventStream()
testCloudAuth()

print()
if failures.isEmpty {
    print("ALL \(passed) CHECKS PASSED")
    exit(0)
} else {
    print("FAILED \(failures.count) of \(passed + failures.count) checks:")
    failures.forEach { print("  ✘ \($0)") }
    exit(1)
}
