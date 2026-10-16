import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What the panel asks of the app; the delegate supplies these.
struct PanelActions {
    var refresh: () -> Void = {}
    var print: () -> Void = {}
    var cancel: () -> Void = {}
    var quit: () -> Void = {}
}

enum ComposeKind: String, CaseIterable {
    case text, qr, barcode, image

    var title: String {
        switch self {
        case .text: "Text"
        case .qr: "QR"
        case .barcode: "Barcode"
        case .image: "Image"
        }
    }
}

@MainActor
final class PanelModel: ObservableObject {
    @Published var status = PrinterStatus()
    @Published var connection: Connection = .searching
    @Published var kind: ComposeKind = .text
    @Published var text = ""
    @Published var qrText = ""
    @Published var barcodeText = ""
    @Published var image: NSImage?
    @Published var copies = 1
    @Published var density = UserDefaults.standard.object(forKey: "density") as? Int ?? 3 {
        didSet { UserDefaults.standard.set(density, forKey: "density") }
    }
    /// The B1 cannot say how big its labels are, so the user picks; remembered.
    @Published var fallbackSize = LabelSize(widthMM: UserDefaults.standard.object(forKey: "labelWidth") as? Double ?? 50,
                                            heightMM: UserDefaults.standard.object(forKey: "labelHeight") as? Double ?? 30) {
        didSet {
            UserDefaults.standard.set(fallbackSize.widthMM, forKey: "labelWidth")
            UserDefaults.standard.set(fallbackSize.heightMM, forKey: "labelHeight")
        }
    }
    @Published var job: JobProgress?
    @Published var lastResult: String?
    /// Bumped each time the panel opens, so the text field can take focus.
    @Published var opened = 0
    var actions = PanelActions()

    var size: LabelSize { status.label?.size ?? fallbackSize }

    var content: LabelContent {
        switch kind {
        case .text: .text(text)
        case .qr: .qr(qrText)
        case .barcode: .barcode(barcodeText)
        case .image: image.map(LabelContent.image) ?? .text("")
        }
    }

    /// The printable part: labels wider than the 48 mm head lose the edges.
    var bitmap: LabelBitmap {
        LabelRenderer.render(content, widthMM: min(size.widthMM, Double(B1Encoder.headDots) / LabelRenderer.dotsPerMM),
                             heightMM: size.heightMM)
    }

    /// Why Print is greyed out, if it is.
    var printBlocker: String? {
        if case .failed = connection { return "Printer not connected" }
        if case .searching = connection { return "Printer not connected" }
        if job != nil { return "Printing…" }
        if content.isEmpty { return kind == .image ? "Paste or drop an image" : "Nothing to print yet" }
        if status.lidOpen == true { return "Close the lid" }
        if status.paperLoaded == false { return "Load a label roll" }
        return nil
    }
}

struct JobProgress: Equatable {
    var page: Int
    var total: Int
}

/// The panel: the printer and its roll at the top, a label to compose, its preview, Print.
struct PanelView: View {
    @ObservedObject var model: PanelModel
    @FocusState private var fieldFocused: Bool
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            tabs
            Rectangle().fill(Ink.hairline).frame(height: 1)
            composer
            preview
            Rectangle().fill(Ink.hairline).frame(height: 1)
            footer
        }
        .frame(width: 380)
        .foregroundStyle(Ink.primary)
        .background(shortcuts)
        .onChange(of: model.opened) { fieldFocused = model.kind != .image }
    }

    private var shortcuts: some View {
        ZStack {
            Button("", action: model.actions.refresh).keyboardShortcut("r")
            Button("", action: model.actions.quit).keyboardShortcut("q")
            Button("", action: { if model.printBlocker == nil { model.actions.print() } }).keyboardShortcut("p")
            Button("", action: pasteImage).keyboardShortcut("v", modifiers: [.command, .shift])
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .top, spacing: 11) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Ink.raised)
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: "printer").font(.system(size: 14, weight: .medium)).foregroundStyle(Ink.secondary))
            VStack(alignment: .leading, spacing: 4) {
                Text("NIIMBOT B1").font(Ink.name).lineLimit(1)
                    .help([model.status.serial, model.status.firmware.map { "firmware \($0)" }]
                        .compactMap { $0 }.joined(separator: " · "))
                statusLine
            }
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                IconButton(symbol: "arrow.clockwise", help: "Refresh (⌘R)", spinning: model.connection == .searching,
                           action: model.actions.refresh)
                IconButton(symbol: "ellipsis", help: "More") { moreMenu() }
            }
            .padding(.top, 3)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    @ViewBuilder private var statusLine: some View {
        switch model.connection {
        case .searching:
            Text("Looking for the printer…").font(Ink.meta).foregroundStyle(Ink.tertiary)
        case .failed(let reason):
            Text(reason).font(Ink.meta).foregroundStyle(Ink.warning).fixedSize(horizontal: false, vertical: true)
        case .connected:
            HStack(spacing: 10) {
                if let battery = model.status.battery { BatteryView(level: battery, charging: model.status.charging == true) }
                if model.status.lidOpen == true { warn("Lid open") }
                else if model.status.paperLoaded == false { warn("No labels") }
                else if let left = model.status.label?.remaining { meta("\(left) labels left", "tag") }
            }
        }
    }

    private func meta(_ text: String, _ symbol: String?) -> some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9.5)) }
            Text(verbatim: text).monospacedDigit()
        }
        .font(Ink.meta)
        .foregroundStyle(Ink.secondary)
        .fixedSize()
    }

    private func warn(_ text: String) -> some View {
        Text(text).font(Ink.meta).foregroundStyle(Ink.warning).fixedSize()
    }

    private func moreMenu() {
        var entries: [ChoiceMenu.Entry] = []
        if model.status.label?.size == nil {
            entries.append(.header("Label size"))
            for size in LabelSize.common {
                entries.append(.action(size.title, checked: size == model.fallbackSize) { model.fallbackSize = size })
            }
            entries.append(.separator)
        }
        entries.append(.header("Density"))
        for d in 1...5 {
            entries.append(.action(d == 3 ? "\(d) (default)" : "\(d)", checked: d == model.density) { model.density = d })
        }
        entries += [.separator, .action("Launch at login", checked: LaunchAtLogin.isEnabled) { LaunchAtLogin.set(!LaunchAtLogin.isEnabled) },
                    .separator, .action("Quit NiimBar", model.actions.quit)]
        ChoiceMenu.show(entries)
    }

    // MARK: tabs

    private var tabs: some View {
        HStack(spacing: 18) {
            ForEach(ComposeKind.allCases, id: \.self) { kind in
                let active = kind == model.kind
                Button {
                    model.kind = kind
                    fieldFocused = kind != .image
                } label: {
                    VStack(spacing: 8) {
                        Text(kind.title)
                            .font(active ? Ink.tabActive : Ink.tab)
                            .foregroundStyle(active ? Ink.primary : Ink.secondary)
                        Capsule().fill(active ? Ink.primary : .clear).frame(height: 2)
                    }
                    .fixedSize()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
    }

    // MARK: composer

    @ViewBuilder private var composer: some View {
        Group {
            switch model.kind {
            case .text:
                field("Label text — Return for a new line", text: $model.text, multiline: true)
            case .qr:
                field("Link or text to encode", text: $model.qrText, multiline: false)
            case .barcode:
                field("Code 128 — letters and digits", text: $model.barcodeText, multiline: false)
            case .image:
                imagePicker
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
    }

    private func field(_ prompt: String, text: Binding<String>, multiline: Bool) -> some View {
        TextField(prompt, text: text, axis: multiline ? .vertical : .horizontal)
            .lineLimit(multiline ? 1...4 : 1...1)
            .textFieldStyle(.plain)
            .font(Ink.body)
            .focused($fieldFocused)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Ink.raised))
    }

    private var imagePicker: some View {
        HStack(spacing: 8) {
            Button("Paste", action: pasteImage).buttonStyle(QuietButtonStyle()).help("Paste an image (⇧⌘V)")
            Button("Choose…", action: chooseImage).buttonStyle(QuietButtonStyle())
            Spacer(minLength: 0)
            Text(model.image == nil ? "or drop one below" : "Drop another to replace")
                .font(Ink.meta).foregroundStyle(Ink.tertiary)
            if model.image != nil {
                IconButton(symbol: "xmark", help: "Clear") { model.image = nil }
            }
        }
    }

    private func pasteImage() {
        let board = NSPasteboard.general
        if let image = NSImage(pasteboard: board) {
            model.kind = .image
            model.image = image
        } else if let string = board.string(forType: .string), !string.isEmpty, model.kind != .image {
            switch model.kind {
            case .qr: model.qrText = string
            case .barcode: model.barcodeText = string
            default: model.text = string
            }
        }
    }

    private func chooseImage() {
        let open = NSOpenPanel()
        open.allowedContentTypes = [.image, .pdf]
        open.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        if open.runModal() == .OK, let url = open.url, let image = NSImage(contentsOf: url) {
            model.kind = .image
            model.image = image
        }
    }

    // MARK: preview

    private var preview: some View {
        let bitmap = model.bitmap
        let aspect = CGFloat(bitmap.width) / CGFloat(max(bitmap.height, 1))
        let maxW: CGFloat = 344, maxH: CGFloat = 190
        let w = min(maxW, maxH * aspect), h = w / aspect
        return VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white)
                if let cg = bitmap.cgImage() {
                    Image(decorative: cg, scale: 1).interpolation(.none).resizable()
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Ink.green, lineWidth: 2)
                }
            }
            .frame(width: w, height: h)
            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
            .onDrop(of: [.image, .fileURL], isTargeted: $dropTargeted, perform: drop)
            .accessibilityLabel("Label preview")
            Text(verbatim: "\(model.size.title) · \(bitmap.width)×\(bitmap.height) dots")
                .font(Ink.meta).foregroundStyle(Ink.tertiary).monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                guard let image = image as? NSImage else { return }
                DispatchQueue.main.async { model.kind = .image; model.image = image }
            }
            return true
        }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, let image = NSImage(contentsOf: url) else { return }
            DispatchQueue.main.async { model.kind = .image; model.image = image }
        }
        return true
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 10) {
            copiesStepper
            Spacer(minLength: 0)
            if let job = model.job {
                Text(verbatim: "Printing \(job.page) of \(job.total)…").font(Ink.meta).foregroundStyle(Ink.secondary)
                    .monospacedDigit()
                Button("Cancel", action: model.actions.cancel).buttonStyle(QuietButtonStyle())
            } else {
                if let note = model.printBlocker ?? model.lastResult {
                    Text(note).font(Ink.meta).foregroundStyle(Ink.tertiary).lineLimit(1)
                }
                Button("Print", action: model.actions.print)
                    .buttonStyle(QuietButtonStyle(prominent: model.printBlocker == nil))
                    .disabled(model.printBlocker != nil)
                    .help("Print (⌘P)")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var copiesStepper: some View {
        HStack(spacing: 0) {
            stepButton("minus", enabled: model.copies > 1) { model.copies -= 1 }
            Text(verbatim: "\(model.copies)")
                .font(Ink.meta.weight(.medium)).monospacedDigit()
                .frame(minWidth: 22)
            stepButton("plus", enabled: model.copies < 99) { model.copies += 1 }
        }
        .padding(.horizontal, 2)
        .background(Capsule().fill(Ink.raised))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Copies")
        .accessibilityValue("\(model.copies)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.copies = min(99, model.copies + 1)
            case .decrement: model.copies = max(1, model.copies - 1)
            @unknown default: break
            }
        }
        .help("Copies")
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold))
                .frame(width: 24, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Ink.primary : Ink.tertiary.opacity(0.5))
        .disabled(!enabled)
    }
}

/// A small battery: four segments, green while charging.
struct BatteryView: View {
    let level: Int  // percent
    let charging: Bool

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 1.5) {
                ForEach(0..<4) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Double(i) < (Double(level) / 25).rounded(.up) ? fill : Ink.raised)
                        .frame(width: 4, height: 8)
                }
            }
            .padding(2)
            .overlay(RoundedRectangle(cornerRadius: 2.5).strokeBorder(Ink.secondary.opacity(0.6), lineWidth: 1))
            Text(verbatim: charging ? "\(level)% · charging" : "\(level)%")
                .font(Ink.meta).foregroundStyle(Ink.secondary).monospacedDigit()
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(charging ? "Battery \(level) percent, charging" : "Battery \(level) percent")
    }

    private var fill: Color { charging ? Ink.green : level <= 25 ? Ink.warning : Ink.primary.opacity(0.85) }
}
