import Foundation
import Observation
import UIKit

/// A short record of Bluetooth events, each with the state the app was in.
///
/// It exists to answer the architecture's first open question on a real
/// iPhone: when the Mac writes to the phone, does iOS wake the app, and
/// does the app get far enough to answer and to post its notification?
/// See `docs/BLE_WAKE_TEST.md`.
///
/// Event names and times only: no key, no server, no user name. It is
/// shown in Settings in Debug builds, and records nothing in a Release
/// build: its file has weaker protection than CLAUDE.md asks of the app's
/// files, which is acceptable for a test tool only.
@MainActor
@Observable
final class WakeLog {
    struct Entry: Codable, Identifiable {
        var id = UUID()
        let date: Date
        let event: String
        /// "active", "inactive" or "background" when the event happened.
        let appState: String
    }

    static let shared = WakeLog()
    private static let maxEntries = 300

    private(set) var entries: [Entry]

    private static var url: URL {
        URL.applicationSupportDirectory.appending(path: "wake-log.json")
    }

    private init() {
        #if DEBUG
        entries = (try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: Self.url))) ?? []
        #else
        entries = []
        #endif
    }

    func record(_ event: String) {
        #if DEBUG
        entries.append(Entry(date: .now, event: event, appState: Self.currentAppState()))
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
        save()
        #endif
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        // Unlike the app's other files, this one must be writable while the
        // phone is locked: that is the very case it is here to observe. It
        // holds nothing sensitive.
        try? FileManager.default.createDirectory(
            at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? JSONEncoder().encode(entries).write(
            to: Self.url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    private static func currentAppState() -> String {
        switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }
}
