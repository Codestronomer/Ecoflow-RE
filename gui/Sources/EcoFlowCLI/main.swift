// EcoFlow CLI — thin wrapper over EcoFlowKit (same flags/behaviour as before
// the M0 restructure). Protocol logic lives in EcoFlowKit.
import Foundation
import EcoFlowKit

@main
struct EcoFlowMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let client = SessionClient()

        if args.first == "run" {
            var i = 1
            while i < args.count {
                switch args[i] {
                case "--sn": i += 1; client.sn = args[i]
                case "--id": i += 1; client.targetID = UUID(uuidString: args[i])
                case "--seconds": i += 1; client.runtimeSeconds = Int(args[i]) ?? 300
                case "--set-time": client.sendSetTime = true
                case "--secret":
                    i += 1
                    if let b = hexBytes(args[i]) { client.authSecret = b }
                    else { print("bad --secret hex"); exit(1) }
                case "--ac":
                    // verified from the app: AC toggle = 21→05 (MPPT), 0x20/0x42,
                    // payload [state][ff x6]; 0x01=on 0x00=off
                    i += 1
                    let on = (args[i] == "on")
                    client.enqueueCommand(src: 0x21, dst: 0x05, cmdFunc: 0x20, cmdId: 0x42,
                                          payload: [on ? 0x01 : 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
                case "--send-cmd":
                    // --send-cmd <src> <dst> <cmd_func> <cmd_id> <payload-hex>
                    // e.g. RTC: --send-cmd 21 03 03 40 ea070b1611231e07
                    guard i + 5 < args.count else { print("--send-cmd needs src dst func id payloadhex"); exit(1) }
                    if let s = UInt8(args[i+1], radix: 16), let d = UInt8(args[i+2], radix: 16),
                       let cf = UInt8(args[i+3], radix: 16), let ci = UInt8(args[i+4], radix: 16),
                       let pl = hexBytes(args[i+5]) {
                        client.enqueueCommand(src: s, dst: d, cmdFunc: cf, cmdId: ci, payload: pl)
                    } else { print("bad --send-cmd args"); exit(1) }
                    i += 5
                case "--logfile": i += 1
                    let path = args[i]
                    _ = FileManager.default.createFile(atPath: path, contents: nil)
                    if let fh = FileHandle(forWritingAtPath: path) {
                        dup2(fh.fileDescriptor, 1); dup2(fh.fileDescriptor, 2); setbuf(stdout, nil)
                    }
                default: break
                }
                i += 1
            }
            client.runtimeSeconds = max(client.runtimeSeconds, 60)
            if client.authSecret.isEmpty,
               let env = ProcessInfo.processInfo.environment["ECOFLOW_AUTH_SECRET"],
               let b = hexBytes(env) {
                client.authSecret = b
            }
            if client.authSecret.isEmpty {
                print("[auth] note: no auth secret set (--secret <32hex> or ECOFLOW_AUTH_SECRET)")
            }
        } else {
            print("usage: ecoflow-session run [--sn SN] [--id UUID] [--seconds N] [--logfile path]")
            print("          [--secret <32hex>] [--set-time] [--ac on|off]")
            print("          [--send-cmd <src> <dst> <func> <id> <payloadhex>]...")
            exit(0)
        }
        client.run()
    }
}
