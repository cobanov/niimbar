import AppKit
import SwiftUI

// Hidden flag: draw the panel with sample content and exit, to check the design without the
// menu bar. Usage: NiimBar --render-panel out.png [text|qr|barcode]
if let flag = CommandLine.arguments.firstIndex(of: "--render-panel"), CommandLine.arguments.indices.contains(flag + 1) {
    _ = NSApplication.shared
    MainActor.assumeIsolated {
        let model = PanelModel()
        model.connection = .connected
        model.status = PrinterStatus(battery: 75, charging: nil, lidOpen: false, paperLoaded: true,
                                     label: LabelInfo(size: LabelSize(widthMM: 50, heightMM: 30), remaining: 182))
        let kind = CommandLine.arguments.indices.contains(flag + 2) ? CommandLine.arguments[flag + 2] : "text"
        model.kind = ComposeKind(rawValue: kind) ?? .text
        model.text = "Kablolar\nUSB-C · HDMI"
        model.qrText = "https://cobanov.dev"
        model.barcodeText = "NB-2026-001"
        let root = ArrowPanelContainer(position: ArrowPosition(), style: AppDelegate.style, content: AnyView(PanelView(model: model)))
        let view = NSHostingView(rootView: root)
        let size = view.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = view
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
    }
    exit(0)
}

// Hidden flag: read the printer's status once and print it. Read-only.
if CommandLine.arguments.contains("--status") {
    guard let path = SerialPort.findPrinter() else { print("no printer"); exit(1) }
    do { print(try B1(port: SerialPort(path: path)).readStatus()) } catch { print("error:", error); exit(1) }
    exit(0)
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
