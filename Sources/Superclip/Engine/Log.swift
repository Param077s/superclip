import Foundation

/// Tiny append-only debug log written to ~/superclip-debug.log so we can trace
/// the hotkey → transform → paste pipeline without a debugger attached.
enum Log {
    static let url = URL(fileURLWithPath: NSHomeDirectory() + "/superclip-debug.log")

    static func reset() {
        try? "=== Superclip debug log ===\n".write(to: url, atomically: true, encoding: .utf8)
    }

    static func write(_ message: String) {
        let line = message + "\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
