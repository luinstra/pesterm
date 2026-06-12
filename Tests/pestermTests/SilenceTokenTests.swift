import XCTest
import ArgumentParser
@testable import pesterm

/// `--sound none` (and synonyms) → post with no sound.
final class SilenceTokenTests: XCTestCase {

    func testSilenceTokensRecognized() {
        for token in ["none", "off", "silent", "mute", "silence", "None", "OFF", "  none  "] {
            XCTAssertTrue(SoundLibrary.isSilenceToken(token), "'\(token)' should mean silence")
        }
    }

    func testRealNamesAndEmptyAreNotSilence() {
        XCTAssertFalse(SoundLibrary.isSilenceToken("Glass"))
        XCTAssertFalse(SoundLibrary.isSilenceToken("Hero"))
        XCTAssertFalse(SoundLibrary.isSilenceToken(""))
        XCTAssertFalse(SoundLibrary.isSilenceToken(nil))
    }

    func testPostSoundNoneProducesNilSound() throws {
        let cmd = try PostCommand.parse(["--message", "hi", "--sound", "none"])
        XCTAssertNil(cmd.makeRequest().sound, "--sound none must silence the notification")
    }

    func testPostRealSoundKept() throws {
        let cmd = try PostCommand.parse(["--message", "hi", "--sound", "Glass"])
        XCTAssertEqual(cmd.makeRequest().sound, "Glass")
    }
}
