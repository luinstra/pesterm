import XCTest
@testable import pesterm

final class SettingsMergerTests: XCTestCase {

    var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pesterm-merger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func path(_ name: String = "settings.json") -> String {
        scratch.appendingPathComponent(name).path
    }

    // An isMine predicate matching `--adapter claude` (mirrors ClaudeHookWriter).
    private func isMine(_ entry: Any) -> Bool {
        guard let d = entry as? [String: Any], let hooks = d["hooks"] as? [Any] else { return false }
        return hooks.contains {
            (($0 as? [String: Any])?["command"] as? String)?.contains("--adapter claude") == true
        }
    }

    private func entry(command: String) -> [String: Any] {
        ["hooks": [["type": "command", "command": "\(command) --adapter claude"]]]
    }

    // 1. missing-file → load returns empty; upsert + write creates minimal valid file.
    func testMissingFileCreatesMinimalSettings() throws {
        let p = path()
        let loaded = try SettingsMerger.load(path: p)
        XCTAssertTrue(loaded.isEmpty)

        let merged = try SettingsMerger.upsert(loaded, event: "Notification",
                                               isMine: isMine, entry: entry(command: "/bin/pesterm"))
        let backup = try SettingsMerger.write(merged, to: p)
        XCTAssertNil(backup, "no backup when there was no pre-existing file")

        let data = try Data(contentsOf: URL(fileURLWithPath: p))
        let reparsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entries = (reparsed?["hooks"] as? [String: Any])?["Notification"] as? [Any]
        XCTAssertEqual(entries?.count, 1)
    }

    // 2. malformed JSON → load throws; original untouched.
    func testMalformedJSONRefused() throws {
        let p = path()
        let bad = "{ this is not json "
        try bad.write(toFile: p, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try SettingsMerger.load(path: p)) { error in
            guard case SettingsMerger.MergeError.malformedJSON = error else {
                return XCTFail("expected malformedJSON, got \(error)")
            }
        }
        // File unchanged.
        let after = try String(contentsOfFile: p, encoding: .utf8)
        XCTAssertEqual(after, bad)
    }

    // 3. atomic write produces valid JSON with trailing newline.
    func testWriteProducesValidJSONWithTrailingNewline() throws {
        let p = path()
        let merged = try SettingsMerger.upsert([:], event: "Notification",
                                               isMine: isMine, entry: entry(command: "/bin/pesterm"))
        try SettingsMerger.write(merged, to: p)

        let data = try Data(contentsOf: URL(fileURLWithPath: p))
        XCTAssertEqual(data.last, 0x0A, "trailing newline")
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
    }

    // 4. backup created (timestamped) when target pre-exists AND content changes;
    //    backup content == pre-write content. NO backup on a no-op re-wire.
    func testBackupOnlyOnActualChange() throws {
        let p = path()

        // First write (no pre-existing file → no backup).
        let first = try SettingsMerger.upsert([:], event: "Notification",
                                              isMine: isMine, entry: entry(command: "/old/pesterm"))
        let b1 = try SettingsMerger.write(first, to: p)
        XCTAssertNil(b1)
        let firstContent = try Data(contentsOf: URL(fileURLWithPath: p))

        // Change: re-wire at a NEW path → content differs → backup created.
        let second = try SettingsMerger.upsert(first, event: "Notification",
                                               isMine: isMine, entry: entry(command: "/new/pesterm"))
        let b2 = try SettingsMerger.write(second, to: p)
        XCTAssertNotNil(b2)
        XCTAssertTrue(b2!.contains(".bak-"))
        let backupContent = try Data(contentsOf: URL(fileURLWithPath: b2!))
        XCTAssertEqual(backupContent, firstContent, "backup == pre-write content")

        // No-op: writing the same content again should NOT create another backup.
        // (Caller skips write on no-op; here we confirm write itself doesn't back up
        //  identical content.)
        let bakDirBefore = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
            .filter { $0.contains(".bak-") }
        let b3 = try SettingsMerger.write(second, to: p)
        XCTAssertNil(b3, "no backup when content is identical")
        let bakDirAfter = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
            .filter { $0.contains(".bak-") }
        XCTAssertEqual(bakDirBefore.count, bakDirAfter.count, "no second backup")
    }

    // 5. upsert twice (same entry) → identical serialized output (idempotent).
    func testUpsertIdempotent() throws {
        let e = entry(command: "/bin/pesterm")
        let once = try SettingsMerger.upsert([:], event: "Notification", isMine: isMine, entry: e)
        let twice = try SettingsMerger.upsert(once, event: "Notification", isMine: isMine, entry: e)

        let s1 = try SettingsMerger.serialize(once)
        let s2 = try SettingsMerger.serialize(twice)
        XCTAssertEqual(s1, s2, "idempotent: byte-identical serialization")
    }

    // Parent-dir creation: write into a nonexistent subdir.
    func testCreatesParentDirectories() throws {
        let nested = scratch.appendingPathComponent("a/b/c/settings.json").path
        let merged = try SettingsMerger.upsert([:], event: "Notification",
                                               isMine: isMine, entry: entry(command: "/bin/pesterm"))
        try SettingsMerger.write(merged, to: nested)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested))
    }

    // remove drops our entry and prunes empty hooks.
    func testRemovePrunesEmptyHooks() throws {
        let merged = try SettingsMerger.upsert([:], event: "Notification",
                                               isMine: isMine, entry: entry(command: "/bin/pesterm"))
        let removed = try SettingsMerger.remove(merged, event: "Notification", isMine: isMine)
        XCTAssertNil(removed["hooks"], "hooks key pruned when it becomes empty")
    }

    // MARK: - FIX 3: refuse unexpected `hooks`/event shapes (preserve what we don't own)

    private let e = ["hooks": [["type": "command", "command": "/bin/pesterm --adapter claude"]]]

    // A MISSING hooks key is fine — upsert creates it.
    func testUpsertMissingHooksCreates() throws {
        let merged = try SettingsMerger.upsert([:], event: "Notification",
                                               isMine: isMine, entry: e)
        XCTAssertNotNil(merged["hooks"])
        XCTAssertEqual(((merged["hooks"] as? [String: Any])?["Notification"] as? [Any])?.count, 1)
    }

    // A MISSING event key (hooks present as object) is fine — upsert creates the event.
    func testUpsertMissingEventCreates() throws {
        let settings: [String: Any] = ["hooks": ["PreToolUse": [["matcher": "Bash"]]]]
        let merged = try SettingsMerger.upsert(settings, event: "Notification",
                                               isMine: isMine, entry: e)
        let hooks = merged["hooks"] as? [String: Any]
        XCTAssertNotNil(hooks?["PreToolUse"], "unrelated event preserved")
        XCTAssertEqual((hooks?["Notification"] as? [Any])?.count, 1)
    }

    // `"hooks": "string"` (present-but-not-object) → upsert refuses.
    func testUpsertRefusesHooksString() throws {
        let settings: [String: Any] = ["hooks": "string"]
        XCTAssertThrowsError(try SettingsMerger.upsert(settings, event: "Notification",
                                                       isMine: isMine, entry: e)) { error in
            guard case SettingsMerger.MergeError.unexpectedHooksShape = error else {
                return XCTFail("expected unexpectedHooksShape, got \(error)")
            }
        }
    }

    // `"hooks": []` (present-but-array, not object) → upsert refuses.
    func testUpsertRefusesHooksArray() throws {
        let settings: [String: Any] = ["hooks": [Any]()]
        XCTAssertThrowsError(try SettingsMerger.upsert(settings, event: "Notification",
                                                       isMine: isMine, entry: e)) { error in
            guard case SettingsMerger.MergeError.unexpectedHooksShape = error else {
                return XCTFail("expected unexpectedHooksShape, got \(error)")
            }
        }
    }

    // `"Notification": {}` (present-but-object, not array) → upsert refuses.
    func testUpsertRefusesEventObject() throws {
        let settings: [String: Any] = ["hooks": ["Notification": [String: Any]()]]
        XCTAssertThrowsError(try SettingsMerger.upsert(settings, event: "Notification",
                                                       isMine: isMine, entry: e)) { error in
            guard case SettingsMerger.MergeError.unexpectedEventShape = error else {
                return XCTFail("expected unexpectedEventShape, got \(error)")
            }
        }
    }

    // remove also refuses rather than clobbers on a present-but-wrong-type hooks.
    func testRemoveRefusesHooksString() throws {
        let settings: [String: Any] = ["hooks": "string"]
        XCTAssertThrowsError(try SettingsMerger.remove(settings, event: "Notification",
                                                       isMine: isMine)) { error in
            guard case SettingsMerger.MergeError.unexpectedHooksShape = error else {
                return XCTFail("expected unexpectedHooksShape, got \(error)")
            }
        }
    }

    // remove refuses on a present-but-object event value.
    func testRemoveRefusesEventObject() throws {
        let settings: [String: Any] = ["hooks": ["Notification": [String: Any]()]]
        XCTAssertThrowsError(try SettingsMerger.remove(settings, event: "Notification",
                                                       isMine: isMine)) { error in
            guard case SettingsMerger.MergeError.unexpectedEventShape = error else {
                return XCTFail("expected unexpectedEventShape, got \(error)")
            }
        }
    }

    // remove on a MISSING hooks/event is a clean no-op (no throw).
    func testRemoveMissingHooksIsNoOp() throws {
        let unchanged = try SettingsMerger.remove([:], event: "Notification", isMine: isMine)
        XCTAssertTrue(unchanged.isEmpty)
        let onlyOther: [String: Any] = ["hooks": ["PreToolUse": [["matcher": "Bash"]]]]
        let after = try SettingsMerger.remove(onlyOther, event: "Notification", isMine: isMine)
        XCTAssertNotNil((after["hooks"] as? [String: Any])?["PreToolUse"])
    }
}
