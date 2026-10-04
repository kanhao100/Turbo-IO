import Foundation
import XCTest
@testable import RayNeoProtocol

final class TeleprompterAudioEnvelopeTests: XCTestCase {
    func testTypeNineAudioExtractsOnlyFieldFourWithoutJSONParsing() throws {
        let audio = Data([0xf8, 0xff, 0xfe])
        let packet = Data([8, 1, 16, 9, 34, 3]) + audio
        XCTAssertEqual(try BusinessEnvelopeMetadata.teleprompterAudio(packet), audio)
        // The optional message field is not interpreted as a JSON header or
        // guessed sequence number by the native audio path.
        let binaryMessage = Data([8, 1, 16, 9, 26, 3, 0xff, 0x00, 0x09, 34, 3]) + audio
        XCTAssertEqual(try BusinessEnvelopeMetadata.teleprompterAudio(binaryMessage), audio)
    }

    func testOtherTypesVersionsAndMessageOnlyBytesCannotBeAudio() throws {
        XCTAssertNil(try BusinessEnvelopeMetadata.teleprompterAudio(Data([8, 1, 16, 4, 34, 1, 0xf8])))
        XCTAssertNil(try BusinessEnvelopeMetadata.teleprompterAudio(Data([8, 2, 16, 9, 34, 1, 0xf8])))
        XCTAssertNil(try BusinessEnvelopeMetadata.teleprompterAudio(Data([16, 9, 34, 1, 0xf8])))
        XCTAssertNil(try BusinessEnvelopeMetadata.teleprompterAudio(Data([8, 1, 16, 9, 26, 1, 0xf8])))
        XCTAssertNil(try BusinessEnvelopeMetadata.teleprompterAudio(Data([8, 1, 16, 9, 34, 0])))
    }

    func testAmbiguousTruncatedAndOversizedAudioRejects() throws {
        XCTAssertThrowsError(try BusinessEnvelopeMetadata.teleprompterAudio(Data([8, 1, 16, 9, 34, 1, 0xf8, 34, 0])))
        XCTAssertThrowsError(try BusinessEnvelopeMetadata.teleprompterAudio(Data([8, 1, 16, 9, 34, 2, 0xf8])))
        let large = Data([8, 1, 16, 9, 34, 0x81, 0x20]) + Data(repeating: 0xf8, count: 4097)
        XCTAssertNil(try BusinessEnvelopeMetadata.teleprompterAudio(large))
    }
}
