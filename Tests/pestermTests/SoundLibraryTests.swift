import XCTest
@testable import pesterm

final class SoundLibraryTests: XCTestCase {

    var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pesterm-sounds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func touch(_ name: String) throws {
        let url = scratch.appendingPathComponent(name)
        try Data().write(to: url)
    }

    // PURE scan: sound files → deduped, sorted base names; non-sound files ignored.
    func testScanReturnsSortedBaseNamesIgnoringNonSounds() throws {
        try touch("Glass.aiff")
        try touch("Morse.caf")
        try touch("Hero.wav")
        try touch("notes.txt")       // non-sound: ignored
        try touch("README")          // no extension: ignored
        try touch("photo.png")       // non-sound: ignored

        let names = SoundLibrary.names(inDirectories: [scratch.path]).map { $0.name }
        XCTAssertEqual(names, ["Glass", "Hero", "Morse"])
    }

    func testScanAllSupportedExtensions() throws {
        try touch("a.aiff")
        try touch("b.aif")
        try touch("c.caf")
        try touch("d.wav")
        try touch("e.m4a")
        try touch("f.m4r")
        let names = SoundLibrary.names(inDirectories: [scratch.path]).map { $0.name }
        XCTAssertEqual(names, ["a", "b", "c", "d", "e", "f"])
    }

    // Dedup across directories: first directory listed wins (user → system precedence).
    func testDedupAcrossDirectoriesFirstWins() throws {
        let other = scratch.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        // Same base name in both dirs.
        try Data().write(to: scratch.appendingPathComponent("Glass.aiff"))
        try Data().write(to: other.appendingPathComponent("Glass.caf"))
        try Data().write(to: other.appendingPathComponent("Pop.wav"))

        let entries = SoundLibrary.names(inDirectories: [scratch.path, other.path])
        let names = entries.map { $0.name }
        XCTAssertEqual(names, ["Glass", "Pop"])
        // The Glass entry came from the FIRST directory.
        let glass = entries.first { $0.name == "Glass" }
        XCTAssertEqual(glass?.directory, scratch.path)
    }

    func testMissingDirectoryIgnored() throws {
        try touch("Glass.aiff")
        let names = SoundLibrary.names(inDirectories: [scratch.path, "/no/such/dir"]).map { $0.name }
        XCTAssertEqual(names, ["Glass"])
    }

    func testEmptyDirectoryReturnsEmpty() {
        let names = SoundLibrary.names(inDirectories: [scratch.path]).map { $0.name }
        XCTAssertEqual(names, [])
    }

    // sample resolution: a known system sound resolves; a bogus name does not.
    // (No audio is played — we only exercise the resolution helper.)
    func testResolvesKnownSystemSound() {
        // Glass ships on every macOS in /System/Library/Sounds.
        XCTAssertTrue(SoundLibrary.resolves("Glass"))
    }

    func testResolvesRejectsBogusName() {
        XCTAssertFalse(SoundLibrary.resolves("DefinitelyNotARealSound_pesterm_xyz"))
    }
}
