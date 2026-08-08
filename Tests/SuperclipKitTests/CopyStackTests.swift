import Foundation
import Testing
@testable import SuperclipKit

/// The copy stack.
///
/// The property worth guarding hardest is that it never fills itself: a
/// clipboard tool that silently accumulates everything you copy is the kind of
/// thing people uninstall.
@Suite("Copy stack")
@MainActor
struct CopyStackTests {

    @Test("Never collects until switched on")
    func noSilentCollection() {
        let stack = CopyStack()
        stack.append("should be ignored")
        #expect(stack.isEmpty)
        #expect(!stack.isCollecting)
    }

    @Test("Seeds with the current clipboard, then collects in order")
    func collectsInOrder() {
        let stack = CopyStack()
        stack.startCollecting(seed: "Simran Kaur")
        #expect(stack.count == 1)

        for value in ["simran@example.com", "+91 98765 43210", "412 Kingsway Road"] {
            stack.append(value)
        }
        #expect(stack.count == 4)
        #expect(stack.items.first == "Simran Kaur")
    }

    @Test("A blank or missing seed creates no phantom first item")
    func blankSeed() {
        let stack = CopyStack()
        stack.startCollecting(seed: "   \n ")
        #expect(stack.isEmpty)

        stack.startCollecting(seed: nil)
        #expect(stack.isEmpty)
    }

    @Test("Stopping keeps the contents but stops accepting more")
    func stopKeepsContents() {
        let stack = CopyStack()
        stack.startCollecting(seed: "one")
        stack.append("two")
        stack.stopCollecting()

        #expect(stack.count == 2)
        #expect(!stack.isCollecting)

        stack.append("three")
        #expect(stack.count == 2)
    }

    @Test("Drains first-in first-out, so a form fills top to bottom")
    func fifo() {
        let stack = CopyStack()
        stack.startCollecting(seed: "first")
        stack.append("second")
        stack.append("third")

        #expect(stack.popFirst() == "first")
        #expect(stack.popFirst() == "second")
        #expect(stack.count == 1)
    }

    @Test("Draining everything preserves order and empties the stack")
    func drainAll() {
        let stack = CopyStack()
        stack.startCollecting(seed: "a")
        stack.append("b")
        stack.append("c")

        #expect(stack.drainAll() == ["a", "b", "c"])
        #expect(stack.isEmpty)
        #expect(stack.popFirst() == nil)
    }

    @Test("Starting a new collection discards the previous one")
    func restartClears() {
        let stack = CopyStack()
        stack.startCollecting(seed: "old")
        stack.append("older")
        stack.startCollecting(seed: "fresh")

        #expect(stack.items == ["fresh"])
    }

    @Test("Clearing resets contents and mode together")
    func clear() {
        let stack = CopyStack()
        stack.startCollecting(seed: "x")
        stack.clear()

        #expect(stack.isEmpty)
        #expect(!stack.isCollecting)
    }

    @Test("Every mutation notifies, so the menu bar count stays honest")
    func notifies() {
        let stack = CopyStack()
        var changes = 0
        stack.onChange = { changes += 1 }

        stack.startCollecting(seed: "a")
        stack.append("b")
        _ = stack.popFirst()
        _ = stack.drainAll()
        stack.clear()

        #expect(changes >= 5)
    }
}
