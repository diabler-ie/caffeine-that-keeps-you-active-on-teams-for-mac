import Cocoa
import IOKit.pwr_mgt
import CoreGraphics

let appName = "Caffeine That Keeps You Active On Teams For Mac"

// MARK: - Logging

let logURL = URL(fileURLWithPath: ("~/Library/Logs/caffeine-that-keeps-you-active-on-teams-for-mac.log" as NSString).expandingTildeInPath)

let logHandle: FileHandle = {
    let fm = FileManager.default
    if !fm.fileExists(atPath: logURL.path) {
        fm.createFile(atPath: logURL.path, contents: nil, attributes: nil)
    }
    let h = try! FileHandle(forWritingTo: logURL)
    h.seekToEndOfFile()
    return h
}()

let logFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

func log(_ s: String) {
    let line = "\(logFmt.string(from: Date())) \(s)\n"
    if let d = line.data(using: .utf8) { logHandle.write(d) }
}

// MARK: - Mouse jiggle

func currentMousePos() -> CGPoint {
    guard let e = CGEvent(source: nil) else { return .zero }
    return e.location
}

func moveMouse(to p: CGPoint) {
    if let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                       mouseCursorPosition: p, mouseButton: .left) {
        e.post(tap: .cghidEventTap)
    }
}

func jiggleOnce() {
    let delta: CGFloat = 1
    let holdMs: UInt32 = 150
    let start = currentMousePos()
    moveMouse(to: CGPoint(x: start.x + delta, y: start.y))
    usleep(holdMs * 1000)
    let mid = currentMousePos()
    moveMouse(to: CGPoint(x: mid.x - delta, y: mid.y))
    usleep(holdMs * 1000)
    let end = currentMousePos()
    let moved = (mid.x != start.x) || (end.x != mid.x)
    log("jiggle start=(\(Int(start.x)),\(Int(start.y))) mid=(\(Int(mid.x)),\(Int(mid.y))) end=(\(Int(end.x)),\(Int(end.y))) moved=\(moved)")
}

// MARK: - Sleep assertion

final class SleepAssertion {
    private var id: IOPMAssertionID = IOPMAssertionID(0)
    private(set) var held = false

    func acquire() {
        guard !held else { return }
        let reason = "\(appName) is keeping the display awake" as CFString
        var newId: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &newId
        )
        if result == kIOReturnSuccess {
            id = newId
            held = true
            log("assertion acquired id=\(id)")
        } else {
            log("assertion failed result=\(result)")
        }
    }

    func release() {
        guard held else { return }
        IOPMAssertionRelease(id)
        log("assertion released id=\(id)")
        id = 0
        held = false
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let cycleSeconds: TimeInterval = 30
    let prefActivateAtLaunch = "ActivateAtLaunch"

    var statusItem: NSStatusItem!
    var menu: NSMenu!
    var activeMenuItem: NSMenuItem!
    var activateAtLaunchItem: NSMenuItem!

    let assertion = SleepAssertion()
    var jiggleTimer: DispatchSourceTimer?
    var expirationTimer: DispatchSourceTimer?
    var menuCountdownTimer: Timer?

    var active = false
    var expiresAt: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("=== \(appName) started PID=\(getpid()) ===")
        UserDefaults.standard.register(defaults: [prefActivateAtLaunch: true])

        buildStatusItem()
        buildMenu()
        updateUI()

        if UserDefaults.standard.bool(forKey: prefActivateAtLaunch) {
            activate(duration: nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        assertion.release()
        log("=== \(appName) terminating ===")
    }

    // MARK: status item

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            DispatchQueue.main.async { self.statusItem.menu = nil }
        } else {
            toggle()
        }
    }

    // MARK: menu

    func buildMenu() {
        menu = NSMenu()

        activeMenuItem = NSMenuItem(title: "Active", action: #selector(menuToggle), keyEquivalent: "")
        activeMenuItem.target = self
        menu.addItem(activeMenuItem)
        menu.addItem(.separator())

        let durations: [(String, TimeInterval)] = [
            ("Activate for 5 minutes", 5 * 60),
            ("Activate for 15 minutes", 15 * 60),
            ("Activate for 30 minutes", 30 * 60),
            ("Activate for 1 hour", 60 * 60),
            ("Activate for 2 hours", 2 * 60 * 60),
            ("Activate for 5 hours", 5 * 60 * 60),
        ]
        for (title, seconds) in durations {
            let item = NSMenuItem(title: title, action: #selector(menuActivateTimed(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = seconds
            menu.addItem(item)
        }
        let indef = NSMenuItem(title: "Activate indefinitely", action: #selector(menuActivateIndefinite), keyEquivalent: "")
        indef.target = self
        menu.addItem(indef)

        menu.addItem(.separator())

        activateAtLaunchItem = NSMenuItem(title: "Activate at launch", action: #selector(menuToggleActivateAtLaunch(_:)), keyEquivalent: "")
        activateAtLaunchItem.target = self
        activateAtLaunchItem.state = UserDefaults.standard.bool(forKey: prefActivateAtLaunch) ? .on : .off
        menu.addItem(activateAtLaunchItem)

        let about = NSMenuItem(title: "About \(appName)", action: #selector(menuAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "Quit \(appName)", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc func menuToggle() { toggle() }
    @objc func menuActivateIndefinite() { activate(duration: nil) }
    @objc func menuActivateTimed(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? TimeInterval else { return }
        activate(duration: seconds)
    }
    @objc func menuToggleActivateAtLaunch(_ sender: NSMenuItem) {
        let new = !UserDefaults.standard.bool(forKey: prefActivateAtLaunch)
        UserDefaults.standard.set(new, forKey: prefActivateAtLaunch)
        sender.state = new ? .on : .off
    }
    @objc func menuAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = appName
        alert.informativeText = "Holds a power assertion AND moves the cursor 1px every 30s so Microsoft Teams (and Slack, while we're at it) don't flip you to Away.\n\nNamed for its problem because Caffeine.app alone doesn't actually keep Teams active — Teams checks HID input, not power assertions.\n\nLog: ~/Library/Logs/caffeine-that-keeps-you-active-on-teams-for-mac.log"
        alert.runModal()
    }
    @objc func menuQuit() { NSApp.terminate(nil) }

    // MARK: state

    func toggle() {
        if active { deactivate() } else { activate(duration: nil) }
    }

    func activate(duration: TimeInterval?) {
        let wasActive = active
        active = true
        assertion.acquire()
        if !wasActive { startJiggleTimer() }
        if let d = duration {
            expiresAt = Date().addingTimeInterval(d)
            scheduleExpiration(after: d)
            startMenuCountdown()
            log("activated for \(Int(d))s")
        } else {
            expiresAt = nil
            cancelExpiration()
            stopMenuCountdown()
            log("activated indefinitely")
        }
        updateUI()
    }

    func deactivate() {
        active = false
        expiresAt = nil
        stopJiggleTimer()
        cancelExpiration()
        stopMenuCountdown()
        assertion.release()
        log("deactivated")
        updateUI()
    }

    // MARK: timers

    func startJiggleTimer() {
        stopJiggleTimer()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + cycleSeconds, repeating: cycleSeconds)
        t.setEventHandler {
            DispatchQueue.global(qos: .background).async { jiggleOnce() }
        }
        t.resume()
        jiggleTimer = t
    }

    func stopJiggleTimer() {
        jiggleTimer?.cancel()
        jiggleTimer = nil
    }

    func scheduleExpiration(after seconds: TimeInterval) {
        cancelExpiration()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + seconds)
        t.setEventHandler { [weak self] in
            log("timer expired")
            self?.deactivate()
        }
        t.resume()
        expirationTimer = t
    }

    func cancelExpiration() {
        expirationTimer?.cancel()
        expirationTimer = nil
    }

    func startMenuCountdown() {
        stopMenuCountdown()
        menuCountdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateUI()
        }
    }

    func stopMenuCountdown() {
        menuCountdownTimer?.invalidate()
        menuCountdownTimer = nil
    }

    // MARK: UI updates

    func updateUI() {
        updateIcon()
        updateActiveItem()
    }

    func updateIcon() {
        guard let button = statusItem.button else { return }
        let name = active ? "cup.and.saucer.fill" : "cup.and.saucer"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: active ? "\(appName) on" : "\(appName) off")
        img?.isTemplate = true
        button.image = img
        button.toolTip = tooltipText()
    }

    func updateActiveItem() {
        if active {
            if let expires = expiresAt {
                let remaining = max(0, Int(expires.timeIntervalSinceNow))
                let mm = remaining / 60
                let ss = remaining % 60
                activeMenuItem.title = String(format: "Active (%d:%02d remaining)", mm, ss)
            } else {
                activeMenuItem.title = "Active"
            }
            activeMenuItem.state = .on
        } else {
            activeMenuItem.title = "Active"
            activeMenuItem.state = .off
        }
    }

    func tooltipText() -> String {
        if !active { return "\(appName): off" }
        if let expires = expiresAt {
            let remaining = max(0, Int(expires.timeIntervalSinceNow))
            let mm = remaining / 60
            let ss = remaining % 60
            return String(format: "\(appName): on (%d:%02d remaining)", mm, ss)
        }
        return "\(appName): on (indefinite)"
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
