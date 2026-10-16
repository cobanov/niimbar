import Foundation

struct LabelSize: Equatable {
    var widthMM: Double
    var heightMM: Double

    var title: String { "\(Self.mm(widthMM))×\(Self.mm(heightMM)) mm" }

    private static func mm(_ v: Double) -> String {
        v.rounded() == v ? String(Int(v)) : String(format: "%.1f", v)
    }

    /// Common B1 rolls, for rolls without a readable tag.
    static let common = [
        LabelSize(widthMM: 50, heightMM: 30), LabelSize(widthMM: 40, heightMM: 30),
        LabelSize(widthMM: 50, heightMM: 50), LabelSize(widthMM: 30, heightMM: 15),
        LabelSize(widthMM: 25, heightMM: 15),
    ]
}

/// The roll in the printer, read from its RFID tag.
struct LabelInfo: Equatable {
    /// nil when the printer cannot tell; the user picks a size then.
    var size: LabelSize?
    var remaining: Int?
    var type: Int?
}

struct PrinterStatus: Equatable {
    /// 0...100, from the printer's four-step gauge.
    var battery: Int?
    var charging: Bool?
    var lidOpen: Bool?
    var paperLoaded: Bool?
    var label: LabelInfo?
    var serial: String?
    var firmware: String?
}

enum Connection: Equatable {
    case searching
    case connected
    case failed(String)
}
