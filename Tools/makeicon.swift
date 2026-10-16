#!/usr/bin/env swift
//
// NiimBar uygulama ikonunu uretir (GHBar'in ikon betiginden).
//
// Harici bir cizim araci yerine AppKit kullaniliyor: makinede zaten var,
// her boyut tam kontrolle ciziliyor ve sonuc dogrudan .iconset klasoru.
//
//   swift Tools/makeicon.swift  ->  build/NiimBar.iconset
//   iconutil -c icns build/NiimBar.iconset -o build/NiimBar.icns
//
import AppKit

// MARK: - Palet

let accent      = NSColor(srgbRed: 0.18, green: 0.72, blue: 0.42, alpha: 1)  // yesil
let accentDeep  = NSColor(srgbRed: 0.09, green: 0.52, blue: 0.30, alpha: 1)
let plateTop    = NSColor(srgbRed: 0.13, green: 0.15, blue: 0.18, alpha: 1)  // grafit
let plateBottom = NSColor(srgbRed: 0.07, green: 0.08, blue: 0.10, alpha: 1)

// MARK: - Cizim

/// macOS ikonlari kenarlarda seffaf pay birakir; 1024'luk tuvalde
/// gorunur alan ~824 px olur. Bu oran korunmazsa ikon Dock'ta
/// komsularindan buyuk gorunur.
func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let context = NSGraphicsContext.current?.cgContext else { return image }
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    let inset = size * 0.098
    let plateRect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = plateRect.width * 0.2237      // Apple'in squircle orani

    // Grafit zemin
    let plate = NSBezierPath(roundedRect: plateRect, xRadius: radius, yRadius: radius)
    plate.addClip()
    let plateGradient = NSGradient(starting: plateTop, ending: plateBottom)!
    plateGradient.draw(in: plateRect, angle: -90)

    // Ust kenarda ince isik cizgisi — duz zeminlere derinlik verir
    context.saveGState()
    let highlight = NSBezierPath(
        roundedRect: plateRect.insetBy(dx: size * 0.006, dy: size * 0.006),
        xRadius: radius, yRadius: radius
    )
    highlight.lineWidth = size * 0.006
    NSColor(white: 1, alpha: 0.10).setStroke()
    highlight.stroke()
    context.restoreGState()

    // MARK: Etiket
    //
    // Yaziciya giren bir yarik ve ondan cikan beyaz bir etiket: uzerinde iki
    // yazi satiri ve yesil bir nokta. Menudeki printer sembolune yakin ama
    // uygulamanin isini (etiket) gosteriyor.

    let slotW = plateRect.width * 0.62
    let slotH = size * 0.05
    let slotY = plateRect.midY + size * 0.20
    let slot = NSBezierPath(roundedRect: CGRect(x: plateRect.midX - slotW / 2, y: slotY, width: slotW, height: slotH),
                            xRadius: slotH / 2, yRadius: slotH / 2)
    NSColor(white: 0, alpha: 0.55).setFill()
    slot.fill()

    let labelW = slotW * 0.84
    let labelH = size * 0.40
    let labelRect = CGRect(x: plateRect.midX - labelW / 2, y: slotY + slotH * 0.45 - labelH, width: labelW, height: labelH)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.03,
                      color: NSColor(white: 0, alpha: 0.45).cgColor)
    let label = NSBezierPath(roundedRect: labelRect, xRadius: size * 0.035, yRadius: size * 0.035)
    NSColor(white: 0.97, alpha: 1).setFill()
    label.fill()
    context.restoreGState()

    // Yazi satirlari
    let ink = NSColor(srgbRed: 0.09, green: 0.10, blue: 0.12, alpha: 1)
    let lineH = size * 0.045
    let lineX = labelRect.minX + labelW * 0.14
    func bar(_ y: CGFloat, _ width: CGFloat) {
        ink.setFill()
        NSBezierPath(roundedRect: CGRect(x: lineX, y: y, width: width, height: lineH),
                     xRadius: lineH / 2, yRadius: lineH / 2).fill()
    }
    bar(labelRect.midY + size * 0.035, labelW * 0.72)
    bar(labelRect.midY - size * 0.065, labelW * 0.46)

    // Yesil nokta: GHBar'daki "yeni" isaretiyle ayni renk
    let dotR = size * 0.032
    accent.setFill()
    NSBezierPath(ovalIn: CGRect(x: labelRect.maxX - labelW * 0.14 - dotR * 2, y: labelRect.midY - size * 0.065 + lineH / 2 - dotR,
                                width: dotR * 2, height: dotR * 2)).fill()

    return image
}

// MARK: - Yazma

func png(_ image: NSImage, _ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(size: CGFloat(pixels)).draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let outputDirectory = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "build/GHBar.iconset"

try? FileManager.default.createDirectory(
    atPath: outputDirectory, withIntermediateDirectories: true
)

// iconutil'in bekledigi tam dosya adlari
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16",      16), ("icon_16x16@2x",     32),
    ("icon_32x32",      32), ("icon_32x32@2x",     64),
    ("icon_128x128",   128), ("icon_128x128@2x",  256),
    ("icon_256x256",   256), ("icon_256x256@2x",  512),
    ("icon_512x512",   512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    let data = png(NSImage(), variant.pixels)
    let path = "\(outputDirectory)/\(variant.name).png"
    try! data.write(to: URL(fileURLWithPath: path))
    print("  \(variant.name).png  (\(variant.pixels)px, \(data.count / 1024) KB)")
}
print("iconset hazir: \(outputDirectory)")
