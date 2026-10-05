// LetMeTalk — turn a wired headset's inline button into a key of your choice (Space by default),
// so it works as push-to-talk for Claude voice mode instead of opening Music.
//
// It uses the HID system's own key remapping (the mechanism behind `hidutil` and the
// Modifier Keys settings): the headset's Play/Pause usage is remapped to a keyboard usage
// on the headset's HID service. Holding the button then behaves exactly like holding the
// key — real key-down, native auto-repeat, real key-up — and the media system never sees it.
// The remap lives on the device's service, so the app re-applies it whenever a headset appears.

import AppKit
import IOKit
import IOKit.hidsystem
import ServiceManagement

private let kPlayPause: UInt64 = 0x0C_0000_00CD          // Consumer page, Play/Pause
private let kKeyboardPage: UInt64 = 0x07_0000_0000

/// macOS virtual key code → HID keyboard usage (page 0x07).
private let hidUsage: [UInt16: UInt64] = {
    var m: [UInt16: UInt64] = [
        49: 0x2C, 36: 0x28, 48: 0x2B, 51: 0x2A, 117: 0x4C, 53: 0x29,
        123: 0x50, 124: 0x4F, 125: 0x51, 126: 0x52, 115: 0x4A, 119: 0x4D, 116: 0x4B, 121: 0x4E,
        // modifiers (left / right)
        59: 0xE0, 56: 0xE1, 58: 0xE2, 55: 0xE3, 62: 0xE4, 60: 0xE5, 61: 0xE6, 54: 0xE7,
        // punctuation
        27: 0x2D, 24: 0x2E, 33: 0x2F, 30: 0x30, 42: 0x31, 41: 0x33, 39: 0x34, 50: 0x35,
        43: 0x36, 47: 0x37, 44: 0x38,
        // function keys F1–F20
        122: 0x3A, 120: 0x3B, 99: 0x3C, 118: 0x3D, 96: 0x3E, 97: 0x3F, 98: 0x40, 100: 0x41,
        101: 0x42, 109: 0x43, 103: 0x44, 111: 0x45, 105: 0x68, 107: 0x69, 113: 0x6A, 106: 0x6B,
        64: 0x6C, 79: 0x6D, 80: 0x6E, 90: 0x6F,
    ]
    let letters: [UInt16] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]
    for (i, code) in letters.enumerated() { m[code] = 0x04 + UInt64(i) }              // A–Z
    let digits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
    for (i, code) in digits.enumerated() { m[code] = 0x1E + UInt64(i) }               // 1–9, 0
    return m
}()

private let keyNames: [UInt16: String] = [
    49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 117: "Forward Delete", 53: "Esc",
    123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
    59: "Left Control", 56: "Left Shift", 58: "Left Option", 55: "Left Command",
    62: "Right Control", 60: "Right Shift", 61: "Right Option", 54: "Right Command",
    122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
    109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
    79: "F18", 80: "F19", 90: "F20",
]

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let hid = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    private var notifyPort: IONotificationPortRef?
    private var picker: NSPanel?
    private var pickerMonitor: Any?
    private var headsetFound = false

    private var enabled = UserDefaults.standard.object(forKey: "enabled") as? Bool ?? true
    private var keyCode = UInt16(exactly: UserDefaults.standard.object(forKey: "keyCode") as? Int ?? 49) ?? 49
    private var keyName = UserDefaults.standard.string(forKey: "keyName") ?? "Space"

    private var sigterm: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ note: Notification) {
        // `kill`/`pkill` send SIGTERM, which would skip applicationWillTerminate and leave the remap behind.
        signal(SIGTERM, SIG_IGN)
        sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm?.setEventHandler { NSApp.terminate(nil) }
        sigterm?.resume()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        buildMenu()
        watchForHeadsets()
        apply()
    }

    func applicationWillTerminate(_ note: Notification) {
        setMapping(nil)   // give the button back to the system
    }

    // MARK: Remapping

    /// HID services for wired headset buttons: consumer-control services on the audio transport.
    private func headsetServices() -> [IOHIDServiceClient] {
        guard let services = IOHIDEventSystemClientCopyServices(hid) as? [IOHIDServiceClient] else { return [] }
        return services.filter { service in
            (IOHIDServiceClientCopyProperty(service, kIOHIDTransportKey as CFString) as? String) == "Audio"
                && IOHIDServiceClientConformsTo(service, UInt32(kHIDPage_Consumer), UInt32(kHIDUsage_Csmr_ConsumerControl)) != 0
        }
    }

    private func setMapping(_ dst: UInt64?) {
        let mapping: [[String: UInt64]] = dst.map { [["HIDKeyboardModifierMappingSrc": kPlayPause,
                                                       "HIDKeyboardModifierMappingDst": kKeyboardPage | $0]] } ?? []
        let services = headsetServices()
        for service in services {
            IOHIDServiceClientSetProperty(service, kIOHIDUserKeyUsageMapKey as CFString, mapping as CFArray)
        }
        headsetFound = !services.isEmpty
    }

    private func apply() {
        setMapping(enabled ? hidUsage[keyCode] : nil)
        refresh()
    }

    /// Re-apply whenever an HID service appears (headset plugged in, wake, etc.).
    private func watchForHeadsets() {
        notifyPort = IONotificationPortCreate(kIOMainPortDefault)
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(), .defaultMode)
        let me = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { me, iterator in
            while case let s = IOIteratorNext(iterator), s != 0 { IOObjectRelease(s) }
            let app = Unmanaged<AppDelegate>.fromOpaque(me!).takeUnretainedValue()
            // The event-system client sees the service a moment after IOKit publishes it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { app.apply() }
        }
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            IOServiceAddMatchingNotification(notifyPort, type, IOServiceMatching("IOHIDEventService"), callback, me, &iterator)
            while case let s = IOIteratorNext(iterator), s != 0 { IOObjectRelease(s) }   // arm the notification
        }
    }

    // MARK: Key picker

    @objc private func chooseKey() {
        let label = NSTextField(labelWithString: "Press the key for the headset button to act as.\nA modifier on its own (like Right Option) works too.")
        label.alignment = .center
        label.frame = NSRect(x: 20, y: 20, width: 360, height: 40)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 80),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Choose Key"
        panel.contentView?.addSubview(label)
        panel.center()
        panel.isReleasedWhenClosed = false
        picker = panel

        pickerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.picker?.isKeyWindow == true else { return event }
            // flagsChanged fires on both press and release; take the press.
            if event.type == .flagsChanged && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty { return nil }
            guard hidUsage[event.keyCode] != nil else { NSSound.beep(); return nil }
            self.keyCode = event.keyCode
            self.keyName = keyNames[event.keyCode] ?? (event.charactersIgnoringModifiers ?? "?").uppercased()
            UserDefaults.standard.set(Int(self.keyCode), forKey: "keyCode")
            UserDefaults.standard.set(self.keyName, forKey: "keyName")
            self.closePicker()
            self.apply()
            return nil
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { [weak self] _ in
            self?.closePicker()
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func closePicker() {
        if let pickerMonitor { NSEvent.removeMonitor(pickerMonitor) }
        pickerMonitor = nil
        let panel = picker
        picker = nil
        panel?.close()
    }

    // MARK: Menu

    private func buildMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "", action: #selector(toggleEnabled), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Choose Key…", action: #selector(chooseKey), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit LetMeTalk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    private func refresh() {
        guard let menu = statusItem?.menu else { return }
        menu.items[0].title = "Headset Button → \(keyName)"
        menu.items[0].state = enabled ? .on : .off
        menu.items[2].state = SMAppService.mainApp.status == .enabled ? .on : .off
        let symbol = !enabled ? "mic" : (headsetFound ? "mic.fill" : "mic.slash")
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "LetMeTalk")
        statusItem.button?.toolTip = headsetFound ? "LetMeTalk" : "LetMeTalk: no wired headset found"
    }

    @objc private func toggleEnabled() {
        enabled.toggle()
        UserDefaults.standard.set(enabled, forKey: "enabled")
        apply()
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSAlert(error: error).runModal()
        }
        refresh()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
