// EcoFlow CLI — thin wrapper over EcoFlowKit (same flags/behaviour as before
// the M0/M1 restructure). Protocol logic lives in EcoFlowKit.
import Foundation
import EcoFlowKit

@main
struct EcoFlowMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        var config = EcoFlowSession.Config()
        var runtimeSeconds = 300
        var logfile: String?
        var loginCreds: (identifier: String, password: String)?
        var loginRegion: EcoFlowRegion = .global

        let transport = RealBleTransport()
        let client = EcoFlowSession(transport: transport, config: config, log: { print($0) })

        if args.first == "run" {
            var i = 1
            while i < args.count {
                switch args[i] {
                case "--sn": i += 1; config.sn = args[i]
                case "--id": i += 1; config.targetID = UUID(uuidString: args[i])
                case "--seconds": i += 1; runtimeSeconds = Int(args[i]) ?? 300
                case "--set-time": config.sendSetTime = true
                case "--secret":
                    i += 1
                    if let b = hexBytes(args[i]) { config.authSecret = b }
                    else { print("bad --secret hex"); exit(1) }
                case "--ac":
                    // verified from the app: AC toggle = 21→05 (MPPT), 0x20/0x42,
                    // payload [state][ff x6]; 0x01=on 0x00=off
                    i += 1
                    let on = (args[i] == "on")
                    client.sendCommand(src: 0x21, dst: 0x05, cmdFunc: 0x20, cmdId: 0x42,
                                       payload: [on ? 0x01 : 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
                case "--send-cmd":
                    // --send-cmd <src> <dst> <cmd_func> <cmd_id> <payload-hex>
                    // e.g. RTC: --send-cmd 21 03 03 40 ea070b1611231e07
                    guard i + 5 < args.count else { print("--send-cmd needs src dst func id payloadhex"); exit(1) }
                    if let s = UInt8(args[i+1], radix: 16), let d = UInt8(args[i+2], radix: 16),
                       let cf = UInt8(args[i+3], radix: 16), let ci = UInt8(args[i+4], radix: 16),
                       let pl = hexBytes(args[i+5]) {
                        client.sendCommand(src: s, dst: d, cmdFunc: cf, cmdId: ci, payload: pl)
                    } else { print("bad --send-cmd args"); exit(1) }
                    i += 5
                case "--logfile": i += 1
                    logfile = args[i]
                case "--login":
                    // --login <email-or-phone> <password>: resolve the auth
                    // secret via EcoFlow's cloud login — no userId hunting.
                    guard i + 2 < args.count else {
                        print("--login needs <email-or-phone> <password>"); exit(1)
                    }
                    loginCreds = (args[i+1], args[i+2])
                    i += 2
                case "--region":
                    guard i + 1 < args.count else { print("--region needs a name"); exit(1) }
                    i += 1
                    let names = args[i].lowercased()
                    guard let r = EcoFlowRegion.allCases.first(where: {
                        String(describing: $0).lowercased() == names
                    }) else {
                        print("--region: unknown region (use global/europe/us/asia/japan/russia/china)")
                        exit(1)
                    }
                    loginRegion = r
                default: break
                }
                i += 1
            }
            runtimeSeconds = max(runtimeSeconds, 60)
            if config.authSecret.isEmpty,
               let env = ProcessInfo.processInfo.environment["ECOFLOW_AUTH_SECRET"],
               let b = hexBytes(env) {
                config.authSecret = b
            }
            if let (identifier, password) = loginCreds {
                guard !(config.sn ?? "").isEmpty else {
                    print("--login requires --sn <serial number> to derive the secret"); exit(1)
                }
                let auth = EcoFlowCloudAuth(region: loginRegion)
                print("[auth] signing in to EcoFlow (\(loginRegion.host))…")
                let sem = DispatchSemaphore(value: 0)
                var result: Result<String, Error>?
                Task {
                    do { result = .success(try await auth.fetchUserId(identifier: identifier, password: password)) }
                    catch { result = .failure(error) }
                    sem.signal()
                }
                sem.wait()
                switch result! {
                case .success(let userId):
                    let secret = EcoFlowCloudAuth.bleSecret(userId: userId, deviceSN: config.sn!)
                    config.authSecret = Array(secret.utf8)
                    print("[auth] resolved userId, derived secret from SN (stored in memory only)")
                case .failure(let error):
                    print("[auth] login failed: \(error)")
                    exit(1)
                }
            }
            if config.authSecret.isEmpty {
                print("[auth] note: no auth secret set (--secret <32hex>, --login, or ECOFLOW_AUTH_SECRET)")
            }
            client.config = config
            if let path = logfile {
                _ = FileManager.default.createFile(atPath: path, contents: nil)
                if let fh = FileHandle(forWritingAtPath: path) {
                    dup2(fh.fileDescriptor, 1); dup2(fh.fileDescriptor, 2); setbuf(stdout, nil)
                }
            }
        } else {
            print("usage: ecoflow-session run [--sn SN] [--id UUID] [--seconds N] [--logfile path]")
            print("          [--secret <32hex> | --login <email-or-phone> <password> [--region global|europe|us|asia|japan|russia|china]]")
            print("          [--sn SN] [--set-time] [--ac on|off]")
            print("          [--send-cmd <src> <dst> <func> <id> <payloadhex>]...")
            exit(0)
        }
        client.start()
        let deadline = Date().addingTimeInterval(TimeInterval(runtimeSeconds + 60))
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        }
        client.stop()
    }
}
