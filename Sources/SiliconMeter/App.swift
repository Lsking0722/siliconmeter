//
//  App.swift
//  Entry point and menu bar shell: a status item with the engraved chip icon, a popover
//  with the live die, and the same view in a floating window ("Open in Window" in the
//  right-click menu, or a click on the desktop widget). Sampling runs only while the
//  popover or the window is showing, so the app costs nothing while it sits in the menu bar.
//
import AppKit
import Combine
import QuartzCore
import SwiftUI
import WidgetKit

@main
struct SiliconMeterMain {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--dump") {
            Dump.run()
            return
        }
        if let i = args.firstIndex(of: "--ane-load") {
            NeuralEngineLoad.run(seconds: i + 1 < args.count ? Double(args[i + 1]) ?? 20 : 20,
                                 light: args.contains("light"))
            return
        }
        if let i = args.firstIndex(of: "--simulate") {
            Simulate.run(outDir: i + 1 < args.count ? args[i + 1] : "sim")
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        if let i = args.firstIndex(of: "--debug") {
            let next = i + 1 < args.count ? args[i + 1] : ""
            delegate.debug = DebugState(selected: SimSpec.all.contains { $0.id == next } ? next : DebugState.real)
        }
        app.delegate = delegate
        // Menu bar only, no Dock icon. Debug runs as a regular app so it can be found and
        // inspected (screen capture tools, accessibility) like any other window.
        app.setActivationPolicy(delegate.debug == nil ? .accessory : .regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var monitor: Monitor!
    private var subscriptions = Set<AnyCancellable>()
    private var drawing = ChipDrawing()
    private var resizeTimer: Timer?
    private var realChip: ChipInfo!

    /// The floating window: the popover's view, kept on screen.
    private var window: NSWindow?
    private var pinButton: NSButton?
    private var windowOnTop: Bool {
        get { UserDefaults.standard.bool(forKey: "windowOnTop") }
        set { UserDefaults.standard.set(newValue, forKey: "windowOnTop") }
    }

    /// Set by `--debug`: simulate any chip from a floating panel.
    var debug: DebugState?
    private var debugPanel: NSPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        realChip = ChipInfo.detect()
        // The widget draws once and never asks again (its picture only changes when the app
        // does), so a new build asks it to redraw; otherwise the desktop keeps the old image.
        if #available(macOS 14.0, *) { WidgetCenter.shared.reloadAllTimelines() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self

        if let debug {
            setUpDebug(debug)
        } else {
            install(chip: realChip)
            // The window comes back if it was open when the app last quit.
            if UserDefaults.standard.bool(forKey: "windowOpen") { showWindow() }
        }
    }

    /// `siliconmeter://window` (the desktop widget's tap target) opens the floating window.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where: { $0.scheme == "siliconmeter" }) else { return }
        if popover.isShown { popover.performClose(nil) }
        showWindow()
    }

    /// Points the status item and popover at a chip. A `feed` replaces this Mac's counters
    /// (debug simulation of another chip).
    private func install(chip: ChipInfo, feed: (() -> Snapshot)? = nil) {
        monitor?.stop()
        resizeTimer?.invalidate()
        subscriptions.removeAll()

        let drawing = ChipLayout.build(for: chip)
        self.drawing = drawing
        monitor = Monitor(chip: chip, feed: feed)

        statusItem.button?.image = MenuBarIcon.make(for: chip)
        statusItem.button?.toolTip = chip.brand

        let size = PopoverMetrics.make(for: drawing, tiers: chip.tiers.count, dieScale: monitor.prefs.displayScale,
                                       simple: monitor.prefs.displaySimple).content
        let hosting = NSHostingController(
            rootView: PopoverView(monitor: monitor, prefs: monitor.prefs, drawing: drawing))
        hosting.sizingOptions = []        // the popover size is driven below, never by SwiftUI
        hosting.view.frame = NSRect(origin: .zero, size: size)
        popover.contentViewController = hosting
        popover.contentSize = size        // after the swap: a new content controller resets it
        if window != nil {
            setWindowContent()
            if window?.isVisible == true { monitor.start() }
        }
        // The size / Simple picker resizes the popover smoothly to fit.
        Publishers.CombineLatest(monitor.prefs.$dieScale, monitor.prefs.$simple)
            .dropFirst()
            .sink { [weak self] scale, simple in self?.animateLayout(scale: scale, simple: simple ? 1 : 0) }
            .store(in: &subscriptions)
    }

    // MARK: - Debug

    private func setUpDebug(_ debug: DebugState) {
        popover.behavior = .applicationDefined     // stays open while the panel is used
        debug.onSelect = { [weak self] id in self?.debugInstall(id) }
        debug.onReopen = { [weak self] in self?.reopenPopover() }
        debug.onWidgets = { [weak self] in self?.showWidgetPreview() }
        debug.$load
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.monitor.refresh() }
            .store(in: &debugLoadSubscription)

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 660),
                            styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "SiliconMeter Debug"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.contentViewController = NSHostingController(rootView: DebugPanel(state: debug))
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: screen.minX + 20, y: screen.maxY - 20))
        }
        panel.orderFrontRegardless()
        debugPanel = panel
        showWidgetPreview()

        // Give the status item a moment to get its place in the menu bar before the popover
        // anchors to it (at launch its frame is still empty).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.debugInstall(debug.selected)
        }
    }
    private var debugLoadSubscription = Set<AnyCancellable>()
    private var widgetPanel: NSPanel?

    /// Debug: the selected chip's widgets, beside the chip list (the "Widgets" button brings
    /// it back after it was closed).
    private func showWidgetPreview() {
        guard let debug else { return }
        if widgetPanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                                styleMask: [.titled, .closable, .utilityWindow],
                                backing: .buffered, defer: false)
            panel.title = "Widget Preview"
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            let hosting = NSHostingController(rootView: DebugWidgetPreview(state: debug))
            hosting.sizingOptions = [.preferredContentSize]    // follows the chip's widget sizes
            panel.contentViewController = hosting
            if let list = debugPanel?.frame {
                panel.setFrameTopLeftPoint(NSPoint(x: list.maxX + 12, y: list.maxY))
            }
            widgetPanel = panel
        }
        widgetPanel?.orderFrontRegardless()
    }

    private func debugInstall(_ id: String) {
        if let spec = SimSpec.all.first(where: { $0.id == id }) {
            let chip = spec.chipInfo()
            let state = debug
            install(chip: chip) {
                SyntheticLoad.snapshot(for: chip, load: state?.load ?? .busy, time: CACurrentMediaTime())
            }
        } else {
            install(chip: realChip)
        }
        reopenPopover()
    }

    /// Re-anchors the popover after the status item changed width.
    private func reopenPopover() {
        popover.animates = false
        if popover.isShown { popover.close() }
        DispatchQueue.main.async { [weak self] in
            guard let self, let button = self.statusItem.button else { return }
            let prefs = self.monitor.prefs
            self.popover.contentSize = PopoverMetrics.make(for: self.drawing, tiers: self.monitor.chip.tiers.count,
                                                           dieScale: prefs.displayScale, simple: prefs.displaySimple).content
            self.monitor.start()
            self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            self.popover.animates = true
        }
    }

    /// Tweens the displayed layout (die scale and the normal ↔ simple blend) over 0.32 s,
    /// ease in-out, and resizes the popover on the same tick, so die, text and window change
    /// together instead of snapping. The popover's own size animation is off meanwhile, so
    /// two animations never fight.
    private func animateLayout(scale target: Double, simple targetSimple: Double) {
        resizeTimer?.invalidate()
        let prefs = monitor.prefs
        let from = prefs.displayScale, fromSimple = prefs.displaySimple
        guard abs(from - target) > 0.0005 || abs(fromSimple - targetSimple) > 0.0005 else { return }
        let start = CACurrentMediaTime()
        let duration = 0.32
        popover.animates = false
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] timer in
            // Scheduled on the main run loop, so this always runs on the main thread.
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let p = min(1, (CACurrentMediaTime() - start) / duration)
                let eased = p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2
                let value = from + (target - from) * eased
                let simple = fromSimple + (targetSimple - fromSimple) * eased
                self.monitor.prefs.displayScale = value
                self.monitor.prefs.displaySimple = simple
                let content = PopoverMetrics.make(for: self.drawing, tiers: self.monitor.chip.tiers.count,
                                                  dieScale: value, simple: simple).content
                self.popover.contentSize = content
                self.resizeWindow(to: PopoverMetrics.make(for: self.drawing, tiers: self.monitor.chip.tiers.count,
                                                          dieScale: value, simple: simple, window: true).content)
                if p >= 1 {
                    timer.invalidate()
                    self.popover.animates = true
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        resizeTimer = timer
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu(from: sender)
            return
        }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            monitor.start()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        let title = NSMenuItem(title: monitor.chip.brand, action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        let open = window?.isVisible == true
        let windowItem = NSMenuItem(title: open ? "Close Window" : "Open in Window",
                                    action: #selector(toggleWindow), keyEquivalent: "")
        windowItem.target = self
        menu.addItem(windowItem)
        let topItem = NSMenuItem(title: "Keep Window on Top", action: #selector(toggleOnTop), keyEquivalent: "")
        topItem.target = self
        topItem.state = windowOnTop ? .on : .off
        menu.addItem(topItem)
        menu.addItem(.separator())
        for rate in Preferences.frameRates {
            let item = NSMenuItem(title: "\(rate) fps", action: #selector(chooseFrameRate(_:)), keyEquivalent: "")
            item.target = self
            item.tag = rate
            item.state = monitor.prefs.fps == rate ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit SiliconMeter", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func chooseFrameRate(_ sender: NSMenuItem) {
        monitor.prefs.fps = sender.tag
    }

    func popoverDidClose(_ notification: Notification) {
        // (debug reopen may already have shown it again; the window may still need samples)
        if !popover.isShown && window?.isVisible != true { monitor.stop() }
    }

    // MARK: - Floating window

    @objc private func toggleWindow() {
        if window?.isVisible == true { window?.performClose(nil) } else { showWindow() }
    }

    @objc private func toggleOnTop() {
        windowOnTop.toggle()
        applyOnTop()
    }

    private func applyOnTop() {
        window?.level = windowOnTop ? .floating : .normal
        pinButton?.image = NSImage(systemSymbolName: windowOnTop ? "pin.fill" : "pin",
                                   accessibilityDescription: windowOnTop ? "Keep on top: on" : "Keep on top: off")
        pinButton?.contentTintColor = windowOnTop ? ChipCatalog.palette(monitor.chip).accent.nsColor
                                                  : NSColor(white: 1, alpha: 0.55)
        pinButton?.toolTip = windowOnTop ? "Keeping this window on top (click to stop)" : "Keep this window on top"
    }

    /// The window's frame for a content size (the content fills the window, title bar
    /// included). The top-left corner stays where it is.
    private func windowFrame(for content: CGSize, topLeft: NSPoint) -> NSRect {
        NSRect(x: topLeft.x, y: topLeft.y - content.height, width: content.width, height: content.height)
    }

    /// The window's content size for the current layout.
    private var windowContent: CGSize {
        let prefs = monitor.prefs
        return PopoverMetrics.make(for: drawing, tiers: monitor.chip.tiers.count, dieScale: prefs.displayScale,
                                   simple: prefs.displaySimple, window: true).content
    }

    private func resizeWindow(to content: CGSize) {
        guard let w = window else { return }
        w.setFrame(windowFrame(for: content, topLeft: NSPoint(x: w.frame.minX, y: w.frame.maxY)), display: true)
    }

    private func showWindow() {
        if window == nil { makeWindow() }
        guard let w = window else { return }
        monitor.start()
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        w.makeKeyAndOrderFront(nil)
        UserDefaults.standard.set(true, forKey: "windowOpen")
    }

    private func makeWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
                         styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "SiliconMeter"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.standardWindowButton(.zoomButton)?.isHidden = true
        w.collectionBehavior = [.fullScreenNone, .moveToActiveSpace]
        w.delegate = self

        // Pin: keep the window above other apps' windows.
        let pin = NSButton(frame: NSRect(x: 0, y: 0, width: 30, height: 22))
        pin.isBordered = false
        pin.bezelStyle = .regularSquare
        pin.imagePosition = .imageOnly
        pin.target = self
        pin.action = #selector(toggleOnTop)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .trailing
        accessory.view = pin
        w.addTitlebarAccessoryViewController(accessory)
        pinButton = pin

        window = w
        setWindowContent()
        applyOnTop()

        // Back where it was last time, or under the menu bar icon.
        let content = windowContent
        if let saved = UserDefaults.standard.string(forKey: "windowTopLeft") {
            let p = NSPointFromString(saved)
            w.setFrame(windowFrame(for: content, topLeft: p), display: false)
        } else if let button = statusItem.button, let screen = button.window?.screen ?? NSScreen.main {
            let anchor = button.window?.convertToScreen(button.frame) ?? .zero
            let x = min(max(screen.visibleFrame.minX + 8, anchor.midX - content.width / 2),
                        screen.visibleFrame.maxX - content.width - 8)
            w.setFrame(windowFrame(for: content, topLeft: NSPoint(x: x, y: screen.visibleFrame.maxY - 8)),
                       display: false)
        }
    }

    /// Puts the current monitor's view in the window (again after a debug chip switch).
    private func setWindowContent() {
        guard let w = window else { return }
        let hosting = NSHostingView(
            rootView: PopoverView(monitor: monitor, prefs: monitor.prefs, drawing: drawing, inWindow: true))
        hosting.sizingOptions = []          // the window size is driven by AppDelegate
        if #available(macOS 26.0, *), Theme.onGlass {
            // Liquid Glass like the popover; the window's rounded corners clip it.
            w.isOpaque = false
            w.backgroundColor = .clear
            let glass = NSGlassEffectView()
            glass.contentView = hosting
            w.contentView = glass
        } else {
            w.isOpaque = true
            w.backgroundColor = .black
            w.contentView = hosting
        }
        resizeWindow(to: windowContent)
    }

    func windowDidMove(_ notification: Notification) {
        guard let w = window else { return }
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: w.frame.minX, y: w.frame.maxY)),
                                  forKey: "windowTopLeft")
    }

    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(false, forKey: "windowOpen")
        if !popover.isShown { monitor.stop() }
    }
}
