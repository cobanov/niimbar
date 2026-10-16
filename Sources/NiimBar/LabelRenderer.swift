import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// What goes on a label.
enum LabelContent: Equatable {
    case text(String)
    case qr(String)
    case barcode(String)
    case image(NSImage)

    var isEmpty: Bool {
        switch self {
        case .text(let s), .qr(let s), .barcode(let s): s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .image: false
        }
    }
}

/// A 1-bit picture of the label as it will come out: `width` x `height` dots, row-major,
/// true = black. The printer's own orientation is the protocol's business, not this one's.
struct LabelBitmap: Equatable {
    let width: Int
    let height: Int
    var dots: [Bool]

    subscript(x: Int, y: Int) -> Bool { dots[y * width + x] }

    var blackCount: Int { dots.reduce(0) { $0 + ($1 ? 1 : 0) } }

    /// For the preview: black dots on white paper.
    func cgImage() -> CGImage? {
        var pixels = dots.map { $0 ? UInt8(0) : UInt8(255) }
        guard let provider = CGDataProvider(data: Data(bytes: &pixels, count: pixels.count) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

enum LabelRenderer {
    /// B1: 203 dpi, 8 dots per millimetre.
    static let dotsPerMM = 8.0
    /// Blank margin kept round the content, in dots (1 mm).
    static let margin: CGFloat = 8

    static func render(_ content: LabelContent, widthMM: Double, heightMM: Double) -> LabelBitmap {
        let w = Int((widthMM * dotsPerMM).rounded()), h = Int((heightMM * dotsPerMM).rounded())
        let space = CGColorSpaceCreateDeviceGray()
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return LabelBitmap(width: max(w, 0), height: max(h, 0), dots: []) }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let box = CGRect(x: 0, y: 0, width: w, height: h).insetBy(dx: margin, dy: margin)

        switch content {
        case .text(let s): drawText(s, in: box, ctx: ctx)
        case .qr(let s): drawCode(qr(s), in: box, ctx: ctx)
        case .barcode(let s): drawCode(barcode(s), in: box, ctx: ctx, stretch: true)
        case .image(let image): drawImage(image, in: box, ctx: ctx)
        }

        // Bitmap context memory is top-down: row 0 is the label's top edge.
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let dots = (0..<(w * h)).map { data[$0] < 128 }
        return LabelBitmap(width: w, height: h, dots: dots)
    }

    // MARK: drawing

    private static func drawText(_ text: String, in box: CGRect, ctx: CGContext) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !text.isEmpty else { return }
        // Largest bold system font at which every line fits the box.
        func attributed(_ size: CGFloat) -> NSAttributedString {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineBreakMode = .byClipping
            return NSAttributedString(string: lines.joined(separator: "\n"), attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: .bold),
                .foregroundColor: NSColor.black,
                .paragraphStyle: style,
            ])
        }
        var lo: CGFloat = 4, hi = box.height
        while hi - lo > 0.5 {
            let mid = (lo + hi) / 2
            let size = attributed(mid).boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
                                                    options: [.usesLineFragmentOrigin]).size
            if size.width <= box.width && size.height <= box.height { lo = mid } else { hi = mid }
        }
        let string = attributed(lo)
        let size = string.boundingRect(with: CGSize(width: box.width, height: CGFloat.greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin]).size
        let rect = CGRect(x: box.minX, y: box.midY - size.height / 2, width: box.width, height: size.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        // No antialiasing would give jagged glyphs; the threshold later turns grey edges crisp.
        string.draw(with: rect, options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawCode(_ image: CIImage?, in box: CGRect, ctx: CGContext, stretch: Bool = false) {
        guard let image, let cg = CIContext().createCGImage(image, from: image.extent) else { return }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        // Whole-dot module sizes keep the code scannable; a barcode may also stretch in height.
        let scale = max(1, floor(min(box.width / w, stretch ? box.width / w : box.height / h)))
        let drawW = w * scale, drawH = stretch ? box.height : h * scale
        let rect = CGRect(x: box.midX - drawW / 2, y: box.midY - drawH / 2, width: drawW, height: min(drawH, box.height))
        ctx.interpolationQuality = .none
        ctx.draw(cg, in: rect)
    }

    private static func drawImage(_ image: NSImage, in box: CGRect, ctx: CGContext) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(box.width / w, box.height / h)
        let rect = CGRect(x: box.midX - w * scale / 2, y: box.midY - h * scale / 2, width: w * scale, height: h * scale)
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: rect)
    }

    private static func qr(_ s: String) -> CIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8)
        f.correctionLevel = "M"
        return f.outputImage
    }

    private static func barcode(_ s: String) -> CIImage? {
        let f = CIFilter.code128BarcodeGenerator()
        f.message = Data(s.utf8)
        f.quietSpace = 0
        return f.outputImage
    }
}
