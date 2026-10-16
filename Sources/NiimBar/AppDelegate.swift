import AppKit
import Combine
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: StatusPanel!
    private let model = PanelModel()
    /// All printer I/O, one request at a time, off the main thread.
    private let io = DispatchQueue(label: "niimbar.io")
    private var timer: Timer?
    private var cancelRequested = false
    private var warnedLowBattery = false
    private var resize: AnyCancellable?

    static let style = ArrowPanelStyle(fill: Ink.panel, border: Color.white.opacity(0.09), cornerRadius: 18,
                                       arrowHalfWidth: 17, arrowHeight: 9)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panel = StatusPanel(style: Self.style) { PanelView(model: model) }
        panel.onOpen = { [weak self] in
            guard let self else { return }
            model.opened += 1
            refresh()
            schedule()
        }
        model.actions = PanelActions(
            refresh: { [weak self] in self?.refresh() },
            print: { [weak self] in self?.printLabel() },
            cancel: { [weak self] in self?.cancelRequested = true },
            quit: { NSApp.terminate(nil) }
        )
        updateIcon()
        // The panel grows and shrinks with what is typed; keep it hanging from the menu bar.
        resize = model.objectWillChange.sink { [weak self] in self?.panel.contentChanged() }
        refresh()
        schedule()
        // USB plug and unplug show up as /dev changes; a refresh picks them up soon enough.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Every 3 s while the panel is open, every minute otherwise (for the icon and low battery).
    private func schedule() {
        timer?.invalidate()
        let interval: TimeInterval = panel.isOpen ? 3 : 60
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                if (interval == 3) != self.panel.isOpen { self.schedule() }
            }
        }
    }

    func refresh() {
        guard model.job == nil else { return }
        if model.connection != .connected { model.connection = .searching }
        io.async { [weak self] in
            let result = Result { () -> PrinterStatus in
                // Opened per request: between requests NiimBlue or another app can use the printer.
                guard let path = SerialPort.findPrinter() else { throw Disconnected() }
                return try B1(port: SerialPort(path: path)).readStatus()
            }
            DispatchQueue.main.async { self?.apply(result) }
        }
    }

    private struct Disconnected: LocalizedError {
        var errorDescription: String? { "Not connected. Plug in the B1 with a USB-C data cable." }
    }

    private func apply(_ result: Result<PrinterStatus, Error>) {
        switch result {
        case .success(let status):
            model.status = status
            model.connection = .connected
            warnIfLow(status)
        case .failure(let error):
            if case SerialPort.Failure.open(let reason) = error {
                model.connection = .failed("Busy: another app has the printer open (\(reason))")
            } else {
                model.connection = .failed(error.localizedDescription)
            }
        }
        updateIcon()
    }

    private func updateIcon() {
        let needsAttention: Bool = {
            guard model.connection == .connected else { return false }
            let s = model.status
            return s.lidOpen == true || s.paperLoaded == false || ((s.battery ?? 100) <= 25 && s.charging != true)
        }()
        let name = needsAttention ? "printer.trianglebadge.exclamationmark" : "printer"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "NiimBar")
            ?? NSImage(systemSymbolName: "printer", accessibilityDescription: "NiimBar")
        image?.isTemplate = true
        panel.statusItem.button?.image = image
        panel.statusItem.button?.appearsDisabled = model.connection != .connected
    }

    // MARK: low battery

    private func warnIfLow(_ status: PrinterStatus) {
        guard let battery = status.battery else { return }
        if battery > 25 || status.charging == true { warnedLowBattery = false; return }
        guard !warnedLowBattery, Bundle.main.bundleIdentifier != nil else { return }
        warnedLowBattery = true
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "NIIMBOT B1 battery low"
            content.body = "About \(battery)% left. Plug it in before the next print."
            center.add(UNNotificationRequest(identifier: "low-battery", content: content, trigger: nil))
        }
    }

    // MARK: printing

    private func printLabel() {
        guard model.printBlocker == nil else { return }
        let bitmap = model.bitmap, copies = model.copies, density = model.density
        let labelType = UInt8(model.status.label?.type ?? 1)
        cancelRequested = false
        model.lastResult = nil
        model.job = JobProgress(page: 1, total: copies)
        io.async { [weak self] in
            let result = Result { () -> Void in
                guard let path = SerialPort.findPrinter() else { throw Disconnected() }
                let printer = B1(port: try SerialPort(path: path))
                try printer.print(bitmap, copies: copies, density: density, labelType: labelType,
                                  progress: { page in
                                      DispatchQueue.main.async { self?.model.job = JobProgress(page: page, total: copies) }
                                  },
                                  cancelled: { DispatchQueue.main.sync { self?.cancelRequested ?? true } })
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.model.job = nil
                switch result {
                case .success: self.model.lastResult = copies == 1 ? "Printed" : "Printed \(copies)"
                case .failure(let error): self.model.lastResult = error.localizedDescription
                }
                self.refresh()
            }
        }
    }
}
