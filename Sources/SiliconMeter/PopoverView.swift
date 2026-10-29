//
//  PopoverView.swift
//  The popover: a spec column in the keynote style on the left, the live die on the right.
//
//  The die can be shown at 100 %, 75 % or 50 %, or in Simple mode (chosen at the bottom-left
//  of the popover, remembered across launches). The die is redrawn at the smaller size, not
//  scaled as an image, so it stays sharp. When it becomes shorter than the text column, the
//  text, margins and spacing shrink with it (down to 75 %). Simple mode keeps the 50 %
//  footprint, lets the die fill it, and shows only numbers beside it.
//
import AppKit
import SwiftUI
import ServiceManagement

/// User choices that outlive the popover.
final class Preferences: ObservableObject {
    static let dieScales: [Double] = [1, 0.75, 0.5]

    /// The chosen size (the picker shows this one).
    @Published var dieScale: Double {
        didSet { if persist { UserDefaults.standard.set(dieScale, forKey: "dieScale") } }
    }
    /// Die animation frame rate: 30 (default) or 60.
    static let frameRates = [30, 60]
    @Published var fps: Int {
        didSet { if persist { UserDefaults.standard.set(fps, forKey: "fps") } }
    }
    /// Simple mode: the 50 % footprint filled by the die, numbers only beside it.
    @Published var simple: Bool {
        didSet { if persist { UserDefaults.standard.set(simple, forKey: "simple") } }
    }
    /// What is being drawn: these follow the choices above through a short tween.
    @Published var displayScale: Double
    @Published var displaySimple: Double      // 0 = normal layout, 1 = simple layout

    private let persist: Bool

    /// `persist: false` gives throwaway preferences (offscreen snapshots) that never touch
    /// the saved choice.
    init(persist: Bool = true) {
        self.persist = persist
        let defaults = UserDefaults.standard
        let saved = persist ? defaults.double(forKey: "dieScale") : 1
        let scale = Self.dieScales.contains(saved) ? saved : 1
        let simple = persist && defaults.bool(forKey: "simple")
        dieScale = scale
        displayScale = scale
        let savedFPS = persist ? defaults.integer(forKey: "fps") : 0
        fps = Self.frameRates.contains(savedFPS) ? savedFPS : 30
        self.simple = simple
        displaySimple = simple ? 1 : 0
    }

    func choose(scale: Double) { simple = false; dieScale = scale }
    func chooseSimple() { simple = true }
}

/// Every size in the popover for one layout.
struct PopoverMetrics {
    let canvas: CGSize
    let text: CGFloat          // multiplier for fonts, margins and spacing
    let margin: CGFloat
    let spacing: CGFloat
    let panelWidth: CGFloat
    let content: CGSize

    /// Text size for a die size: the same for every chip (100 % → 1, 75 % → 0.88,
    /// 50 % → 0.8, linear in between for the resize animation).
    /// Text scale below which the memory legend wraps to two rows.
    static let legendOneRow: CGFloat = 0.95

    static func textScale(_ dieScale: Double) -> CGFloat {
        let d = CGFloat(min(1, max(0.5, dieScale)))
        return d >= 0.75 ? 0.88 + (d - 0.75) * 0.48 : 0.8 + (d - 0.5) * 0.32
    }

    /// Height the spec column needs at full size, measured from the rendered panel: 251 pt of
    /// title, GPU, Neural Engine and memory sections, 66 pt per CPU tier, and in the live
    /// popover the GPU clock and Neural Engine power lines (18 each) plus the die size
    /// picker and login row (56).
    static func textColumnHeight(tiers: Int, controls: Bool) -> CGFloat {
        251 + 66 * CGFloat(max(1, tiers)) + (controls ? 18 + 18 + 56 : 0) + 4
    }

    static func make(for drawing: ChipDrawing, tiers: Int, dieScale: Double, controls: Bool = true) -> PopoverMetrics {
        let base = PopoverView.canvasSize(for: drawing)
        let canvas = CGSize(width: base.width * dieScale, height: base.height * dieScale)
        let text = textScale(dieScale)
        let legendRow: CGFloat = text < legendOneRow ? 15 : 0      // second legend row
        let column = textColumnHeight(tiers: tiers, controls: controls) + legendRow / text
        let margin = PopoverView.margin * text
        let spacing = PopoverView.spacing * text
        let panel = PopoverView.panelWidth * text
        let content = CGSize(width: margin * 2 + panel + spacing + canvas.width,
                             height: margin * 2 + max(canvas.height, column * text))
        return PopoverMetrics(canvas: canvas, text: text, margin: margin, spacing: spacing,
                              panelWidth: panel, content: content)
    }

    // Simple mode.
    static let simpleMargin: CGFloat = 14
    static let simpleSpacing: CGFloat = 14
    static let simplePanelWidth: CGFloat = 104

    static func simpleColumnHeight(tiers: Int) -> CGFloat {
        24 + 17 * CGFloat(max(1, tiers)) + 8 + 24 * 3 + 17 + 12 + 20
    }

    /// Exactly the 50 % popover's footprint; the die canvas takes everything the narrow
    /// numbers column leaves free (the renderer fits the die into it, keeping proportions).
    static func simple(for drawing: ChipDrawing, tiers: Int) -> PopoverMetrics {
        let half = make(for: drawing, tiers: tiers, dieScale: 0.5)
        // The 50 % popover's width; the height is only what the die (filling that width) or
        // the numbers column needs, never the taller 50 % text column, so a wide die such as
        // M6 leaves no bands above and below.
        let width = half.content.width - simpleMargin * 2 - simplePanelWidth - simpleSpacing
        let aspect = drawing.size.width / max(drawing.size.height, 0.01)
        let dieHeight = min((width - 8) / aspect + 8, half.content.height - simpleMargin * 2)
        let height = simpleMargin * 2 + max(dieHeight, simpleColumnHeight(tiers: tiers))
        let canvas = CGSize(width: width, height: height - simpleMargin * 2)
        return PopoverMetrics(canvas: canvas, text: 1, margin: simpleMargin, spacing: simpleSpacing,
                              panelWidth: simplePanelWidth,
                              content: CGSize(width: half.content.width, height: height))
    }

    /// The layout `simple` of the way (0…1) from the normal layout to the simple one.
    static func make(for drawing: ChipDrawing, tiers: Int, dieScale: Double, simple: Double) -> PopoverMetrics {
        let a = make(for: drawing, tiers: tiers, dieScale: dieScale)
        guard simple > 0 else { return a }
        let b = self.simple(for: drawing, tiers: tiers)
        guard simple < 1 else { return b }
        func l(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * CGFloat(simple) }
        return PopoverMetrics(canvas: CGSize(width: l(a.canvas.width, b.canvas.width), height: l(a.canvas.height, b.canvas.height)),
                              text: l(a.text, b.text), margin: l(a.margin, b.margin), spacing: l(a.spacing, b.spacing),
                              panelWidth: l(a.panelWidth, b.panelWidth),
                              content: CGSize(width: l(a.content.width, b.content.width),
                                              height: l(a.content.height, b.content.height)))
    }
}

struct PopoverView: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var prefs: Preferences
    let drawing: ChipDrawing

    // No @State here: on macOS 27 SDKs @State is a macro whose plugin ships only with
    // Xcode, so a Command Line Tools build fails. Long-lived state lives in Monitor instead.
    private var anim: AnimState { monitor.anim }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let panelWidth: CGFloat = 236
    static let spacing: CGFloat = 28
    static let margin: CGFloat = 26

    /// Corner radius of the system popover on macOS 26 and later, the container shape inner
    /// elements are concentric with. Measured on screen on macOS 27 (≈ 12 pt); the system does
    /// not publish it.
    static let popoverCornerRadius: CGFloat = 12

    /// Die canvas at 100 %.
    /// Every chip gets about the same die area (≈ 215 000 pt²), so a base chip, a Pro and an
    /// Ultra look equally weighty and their popovers differ little in size; very tall or very
    /// wide drawings are held between 400 and 540 pt high and at most 600 pt wide.
    static func canvasSize(for drawing: ChipDrawing) -> CGSize {
        let aspect = drawing.size.width / max(drawing.size.height, 0.01)
        var height = min(540, max(400, (215_000 / aspect).squareRoot()))
        var width = height * aspect
        if width > 600 { width = 600; height = width / aspect }
        return CGSize(width: width, height: height)
    }

    /// Offscreen snapshot size (no controls, 100 %).
    static func contentSize(for drawing: ChipDrawing, tiers: Int) -> CGSize {
        PopoverMetrics.make(for: drawing, tiers: tiers, dieScale: 1, controls: false).content
    }

    var body: some View {
        let m = PopoverMetrics.make(for: drawing, tiers: monitor.chip.tiers.count,
                                    dieScale: prefs.displayScale, simple: prefs.displaySimple)
        HStack(alignment: .center, spacing: m.spacing) {
            Group {
                if prefs.simple {
                    SimplePanel(chip: monitor.chip, snapshot: monitor.snapshot, prefs: prefs)
                } else {
                    SpecPanel(chip: monitor.chip, snapshot: monitor.snapshot, login: monitor.login,
                              prefs: prefs, z: m.text)
                }
            }
            // Leading-aligned: anything that ever runs wider is cut on the right, never shifted
            // left (which once cut the first letters off every line at 50 %).
            .frame(width: m.panelWidth, alignment: .leading)
            .frame(maxHeight: .infinity)
            .clipped()

            // 30 or 60 fps (chosen in the popover), driven by Monitor.clock: a plain timer,
            // stopped while the popover is closed (NSPopover keeps its view alive).
            DieCanvas(clock: monitor.clock, monitor: monitor, drawing: drawing, reduceMotion: reduceMotion,
                      size: m.canvas)
                .overlay(alignment: .topTrailing) {
                    // Debug runs of another chip show made-up loads; say so on the die.
                    if monitor.simulated {
                        Text("SIMULATED LOAD")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.8)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.85)))
                            .foregroundColor(.black)
                    }
                }
            .frame(width: m.canvas.width, height: m.canvas.height)
        }
        .padding(m.margin)
        .frame(width: m.content.width, height: m.content.height)
        .modifier(PopoverBackground())
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Liquid Glass background (macOS 26+)

/// macOS 26 and later: no background of our own, so the system popover's Liquid Glass shows
/// (HIG: remove custom backgrounds from popovers), and the content declares the popover's
/// shape so inner elements can be concentric with it. Earlier systems keep the solid black
/// popover.
struct PopoverBackground: ViewModifier {
    func body(content: Content) -> some View {
        // `-SMNoGlass YES` keeps the solid background on macOS 26+ too (for A/B measurements).
        if #available(macOS 26.0, *), Theme.onGlass {
            content.containerShape(.rect(cornerRadius: PopoverView.popoverCornerRadius))
        } else {
            content.background(Color.black)
        }
    }
}

// MARK: - Die canvas

/// The animated die. Only this view observes the frame clock, so a frame redraws the canvas
/// and nothing else in the popover.
struct DieCanvas: View {
    @ObservedObject var clock: FrameClock
    let monitor: Monitor
    let drawing: ChipDrawing
    let reduceMotion: Bool
    let size: CGSize
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let frame = clock.frame
        let renderer = DieRenderer(drawing: drawing, chip: monitor.chip)
        // Everything static comes from images rendered once for this size (nil while the
        // popover is resizing; the frame is then drawn in full).
        let layers = monitor.layers.layers(for: renderer, size: size, scale: displayScale, state: monitor.anim)
        Canvas { context, size in
            _ = frame
            let now = Date().timeIntervalSinceReferenceDate
            monitor.anim.step(toward: monitor.snapshot, time: now)
            renderer.render(context, size: size, state: monitor.anim, time: reduceMotion ? 0 : now, layers: layers)
        }
        .onAppear { monitor.reduceMotion = reduceMotion }
        .onChange(of: reduceMotion) { monitor.reduceMotion = $0 }
    }
}

// MARK: - Controls
//
// Every choice and action in the popover is the same pill, so each kind of control looks and
// behaves alike: the current choice is filled with the chip's accent, the rest are faint;
// hovering lifts a pill slightly; the whole pill (not just its text) is clickable; VoiceOver
// reads each as a button and says which one is selected.

/// One pill: used for die size, frame rate and Quit.
struct Pill: View {
    let label: String
    var selected = false
    let accent: Color
    var z: CGFloat = 1
    var compact = false
    var accessibilityName: String? = nil
    let action: () -> Void

    // Not @State: that is a macro the Command Line Tools cannot expand on macOS 27 SDKs.
    @StateObject private var hover = HoverFlag()
    private var hovering: Bool { hover.on }
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button(action: action) {
            Text(label)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, (compact ? 4.5 : 6) * z)
                .padding(.vertical, 2 * z)
                .background(Capsule().fill(fill))
                // Increase contrast: every pill gets an outline, so unselected ones don't
                // dissolve into the glass.
                .overlay(Capsule().strokeBorder(outline, lineWidth: contrast == .increased ? 1 : 0))
                .foregroundColor(selected ? accent : (hovering ? Theme.text : Theme.secondary))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
        .accessibilityLabel(accessibilityName ?? label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var fill: Color {
        let strong = contrast == .increased
        if selected { return accent.opacity(hovering ? 0.36 : (strong ? 0.32 : 0.22)) }
        return Color.white.opacity(hovering ? 0.14 : (strong ? 0.12 : 0.06))
    }

    private var outline: Color { selected ? accent : Color.white.opacity(0.45) }
}

final class HoverFlag: ObservableObject { @Published var on = false }

/// "100% 75% 50% Simple" (or "100 75 50 S" in simple mode), never wrapping.
struct LayoutPicker: View {
    @ObservedObject var prefs: Preferences
    let accent: Color
    var z: CGFloat = 1
    var compact = false

    var body: some View {
        HStack(spacing: (compact ? 3 : 4) * z) {
            ForEach(Preferences.dieScales, id: \.self) { value in
                let percent = Int((value * 100).rounded())
                Pill(label: compact ? "\(percent)" : "\(percent)%",
                     selected: !prefs.simple && abs(prefs.dieScale - value) < 0.001,
                     accent: accent, z: z, compact: compact,
                     accessibilityName: "Die size \(percent) percent") { prefs.choose(scale: value) }
            }
            Pill(label: compact ? "S" : "Simple", selected: prefs.simple, accent: accent, z: z,
                 compact: compact, accessibilityName: "Simple mode") { prefs.chooseSimple() }
        }
        .font(.system(size: max(9, (compact ? 9.5 : 11) * z), weight: .medium).monospacedDigit())
    }
}

/// "30 60 fps": the die animation frame rate.
struct FrameRatePicker: View {
    @ObservedObject var prefs: Preferences
    let accent: Color
    var z: CGFloat = 1
    var showLabel = true

    var body: some View {
        HStack(spacing: 3 * z) {
            ForEach(Preferences.frameRates, id: \.self) { rate in
                Pill(label: "\(rate)", selected: prefs.fps == rate, accent: accent, z: z,
                     accessibilityName: "\(rate) frames per second") { prefs.fps = rate }
            }
            if showLabel { Text("fps").foregroundColor(Theme.secondary).fixedSize() }
        }
        .font(.system(size: max(9, 11 * z), weight: .medium).monospacedDigit())
        .help("Animation frame rate (frames per second)")
    }
}

/// Quit, as a pill like the other controls (⌘Q also works while the popover is open).
struct QuitButton: View {
    let accent: Color
    var z: CGFloat = 1

    var body: some View {
        Pill(label: "Quit", accent: accent, z: z, accessibilityName: "Quit SiliconMeter") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
        .font(.system(size: max(9, 11 * z), weight: .medium))
    }
}

// MARK: - Simple column

/// Numbers only: CPU total and per tier (S / P / E), GPU, Neural Engine, memory used and
/// the chip's memory bandwidth.
struct SimplePanel: View {
    let chip: ChipInfo
    let snapshot: Snapshot
    @ObservedObject var prefs: Preferences

    private var accent: Color { ChipCatalog.palette(chip).accent.color }
    private var valueColor: Color { ChipCatalog.palette(chip).value.color }

    var body: some View {
        let gb = 1_073_741_824.0
        let cores = snapshot.cores
        let all = cores.isEmpty ? 0 : cores.reduce(0, +) / Double(cores.count)
        VStack(alignment: .leading, spacing: 0) {
            big("CPU", snapshot.valid ? num(all) : "–", "%")
            ForEach(chip.tiers, id: \.index) { tier in
                let loads = chip.cpus(ofTier: tier.index).map { $0 < cores.count ? cores[$0] : 0 }
                let avg = loads.isEmpty ? 0 : loads.reduce(0, +) / Double(loads.count)
                small(String(tier.name.prefix(1)).uppercased(), snapshot.valid ? num(avg) : "–", "%")
            }
            Spacer().frame(height: 8)
            big("GPU", snapshot.valid ? num(snapshot.gpu) : "–", "%")
            big("NE", snapshot.ane.map { num($0) } ?? "–", snapshot.ane == nil ? "" : "%")
            big("MEM", snapshot.memory.total > 0 ? String(format: "%.1f", snapshot.memory.used / gb) : "–",
                "/\(Int((Double(chip.memoryBytes) / gb).rounded()))")
            small("BW", ChipCatalog.formatBandwidth(ChipCatalog.bandwidth(chip).gbps), "GB/s")
            Spacer(minLength: 12)
            LayoutPicker(prefs: prefs, accent: accent, compact: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func num(_ x: Double) -> String { "\(Int((x * 100).rounded()))" }

    private func big(_ label: String, _ value: String, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundColor(Theme.secondary)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 17, weight: .light).monospacedDigit())
                .foregroundColor(valueColor)
            Text(unit)
                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                .foregroundColor(Theme.secondary)
                .padding(.leading, 1)
        }
        .frame(height: 24)
    }

    private func small(_ label: String, _ value: String, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(accent)
                .padding(.leading, 8)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 12.5, weight: .regular).monospacedDigit())
                .foregroundColor(valueColor)
            Text(unit)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(Theme.secondary)
                .padding(.leading, 1)
        }
        .frame(height: 17)
    }
}

// MARK: - Login item

/// "Open at login" backed by SMAppService. Reverts the checkbox if macOS refuses.
final class LoginItem: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue, !reverting else { return }
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                reverting = true
                enabled = SMAppService.mainApp.status == .enabled
                reverting = false
            }
        }
    }
    private var reverting = false

    init() {
        enabled = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Spec column

struct SpecPanel: View {
    let chip: ChipInfo
    let snapshot: Snapshot
    @ObservedObject var login: LoginItem
    /// nil for offscreen snapshots: ImageRenderer cannot draw AppKit-backed controls.
    var prefs: Preferences? = nil
    /// Text scale: fonts, spacing and padding are all multiplied by it.
    var z: CGFloat = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(chip.cpuCount)-core CPU")
                .font(.system(size: 21 * z, weight: .regular))
                .foregroundColor(Theme.text)
            Rectangle()
                .fill(Theme.text.opacity(0.5))
                .frame(height: 1)
                .padding(.top, 9 * z)
                .padding(.bottom, 12 * z)

            VStack(alignment: .leading, spacing: 12 * z) {
                ForEach(chip.tiers, id: \.index) { tier in
                    let loads = chip.cpus(ofTier: tier.index).map { cpu in
                        cpu < snapshot.cores.count ? snapshot.cores[cpu] : 0
                    }
                    VStack(alignment: .leading, spacing: 3 * z) {
                        heading("\(tier.cpuCount) \(tier.name.lowercased()) core\(tier.cpuCount == 1 ? "" : "s")")
                        if snapshot.valid {
                            line("Load", pct(average(loads)), "· \(loads.filter { $0 > 0.05 }.count) of \(tier.cpuCount) active")
                            line("Busiest core", pct(loads.max() ?? 0))
                        } else {
                            line("Measuring", "…")
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 3 * z) {
                    heading("\(chip.gpuCores)-core GPU")
                    line("Utilization", snapshot.valid ? pct(snapshot.gpu) : "…")
                    if let mhz = snapshot.gpuMHz { line("Clock", "\(Int(mhz.rounded())) MHz") }
                }

                VStack(alignment: .leading, spacing: 3 * z) {
                    heading("\(chip.npuCores)-core Neural Engine")
                    if let ane = snapshot.ane {
                        line("Activity", pct(ane), snapshot.aneEstimated ? "(est.)" : "")
                        if let watts = snapshot.anePower {
                            line("Power", String(format: watts < 0.1 ? "%.2f W" : "%.1f W", watts))
                        } else if let traffic = snapshot.aneTraffic {
                            line("Traffic", String(format: traffic < 10 ? "%.1f GB/s" : "%.0f GB/s", traffic))
                        }
                    } else {
                        line(snapshot.valid ? "Not reported on this Mac" : "Measuring", "")
                    }
                }

                memorySection
            }

            Spacer(minLength: 14 * z)

            if let prefs {
                VStack(alignment: .leading, spacing: 8 * z) {
                    LayoutPicker(prefs: prefs, accent: accent, z: z)
                    // The narrow 50 % column can't fit "fps" after the rate pills; then it goes
                    // (the pills keep their "frames per second" label for VoiceOver).
                    ViewThatFits(in: .horizontal) {
                        controlRow(prefs, fpsLabel: true)
                        controlRow(prefs, fpsLabel: false)
                    }
                }
            }
        }
    }

    private var accent: Color { ChipCatalog.palette(chip).accent.color }
    private var valueColor: Color { ChipCatalog.palette(chip).value.color }

    private func controlRow(_ prefs: Preferences, fpsLabel: Bool) -> some View {
        HStack(spacing: 6 * z) {
            Toggle("Open at login", isOn: $login.enabled)
                .toggleStyle(.checkbox)
                .font(.system(size: max(9, 11 * z)))
                .foregroundColor(Theme.secondary)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 4 * z)
            FrameRatePicker(prefs: prefs, accent: accent, z: z, showLabel: fpsLabel)
            Spacer(minLength: 4 * z)
            QuitButton(accent: accent, z: z)
        }
    }

    private var memorySection: some View {
        let m = snapshot.memory
        let gb = 1_073_741_824.0
        let totalGB = Int((Double(chip.memoryBytes) / gb).rounded())
        return VStack(alignment: .leading, spacing: 3 * z) {
            heading("\(totalGB)GB unified memory")
            if m.total > 0 {
                line("Used", String(format: "%.1f GB", m.used / gb), "of \(totalGB) GB")
                line("Wired", String(format: "%.1f", m.wired / gb), String(format: "· Compressed %.1f GB", m.compressed / gb))
                let bw = ChipCatalog.bandwidth(chip)
                line("Bandwidth", "\(ChipCatalog.formatBandwidth(bw.gbps)) GB/s", bw.known ? "" : "(est.)")
                HStack(spacing: 6 * z) {
                    Text("Pressure").foregroundColor(Theme.secondary)
                    Text(m.pressure.rawValue)
                        .font(.system(size: max(9, 10.5 * z), weight: .semibold))
                        .padding(.horizontal, 6 * z)
                        .padding(.vertical, 1 * z)
                        .background(Capsule().fill(pressureColor(m.pressure).opacity(0.18)))
                        .foregroundColor(pressureColor(m.pressure))
                    Text(String(format: "Swap %.1f GB", m.swapUsed / gb)).foregroundColor(Theme.secondary)
                }
                .font(.system(size: 12.5 * z))
                legend.padding(.top, 5 * z)
            } else {
                line("Measuring", "…")
            }
        }
    }

    /// One row at full size; two rows once the text is scaled down, where the 9 pt minimum
    /// no longer fits five labels across the column.
    @ViewBuilder private var legend: some View {
        if z >= PopoverMetrics.legendOneRow {
            HStack(spacing: 9 * z) {
                swatch("Wired", fill: 1.0, mark: false)
                swatch("App", fill: 0.78, mark: false)
                swatch("Compr.", fill: 0.4, mark: true)
                swatch("Cached", fill: 0.16, mark: false)
                swatch("Free", fill: 0, mark: false)
            }
        } else {
            VStack(alignment: .leading, spacing: 3 * z) {
                HStack(spacing: 9 * z) {
                    swatch("Wired", fill: 1.0, mark: false)
                    swatch("App", fill: 0.78, mark: false)
                    swatch("Compr.", fill: 0.4, mark: true)
                }
                HStack(spacing: 9 * z) {
                    swatch("Cached", fill: 0.16, mark: false)
                    swatch("Free", fill: 0, mark: false)
                }
            }
        }
    }

    private func swatch(_ label: String, fill: Double, mark: Bool) -> some View {
        let side = 7 * z
        return HStack(spacing: 3 * z) {
            ZStack {
                RoundedRectangle(cornerRadius: 1)
                    .fill(accent.opacity(fill))
                RoundedRectangle(cornerRadius: 1)
                    .stroke(accent.opacity(fill == 0 ? 0.6 : 0), lineWidth: 0.8)
                if mark {
                    Path { p in p.move(to: CGPoint(x: 0, y: side)); p.addLine(to: CGPoint(x: side, y: 0)) }
                        .stroke(Color.black, lineWidth: 0.8)
                }
            }
            .frame(width: side, height: side)
            Text(label).font(.system(size: max(9, 9.5 * z))).foregroundColor(Theme.secondary)
        }
    }

    // MARK: - Pieces

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14 * z, weight: .regular))
            .foregroundColor(Theme.text)
            .padding(.bottom, 1 * z)
    }

    private func line(_ label: String, _ value: String, _ suffix: String = "") -> some View {
        (Text(label + " ").foregroundColor(Theme.secondary)
            + Text(value).foregroundColor(valueColor)
            + Text(suffix.isEmpty ? "" : " " + suffix).foregroundColor(Theme.secondary))
            .font(.system(size: 12.5 * z).monospacedDigit())
            .lineLimit(1)
            // Never "…": while the column widens back from Simple mode a line can be laid out
            // narrow, and SwiftUI kept that truncation after the column reached full width.
            // At rest every line fits; mid-animation the column clips instead.
            .fixedSize(horizontal: true, vertical: false)
    }

    private func pct(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }

    private func average(_ xs: [Double]) -> Double {
        xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count)
    }

    private func pressureColor(_ p: Pressure) -> Color {
        switch p {
        case .normal: return accent
        case .warning: return Theme.warning
        case .critical: return Theme.critical
        }
    }
}
