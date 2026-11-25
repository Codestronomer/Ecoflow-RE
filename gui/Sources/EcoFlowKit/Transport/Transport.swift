// Transport abstraction — the session engine is testable against a fake
// transport; RealBleTransport implements it over CoreBluetooth.
import Foundation

public enum TransportState: Equatable {
    case poweredOn
    case poweredOff
    case unauthorized
    case other(Int)
}

public struct DiscoveredDevice: Equatable {
    public let name: String?
    public let id: UUID
    public let rssi: Int

    public init(name: String?, id: UUID, rssi: Int) {
        self.name = name
        self.id = id
        self.rssi = rssi
    }
}

public protocol TransportDelegate: AnyObject {
    func transport(_ t: Transport, didUpdateState state: TransportState)
    func transport(_ t: Transport, didDiscover device: DiscoveredDevice)
    func transport(_ t: Transport, didConnect id: UUID, name: String?)
    func transport(_ t: Transport, didDisconnect id: UUID, error: Error?)
    func transport(_ t: Transport, didReceive id: UUID, data: [UInt8])
    func transport(_ t: Transport, didFailWrite id: UUID, error: Error?)
    /// All needed characteristics were discovered and notify is subscribed.
    func transport(_ t: Transport, characteristicsReady id: UUID, withoutResponse: Bool)
}

public protocol Transport: AnyObject {
    var delegate: TransportDelegate? { get set }
    /// Bring the radio up (CBCentralManager init). Events follow.
    func start()
    func scan()
    func stopScan()
    func connect(id: UUID)
    /// Stop everything and drop any open connection.
    func shutdown()
    /// Send data; the transport handles write type and chunking.
    func write(id: UUID, data: Data)
    /// Human-readable peripheral name if known.
    func displayName(id: UUID) -> String?
}

// MARK: scheduling (injectable for tests)

public protocol Cancellable: AnyObject {
    func cancel()
}

public typealias Scheduler = (_ interval: TimeInterval, _ block: @escaping () -> Void) -> Cancellable

public final class TimerCancellable: Cancellable {
    private let timer: Timer
    public init(_ timer: Timer) { self.timer = timer }
    public func cancel() { timer.invalidate() }
}

public final class NoopCancellable: Cancellable {
    public init() {}
    public func cancel() {}
}

/// One-shot Timer on the current run loop (matches the proven CLI behaviour:
/// callbacks arrive on the main thread).
public func defaultScheduler(_ interval: TimeInterval, _ block: @escaping () -> Void) -> Cancellable {
    let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in block() }
    return TimerCancellable(t)
}
