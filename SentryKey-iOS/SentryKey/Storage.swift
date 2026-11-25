import Foundation
import SentryKeyProtocol

/// Saves the pairing flag, the paired Macs and server names in one JSON file.
///
/// The file uses `complete` data protection (CLAUDE.md): it is unreadable
/// while the phone is locked. It holds no secret, only public keys,
/// fingerprints and the names the user typed.
struct Storage {
    struct Saved: Codable {
        var isPaired = false
        var knownHosts = KnownHosts()
        /// Identity public keys of the paired Macs. Optional so a file
        /// written before this field existed still loads.
        var pairedMacKeys: [[UInt8]]?
    }

    private var url: URL {
        URL.applicationSupportDirectory.appending(path: "state.json")
    }

    enum Loaded {
        case saved(Saved)
        /// First launch: no file yet.
        case none
        /// The file exists but cannot be read now, for example while the
        /// phone is locked (`complete` protection). Do not overwrite it.
        case unavailable
    }

    func load() -> Loaded {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return .none
        } catch {
            return .unavailable
        }
        guard let saved = try? JSONDecoder().decode(Saved.self, from: data) else {
            return .unavailable
        }
        return .saved(saved)
    }

    func save(isPaired: Bool, knownHosts: KnownHosts, pairedMacKeys: [[UInt8]]) {
        let saved = Saved(isPaired: isPaired, knownHosts: knownHosts, pairedMacKeys: pairedMacKeys)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder().encode(saved).write(to: url, options: [.atomic, .completeFileProtection])
            // The Keychain key is ThisDeviceOnly and never restored, so a
            // restored "paired" flag would point at a key that is gone.
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var file = url
            try file.setResourceValues(values)
        } catch {
            // Losing a server name is not a security problem: the prompt
            // falls back to the fingerprint. Never log the names themselves.
        }
    }
}
