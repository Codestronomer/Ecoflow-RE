// RealBleTransport — CoreBluetooth implementation of Transport.
// Callbacks arrive on the main thread (queue: nil), matching the proven CLI:
// the session's timers then run on the main run loop.
import Foundation
import CoreBluetooth

public final class RealBleTransport: NSObject, Transport, CBCentralManagerDelegate, CBPeripheralDelegate {
    public weak var delegate: TransportDelegate?
    public var log: ((String) -> Void)?

    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var writeChar: [UUID: CBCharacteristic] = [:]
    private var notifyChar: [UUID: CBCharacteristic] = [:]
    private var maxWrite: [UUID: Int] = [:]
    private var canWriteNR: [UUID: Bool] = [:]
    private var names: [UUID: String] = [:]

    public override init() { super.init() }

    public func start() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: nil)
        }
    }

    public func scan() {
        central?.scanForPeripherals(withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    public func stopScan() { central?.stopScan() }

    public func connect(id: UUID) {
        if let p = central?.retrievePeripherals(withIdentifiers: [id]).first {
            peripherals[p.identifier] = p
            p.delegate = self
            central?.connect(p, options: nil)
        }
    }

    public func shutdown() {
        for (_, p) in peripherals { central?.cancelPeripheralConnection(p) }
        writeChar.removeAll(); notifyChar.removeAll()
    }

    public func write(id: UUID, data: Data) {
        guard let p = peripherals[id], let ch = writeChar[id] else { return }
        let type: CBCharacteristicWriteType = (canWriteNR[id] ?? false) ? .withoutResponse : .withResponse
        var chunk = maxWrite[id] ?? p.maximumWriteValueLength(for: type)
        if chunk <= 0 { chunk = 20 }
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + chunk, bytes.count)
            p.writeValue(Data(bytes[offset..<end]), for: ch, type: type)
            offset = end
        }
    }

    public func displayName(id: UUID) -> String? { names[id] ?? peripherals[id]?.name }

    // MARK: CBCentralManagerDelegate

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:     delegate?.transport(self, didUpdateState: .poweredOn)
        case .poweredOff:    delegate?.transport(self, didUpdateState: .poweredOff)
        case .unauthorized:  delegate?.transport(self, didUpdateState: .unauthorized)
        default:             delegate?.transport(self, didUpdateState: .other(central.state.rawValue))
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
        if let n = name { names[peripheral.identifier] = n }
        delegate?.transport(self, didDiscover: DiscoveredDevice(name: name, id: peripheral.identifier, rssi: RSSI.intValue))
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripherals[peripheral.identifier] = peripheral
        peripheral.delegate = self
        peripheral.discoverServices(nil)
        delegate?.transport(self, didConnect: peripheral.identifier, name: peripheral.name)
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        delegate?.transport(self, didDisconnect: peripheral.identifier, error: error)
    }

    // MARK: CBPeripheralDelegate

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for s in peripheral.services ?? [] {
            log?("[svc] \(s.uuid)")
            peripheral.discoverCharacteristics(nil, for: s)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let id = peripheral.identifier
        for ch in service.characteristics ?? [] {
            var props: [String] = []
            if ch.properties.contains(.notify) { props.append("notify") }
            if ch.properties.contains(.write) { props.append("write") }
            if ch.properties.contains(.writeWithoutResponse) { props.append("writeNR") }
            log?("  [chr] \(ch.uuid) [\(props.joined(separator: ","))]")

            if (ch.properties.contains(.notify) || ch.properties.contains(.indicate)), notifyChar[id] == nil {
                notifyChar[id] = ch
            }
            if (ch.properties.contains(.write) || ch.properties.contains(.writeWithoutResponse)), writeChar[id] == nil {
                writeChar[id] = ch
                let type: CBCharacteristicWriteType = ch.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
                canWriteNR[id] = ch.properties.contains(.writeWithoutResponse)
                maxWrite[id] = peripheral.maximumWriteValueLength(for: type)
            }
        }
        if let n = notifyChar[id], service.characteristics?.contains(n) == true {
            peripheral.setNotifyValue(true, for: n)
            log?("[ble] subscribed \(n.uuid)")
        }
        if writeChar[id] != nil, notifyChar[id] != nil {
            delegate?.transport(self, characteristicsReady: id, withoutResponse: canWriteNR[id] ?? false)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic == notifyChar[peripheral.identifier], let v = characteristic.value else { return }
        delegate?.transport(self, didReceive: peripheral.identifier, data: [UInt8](v))
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let e = error { delegate?.transport(self, didFailWrite: peripheral.identifier, error: e) }
    }
}
