import Foundation

struct CopyCheckFailure: Error { let message: String }
func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw CopyCheckFailure(message: message) }
}

@MainActor final class FakeWPSCopy: WPSCopyEnvironment {
    var changeCount = 10
    var now: TimeInterval = 0
    var safe = true
    var sourceChanged = false
    var backupAllowed = true
    var backupChangesClipboard = false
    var postCount = 0
    var textReads = 0
    var restoreCount = 0
    var resultText: String? = "new WPS selection"
    var onPause: ((FakeWPSCopy) -> Void)?
    var onRead: ((FakeWPSCopy) -> Void)?
    var onRestore: ((FakeWPSCopy) -> Void)?
    var restoreAllowed = true
    var original = [[ClipboardRepresentation(type: "public.utf8-plain-text", data: Data("old clipboard".utf8)), ClipboardRepresentation(type: "public.rtf", data: Data([1,2,3]))], [ClipboardRepresentation(type: "public.png", data: Data([4,5]))]]
    var restored: ClipboardSnapshot?
    func validateContext() throws -> Bool { if sourceChanged { throw CancellationError() }; return safe }
    func backup() throws -> ClipboardSnapshot? {
        if backupChangesClipboard { changeCount += 1 }
        return backupAllowed ? ClipboardSnapshot(changeCount: 10, items: original) : nil
    }
    func postCopy() throws { postCount += 1 }
    func copiedText() throws -> String? { textReads += 1; onRead?(self); return resultText }
    func restore(_ snapshot: ClipboardSnapshot, ifUnchanged count: Int) throws -> Bool {
        onRestore?(self)
        guard changeCount == count, restoreAllowed else { return false }
        restored = snapshot; restoreCount += 1; changeCount += 1; return true
    }
    func pause() async { now += 0.025; onPause?(self); await Task.yield() }
}

@main struct WPSCopyChecks {
    @MainActor static func main() async {
        do {
            let env = FakeWPSCopy()
            env.onPause = { if $0.now >= 0.05 && $0.changeCount == 10 { $0.changeCount = 11 } }
            let text = try await WPSCopyTransaction().run(env)
            try check(text == "new WPS selection", "fresh copied selection must be returned")
            try check(env.postCount == 1 && env.textReads == 1, "copy is sent once, only new text is read")
            try check(env.restored?.items == env.original, "all clipboard items and representations are restored")
            print("PASS: new selection, one Copy and lossless multi-item clipboard restoration")
            let oversized = FakeWPSCopy()
            oversized.original = [[ClipboardRepresentation(type: "public.png", data: Data(count: 32 * 1024 * 1024 + 1))]]
            do { _ = try await WPSCopyTransaction().run(oversized); throw CopyCheckFailure(message: "oversized backup should report a clear error") }
            catch is TranslatorError {}
            try check(oversized.postCount == 0, "unrestorable oversized backup must not send Copy")
            print("PASS: oversized backup blocks Copy")

            let noCopy = FakeWPSCopy()
            let absent = try await WPSCopyTransaction().run(noCopy)
            try check(absent == nil && noCopy.textReads == 0 && noCopy.restoreCount == 0, "unchanged old clipboard must never be read as a result or rewritten")
            print("PASS: no new copy times out without reading old clipboard")

            let denied = FakeWPSCopy(); denied.backupAllowed = false
            do { _ = try await WPSCopyTransaction().run(denied); throw CopyCheckFailure(message: "unavailable representation must fail") }
            catch is TranslatorError {}
            try check(denied.postCount == 0, "incomplete backup must block Copy")
            let changedBackup = FakeWPSCopy(); changedBackup.backupChangesClipboard = true
            do { _ = try await WPSCopyTransaction().run(changedBackup); throw CopyCheckFailure(message: "backup race must cancel") }
            catch is CancellationError {}
            try check(changedBackup.postCount == 0 && changedBackup.restoreCount == 0, "backup race must preserve newer clipboard")
            print("PASS: incomplete backup and backup race do not send Copy")

            let unsafe = FakeWPSCopy(); unsafe.safe = false
            let refused = try await WPSCopyTransaction().run(unsafe)
            try check(refused == nil && unsafe.postCount == 0, "unsafe context must not copy")
            let switched = FakeWPSCopy(); switched.sourceChanged = true
            do { _ = try await WPSCopyTransaction().run(switched); throw CopyCheckFailure(message: "changed source must cancel") }
            catch is CancellationError {}
            try check(switched.postCount == 0, "changed source must not copy")
            print("PASS: unsafe or changed source blocks the transaction")

            let twoWrites = FakeWPSCopy()
            twoWrites.onPause = { env in
                if env.now >= 0.1 { env.changeCount = 12 }
                else if env.now >= 0.05 { env.changeCount = 11 }
            }
            let ambiguous = try await WPSCopyTransaction().run(twoWrites)
            try check(ambiguous == nil && twoWrites.textReads == 0 && twoWrites.restoreCount == 0 && twoWrites.changeCount == 12, "second observed write must be preserved")
            let readRace = FakeWPSCopy()
            readRace.onPause = { if $0.changeCount == 10 { $0.changeCount = 11 } }
            readRace.onRead = { $0.changeCount = 12 }
            let raced = try await WPSCopyTransaction().run(readRace)
            try check(raced == nil && readRace.restoreCount == 0 && readRace.changeCount == 12, "write during text read must not be overwritten")
            let restoreRace = FakeWPSCopy()
            restoreRace.onPause = { if $0.changeCount == 10 { $0.changeCount = 11 } }
            restoreRace.onRestore = { $0.changeCount = 12 }
            let restoreRaced = try await WPSCopyTransaction().run(restoreRace)
            try check(restoreRaced == nil && restoreRace.restoreCount == 0 && restoreRace.changeCount == 12, "write before restore must not be overwritten")
            print("PASS: writes during waiting, reading or restoration are preserved")

            let cancelled = FakeWPSCopy()
            cancelled.onPause = { if $0.now >= 0.15 && $0.changeCount == 10 { $0.changeCount = 11 } }
            let pending = Task { try await WPSCopyTransaction().run(cancelled) }
            while cancelled.postCount == 0 { await Task.yield() }
            let concurrent = FakeWPSCopy()
            let concurrentResult = try await WPSCopyTransaction().run(concurrent)
            try check(concurrentResult == nil && concurrent.postCount == 0, "single-flight excludes overlapping Copy")
            pending.cancel()
            do { _ = try await pending.value; throw CopyCheckFailure(message: "cancelled transaction must throw") }
            catch is CancellationError {}
            try check(cancelled.postCount == 1 && cancelled.textReads == 0 && cancelled.restoreCount == 1, "cancel waits for late copy then restores without reading selected text")
            print("PASS: cancelled Copy cleans up once; concurrent transaction is excluded")

            let switchDuringCopy = FakeWPSCopy()
            switchDuringCopy.onPause = { if $0.now >= 0.05 { $0.changeCount = 11; $0.sourceChanged = true } }
            do { _ = try await WPSCopyTransaction().run(switchDuringCopy); throw CopyCheckFailure(message: "source switch during Copy must cancel") }
            catch is CancellationError {}
            try check(switchDuringCopy.textReads == 0 && switchDuringCopy.restoreCount == 0, "unattributed content after source switch must not be read or replaced")
            print("PASS: source switch after Copy never reads or overwrites unattributed content")

            let empty = FakeWPSCopy(); empty.original = []; empty.resultText = "   "
            empty.onPause = { if $0.changeCount == 10 { $0.changeCount = 11 } }
            let emptyResult = try await WPSCopyTransaction().run(empty)
            try check(emptyResult == nil && empty.restored?.items.isEmpty == true, "empty original clipboard and whitespace response are supported")
            print("PASS: empty clipboard restoration and empty copied selection")
        } catch let failure as CopyCheckFailure { print("FAIL: \(failure.message)"); exit(1) }
        catch { print("FAIL: unexpected \(type(of: error))"); exit(1) }
    }
}
