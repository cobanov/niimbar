import XCTest
@testable import NiimBar

final class EncoderTests: XCTestCase {
    private func hex(_ s: String) -> [UInt8] {
        s.split(separator: " ").map { UInt8($0, radix: 16)! }
    }

    /// The 16x4 example from niimbluelib's encoder, frame for frame.
    func testSpecExample() {
        var dots = [Bool](repeating: false, count: 16 * 4)
        for x in 0..<16 { dots[x] = true; dots[16 + x] = true }
        dots[3 * 16 + 3] = true
        let runs = B1Encoder.runs(LabelBitmap(width: 16, height: 4, dots: dots))
        XCTAssertEqual(runs.map { B1Encoder.packet($0).bytes }, [
            hex("55 55 85 08 00 00 10 00 00 02 ff ff 9f aa aa"),
            hex("55 55 84 03 00 02 01 84 aa aa"),
            hex("55 55 83 08 00 03 01 00 00 01 00 03 8b aa aa"),
        ])
    }

    func testKnownFrames() {
        XCTAssertEqual(Packet(command: 0x40, data: [0x0A]).bytes, hex("55 55 40 01 0a 4b aa aa"))
        XCTAssertEqual(Packet(command: 0x01, data: B1Encoder.be16(1) + [0, 0, 0, 0, 0]).bytes,
                       hex("55 55 01 07 00 01 00 00 00 00 00 07 aa aa"))
        XCTAssertEqual(Packet(command: 0x13, data: B1Encoder.be16(4) + B1Encoder.be16(16) + B1Encoder.be16(1)).bytes,
                       hex("55 55 13 06 00 04 00 10 00 01 00 aa aa"))
    }

    func testParseSkipsJunkAndSplitsPackets() {
        let a = Packet(command: 0xB3, data: [0, 1, 100, 100])
        let b = Packet(command: 0xF4, data: [1])
        XCTAssertEqual(Packet.parse([0x00, 0x13] + a.bytes + b.bytes + [0x55]), [a, b])
    }

    /// Runs break at row 200 and never exceed 255 rows.
    func testRunLimits() {
        let runs = B1Encoder.runs(LabelBitmap(width: 8, height: 600, dots: .init(repeating: false, count: 8 * 600)))
        XCTAssertEqual(runs, [.void(pos: 0, repeat: 200), .void(pos: 200, repeat: 200), .void(pos: 400, repeat: 200)])
    }

    /// Seven black dots must not use the indexed form (it powers the B1 off).
    func testSevenDotsUseFullRow() {
        var dots = [Bool](repeating: false, count: 16)
        for x in 0..<7 { dots[x] = true }
        let packet = B1Encoder.packet(B1Encoder.runs(LabelBitmap(width: 16, height: 1, dots: dots))[0])
        XCTAssertEqual(packet.command, 0x85)
    }

    func testRenderedTextFitsHead() {
        let bitmap = LabelRenderer.render(.text("Hello"), widthMM: 48, heightMM: 30)
        XCTAssertEqual(bitmap.width, 384)
        XCTAssertEqual(bitmap.height, 240)
        XCTAssertGreaterThan(bitmap.blackCount, 500)
        // Text is centred: the top-left corner stays blank.
        XCTAssertFalse(bitmap[2, 2])
    }
}
