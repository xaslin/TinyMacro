// TinyMacro — a tiny mouse & keyboard macro recorder for macOS.
// Record, play back, loop, change speed, save/load, and export a recording
// as a standalone app that plays itself.

import Cocoa
import Carbon.HIToolbox
import UniformTypeIdentifiers

// MARK: - Clock
//
// Timing uses each event's own hardware timestamp (not "when our code got around to it"),
// so the recorded pace is exact even if the app is busy. Playback waits with mach_wait_until.

enum EventClock {
    static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t(); mach_timebase_info(&info); return info
    }()

    static func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    /// CGEvent timestamps are mach ticks on some Macs and nanoseconds on others.
    /// Decide from a real, just-delivered event by seeing which clock it's closer to.
    static func timestampIsNs(_ ts: CGEventTimestamp) -> Bool {
        let ns = Double(nowNs()), ticks = Double(mach_absolute_time()), t = Double(ts)
        return abs(t - ns) <= abs(t - ticks)
    }

    static func ns(fromTicks t: UInt64) -> UInt64 {
        UInt64(Double(t) * Double(timebase.numer) / Double(timebase.denom))
    }

    static func ticks(fromNs ns: UInt64) -> UInt64 {
        UInt64(Double(ns) * Double(timebase.denom) / Double(timebase.numer))
    }

    /// Gives the current thread real-time scheduling so waits wake up within microseconds
    /// instead of ~2 ms late.
    static func makeCurrentThreadRealtime() {
        var p = thread_time_constraint_policy_data_t(period: UInt32(ticks(fromNs: 1_000_000)),
                                                     computation: UInt32(ticks(fromNs: 100_000)),
                                                     constraint: UInt32(ticks(fromNs: 500_000)),
                                                     preemptible: 1)
        let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &p) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_policy_set(pthread_mach_thread_np(pthread_self()),
                                  thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
            }
        }
    }
}

// MARK: - Shortcuts

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var mods: UInt32      // Carbon modifier mask (controlKey | optionKey | shiftKey | cmdKey)
    var name: String      // display name of the key, e.g. "R" or "F5"

    static let defaultRecord = Shortcut(keyCode: UInt32(kVK_ANSI_R), mods: UInt32(controlKey | optionKey | shiftKey), name: "R")
    static let defaultPlay = Shortcut(keyCode: UInt32(kVK_ANSI_P), mods: UInt32(controlKey | optionKey | shiftKey), name: "P")

    static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]
    static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]

    /// Builds a shortcut from a key press. Needs ⌃, ⌥ or ⌘ (F-keys may be used alone)
    /// so it can't hijack normal typing.
    init?(event: NSEvent) {
        let code = Int(event.keyCode)
        let f = event.modifierFlags
        var m = 0
        if f.contains(.control) { m |= controlKey }
        if f.contains(.option) { m |= optionKey }
        if f.contains(.shift) { m |= shiftKey }
        if f.contains(.command) { m |= cmdKey }
        let isFn = Shortcut.functionKeys[code] != nil
        guard isFn || (m & (controlKey | optionKey | cmdKey)) != 0 else { return nil }
        let name = Shortcut.functionKeys[code] ?? Shortcut.specialKeys[code]
            ?? (event.characters(byApplyingModifiers: [])?.uppercased() ?? "?")
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.init(keyCode: UInt32(code), mods: UInt32(m), name: name)
    }

    init(keyCode: UInt32, mods: UInt32, name: String) {
        self.keyCode = keyCode; self.mods = mods; self.name = name
    }

    var display: String {
        var s = ""
        if mods & UInt32(controlKey) != 0 { s += "⌃" }
        if mods & UInt32(optionKey) != 0 { s += "⌥" }
        if mods & UInt32(shiftKey) != 0 { s += "⇧" }
        if mods & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + name
    }

    var cgFlags: CGEventFlags {
        var f: CGEventFlags = []
        if mods & UInt32(controlKey) != 0 { f.insert(.maskControl) }
        if mods & UInt32(optionKey) != 0 { f.insert(.maskAlternate) }
        if mods & UInt32(shiftKey) != 0 { f.insert(.maskShift) }
        if mods & UInt32(cmdKey) != 0 { f.insert(.maskCommand) }
        return f
    }
}

// MARK: - Model

struct RecordedEvent: Codable {
    var d: Double      // delay in seconds since the previous event
    var t: UInt32      // CGEventType raw value
    var e: Data        // serialized CGEvent
}

struct Recording: Codable {
    var version = 1
    var speed: Double? = nil        // exported apps only
    var loops: Int? = nil           // exported apps only (0 = forever)
    var loopDelay: Double? = nil    // exported apps only (seconds between runs)
    var stopKey: Shortcut? = nil    // exported apps only
    var events: [RecordedEvent]

    var duration: Double { events.reduce(0) { $0 + $1.d } }
}

let fileExtension = "tinyrec"

let mouseTypes: Set<CGEventType> = [
    .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
    .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged,
    .otherMouseDragged, .scrollWheel,
]
let keyTypes: Set<CGEventType> = [.keyDown, .keyUp, .flagsChanged]

// MARK: - Recorder (event tap on its own high-priority thread)

private struct RawEvent {
    var time: UInt64
    var type: CGEventType
    var data: Data
    var location: CGPoint
    var keycode: Int64
    var flags: CGEventFlags
}

final class Recorder {
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private let lock = NSLock()
    private var raw: [RawEvent] = []
    private var unitIsNs: Bool?     // decided from the first event of each recording
    var recordMouseMoves = true

    var isRecording: Bool { tap != nil }

    func start() -> Bool {
        lock.lock(); raw.removeAll(keepingCapacity: true); unitIsNs = nil; lock.unlock()

        let mask = mouseTypes.union(keyTypes).reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon { Unmanaged<Recorder>.fromOpaque(refcon).takeUnretainedValue().handle(type, event) }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .listenOnly, eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            EventClock.makeCurrentThreadRealtime()
            let rl = CFRunLoopGetCurrent()!
            runLoop = rl
            CFRunLoopAddSource(rl, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.qualityOfService = .userInteractive
        thread.name = "TinyMacro.recorder"
        thread.start()
        ready.wait()
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        if !recordMouseMoves && type == .mouseMoved { return }
        guard let data = event.data as Data? else { return }
        let ts = event.timestamp
        lock.lock()
        let time: UInt64
        if ts == 0 {
            time = EventClock.nowNs()
        } else {
            if unitIsNs == nil { unitIsNs = EventClock.timestampIsNs(ts) }
            time = unitIsNs! ? ts : EventClock.ns(fromTicks: ts)
        }
        raw.append(RawEvent(time: time, type: type, data: data, location: event.location,
                            keycode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags))
        lock.unlock()
    }

    /// Stops recording and returns cleaned-up events.
    /// - hotkeys: shortcut presses to strip out.
    /// - ignoreRect: our own window (global, top-left origin); trailing clicks on it (the Stop button) are dropped.
    func stop(hotkeys: [Shortcut], ignoreRect: CGRect) -> [RecordedEvent] {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let runLoop { CFRunLoopStop(runLoop) }
            CFMachPortInvalidate(tap)
        }
        tap = nil
        runLoop = nil

        lock.lock()
        var events = raw.sorted { $0.time < $1.time }
        raw.removeAll()
        lock.unlock()

        // 1. Drop hotkey presses, and key-ups whose key-down wasn't recorded.
        var down = Set<Int64>()
        events = events.filter { ev in
            switch ev.type {
            case .keyDown:
                if hotkeys.contains(where: { Int64($0.keyCode) == ev.keycode && ev.flags.isSuperset(of: $0.cgFlags) }) {
                    return false
                }
                down.insert(ev.keycode)
                return true
            case .keyUp:
                return down.remove(ev.keycode) != nil
            default:
                return true
            }
        }
        // 2. Drop the modifier presses/releases around the start/stop hotkey.
        while let f = events.first, f.type == .flagsChanged { events.removeFirst() }
        while let l = events.last, l.type == .flagsChanged { events.removeLast() }
        // 3. Drop trailing mouse activity on our own window (clicking "Stop").
        while let l = events.last, mouseTypes.contains(l.type), ignoreRect.contains(l.location) {
            events.removeLast()
        }

        var out: [RecordedEvent] = []
        out.reserveCapacity(events.count)
        var prev = events.first?.time ?? 0
        for ev in events {
            let gap = ev.time >= prev ? ev.time - prev : 0
            out.append(RecordedEvent(d: Double(gap) / 1e9, t: ev.type.rawValue, e: ev.data))
            prev = ev.time
        }
        return out
    }
}

// MARK: - Player

final class Player {
    private let lock = NSLock()
    private var _cancelled = false
    private(set) var isPlaying = false

    var cancelled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _cancelled }
        set { lock.lock(); _cancelled = newValue; lock.unlock() }
    }

    func cancel() { cancelled = true }

    /// Sleeps precisely until `target` (ns, uptime clock). Returns false if cancelled.
    private func wait(until target: UInt64) -> Bool {
        while true {
            if cancelled { return false }
            let now = EventClock.nowNs()
            if now >= target { return true }
            let chunk = min(target - now, 10_000_000) // stay responsive to cancel
            mach_wait_until(mach_absolute_time() + EventClock.ticks(fromNs: chunk))
        }
    }

    /// loops: 0 = forever
    /// loopDelay: real seconds to wait between runs (not affected by speed)
    func play(_ events: [RecordedEvent], speed: Double, loops: Int, loopDelay: Double = 0,
              onWait: @escaping (Int) -> Void = { _ in },
              onLoop: @escaping (Int) -> Void, done: @escaping () -> Void) {
        let delayNs = UInt64(max(0, loopDelay) * 1e9)
        guard !events.isEmpty, !isPlaying else { return }
        cancelled = false
        isPlaying = true

        // Decode once up front so playback never stalls on parsing.
        let decoded: [(delay: UInt64, type: CGEventType?, event: CGEvent)] = events.compactMap { ev in
            guard let cg = CGEvent(withDataAllocator: nil, data: ev.e as CFData) else { return nil }
            return (UInt64(max(0, ev.d) / speed * 1e9), CGEventType(rawValue: ev.t), cg)
        }

        let thread = Thread { [self] in
            EventClock.makeCurrentThreadRealtime()
            var heldKeys = Set<Int64>()
            var heldButtons = Set<UInt32>()
            var lastFlags: CGEventFlags = []
            var iteration = 0

            outer: while loops == 0 || iteration < loops {
                iteration += 1
                let n = iteration
                if n > 1 && delayNs > 0 {
                    DispatchQueue.main.async { onWait(n) }
                    if !wait(until: EventClock.nowNs() + delayNs) { break outer }
                }
                DispatchQueue.main.async { onLoop(n) }
                var target = EventClock.nowNs()
                for item in decoded {
                    target += item.delay
                    if !wait(until: target) { break outer }
                    let cg = item.event
                    cg.timestamp = 0   // let macOS stamp it with "now" instead of the recorded time
                    cg.post(tap: .cghidEventTap)

                    switch item.type {
                    case .keyDown?: heldKeys.insert(cg.getIntegerValueField(.keyboardEventKeycode))
                    case .keyUp?: heldKeys.remove(cg.getIntegerValueField(.keyboardEventKeycode))
                    case .flagsChanged?: lastFlags = cg.flags
                    case .leftMouseDown?: heldButtons.insert(CGMouseButton.left.rawValue)
                    case .rightMouseDown?: heldButtons.insert(CGMouseButton.right.rawValue)
                    case .otherMouseDown?: heldButtons.insert(CGMouseButton.center.rawValue)
                    case .leftMouseUp?: heldButtons.remove(CGMouseButton.left.rawValue)
                    case .rightMouseUp?: heldButtons.remove(CGMouseButton.right.rawValue)
                    case .otherMouseUp?: heldButtons.remove(CGMouseButton.center.rawValue)
                    default: break
                    }
                }
            }

            // Release anything still held so nothing gets "stuck".
            for key in heldKeys {
                let up = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: false)
                up?.flags = []
                up?.post(tap: .cghidEventTap)
            }
            if !lastFlags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand]).isEmpty,
               let ev = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Shift), keyDown: false) {
                ev.type = .flagsChanged
                ev.flags = []
                ev.post(tap: .cghidEventTap)
            }
            let loc = CGEvent(source: nil)?.location ?? .zero
            for raw in heldButtons {
                guard let b = CGMouseButton(rawValue: raw) else { continue }
                let type: CGEventType = b == .left ? .leftMouseUp : b == .right ? .rightMouseUp : .otherMouseUp
                CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: loc, mouseButton: b)?
                    .post(tap: .cghidEventTap)
            }

            DispatchQueue.main.async {
                self.isPlaying = false
                done()
            }
        }
        thread.qualityOfService = .userInteractive
        thread.name = "TinyMacro.player"
        thread.start()
    }
}

// MARK: - Global hotkeys (Carbon; no extra permission needed)

enum HotKey: UInt32 { case record = 1, play = 2 }

final class HotKeys {
    private var refs: [EventHotKeyRef] = []
    private var installed = false
    static var handler: ((HotKey) -> Void)?

    /// Returns the hotkeys that failed to register (e.g. already taken by another app).
    @discardableResult
    func register(_ keys: [(HotKey, Shortcut)]) -> [HotKey] {
        if !installed {
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                if let key = HotKey(rawValue: id.id) {
                    DispatchQueue.main.async { HotKeys.handler?(key) }
                }
                return noErr
            }, 1, &spec, nil, nil)
        }
        unregisterAll()
        var failed: [HotKey] = []
        for (key, sc) in keys {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(sc.keyCode, sc.mods,
                                             EventHotKeyID(signature: OSType(0x544D4352), id: key.rawValue),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) } else { failed.append(key) }
        }
        return failed
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
    }
}

// MARK: - Permissions

enum Permissions {
    static func accessibility(prompt: Bool) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }
    static var inputMonitoring: Bool { CGPreflightListenEventAccess() }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    static func openInputMonitoringSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
}

// MARK: - Settings storage

enum Prefs {
    static let d = UserDefaults.standard

    static var speed: Double {
        get { d.object(forKey: "speed") as? Double ?? 1 }
        set { d.set(newValue, forKey: "speed") }
    }
    /// 0 = continuous, otherwise number of times to play
    static var loops: Int {
        get { max(0, d.object(forKey: "loops") as? Int ?? 1) }
        set { d.set(max(0, newValue), forKey: "loops") }
    }
    static var loopDelay: Double {   // seconds to wait between runs
        get { max(0, d.object(forKey: "loopDelay") as? Double ?? 0) }
        set { d.set(max(0, newValue), forKey: "loopDelay") }
    }
    static var repeatCount: Int {   // remembered value for the "Repeat N times" field
        get { max(2, d.object(forKey: "repeatCount") as? Int ?? 2) }
        set { d.set(max(2, newValue), forKey: "repeatCount") }
    }
    static var alwaysOnTop: Bool {
        get { d.object(forKey: "onTop") as? Bool ?? true }
        set { d.set(newValue, forKey: "onTop") }
    }
    static var recordMouseMoves: Bool {
        get { d.object(forKey: "mouseMoves") as? Bool ?? true }
        set { d.set(newValue, forKey: "mouseMoves") }
    }
    static var hideWhilePlaying: Bool {
        get { d.bool(forKey: "hideWhilePlaying") }
        set { d.set(newValue, forKey: "hideWhilePlaying") }
    }
    static var recordShortcut: Shortcut {
        get { shortcut("recordKey") ?? .defaultRecord }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: "recordKey") }
    }
    static var playShortcut: Shortcut {
        get { shortcut("playKey") ?? .defaultPlay }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: "playKey") }
    }
    private static func shortcut(_ key: String) -> Shortcut? {
        d.data(forKey: key).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
    }
}

// MARK: - Toolbar button (flat, icon above a small label, hover highlight)

final class ToolButton: NSButton {
    private var hovering = false { didSet { needsDisplay = true } }
    var active = false { didSet { needsDisplay = true } }

    convenience init(title: String, image: NSImage?, target: AnyObject, action: Selector) {
        self.init(frame: NSRect(x: 0, y: 0, width: 44, height: 48))
        isBordered = false
        imagePosition = .imageAbove
        imageScaling = .scaleNone
        setButtonType(.momentaryChange)
        self.title = title
        self.image = image
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 44).isActive = true
        heightAnchor.constraint(equalToConstant: 48).isActive = true
    }

    override var title: String {
        didSet {
            let p = NSMutableParagraphStyle(); p.alignment = .center
            attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.black, .paragraphStyle: p])
        }
    }

    override var isEnabled: Bool { didSet { alphaValue = isEnabled ? 1 : 0.35; needsDisplay = true } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        if isEnabled && (isHighlighted || hovering || active) {
            NSColor(white: isHighlighted || active ? 0.85 : 0.93, alpha: 1).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
    }
}

// MARK: - Shortcut recorder field (click, then press the new key combo)

final class ShortcutField: NSButton {
    var shortcut: Shortcut { didSet { refresh() } }
    var onChange: ((Shortcut) -> Void)?
    var onCaptureBegan: (() -> Void)?
    var onCaptureEnded: (() -> Void)?
    private var monitor: Any?

    init(_ s: Shortcut) {
        shortcut = s
        super.init(frame: .zero)
        bezelStyle = .push
        target = self
        action = #selector(clicked)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 150).isActive = true
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        title = monitor == nil ? shortcut.display : "Type shortcut…"
        toolTip = monitor == nil ? "Click, then press a new key combination" : "Press keys (Esc to cancel)"
    }

    @objc private func clicked() { monitor == nil ? begin() : end() }

    private func begin() {
        onCaptureBegan?()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] e in
            guard let self else { return e }
            if e.type == .leftMouseDown {
                if e.window !== self.window || !self.bounds.contains(self.convert(e.locationInWindow, from: nil)) {
                    self.end()
                }
                return e
            }
            if e.keyCode == UInt16(kVK_Escape) { self.end(); return nil }
            if let s = Shortcut(event: e) {
                self.end()
                self.onChange?(s)
            } else {
                NSSound.beep()
            }
            return nil
        }
        refresh()
    }

    func end() {
        guard let m = monitor else { return }
        NSEvent.removeMonitor(m)
        monitor = nil
        refresh()
        onCaptureEnded?()
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    let recorder = Recorder()
    let player = Player()
    let hotkeys = HotKeys()
    var activity: NSObjectProtocol?   // keeps App Nap from throttling us while recording/playing

    var recording: Recording? { didSet { updateUI() } }
    var currentFile: URL?
    var loopIteration = 0
    var embedded: Recording?

    // Toolbar
    var recordButton: ToolButton!
    var playButton: ToolButton!
    var openButton: ToolButton!
    var saveButton: ToolButton!
    var exportButton: ToolButton!
    var prefsButton: ToolButton!
    var recordMenuItem: NSMenuItem!
    var playMenuItem: NSMenuItem!

    // Settings window
    var settingsWindow: NSWindow?
    var recordField: ShortcutField!
    var playField: ShortcutField!
    var shortcutError: NSTextField!
    var speedPopup: NSPopUpButton!
    var onceRadio: NSButton!
    var repeatRadio: NSButton!
    var foreverRadio: NSButton!
    var repeatField: NSTextField!
    var delayField: NSTextField!
    var waitingForRun = 0       // >0 while pausing before that run
    var onTopCheck: NSButton!
    var mouseMovesCheck: NSButton!
    var hideCheck: NSButton!
    var axStatus: NSTextField!
    var imStatus: NSTextField!

    let speeds: [Double] = [0.25, 0.5, 1, 2, 4, 8, 16, 50, 100]

    func applicationDidFinishLaunching(_ note: Notification) {
        if let url = Bundle.main.url(forResource: "embedded", withExtension: fileExtension),
           let rec = try? JSONDecoder().decode(Recording.self, from: Data(contentsOf: url)) {
            embedded = rec
            runEmbedded(rec)
            return
        }

        buildMenu()
        buildWindow()
        HotKeys.handler = { [weak self] key in
            switch key {
            case .record: self?.toggleRecord(nil)
            case .play: self?.togglePlay(nil)
            }
        }
        registerHotkeys()
        updateUI()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        if window == nil { DispatchQueue.main.async { self.load(URL(fileURLWithPath: filename)) }; return true }
        return load(URL(fileURLWithPath: filename))
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === window { NSApp.terminate(nil); return false }
        return true
    }

    func windowDidBecomeKey(_ note: Notification) {
        if (note.object as? NSWindow) === settingsWindow { refreshSettings() }
    }

    @discardableResult
    func registerHotkeys() -> [HotKey] {
        let failed = hotkeys.register([(.record, Prefs.recordShortcut), (.play, Prefs.playShortcut)])
        updateShortcutLabels()
        return failed
    }

    func beginActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled, .idleDisplaySleepDisabled],
            reason: "Recording or playing a macro")
    }

    func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    // MARK: Menu

    func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About TinyMacro", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide TinyMacro", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit TinyMacro", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open…", action: #selector(openFile(_:)), keyEquivalent: "o").target = self
        fileMenu.addItem(withTitle: "Save…", action: #selector(saveFile(_:)), keyEquivalent: "s").target = self
        fileMenu.addItem(withTitle: "Export as App…", action: #selector(exportApp(_:)), keyEquivalent: "e").target = self
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu

        let editItem = NSMenuItem(); main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let macroItem = NSMenuItem(); main.addItem(macroItem)
        let macroMenu = NSMenu(title: "Macro")
        recordMenuItem = macroMenu.addItem(withTitle: "Record", action: #selector(toggleRecord(_:)), keyEquivalent: "")
        recordMenuItem.target = self
        playMenuItem = macroMenu.addItem(withTitle: "Play", action: #selector(togglePlay(_:)), keyEquivalent: "")
        playMenuItem.target = self
        macroItem.submenu = macroMenu

        NSApp.mainMenu = main
    }

    // MARK: Main window

    func symbol(_ name: String, _ colors: [NSColor]) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 21, weight: .regular)
            .applying(.init(paletteColors: colors))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
    }

    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "TinyMacro"
        window.appearance = NSAppearance(named: .aqua)   // always light/white
        window.backgroundColor = .white
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.level = Prefs.alwaysOnTop ? .floating : .normal

        let w = NSColor.white
        openButton = ToolButton(title: "Open", image: symbol("folder.fill", [.systemYellow]), target: self, action: #selector(openFile(_:)))
        saveButton = ToolButton(title: "Save", image: symbol("square.and.arrow.down.fill", [.systemBlue]), target: self, action: #selector(saveFile(_:)))
        recordButton = ToolButton(title: "Rec", image: symbol("record.circle.fill", [w, .systemRed]), target: self, action: #selector(toggleRecord(_:)))
        playButton = ToolButton(title: "Play", image: symbol("play.circle.fill", [w, .systemGreen]), target: self, action: #selector(togglePlay(_:)))
        exportButton = ToolButton(title: ".app", image: symbol("shippingbox.fill", [.systemBrown]), target: self, action: #selector(exportApp(_:)))
        prefsButton = ToolButton(title: "Prefs", image: symbol("gearshape.fill", [.systemGray]), target: self, action: #selector(showSettings(_:)))
        openButton.toolTip = "Open a recording (⌘O)"
        saveButton.toolTip = "Save the recording (⌘S)"
        exportButton.toolTip = "Compile the recording into a standalone app that plays it (⌘E)"
        prefsButton.toolTip = "Settings: shortcuts, speed, repeat (⌘,)"

        let row = NSStackView(views: [openButton, saveButton, recordButton, playButton, exportButton, prefsButton])
        row.spacing = 1
        row.edgeInsets = NSEdgeInsets(top: 3, left: 4, bottom: 4, right: 4)
        window.contentView = row
        window.setContentSize(row.fittingSize)
        window.setFrameAutosaveName("TinyMacroMain")
        if !window.setFrameUsingName("TinyMacroMain") { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    func speedlessSeconds(_ s: Double) -> String { s == s.rounded() ? "\(Int(s))" : String(format: "%g", s) }

    func speedTitle(_ s: Double) -> String { s == s.rounded() ? "\(Int(s))x" : "\(s)x" }

    func updateShortcutLabels() {
        let r = Prefs.recordShortcut.display, p = Prefs.playShortcut.display
        recordButton?.toolTip = "Record / stop recording  (\(r))"
        recordMenuItem?.title = "Record / Stop\t\(r)"
        playMenuItem?.title = "Play / Stop\t\(p)"
        updateUI()
    }

    func updateUI() {
        guard window != nil else { return }
        let rec = recorder.isRecording, play = player.isPlaying, busy = rec || play
        let has = !(recording?.events.isEmpty ?? true)
        let w = NSColor.white

        recordButton.image = symbol(rec ? "stop.circle.fill" : "record.circle.fill", [w, .systemRed])
        recordButton.title = rec ? "Stop" : "Rec"
        recordButton.active = rec
        playButton.image = symbol(play ? "stop.circle.fill" : "play.circle.fill", [w, .systemGreen])
        playButton.title = play ? "Stop" : "Play"
        playButton.active = play

        recordButton.isEnabled = !play
        playButton.isEnabled = !rec && (has || play)
        openButton.isEnabled = !busy
        saveButton.isEnabled = !busy && has
        exportButton.isEnabled = !busy && has
        prefsButton.isEnabled = !busy

        let loops = Prefs.loops
        if rec {
            window.title = "Recording…"
        } else if play {
            let total = loops == 0 ? "∞" : "\(loops)"
            if waitingForRun > 0 {
                window.title = "Waiting \(speedlessSeconds(Prefs.loopDelay))s… (next \(waitingForRun)/\(total))"
            } else {
                window.title = loops == 1 ? "Playing…" : "Playing \(loopIteration)/\(total)…"
            }
        } else if let f = currentFile {
            window.title = f.deletingPathExtension().lastPathComponent
        } else {
            window.title = "TinyMacro"
        }

        var tip = "Play / stop  (\(Prefs.playShortcut.display))"
        tip += "\nSpeed \(speedTitle(Prefs.speed)), " + (loops == 0 ? "continuous" : loops == 1 ? "play once" : "\(loops) times")
        if loops != 1 && Prefs.loopDelay > 0 { tip += ", \(speedlessSeconds(Prefs.loopDelay))s between runs" }
        if let r = recording, has { tip += "\n\(r.events.count) events, \(String(format: "%.1f", r.duration)) s" }
        playButton.toolTip = tip
    }

    var windowRectCG: CGRect {
        let f = window.frame
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: f.minX, y: h - f.maxY, width: f.width, height: f.height)
    }

    // MARK: Settings window

    func buildSettings() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "TinyMacro Settings"
        win.appearance = NSAppearance(named: .aqua)
        win.backgroundColor = .white
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.level = .floating

        func label(_ s: String) -> NSTextField { NSTextField(labelWithString: s) }
        func header(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s); l.font = .boldSystemFont(ofSize: 13); return l
        }
        func hint(_ s: String) -> NSTextField {
            let l = NSTextField(wrappingLabelWithString: s)
            l.font = .systemFont(ofSize: 11); l.textColor = .secondaryLabelColor
            l.preferredMaxLayoutWidth = 260
            return l
        }

        // Shortcuts
        recordField = ShortcutField(Prefs.recordShortcut)
        playField = ShortcutField(Prefs.playShortcut)
        for (field, key) in [(recordField!, HotKey.record), (playField!, HotKey.play)] {
            field.onCaptureBegan = { [weak self] in
                self?.hotkeys.unregisterAll()
                if field === self?.recordField { self?.playField.end() } else { self?.recordField.end() }
            }
            field.onCaptureEnded = { [weak self] in self?.registerHotkeys() }
            field.onChange = { [weak self] s in self?.setShortcut(s, for: key) }
        }
        let reset = NSButton(title: "Reset to Defaults", target: self, action: #selector(resetShortcuts))
        reset.controlSize = .small
        shortcutError = hint("")
        shortcutError.textColor = .systemRed

        // Playback
        speedPopup = NSPopUpButton()
        speedPopup.addItems(withTitles: speeds.map(speedTitle))
        speedPopup.target = self
        speedPopup.action = #selector(settingsChanged)

        onceRadio = NSButton(radioButtonWithTitle: "Play once", target: self, action: #selector(repeatModeChanged(_:)))
        repeatRadio = NSButton(radioButtonWithTitle: "Repeat", target: self, action: #selector(repeatModeChanged(_:)))
        foreverRadio = NSButton(radioButtonWithTitle: "Repeat continuously (until stopped)", target: self, action: #selector(repeatModeChanged(_:)))
        repeatField = NSTextField(string: "\(Prefs.repeatCount)")
        repeatField.alignment = .right
        let fmt = NumberFormatter(); fmt.minimum = 2; fmt.maximum = 1_000_000; fmt.allowsFloats = false
        repeatField.formatter = fmt
        repeatField.target = self
        repeatField.action = #selector(settingsChanged)
        repeatField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        let repeatRow = NSStackView(views: [repeatRadio, repeatField, label("times")])
        repeatRow.spacing = 6
        let repeatStack = NSStackView(views: [onceRadio, repeatRow, foreverRadio])
        repeatStack.orientation = .vertical
        repeatStack.alignment = .leading
        repeatStack.spacing = 6

        delayField = NSTextField(string: "")
        delayField.alignment = .right
        let dfmt = NumberFormatter()
        dfmt.numberStyle = .decimal; dfmt.minimum = 0; dfmt.maximum = 86_400; dfmt.maximumFractionDigits = 2
        delayField.formatter = dfmt
        delayField.target = self
        delayField.action = #selector(settingsChanged)
        delayField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        let delayRow = NSStackView(views: [delayField, label("seconds")])
        delayRow.spacing = 6

        // Options
        onTopCheck = NSButton(checkboxWithTitle: "Keep TinyMacro on top of other windows", target: self, action: #selector(settingsChanged))
        mouseMovesCheck = NSButton(checkboxWithTitle: "Record mouse movement (not just clicks)", target: self, action: #selector(settingsChanged))
        hideCheck = NSButton(checkboxWithTitle: "Hide TinyMacro while playing", target: self, action: #selector(settingsChanged))
        let optStack = NSStackView(views: [onTopCheck, mouseMovesCheck, hideCheck])
        optStack.orientation = .vertical
        optStack.alignment = .leading
        optStack.spacing = 6

        // Permissions
        axStatus = label("")
        imStatus = label("")
        let axButton = NSButton(title: "Open…", target: self, action: #selector(openAXSettings))
        let imButton = NSButton(title: "Open…", target: self, action: #selector(openIMSettings))
        axButton.controlSize = .small; imButton.controlSize = .small
        let axRow = NSStackView(views: [axStatus, axButton]); axRow.spacing = 8
        let imRow = NSStackView(views: [imStatus, imButton]); imRow.spacing = 8

        let grid = NSGridView(views: [
            [header("Shortcuts"), NSGridCell.emptyContentView],
            [label("Record / Stop:"), recordField],
            [label("Play / Stop:"), playField],
            [NSGridCell.emptyContentView, reset],
            [NSGridCell.emptyContentView, hint("Click a shortcut, then press the new keys. Use ⌃, ⌥ or ⌘ with a key, or an F-key on its own. These work from any app.")],
            [NSGridCell.emptyContentView, shortcutError],
            [header("Playback"), NSGridCell.emptyContentView],
            [label("Speed:"), speedPopup],
            [label("Repeat:"), repeatStack],
            [label("Wait between runs:"), delayRow],
            [header("Options"), NSGridCell.emptyContentView],
            [NSGridCell.emptyContentView, optStack],
            [header("Permissions"), NSGridCell.emptyContentView],
            [label("Accessibility:"), axRow],
            [label("Input Monitoring:"), imRow],
            [NSGridCell.emptyContentView, hint("Accessibility is needed to play macros, Input Monitoring to record keystrokes. After allowing, relaunch TinyMacro.")],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        for i in [0, 6, 10, 12] {
            let row = grid.row(at: i)
            row.mergeCells(in: NSRange(location: 0, length: 2))
            row.cell(at: 0).xPlacement = .leading
            if i > 0 { row.topPadding = 10 }
        }
        grid.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        win.contentView = content
        win.setContentSize(content.fittingSize)
        win.center()
        settingsWindow = win
    }

    @objc func showSettings(_ sender: Any?) {
        if player.isPlaying || recorder.isRecording { return }
        if settingsWindow == nil { buildSettings() }
        refreshSettings()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refreshSettings() {
        guard settingsWindow != nil else { return }
        recordField.shortcut = Prefs.recordShortcut
        playField.shortcut = Prefs.playShortcut
        speedPopup.selectItem(at: speeds.firstIndex(of: Prefs.speed) ?? 2)
        let loops = Prefs.loops
        onceRadio.state = loops == 1 ? .on : .off
        repeatRadio.state = loops > 1 ? .on : .off
        foreverRadio.state = loops == 0 ? .on : .off
        repeatField.integerValue = loops > 1 ? loops : Prefs.repeatCount
        repeatField.isEnabled = loops > 1
        delayField.doubleValue = Prefs.loopDelay
        delayField.isEnabled = loops != 1
        onTopCheck.state = Prefs.alwaysOnTop ? .on : .off
        mouseMovesCheck.state = Prefs.recordMouseMoves ? .on : .off
        hideCheck.state = Prefs.hideWhilePlaying ? .on : .off

        func status(_ field: NSTextField, _ ok: Bool) {
            field.stringValue = ok ? "● Allowed" : "● Not allowed"
            field.textColor = ok ? .systemGreen : .systemRed
        }
        status(axStatus, Permissions.accessibility(prompt: false))
        status(imStatus, Permissions.inputMonitoring)
    }

    func setShortcut(_ s: Shortcut, for key: HotKey) {
        let other = key == .record ? Prefs.playShortcut : Prefs.recordShortcut
        if s == other {
            shortcutError.stringValue = "\(s.display) is already used for \(key == .record ? "Play" : "Record")."
            NSSound.beep()
            return
        }
        let old = key == .record ? Prefs.recordShortcut : Prefs.playShortcut
        if key == .record { Prefs.recordShortcut = s } else { Prefs.playShortcut = s }
        if registerHotkeys().contains(key) {
            // Taken by the system or another app; roll back.
            if key == .record { Prefs.recordShortcut = old } else { Prefs.playShortcut = old }
            registerHotkeys()
            shortcutError.stringValue = "\(s.display) is already used by macOS or another app. Try a different one."
            NSSound.beep()
        } else {
            shortcutError.stringValue = ""
        }
        refreshSettings()
    }

    @objc func resetShortcuts() {
        Prefs.recordShortcut = .defaultRecord
        Prefs.playShortcut = .defaultPlay
        shortcutError.stringValue = registerHotkeys().isEmpty ? "" : "A default shortcut is taken by another app."
        refreshSettings()
    }

    @objc func repeatModeChanged(_ sender: NSButton) {
        for r in [onceRadio!, repeatRadio!, foreverRadio!] { r.state = r === sender ? .on : .off }
        if sender === repeatRadio { settingsWindow?.makeFirstResponder(repeatField) }
        settingsChanged()
    }

    @objc func settingsChanged() {
        Prefs.speed = speeds[max(0, speedPopup.indexOfSelectedItem)]
        if repeatRadio.state == .on {
            let n = max(2, repeatField.integerValue)
            Prefs.repeatCount = n
            Prefs.loops = n
        } else {
            Prefs.loops = foreverRadio.state == .on ? 0 : 1
        }
        repeatField.isEnabled = repeatRadio.state == .on
        Prefs.loopDelay = max(0, delayField.doubleValue)
        delayField.isEnabled = onceRadio.state != .on
        Prefs.alwaysOnTop = onTopCheck.state == .on
        window.level = Prefs.alwaysOnTop ? .floating : .normal
        Prefs.recordMouseMoves = mouseMovesCheck.state == .on
        Prefs.hideWhilePlaying = hideCheck.state == .on
        updateUI()
    }

    // MARK: Actions

    @objc func toggleRecord(_ sender: Any?) {
        if embedded != nil || player.isPlaying { return }
        if recorder.isRecording {
            let events = recorder.stop(hotkeys: [Prefs.recordShortcut, Prefs.playShortcut], ignoreRect: windowRectCG)
            endActivity()
            currentFile = nil
            recording = Recording(events: events)
            return
        }
        if let s = settingsWindow, s.isVisible { settingsChanged(); s.close() }
        guard Permissions.accessibility(prompt: true) else {
            alert("Accessibility permission needed",
                  "Allow TinyMacro in System Settings → Privacy & Security → Accessibility, then try again.",
                  open: Permissions.openAccessibilitySettings)
            return
        }
        if !Permissions.inputMonitoring { CGRequestListenEventAccess() }
        recorder.recordMouseMoves = Prefs.recordMouseMoves
        if !recorder.start() {
            alert("Couldn't start recording",
                  "Allow TinyMacro in System Settings → Privacy & Security → Input Monitoring, then relaunch TinyMacro.",
                  open: Permissions.openInputMonitoringSettings)
            return
        }
        beginActivity()
        updateUI()
    }

    @objc func togglePlay(_ sender: Any?) {
        if embedded != nil { player.cancel(); return }
        if recorder.isRecording { return }
        if player.isPlaying { player.cancel(); return }
        guard let rec = recording, !rec.events.isEmpty else { return }
        guard Permissions.accessibility(prompt: true) else {
            alert("Accessibility permission needed",
                  "Allow TinyMacro in System Settings → Privacy & Security → Accessibility, then try again.",
                  open: Permissions.openAccessibilitySettings)
            return
        }
        if let s = settingsWindow, s.isVisible { settingsChanged(); s.close() }
        loopIteration = 0
        beginActivity()
        let hide = Prefs.hideWhilePlaying
        if hide { window.orderOut(nil) }
        waitingForRun = 0
        player.play(rec.events, speed: Prefs.speed, loops: Prefs.loops, loopDelay: Prefs.loopDelay,
                    onWait: { [weak self] i in self?.waitingForRun = i; self?.updateUI() },
                    onLoop: { [weak self] i in
                        self?.waitingForRun = 0; self?.loopIteration = i; self?.updateUI()
                    },
                    done: { [weak self] in
                        guard let self else { return }
                        self.endActivity()
                        if hide { self.window.orderFront(nil) }
                        self.updateUI()
                    })
        updateUI()
    }

    @objc func openFile(_ sender: Any?) {
        guard !recorder.isRecording, !player.isPlaying else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: fileExtension) ?? .json, .json]
        panel.begin { [weak self] resp in
            if resp == .OK, let url = panel.url { self?.load(url) }
        }
    }

    @discardableResult
    func load(_ url: URL) -> Bool {
        do {
            let rec = try JSONDecoder().decode(Recording.self, from: Data(contentsOf: url))
            currentFile = url
            recording = rec
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            return true
        } catch {
            alert("Couldn't open file", error.localizedDescription)
            return false
        }
    }

    @objc func saveFile(_ sender: Any?) {
        guard let rec = recording, !rec.events.isEmpty, !recorder.isRecording, !player.isPlaying else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: fileExtension) ?? .json]
        panel.nameFieldStringValue = currentFile?.lastPathComponent ?? "Macro.\(fileExtension)"
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            do {
                try JSONEncoder().encode(rec).write(to: url, options: .atomic)
                self.currentFile = url
                self.updateUI()
            } catch {
                self.alert("Couldn't save file", error.localizedDescription)
            }
        }
    }

    @objc func exportApp(_ sender: Any?) {
        guard var rec = recording, !rec.events.isEmpty, !recorder.isRecording, !player.isPlaying else { return }
        rec.speed = Prefs.speed
        rec.loops = Prefs.loops
        rec.loopDelay = Prefs.loopDelay
        rec.stopKey = Prefs.playShortcut

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.nameFieldStringValue = (currentFile?.deletingPathExtension().lastPathComponent ?? "Macro") + ".app"
        panel.message = "The exported app plays this macro when opened (\(Prefs.playShortcut.display) stops it)."
        panel.begin { [weak self] resp in
            guard resp == .OK, let dest = panel.url, let self else { return }
            do {
                try self.writeExportedApp(rec, to: dest)
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            } catch {
                self.alert("Export failed", error.localizedDescription)
            }
        }
    }

    func writeExportedApp(_ rec: Recording, to dest: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: Bundle.main.bundleURL, to: dest)

        let resources = dest.appendingPathComponent("Contents/Resources")
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        try JSONEncoder().encode(rec).write(to: resources.appendingPathComponent("embedded.\(fileExtension)"))

        let name = dest.deletingPathExtension().lastPathComponent
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let plistURL = dest.appendingPathComponent("Contents/Info.plist")
        var plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil)
            as? [String: Any] ?? [:]
        plist["CFBundleIdentifier"] = "com.tinymacro.player.\(slug)"
        plist["CFBundleName"] = name
        plist["CFBundleDisplayName"] = name
        plist.removeValue(forKey: "CFBundleDocumentTypes")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["--force", "--deep", "--sign", "-", dest.path]
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw NSError(domain: "TinyMacro", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "codesign failed (status \(p.terminationStatus))"])
        }
    }

    @objc func openAXSettings() { Permissions.openAccessibilitySettings() }
    @objc func openIMSettings() { Permissions.openInputMonitoringSettings() }

    func alert(_ title: String, _ text: String, open: (() -> Void)? = nil) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: open == nil ? "OK" : "Open Settings")
        if open != nil { a.addButton(withTitle: "Cancel") }
        if a.runModal() == .alertFirstButtonReturn { open?() }
    }

    // MARK: Embedded (exported app) mode

    func runEmbedded(_ rec: Recording) {
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let m = NSMenu(); m.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = m
        NSApp.mainMenu = menu

        let stop = rec.stopKey ?? .defaultPlay
        HotKeys.handler = { [weak self] key in if key == .play { self?.player.cancel() } }
        hotkeys.register([(.play, stop)])

        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Macro"
        let label = NSTextField(labelWithString: "")
        label.alignment = .center
        label.font = .systemFont(ofSize: 12)
        label.textColor = .black
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 40),
                            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = name
        panel.appearance = NSAppearance(named: .aqua)
        panel.backgroundColor = .white
        panel.level = .floating
        let box = NSStackView(views: [label]); box.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        panel.contentView = box
        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: v.maxX - 320, y: v.maxY - 10))
        }
        panel.orderFrontRegardless()
        window = nil

        let loops = rec.loops ?? 1
        let total = loops == 0 ? "∞" : "\(loops)"
        func start() {
            beginActivity()
            label.stringValue = "▶ Playing…  \(stop.display) to stop"
            player.play(rec.events, speed: rec.speed ?? 1, loops: loops, loopDelay: rec.loopDelay ?? 0,
                        onWait: { i in label.stringValue = "⏸ Waiting before run \(i)/\(total)…  \(stop.display) to stop" },
                        onLoop: { i in
                            if loops != 1 { label.stringValue = "▶ Playing \(i)/\(total)…  \(stop.display) to stop" }
                        },
                        done: { NSApp.terminate(nil) })
        }

        if Permissions.accessibility(prompt: true) {
            label.stringValue = "Starting…"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { start() }
        } else {
            label.stringValue = "Allow Accessibility access to start…"
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
                if Permissions.accessibility(prompt: false) { t.invalidate(); start() }
            }
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
