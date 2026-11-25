import CoreBluetooth
import Foundation
import SentryKeyProtocol

public enum BluetoothError: Error, Equatable {
    /// Bluetooth is off, not allowed for this program, or the phone is not
    /// known to this Mac.
    case unavailable
    case timedOut
    case disconnected
    /// The device does not offer the SentryKey service.
    case serviceNotFound
}

/// One Bluetooth connection from the Mac to the phone (ARCHITECTURE.md,
/// BLECentral). The Mac is the central: it connects, writes its messages to
/// one characteristic and is notified of the phone's on another.
///
/// It only moves whole messages and gives no security. One object serves one
/// connection: after `close()` or a failure, make a new one.
///
/// NOT YET RUN: written from Apple's CoreBluetooth documentation and checked
/// by the compiler only. No Mac with the iPhone was available.
final class BluetoothLink: NSObject, @unchecked Sendable {
    enum Target {
        /// The phone recorded at pairing. No scan: iOS hides the service of
        /// a backgrounded app from a Mac that scans.
        case known(UUID)
        /// Any device advertising the service. Only during pairing, with the
        /// phone's app in the foreground.
        case anyAdvertising
    }

    /// Messages from the phone, still untrusted.
    let incoming: AsyncStream<TransportMessage>
    private let received: AsyncStream<TransportMessage>.Continuation

    // Everything below is only touched on `queue`, where CoreBluetooth also
    // delivers its callbacks. That is what makes this class safe to share.
    private let queue = DispatchQueue(label: "SentryKey.bluetooth")
    private var manager: CBCentralManager?
    private var target = Target.anyAdvertising
    private var peripheral: CBPeripheral?
    private var toPhone: CBCharacteristic?
    private var reassembler = Reassembler(maxMessageLength: TransportMessage.maxLength)
    private var pendingOpen: CheckedContinuation<UUID, Error>?
    private var pendingWrite: CheckedContinuation<Void, Error>?
    private var isClosed = false

    override init() {
        (incoming, received) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
        super.init()
    }

    /// Connects and returns the phone's Bluetooth identifier, to record at
    /// pairing. Gives up after `timeout`: CoreBluetooth itself would wait
    /// forever for a phone that is not there.
    func open(_ target: Target, timeout: TimeInterval) async throws -> UUID {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.target = target
                self.pendingOpen = continuation
                self.manager = CBCentralManager(delegate: self, queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    guard self.pendingOpen != nil else { return }
                    self.fail(BluetoothError.timedOut)
                }
            }
        }
    }

    /// Sends one whole message. One call at a time.
    func send(_ message: TransportMessage) async throws {
        let chunkSize = try await onQueue { () throws -> Int in
            guard let peripheral = self.peripheral, !self.isClosed else { throw BluetoothError.disconnected }
            return peripheral.maximumWriteValueLength(for: .withResponse)
        }
        let chunks = try Framing.chunks(
            for: message.encoded(), chunkSize: chunkSize, maxMessageLength: TransportMessage.maxLength
        )
        for chunk in chunks {
            try await write(Data(chunk))
        }
    }

    func close() {
        queue.async { self.fail(BluetoothError.disconnected) }
    }

    /// Each chunk is acknowledged by the phone before the next is sent, so
    /// they arrive in order.
    private func write(_ chunk: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard let peripheral = self.peripheral, let toPhone = self.toPhone, !self.isClosed,
                      self.pendingWrite == nil
                else {
                    continuation.resume(throwing: BluetoothError.disconnected)
                    return
                }
                self.pendingWrite = continuation
                peripheral.writeValue(chunk, for: toPhone, type: .withResponse)
            }
        }
    }

    private func onQueue<Value: Sendable>(_ body: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }

    /// Ends the connection and everything waiting on it. Called on `queue`.
    private func fail(_ error: Error) {
        guard !isClosed else { return }
        isClosed = true
        if let peripheral { manager?.cancelPeripheralConnection(peripheral) }
        manager?.stopScan()
        pendingOpen?.resume(throwing: error)
        pendingOpen = nil
        pendingWrite?.resume(throwing: error)
        pendingWrite = nil
        received.finish()
    }

    private func connect(to found: CBPeripheral) {
        // CoreBluetooth does not keep the peripheral alive itself.
        peripheral = found
        found.delegate = self
        manager?.connect(found)
    }
}

extension BluetoothLink: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            guard peripheral == nil, !isClosed else { return }
            switch target {
            case .known(let identifier):
                guard let known = central.retrievePeripherals(withIdentifiers: [identifier]).first else {
                    return fail(BluetoothError.unavailable)
                }
                connect(to: known)
            case .anyAdvertising:
                central.scanForPeripherals(withServices: [CBUUID(string: BluetoothLayout.service)])
            }
        case .poweredOff, .unauthorized, .unsupported:
            fail(BluetoothError.unavailable)
        default:
            // Still starting up: another state follows.
            break
        }
    }

    func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        guard self.peripheral == nil else { return }
        central.stopScan()
        connect(to: peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([CBUUID(string: BluetoothLayout.service)])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        fail(BluetoothError.disconnected)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        fail(BluetoothError.disconnected)
    }
}

extension BluetoothLink: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: BluetoothLayout.service) }) else {
            return fail(BluetoothError.serviceNotFound)
        }
        peripheral.discoverCharacteristics(
            [CBUUID(string: BluetoothLayout.toPhone), CBUUID(string: BluetoothLayout.toMac)], for: service
        )
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let characteristics = service.characteristics ?? []
        guard let toPhone = characteristics.first(where: { $0.uuid == CBUUID(string: BluetoothLayout.toPhone) }),
              let toMac = characteristics.first(where: { $0.uuid == CBUUID(string: BluetoothLayout.toMac) })
        else {
            return fail(BluetoothError.serviceNotFound)
        }
        self.toPhone = toPhone
        // The phone treats the subscription as the start of the connection.
        peripheral.setNotifyValue(true, for: toMac)
    }

    func peripheral(
        _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?
    ) {
        guard error == nil, characteristic.isNotifying else { return fail(BluetoothError.serviceNotFound) }
        pendingOpen?.resume(returning: peripheral.identifier)
        pendingOpen = nil
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value,
              let messages = try? reassembler.append(value)
        else {
            // The stream is out of step and cannot be trusted any more.
            return fail(BluetoothError.disconnected)
        }
        for message in messages {
            guard let parsed = try? TransportMessage.parse(message) else {
                return fail(BluetoothError.disconnected)
            }
            received.yield(parsed)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            return fail(error)
        }
        pendingWrite?.resume()
        pendingWrite = nil
    }
}
