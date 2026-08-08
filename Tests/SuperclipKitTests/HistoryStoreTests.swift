import CryptoKit
import Foundation
import Testing
@testable import SuperclipKit

/// The encrypted store.
///
/// Only the pure core is exercised — sealing, opening, and retention. The
/// keychain and filesystem halves are deliberately left out: they would pollute
/// the developer's login keychain and depend on TCC state, and what actually
/// needs proving is that the bytes are unreadable and that tampering is caught.
@Suite("History store")
struct HistoryStoreTests {

    private let key = SymmetricKey(size: .bits256)

    private func sample(now: Date = Date()) -> [PersistedClip] {
        [
            PersistedClip(text: "412 Kingsway Road, Jalandhar", appName: "Notes",
                          bundleID: "com.apple.Notes", capturedAt: now.addingTimeInterval(-3600)),
            PersistedClip(text: "postgres://analytics@db.internal:5432", appName: "Slack",
                          bundleID: "com.tinyspeck.slackmacgap", capturedAt: now.addingTimeInterval(-7200)),
            PersistedClip(text: "VR-88231", appName: "Safari",
                          bundleID: "com.apple.Safari", capturedAt: now.addingTimeInterval(-86_400 * 3))
        ]
    }

    @Test("Round-trips")
    func roundTrip() throws {
        let clips = sample()
        let sealed = try HistoryStore.seal(clips, key: key)
        #expect(try HistoryStore.open(sealed, key: key) == clips)
    }

    @Test("The stored bytes contain no plaintext")
    func noPlaintext() throws {
        let sealed = try HistoryStore.seal(sample(), key: key)
        for secret in ["Kingsway", "postgres", "VR-88231", "Notes", "Slack"] {
            #expect(sealed.range(of: Data(secret.utf8)) == nil,
                    "\(secret) appeared in the ciphertext")
        }
    }

    @Test("A different key cannot open it")
    func wrongKey() throws {
        let sealed = try HistoryStore.seal(sample(), key: key)
        #expect(throws: (any Error).self) {
            try HistoryStore.open(sealed, key: SymmetricKey(size: .bits256))
        }
    }

    @Test("Any single flipped bit is detected")
    func tamperDetection() throws {
        let sealed = try HistoryStore.seal(sample(), key: key)
        let step = max(1, sealed.count / 24)
        for offset in Array(stride(from: 0, to: sealed.count, by: step)) {
            var corrupted = sealed
            corrupted[offset] ^= 0x01
            #expect(throws: (any Error).self) {
                try HistoryStore.open(corrupted, key: key)
            }
        }
    }

    @Test("Truncation is detected")
    func truncation() throws {
        let sealed = try HistoryStore.seal(sample(), key: key)
        #expect(throws: (any Error).self) {
            try HistoryStore.open(Data(sealed.prefix(sealed.count - 4)), key: key)
        }
    }

    @Test("Identical input seals differently — the nonce is not reused")
    func distinctCiphertexts() throws {
        let clips = sample()
        #expect(try HistoryStore.seal(clips, key: key) != HistoryStore.seal(clips, key: key))
    }

    @Test("An empty store round-trips rather than erroring")
    func emptyStore() throws {
        #expect(try HistoryStore.open(HistoryStore.seal([], key: key), key: key).isEmpty)
    }

    @Test("Retention keeps only what is inside the window")
    func retentionWindow() {
        let now = Date()
        let clips = sample(now: now)
        #expect(HistoryStore.applyRetention(clips, days: 7, cap: 100, now: now).count == 3)

        let day = HistoryStore.applyRetention(clips, days: 1, cap: 100, now: now)
        #expect(day.count == 2)
        #expect(!day.contains { $0.text == "VR-88231" })
    }

    @Test("Retention returns newest first")
    func retentionOrdering() {
        let now = Date()
        let kept = HistoryStore.applyRetention(sample(now: now), days: 7, cap: 100, now: now)
        #expect(kept.first?.text == "412 Kingsway Road, Jalandhar")
    }

    @Test("Zero days keeps nothing at all")
    func retentionOff() {
        #expect(HistoryStore.applyRetention(sample(), days: 0, cap: 100).isEmpty)
    }

    @Test("The cap is applied after the window")
    func cap() {
        let now = Date()
        #expect(HistoryStore.applyRetention(sample(now: now), days: 30, cap: 2, now: now).count == 2)
    }
}
