//
//  Debug.swift
//  `SiliconMeter --debug [chip-id]` runs the real menu bar app as any Apple Silicon chip:
//  the status item, popover, die animation, size / Simple picker and resize tween are the
//  shipping code, only the chip identity and the load come from SimSpec and a synthetic
//  load generator instead of this Mac. A floating panel lists every chip M1–M6 plus
//  "This Mac", and switches between them live. The popover stays open while debugging.
//
import AppKit
import SwiftUI
import Vision

enum DebugLoad: String, CaseIterable, Identifiable {
    case idle = "Idle", sample = "Sample", busy = "Busy", full = "Full"
    var id: String { rawValue }
}

final class DebugState: ObservableObject {
    static let real = "real"

    @Published var selected: String
    @Published var load: DebugLoad = .busy

    var onSelect: ((String) -> Void)?
    var onReopen: (() -> Void)?

    init(selected: String) { self.selected = selected }

    var ids: [String] { [Self.real] + SimSpec.all.map(\.id) }

    func select(_ id: String) {
        selected = id
        onSelect?(id)
    }

    func step(_ delta: Int) {
        let all = ids
        let i = all.firstIndex(of: selected) ?? 0
        select(all[(i + delta + all.count) % all.count])
    }

    func title(_ id: String) -> String {
        guard let s = SimSpec.all.first(where: { $0.id == id }) else { return "This Mac (detected, live)" }
        return "\(s.brand.replacingOccurrences(of: "Apple ", with: ""))  \(s.cpuCount)C · \(s.gpu)G · \(s.memoryGB)GB"
    }
}

/// Plausible, moving loads for a simulated chip.
enum SyntheticLoad {
    static func snapshot(for chip: ChipInfo, load: DebugLoad, time t: Double) -> Snapshot {
        if load == .sample { return Simulate.sampleSnapshot(for: chip) }
        var s = Snapshot()
        s.valid = true
        func h(_ i: Int) -> Double { hash01(i * 7919 + 17) }
        switch load {
        case .idle:
            s.cores = (0..<chip.cpuCount).map { i in max(0, 0.04 + 0.04 * sin(t * 0.8 + Double(i)) * h(i)) }
            s.gpu = 0.03; s.ane = 0; s.aneTraffic = 0
        case .busy:
            s.cores = (0..<chip.cpuCount).map { i in
                h(i) < 0.2 ? 0.03 : min(1, max(0, 0.55 + 0.42 * sin(t * (0.5 + h(i + 3)) + Double(i) * 1.7)))
            }
            s.gpu = 0.55 + 0.35 * sin(t * 0.45)
            s.ane = 0.4 + 0.35 * sin(t * 0.3 + 1)
            s.aneTraffic = 14 * (s.ane ?? 0)
        case .full:
            s.cores = Array(repeating: 1, count: chip.cpuCount)
            s.gpu = 1; s.ane = 1; s.aneTraffic = 18
        case .sample:
            break
        }
        let total = Double(chip.memoryBytes)
        let used = load == .full ? 0.86 : load == .idle ? 0.32 : 0.6
        s.memory.total = total
        s.memory.wired = total * used * 0.22
        s.memory.app = total * used * 0.68
        s.memory.compressed = total * used * 0.10
        s.memory.cached = total * 0.08
        s.memory.swapUsed = load == .full ? 2.4 * 1_073_741_824 : 0
        s.memory.pressure = load == .full ? .warning : .normal
        return s
    }
}

struct DebugPanel: View {
    @ObservedObject var state: DebugState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(state.title(state.selected))
                .font(.system(size: 13, weight: .semibold))
            HStack(spacing: 6) {
                Button("◀ Prev") { state.step(-1) }
                Button("Next ▶") { state.step(1) }
                Spacer()
                Button("Reopen") { state.onReopen?() }
            }
            HStack(spacing: 4) {
                Text("Load").foregroundColor(.secondary)
                ForEach(DebugLoad.allCases) { l in
                    Button(l.rawValue) { state.load = l }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(state.load == l ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.07)))
                }
            }
            .font(.system(size: 11))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(state.ids, id: \.self) { id in
                        Button { state.select(id) } label: {
                            Text(state.title(id))
                                .font(.system(size: 11.5).monospacedDigit())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 4)
                                    .fill(state.selected == id ? Color.accentColor.opacity(0.3) : Color.clear))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 300, height: 660)
    }
}

// MARK: - Neural Engine load

/// `SiliconMeter --ane-load [seconds]`: keeps the Neural Engine busy with Vision requests
/// (text recognition and image classification, which macOS runs on the ANE where it can),
/// so the popover's Neural Engine reading can be checked against a known load.
enum NeuralEngineLoad {
    /// `light`: one worker that rests 0.4 s between passes, to check that a light load
    /// reads well below a sustained one.
    static func run(seconds: Double, light: Bool = false) {
        guard let image = sampleImage() else { print("could not make the test image"); return }
        print(String(format: "Running Vision requests for %.0f s (watch the Neural Engine in the popover)…", seconds))
        let end = Date().addingTimeInterval(seconds)
        let group = DispatchGroup()
        let workers = light ? 1 : 4
        var counts = [Int](repeating: 0, count: workers)
        let lock = NSLock()
        for worker in 0..<workers {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                while Date() < end {
                    let text = VNRecognizeTextRequest()
                    text.recognitionLevel = .accurate
                    let classify = VNClassifyImageRequest()
                    try? VNImageRequestHandler(cgImage: image, options: [:]).perform([text, classify])
                    lock.lock(); counts[worker] += 1; lock.unlock()
                    if light { Thread.sleep(forTimeInterval: 0.4) }
                }
            }
        }
        group.wait()
        print("done: \(counts.reduce(0, +)) Vision passes")
    }

    private static func sampleImage() -> CGImage? {
        let size = NSSize(width: 1024, height: 768)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 28), .foregroundColor: NSColor.black]
            for i in 0..<18 {
                ("SiliconMeter Neural Engine test line \(i) — the quick brown fox jumps over the lazy dog" as NSString)
                    .draw(at: NSPoint(x: 20, y: CGFloat(20 + i * 40)), withAttributes: attributes)
            }
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
