import Foundation

/// NIIMBOT's packet: 55 55 | command | length | data… | xor(command, length, data) | AA AA.
struct Packet: Equatable {
    let command: UInt8
    let data: [UInt8]

    var bytes: [UInt8] {
        let checksum = data.reduce(command ^ UInt8(data.count), ^)
        return [0x55, 0x55, command, UInt8(data.count)] + data + [checksum, 0xAA, 0xAA]
    }

    /// Every whole, valid packet in `buffer`, in order; junk between them is skipped.
    static func parse(_ buffer: [UInt8]) -> [Packet] {
        var out: [Packet] = []
        var i = 0
        while i + 7 <= buffer.count {
            guard buffer[i] == 0x55, buffer[i + 1] == 0x55 else { i += 1; continue }
            let n = Int(buffer[i + 3]), end = i + 4 + n
            guard end + 3 <= buffer.count else { break }
            let packet = Packet(command: buffer[i + 2], data: Array(buffer[(i + 4)..<end]))
            if buffer[end] == packet.bytes[4 + n], buffer[end + 1] == 0xAA, buffer[end + 2] == 0xAA {
                out.append(packet)
                i = end + 3
            } else {
                i += 1
            }
        }
        return out
    }
}

/// Talks to a B1 over its USB serial port. Blocking; call from a background queue.
final class B1 {
    enum Failure: LocalizedError {
        case noReply(UInt8)
        case printer(String)

        var errorDescription: String? {
            switch self {
            case .noReply(let c): String(format: "The printer did not answer (0x%02X)", c)
            case .printer(let s): s
            }
        }
    }

    private let port: SerialPort

    init(port: SerialPort) { self.port = port }

    func portWrite(_ bytes: [UInt8]) throws { try port.write(bytes) }

    /// Sends a request and waits for the reply whose command is one of `expect`.
    @discardableResult
    func send(_ command: UInt8, _ data: [UInt8], expect: Set<UInt8>, timeout: TimeInterval = 1) throws -> Packet {
        port.flushInput()
        try port.write(Packet(command: command, data: data).bytes)
        var reply: Packet?
        _ = try? port.read(timeout: timeout) { buffer in
            reply = Packet.parse(buffer).first { expect.contains($0.command) }
            return reply != nil
        }
        guard let reply else { throw Failure.noReply(command) }
        return reply
    }

    /// GET_INFO (0x40); the reply comes back as 0x40 + key.
    func info(_ key: UInt8) throws -> [UInt8] {
        try send(0x40, [key], expect: [0x40 + key]).data
    }

    func readStatus() throws -> PrinterStatus {
        var s = PrinterStatus()
        if let level = try? info(10).first { s.battery = Int(min(level, 4)) * 25 }
        if let serial = try? info(11) { s.serial = String(decoding: serial, as: UTF8.self) }
        if let v = try? info(9), v.count >= 2 { s.firmware = "\(v[0]).\(v[1])" }
        let beat = try send(0xDC, [1], expect: [0xDD, 0xDE, 0xDF])
        Self.apply(heartbeat: beat.data, to: &s)
        if let roll = readRoll() {
            s.label = LabelInfo(size: readPaperSize(), remaining: roll.remaining, type: roll.type)
        }
        return s
    }

    /// The 13-byte heartbeat (what the B1 sends): [9] lid, [10] battery, [11] paper, [12] RFID.
    static func apply(heartbeat d: [UInt8], to s: inout PrinterStatus) {
        guard d.count == 13 else { return }
        s.lidOpen = d[9] != 0
        if s.battery == nil { s.battery = Int(min(d[10], 4)) * 25 }
        s.paperLoaded = d[11] == 0
    }
}

// MARK: - printing: niimbluelib's B1PrintTask, byte for byte (docs/b1-protocol.md)

/// One packet's worth of rows: a run of identical rows starting at `pos`.
enum RowRun: Equatable {
    case void(pos: Int, repeat: Int)
    case pixels(pos: Int, repeat: Int, bytes: [UInt8])
}

enum B1Encoder {
    /// The head is 384 dots (48 mm) wide.
    static let headDots = 384

    /// Rows top to bottom, MSB first, 1 = burn. Identical neighbours share a packet, but a run
    /// never crosses a multiple of 200 rows (niimbluelib) or 255 rows (the repeat is one byte).
    static func runs(_ bitmap: LabelBitmap) -> [RowRun] {
        let rowBytes = (bitmap.width + 7) / 8
        var runs: [RowRun] = []
        var lastBreak = 0
        for y in 0..<bitmap.height {
            var bytes = [UInt8](repeating: 0, count: rowBytes)
            for x in 0..<bitmap.width where bitmap[x, y] { bytes[x / 8] |= 0x80 >> UInt8(x % 8) }
            let blank = bytes.allSatisfy { $0 == 0 }
            let canJoin = y != lastBreak
            switch runs.last {
            case .void(let pos, let n)? where blank && canJoin && n < 255:
                runs[runs.count - 1] = .void(pos: pos, repeat: n + 1)
            case .pixels(let pos, let n, let prev)? where !blank && prev == bytes && canJoin && n < 255:
                runs[runs.count - 1] = .pixels(pos: pos, repeat: n + 1, bytes: prev)
            default:
                runs.append(blank ? .void(pos: y, repeat: 1) : .pixels(pos: y, repeat: 1, bytes: bytes))
            }
            if y % 200 == 199 { lastBreak = y + 1 }
        }
        return runs
    }

    static func packet(_ run: RowRun) -> Packet {
        switch run {
        case .void(let pos, let n):
            return Packet(command: 0x84, data: be16(pos) + [UInt8(n)])
        case .pixels(let pos, let n, let bytes):
            // Black dots per 16-byte (128-dot) third of the head.
            let counts = (0..<3).map { i -> UInt8 in
                let chunk = bytes.dropFirst(i * 16).prefix(16)
                return UInt8(chunk.reduce(0) { $0 + $1.nonzeroBitCount })
            }
            let total = counts.reduce(0) { $0 + Int($1) }
            let head = be16(pos) + counts + [UInt8(n)]
            if total <= 6 {
                // Indexed form: the x of each black dot. Never above 6: the B1 powers off.
                var xs: [UInt8] = []
                for (i, b) in bytes.enumerated() {
                    for bit in 0..<8 where b & (0x80 >> UInt8(bit)) != 0 { xs += be16(i * 8 + bit) }
                }
                return Packet(command: 0x83, data: head + xs)
            }
            return Packet(command: 0x85, data: head + bytes)
        }
    }

    static func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
}

extension B1 {
    static let printErrors: [UInt8: String] = [
        0x01: "The lid is open", 0x02: "Out of labels", 0x03: "Battery too low to print",
        0x04: "Battery fault", 0x05: "Cancelled", 0x06: "The printer rejected the data",
        0x07: "The printer is too hot", 0x08: "Paper feed problem", 0x09: "The printer is busy",
        0x10: "Wrong label type", 0x34: "The printer timed out waiting for data",
    ]

    private func check(_ reply: Packet) throws {
        if reply.command == 0xDB {
            let code = reply.data.first ?? 0
            throw Failure.printer(Self.printErrors[code] ?? String(format: "Printer error 0x%02X", code))
        }
    }

    private func step(_ command: UInt8, _ data: [UInt8], _ reply: UInt8, timeout: TimeInterval = 1) throws -> Packet {
        usleep(10_000)
        let r = try send(command, data, expect: [reply, 0xDB], timeout: timeout)
        try check(r)
        return r
    }

    /// Prints `copies` of `bitmap`. Widths over 384 dots are refused rather than cropped.
    func print(_ bitmap: LabelBitmap, copies: Int, density: Int, labelType: UInt8,
               progress: (Int) -> Void, cancelled: () -> Bool) throws {
        guard bitmap.width <= B1Encoder.headDots, bitmap.height > 0, copies > 0 else {
            throw Failure.printer("The label is wider than the 48 mm print head")
        }
        _ = try step(0x21, [UInt8(min(max(density, 1), 5))], 0x31)
        _ = try step(0x23, [labelType], 0x33)
        _ = try step(0x01, B1Encoder.be16(copies) + [0, 0, 0, 0, 0], 0x02)
        // PrintEnd runs whatever happens, or the B1 stays mid-job.
        defer { _ = try? step(0xF3, [1], 0xF4) }

        guard try step(0x03, [1], 0x04, timeout: 10).data.first == 1 else { throw Failure.printer("The printer refused the page") }
        let cols = (bitmap.width + 7) / 8 * 8
        _ = try step(0x13, B1Encoder.be16(bitmap.height) + B1Encoder.be16(cols) + B1Encoder.be16(copies), 0x14, timeout: 10)
        for run in B1Encoder.runs(bitmap) {
            usleep(10_000)
            try writeOneWay(B1Encoder.packet(run))
        }
        guard try step(0xE3, [1], 0xE4, timeout: 10).data.first == 1 else { throw Failure.printer("The printer refused the page") }

        // Poll until every copy is out; two minutes is far longer than any real label.
        let deadline = Date().addingTimeInterval(120)
        var shown = 0
        while Date() < deadline {
            if cancelled() { throw Failure.printer("Cancelled") }
            usleep(150_000)
            guard let status = try? step(0xA3, [1], 0xB3, timeout: 5), status.data.count >= 4 else { continue }
            if status.data.count == 10, status.data[6] != 0 {
                let code = status.data[6]
                throw Failure.printer(Self.printErrors[code] ?? String(format: "Printer error 0x%02X", code))
            }
            let page = Int(status.data[0]) << 8 | Int(status.data[1])
            if page != shown, page < copies { shown = page; progress(page + 1) }
            if page >= copies { return }
        }
        throw Failure.printer("The printer did not finish in time")
    }

    private func writeOneWay(_ packet: Packet) throws {
        try portWrite(packet.bytes)
    }

    /// The roll's tag: total and used labels, and its type. nil when there is no tag.
    func readRoll() -> (remaining: Int, type: Int)? {
        guard let r = try? send(0x1A, [1], expect: [0x1B]), r.data.count > 1 else { return nil }
        var i = 8
        func skipString() -> Bool {
            guard i < r.data.count else { return false }
            i += 1 + Int(r.data[i]); return i <= r.data.count
        }
        guard skipString(), skipString(), i + 5 <= r.data.count else { return nil }
        let all = Int(r.data[i]) << 8 | Int(r.data[i + 1])
        let used = Int(r.data[i + 2]) << 8 | Int(r.data[i + 3])
        return (max(all - used, 0), Int(r.data[i + 4]))
    }

    /// Label size from the printer's paper sensor (0x59); unverified on the B1, so may be nil.
    func readPaperSize() -> LabelSize? {
        guard let r = try? send(0x59, [1], expect: [0x69]), r.data.count == 18 else { return nil }
        let d = r.data
        let height = Double(Int(d[7]) << 8 | Int(d[8])) / 10
        let width = Double(Int(d[11]) << 8 | Int(d[12])) / 10
        guard width > 5, height > 5 else { return nil }
        return LabelSize(widthMM: width, heightMM: height)
    }
}
