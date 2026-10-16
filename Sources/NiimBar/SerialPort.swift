import Foundation

/// A raw USB serial port (the B1 shows up as /dev/cu.usbmodemB1_<serial>), opened 115200 8N1.
/// Blocking reads with a deadline; callers run it off the main thread.
final class SerialPort {
    enum Failure: Error { case open(String), write, timeout }

    private let fd: Int32
    let path: String

    /// The first port whose name says it is a NIIMBOT B1, if one is plugged in.
    static func findPrinter() -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names.filter { $0.hasPrefix("cu.usbmodemB1") }.sorted().first.map { "/dev/" + $0 }
    }

    init(path: String) throws {
        self.path = path
        fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.open(String(cString: strerror(errno))) }
        // Exclusive: NiimBlue or a second copy of the app would interleave packets with ours.
        guard ioctl(fd, TIOCEXCL) == 0 else {
            let reason = String(cString: strerror(errno)); close(fd); throw Failure.open(reason)
        }
        var t = termios()
        tcgetattr(fd, &t)
        cfmakeraw(&t)
        cfsetspeed(&t, speed_t(B115200))
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tcsetattr(fd, TCSANOW, &t)
        tcflush(fd, TCIOFLUSH)
    }

    deinit { close(fd) }

    func write(_ data: [UInt8]) throws {
        var offset = 0
        while offset < data.count {
            let n = data[offset...].withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EAGAIN { usleep(1000); continue }
                throw Failure.write
            }
            offset += n
        }
    }

    /// Whatever arrives before the deadline, returning as soon as `done` says it is enough.
    func read(timeout: TimeInterval, until done: ([UInt8]) -> Bool) throws -> [UInt8] {
        var buffer: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 512)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let left = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
            guard poll(&pfd, 1, left) > 0 else { continue }
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n < 0 { if errno == EAGAIN { continue }; throw Failure.write }
            if n == 0 { break }
            buffer += chunk[..<n]
            if done(buffer) { return buffer }
        }
        if buffer.isEmpty { throw Failure.timeout }
        return buffer
    }

    func flushInput() { tcflush(fd, TCIFLUSH) }
}
