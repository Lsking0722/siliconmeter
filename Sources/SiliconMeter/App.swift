//
//  App.swift
//  Entry point and menu bar shell: a status item with the engraved chip icon, and a
//  popover with the live die. Sampling runs only while the popover is open, so the
//  app costs nothing while it sits in the menu bar.
//
import AppKit
import Combine
import QuartzCore
import SwiftUI

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
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var monitor: Monitor!
    private var subscriptions = Set<AnyCancellable>()
    private var drawing = ChipDrawing()
    private var resizeTimer: Timer?
    private var realChip: ChipInfo!

    /// Set by `--debug`: simulate any chip from a floating panel.
    var debug: DebugState?
    private var debugPanel: NSPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        realChip = ChipInfo.detect()

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
        }
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

        debugInstall(debug.selected)
    }
    private var debugLoadSubscription = Set<AnyCancellable>()

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
                self.popover.contentSize = PopoverMetrics.make(for: self.drawing, tiers: self.monitor.chip.tiers.count,
                                                               dieScale: value, simple: simple).content
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
        if !popover.isShown { monitor.stop() }   // (debug reopen may already have shown it again)
    }
}
