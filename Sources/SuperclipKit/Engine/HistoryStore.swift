import CryptoKit
import Foundation

/// The on-disk form of a clip. Deliberately smaller than the in-memory entry:
/// the process id is meaningless across launches, and window titles routinely
/// carry document names, client names, and ticket subjects that have no business
/// outliving the session that produced them.
struct PersistedClip: Codable, Equatable {
    let text: String
    let appName: String?
    let bundleID: String?
    let capturedAt: Date

    init(text: String, appName: String?, bundleID: String?, capturedAt: Date) {
        self.text = text
        self.appName = appName
        self.bundleID = bundleID
        // Whole seconds, deliberately. A `Date` is encoded as a JSON number and
        // decoded back through a decimal string, and that is not always
        // bit-identical — so a timestamp drifted very slightly on every
        // save/load cycle. Nothing here needs finer resolution than a second:
        // the retention window is measured in days and the only other consumer
        // is a "5 minutes ago" label. Rounding makes the round-trip exact by
        // construction rather than approximately true.
        self.capturedAt = Date(timeIntervalSince1970: capturedAt.timeIntervalSince1970.rounded())
    }
}

/// Encrypted, aging clipboard history on disk.
///
/// Three properties matter more than anything else here, and each is enforced
/// rather than documented:
///
/// - The file is useless without the key, and the key never leaves the machine.
/// - Nothing survives past the retention window, so the file cannot quietly
///   become a years-long transcript of everything the user copied.
/// - A corrupt or tampered file loses history rather than producing wrong
///   history. Authenticated encryption makes that failure mode automatic.
enum HistoryStore {

    // MARK: - Pure core (no keychain, no filesystem)

    /// Serializes and seals. AES-GCM is authenticated, so any modification to
    /// the stored bytes is detected on read instead of decrypting to garbage.
    static func seal(_ clips: [PersistedClip], key: SymmetricKey) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let plaintext = try encoder.encode(clips)
        return try AES.GCM.seal(plaintext, using: key).combined ?? Data()
    }

    /// Opens and deserializes. Throws on a wrong key, a truncated file, or a
    /// single flipped bit.
    static func open(_ data: Data, key: SymmetricKey) throws -> [PersistedClip] {
        let box = try AES.GCM.SealedBox(combined: data)
        let plaintext = try AES.GCM.open(box, using: key)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode([PersistedClip].self, from: plaintext)
    }

    /// Drops anything past the retention window and anything past the cap.
    /// Applied on both write and read, so shortening the window takes effect on
    /// the next save rather than waiting for entries to be re-examined.
    static func applyRetention(_ clips: [PersistedClip],
                               days: Int,
                               cap: Int,
                               now: Date = Date()) -> [PersistedClip] {
        guard days > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return clips
            .filter { $0.capturedAt > cutoff }
            .sorted { $0.capturedAt > $1.capturedAt }
            .prefix(cap)
            .map { $0 }
    }

    // MARK: - Location

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("Superclip", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("history.dat") }

    // MARK: - Disk

    /// Not main-actor isolated, deliberately. Reading the store touches the
    /// keychain, and the keychain can put a modal authorization prompt in front
    /// of the caller — on the main thread that means a frozen app. Callers run
    /// this off-main and apply the result back on the main actor.
    static func load(retentionDays: Int, cap: Int) -> [PersistedClip] {
        guard retentionDays > 0 else { return [] }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        guard let key = HistoryKey.existing() else {
            // A file with no key is unreadable by construction. Remove it rather
            // than leaving ciphertext lying around that nothing can ever open.
            Log.write("history: file present but no key — discarding")
            try? FileManager.default.removeItem(at: fileURL)
            return []
        }
        do {
            let clips = try open(data, key: key)
            let kept = applyRetention(clips, days: retentionDays, cap: cap)
            Log.write("history: loaded \(clips.count), kept \(kept.count) after retention")
            return kept
        } catch {
            // Authenticated decryption failed. The honest response is to lose
            // the history, not to guess at what it might have said.
            Log.write("history: could not open store — discarding (\(error))")
            try? FileManager.default.removeItem(at: fileURL)
            return []
        }
    }

    /// Off-main for the same reason as `load`.
    static func save(_ clips: [PersistedClip], retentionDays: Int, cap: Int) {
        guard retentionDays > 0 else { purge(); return }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let kept = applyRetention(clips, days: retentionDays, cap: cap)
            let sealed = try seal(kept, key: HistoryKey.loadOrCreate())
            try sealed.write(to: fileURL, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: fileURL.path)
        } catch {
            Log.write("history: save failed — \(error)")
        }
    }

    /// Removes the store and the key. Without the key the bytes are
    /// unrecoverable even if the file itself is later undeleted.
    static func purge() {
        try? FileManager.default.removeItem(at: fileURL)
        HistoryKey.destroy()
        Log.write("history: purged")
    }
}

/// The symmetric key, held in the login keychain.
///
/// `ThisDeviceOnly` is the important attribute: it keeps the key out of iCloud
/// Keychain and out of encrypted backups, so a copy of the history file taken
/// from a backup cannot be opened anywhere else.
enum HistoryKey {
    private static let service = "com.param.superclip"
    private static let account = "history-encryption-key"

    static func loadOrCreate() -> SymmetricKey {
        if let existing = existing() { return existing }
        let key = SymmetricKey(size: .bits256)
        store(key)
        Log.write("history: created encryption key")
        return key
    }

    static func existing() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return SymmetricKey(data: data)
    }

    private static func store(_ key: SymmetricKey) {
        let data = key.withUnsafeBytes { Data($0) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func destroy() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
