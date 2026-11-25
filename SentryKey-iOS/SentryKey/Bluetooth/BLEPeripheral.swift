import CoreBluetooth
import Foundation
import SentryKeyProtocol

/// The phone as a Bluetooth peripheral (ARCHITECTURE.md, BLEPeripheral): it
/// advertises the SentryKey service, the Mac connects, writes its messages
/// to one characteristic and receives the phone's on another.
///
/// This class only moves whole messages. It gives no security: any device in
/// range can connect and write. Everything it hands over is untrusted until
/// the secure channel has checked it.
///
/// NOT YET RUN ON A DEVICE. Written from Apple's CoreBluetooth documentation
/// and checked by the compiler only. State restoration in particular has to
/// be confirmed on the iPhone.
@MainActor
final class BLEPeripheral: NSObject {
    /// Lets iOS relaunch the app in the background when a Mac writes to it.
    private static let restoreIdentifier = "SentryKey.peripheral"
    /// Devices handled at once. The paired Macs need one each. The limit
    /// stops strangers in range from taking unlimited memory.
    private static let maxCentrals = 4
    /// Chunks that may wait to be sent to one device.
    private static let maxQueuedChunks = 4096

    private struct Connection {
        let central: CBCentral
        var reassembler = Reassembler(maxMessageLength: TransportMessage.maxLength)
    }

    /// A device subscribed: it can now receive messages.
    var onConnect: (UUID) -> Void = { _ in }
    var onDisconnect: (UUID) -> Void = { _ in }
    /// One whole message from a device, still untrusted.
    var onMessage: (UUID, [UInt8]) -> Void = { _, _ in }

    private var manager: CBPeripheralManager?
    private var toPhone = CBMutableCharacteristic(
        type: CBUUID(string: BluetoothLayout.toPhone), properties: [.write], value: nil, permissions: [.writeable]
    )
    private var toMac = CBMutableCharacteristic(
        type: CBUUID(string: BluetoothLayout.toMac), properties: [.notify], value: nil, permissions: [.readable]
    )
    private var isServicePublished = false
    private var connections: [UUID: Connection] = [:]
    private var outgoing: [(central: CBCentral, chunk: Data)] = []

    /// Starts Bluetooth. The first call makes iOS ask the user's permission.
    func start() {
        guard manager == nil else { return }
        manager = CBPeripheralManager(
            delegate: self, queue: .main,
            options: [CBPeripheralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier]
        )
    }

    /// Sends one whole message to a subscribed device.
    func send(_ message: [UInt8], to identifier: UUID) {
        guard let connection = connections[identifier],
              let chunks = try? Framing.chunks(
                  for: message,
                  chunkSize: connection.central.maximumUpdateValueLength,
                  maxMessageLength: TransportMessage.maxLength
              ),
              outgoing.count + chunks.count <= Self.maxQueuedChunks
        else {
            return
        }
        outgoing += chunks.map { (connection.central, Data($0)) }
        flush()
    }

    /// Sends queued chunks until Bluetooth's own buffer is full. iOS calls
    /// back when there is room again.
    private func flush() {
        guard let manager else { return }
        while let next = outgoing.first {
            guard manager.updateValue(next.chunk, for: toMac, onSubscribedCentrals: [next.central]) else { return }
            outgoing.removeFirst()
        }
    }

    private func publishService() {
        guard let manager, manager.state == .poweredOn else { return }
        if !isServicePublished {
            let service = CBMutableService(type: CBUUID(string: BluetoothLayout.service), primary: true)
            service.characteristics = [toPhone, toMac]
            manager.add(service)
            isServicePublished = true
        }
        if !manager.isAdvertising {
            manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: BluetoothLayout.service)]])
        }
    }

    private func drop(_ identifier: UUID) {
        guard connections.removeValue(forKey: identifier) != nil else { return }
        outgoing.removeAll { $0.central.identifier == identifier }
        onDisconnect(identifier)
    }

    private func handleWrites(_ requests: [CBATTRequest]) {
        guard let manager, let first = requests.first else { return }
        for request in requests {
            let identifier = request.central.identifier
            // Only a subscribed device may write, and only whole values to
            // the right characteristic.
            guard request.characteristic.uuid == toPhone.uuid, request.offset == 0,
                  var connection = connections[identifier], let value = request.value
            else {
                manager.respond(to: first, withResult: .writeNotPermitted)
                return
            }
            do {
                let messages = try connection.reassembler.append(value)
                connections[identifier] = connection
                for message in messages {
                    onMessage(identifier, message)
                }
            } catch {
                // The stream is out of step and cannot be trusted any more.
                drop(identifier)
                manager.respond(to: first, withResult: .unlikelyError)
                return
            }
        }
        // iOS wants one answer for the whole batch, given to its first request.
        manager.respond(to: first, withResult: .success)
    }
}

// CoreBluetooth calls these on the main queue, as asked in `start()`.
extension BLEPeripheral: CBPeripheralManagerDelegate {
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        MainActor.assumeIsolated {
            publishService()
        }
    }

    /// iOS relaunched the app for a Bluetooth event: the service it kept
    /// published comes back here, and must not be added a second time.
    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        MainActor.assumeIsolated {
            guard let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] else { return }
            for characteristic in services.flatMap({ $0.characteristics ?? [] }) {
                guard let restored = characteristic as? CBMutableCharacteristic else { continue }
                if restored.uuid == toPhone.uuid { toPhone = restored }
                if restored.uuid == toMac.uuid {
                    toMac = restored
                    // Devices that were subscribed still are.
                    for central in restored.subscribedCentrals ?? [] where connections.count < Self.maxCentrals {
                        connections[central.identifier] = Connection(central: central)
                    }
                }
            }
            isServicePublished = !services.isEmpty
        }
    }

    nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic
    ) {
        MainActor.assumeIsolated {
            guard characteristic.uuid == toMac.uuid, connections[central.identifier] == nil,
                  connections.count < Self.maxCentrals
            else { return }
            connections[central.identifier] = Connection(central: central)
            onConnect(central.identifier)
        }
    }

    /// Also called when the device disconnects.
    nonisolated func peripheralManager(
        _ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        MainActor.assumeIsolated {
            drop(central.identifier)
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        MainActor.assumeIsolated {
            handleWrites(requests)
        }
    }

    nonisolated func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        MainActor.assumeIsolated {
            flush()
        }
    }
}
