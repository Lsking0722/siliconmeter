//
//  Sampler.swift
//  One sudoless sampler for everything the popover shows. Called on a background
//  queue about once a second, and only while the popover is open.
//
//  - Per-core CPU load: host_processor_info tick deltas (public API).
//  - GPU busy share: IOAccelerator "Device Utilization %" (as Activity Monitor shows it);
//    average clock: IOReport "GPU Stats" › GPUPH residency.
//  - Neural Engine, best signal first:
//      1. "SoC Stats" › "Cluster Power States" ACT residency, where a chip reports it;
//      2. "PMP" › "DCS Floor" / "SOC Floor" ANE-* residency: the share of time the engine
//         held a bandwidth floor above minimum. Measured on an M4: 0 % idle, ~94 % under a
//         sustained Vision load, while "Energy Model" › ANE stayed at 0 mJ;
//      3. power from "Energy Model" › ANE over a reference maximum (M1–M3 era chips).
//    Power is shown only while it is plausible (it is dropped for good once the engine is
//    seen busy at 0 W); memory traffic comes from "AMC Stats" › "Perf Counters" ANE bytes.
//  - Memory: host_statistics64, Activity Monitor breakdown; pressure and swap via sysctl.
//
//  IOReport channel handling follows SiliconScope (GPUSampler.swift, ANESampler.swift,
//  MemorySampler.swift — MIT, (c) 2026 Kennt Kim / Calida Lab). Unlike there, both IOReport
//  groups share one subscription and each tick diffs against the previous tick, so nothing
//  sleeps inside the sampler.
//
import Combine
import Foundation
import IOKit
import CIOReport

enum Pressure: String {
    case normal = "Normal", warning = "Warning", critical = "Critical"
}

struct MemoryState {
    var total: Double = 0
    var app: Double = 0
    var wired: Double = 0
    var compressed: Double = 0
    var cached: Double = 0
    var swapUsed: Double = 0
    var pressure: Pressure = .normal

    var used: Double { app + wired + compressed }
    var free: Double { max(0, total - app - wired - compressed - cached) }
}

struct Snapshot {
    var cores: [Double] = []      // 0…1, indexed by CPU number
    var gpu: Double = 0           // 0…1
    var gpuMHz: Double?
    var ane: Double?              // 0…1, nil when this Mac does not report it
    var anePower: Double?         // W, from IOReport "Energy Model" (nil when not reported)
    var aneEstimated = false      // `ane` derived from a proxy (bandwidth floor or power)
    var aneTraffic: Double?       // GB/s the engine moved through the fabric (nil when not reported)
    var memory = MemoryState()
    var valid = false             // false until two CPU samples exist
}

final class SystemSampler {
    let chip: ChipInfo

    private var prevBusy: [UInt64] = []
    private var prevTotal: [UInt64] = []

    private var subscription: IOReportSubscriptionRef?
    private var channels: CFMutableDictionary?
    private var previous: CFDictionary?

    private var accelerator: io_service_t = 0
    private var previousTime: Double?
    /// Neural Engine power that counts as 100 %: the chip's reference, raised to the highest
    /// power seen so far.
    private lazy var aneFullPower: Double = ChipCatalog.aneReferenceWatts(chip)
    /// Set once the engine is seen busy while its energy counter stays at zero (M4).
    private var anePowerBroken = false
    /// Set once the energy counter has moved at all. Until then the panel shows traffic, not a
    /// "0.00 W" that may only mean the counter is dead (an idle M4 read exactly that).
    private var anePowerSeen = false

    var ioReportAvailable: Bool { subscription != nil }

    init(chip: ChipInfo) {
        self.chip = chip
        setUpIOReport()
        accelerator = Self.findAccelerator()
    }

    deinit {
        if accelerator != 0 { IOObjectRelease(accelerator) }
    }

    func sample() -> Snapshot {
        var snap = Snapshot()
        snap.cores = sampleCores()
        snap.valid = !snap.cores.isEmpty
        _ = readIOReport(into: &snap)                 // GPU clock, Neural Engine
        // GPU busy share: the driver's own "Device Utilization %", the figure Activity
        // Monitor's GPU History shows. IOReport's GPUPH residency counts every powered state
        // as busy on recent chips (an idle M4 desktop read 75–100 %), so it is only the
        // fallback.
        if let utilization = acceleratorUtilization() { snap.gpu = utilization }
        snap.memory = sampleMemory()
        return snap
    }

    // MARK: - CPU

    /// Busy share per logical CPU since the previous call. Empty on the first call.
    private func sampleCores() -> [Double] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            let size = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)
        }

        let count = Int(cpuCount)
        let states = Int(CPU_STATE_MAX)
        var busy = [UInt64](repeating: 0, count: count)
        var total = [UInt64](repeating: 0, count: count)
        for i in 0..<count {
            let user = UInt64(UInt32(bitPattern: info[i * states + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[i * states + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[i * states + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[i * states + Int(CPU_STATE_IDLE)]))
            busy[i] = user + system + nice
            total[i] = user + system + nice + idle
        }
        defer { prevBusy = busy; prevTotal = total }
        guard prevBusy.count == count, count > 0 else { return [] }

        return (0..<count).map { i in
            let db = busy[i] >= prevBusy[i] ? Double(busy[i] - prevBusy[i]) : 0
            let dt = total[i] >= prevTotal[i] ? Double(total[i] - prevTotal[i]) : 0
            return dt > 0 ? min(1, db / dt) : 0
        }
    }

    // MARK: - IOReport (GPU + Neural Engine)

    private func setUpIOReport() {
        guard let wanted = IOReportCopyChannelsInGroup("GPU Stats" as CFString, nil, 0, 0, 0)?
            .takeRetainedValue() else { return }
        if let soc = IOReportCopyChannelsInGroup("SoC Stats" as CFString,
                                                 "Cluster Power States" as CFString, 0, 0, 0)?
            .takeRetainedValue() {
            IOReportMergeChannels(wanted, soc, nil)
        }
        for (group, subgroup) in [("Energy Model", nil), ("PMP", "DCS Floor"), ("PMP", "SOC Floor"),
                                  ("AMC Stats", "Perf Counters")] as [(String, String?)] {
            if let more = IOReportCopyChannelsInGroup(group as CFString, subgroup as CFString?, 0, 0, 0)?
                .takeRetainedValue() {
                IOReportMergeChannels(wanted, more, nil)
            }
        }
        var subbed: Unmanaged<CFMutableDictionary>?
        guard let sub = IOReportCreateSubscription(nil, wanted, &subbed, 0, nil),
              let subscribed = subbed?.takeRetainedValue() else { return }
        subscription = sub
        channels = subscribed
    }

    /// Fills GPU and ANE fields from the delta since the previous tick.
    /// Returns false when IOReport gave no GPU reading (the caller then falls back).
    private func readIOReport(into snap: inout Snapshot) -> Bool {
        guard let sub = subscription, let subscribed = channels,
              let current = IOReportCreateSamples(sub, subscribed, nil)?.takeRetainedValue()
        else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = previousTime.map { now - $0 } ?? 0
        defer { previous = current; previousTime = now }
        guard let prev = previous,
              let delta = IOReportCreateSamplesDelta(prev, current, nil)?.takeRetainedValue()
        else { return false }

        let freqs = chip.gpuFreqsMHz
        var gpuActive = 0.0, gpuTotal = 0.0, gpuFreqAcc = 0.0, sawGPU = false
        var aneFractions: [Double] = []
        var aneJoules = 0.0, sawANEEnergy = false
        var aneFloors: [Double] = []
        var aneBytes = 0.0, sawANEBytes = false

        IOReportIterate(delta) { channel in
            let group = (IOReportChannelGetGroup(channel)?.takeUnretainedValue() as String?) ?? ""
            if group == "Energy Model" {
                let name = (IOReportChannelGetChannelName(channel)?.takeUnretainedValue() as String?) ?? ""
                if isNeuralEngineChannel(name) {
                    let unit = (IOReportChannelGetUnitLabel(channel)?.takeUnretainedValue() as String?) ?? "mJ"
                    aneJoules += Double(IOReportSimpleGetIntegerValue(channel, nil)) * joules(per: unit)
                    sawANEEnergy = true
                }
                return 0
            }
            if group == "AMC Stats" {
                // "ANE NRT AF RD" / "ANE NRT AF WR": what the engine pulled over the fabric.
                // (The "ANE DCS" pair is the DRAM share of the same traffic.)
                let name = (IOReportChannelGetChannelName(channel)?.takeUnretainedValue() as String?) ?? ""
                if name.hasPrefix("ANE") && name.contains(" AF ") {
                    aneBytes += Double(IOReportSimpleGetIntegerValue(channel, nil))
                    sawANEBytes = true
                }
                return 0
            }
            guard IOReportChannelGetFormat(channel) == 2 else { return 0 }   // state format
            let name = (IOReportChannelGetChannelName(channel)?.takeUnretainedValue() as String?) ?? ""
            let subgroup = (IOReportChannelGetSubGroup(channel)?.takeUnretainedValue() as String?) ?? ""
            let count = IOReportStateGetCount(channel)
            guard count > 0 else { return 0 }

            if subgroup == "GPU Performance States" && name == "GPUPH" {
                sawGPU = true
                var activeIndex = 0
                for i in 0..<count {
                    let residency = Double(IOReportStateGetResidency(channel, i))
                    let state = (IOReportStateGetNameForIndex(channel, i)?.takeUnretainedValue() as String?) ?? ""
                    gpuTotal += residency
                    if state == "OFF" || state == "IDLE" || state == "DOWN" { continue }
                    let mhz = activeIndex < freqs.count ? freqs[activeIndex] : (freqs.last ?? 0)
                    activeIndex += 1
                    gpuActive += residency
                    gpuFreqAcc += residency * mhz
                }
            } else if subgroup == "Cluster Power States" && isNeuralEngineChannel(name) {
                var total = 0.0, active = 0.0, hasAct = false
                for i in 0..<count {
                    let residency = Double(IOReportStateGetResidency(channel, i))
                    let state = (IOReportStateGetNameForIndex(channel, i)?.takeUnretainedValue() as String?) ?? ""
                    total += residency
                    if state == "ACT" { active += residency; hasAct = true }
                }
                if hasAct { aneFractions.append(total > 0 ? active / total : 0) }
            } else if group == "PMP" && name.uppercased().hasPrefix("ANE-") {
                // Bandwidth-floor votes: first state (F1 / VMIN) is "no demand".
                var total = 0.0, idle = 0.0
                for i in 0..<count {
                    let residency = Double(IOReportStateGetResidency(channel, i))
                    total += residency
                    if i == 0 { idle = residency }
                }
                if total > 0 { aneFloors.append(1 - idle / total) }
            }
            return 0
        }

        if sawGPU {
            snap.gpu = gpuTotal > 0 ? min(1, gpuActive / gpuTotal) : 0
            snap.gpuMHz = (gpuActive > 0 && !freqs.isEmpty) ? gpuFreqAcc / gpuActive : nil
        }
        snap.ane = aneFractions.max()
        if snap.ane == nil, let floor = aneFloors.max() {
            snap.ane = min(1, max(0, floor))
            snap.aneEstimated = true
        }
        if sawANEBytes, elapsed > 0.05 { snap.aneTraffic = aneBytes / elapsed / 1e9 }
        if sawANEEnergy, elapsed > 0.05 {
            let watts = max(0, aneJoules / elapsed)
            let busy = (snap.ane ?? 0) > 0.2 || (snap.aneTraffic ?? 0) > 1
            if busy && watts == 0 && !anePowerSeen { anePowerBroken = true }
            if watts > 0 { anePowerSeen = true }
            if !anePowerBroken {
                // Only where there is no traffic counter: a measured traffic figure beats a
                // power reading that may be stuck near zero (an M4 shows stray tiny values),
                // and the line keeps one meaning instead of flipping between the two.
                if snap.aneTraffic == nil { snap.anePower = watts }
                if snap.ane == nil {
                    aneFullPower = max(aneFullPower, watts)
                    snap.ane = min(1, watts / aneFullPower)
                    snap.aneEstimated = true
                }
            }
        }
        return sawGPU
    }

    // MARK: - GPU fallback (public IOKit)

    private static func findAccelerator() -> io_service_t {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let perf = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString,
                                                          kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
               perf["Device Utilization %"] != nil {
                return service   // kept; released in deinit
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return 0
    }

    private func acceleratorUtilization() -> Double? {
        guard accelerator != 0,
              let perf = IORegistryEntryCreateCFProperty(accelerator, "PerformanceStatistics" as CFString,
                                                         kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
              let value = perf["Device Utilization %"] as? NSNumber
        else { return nil }
        return min(1, max(0, value.doubleValue / 100))
    }

    // MARK: - Memory

    private func sampleMemory() -> MemoryState {
        var m = MemoryState()
        m.total = Double(Sys.uint64("hw.memsize"))

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let host = mach_host_self()
        let kr = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            var rawPageSize: vm_size_t = 0
            host_page_size(host, &rawPageSize)
            let page = Double(rawPageSize)
            let internalPages = Double(stats.internal_page_count)
            let purgeable = Double(stats.purgeable_count)
            m.wired = Double(stats.wire_count) * page
            m.compressed = Double(stats.compressor_page_count) * page
            m.app = max(0, internalPages - purgeable) * page
            m.cached = (Double(stats.external_page_count) + purgeable) * page
        }

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.stride
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            m.swapUsed = Double(swap.xsu_used)
        }

        switch Sys.int("kern.memorystatus_vm_pressure_level") {
        case 4: m.pressure = .critical
        case 2: m.pressure = .warning
        default: m.pressure = .normal
        }
        return m
    }
}

/// "ANE0", "ANE", or a die-prefixed "DIE0 ANE1" / "DIE_0_ANE".
func isNeuralEngineChannel(_ name: String) -> Bool {
    let n = name.uppercased()
    return n.hasPrefix("ANE") || n.contains(" ANE") || n.contains("_ANE")
}

/// IOReport energy unit labels to joules.
func joules(per unit: String) -> Double {
    switch unit.trimmingCharacters(in: .whitespaces) {
    case "nJ": return 1e-9
    case "uJ", "µJ": return 1e-6
    case "mJ": return 1e-3
    case "J": return 1
    default: return 1e-3
    }
}

// MARK: - Frame clock

/// Drives the die animation: a plain main-run-loop timer at the chosen frame rate that bumps
/// a counter the die canvas observes. Unlike a TimelineView, nothing runs at the display's
/// refresh rate between frames.
final class FrameClock: ObservableObject {
    @Published private(set) var frame = 0
    private var timer: Timer?

    func run(fps: Double) {
        stop()
        let interval = 1 / max(1, fps)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.frame &+= 1 }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Monitor

/// Publishes snapshots to the popover. Samples only while started (popover open).
/// With a `feed` (debug mode, simulating another chip) the snapshots come from it instead
/// of this Mac's counters.
final class Monitor: ObservableObject {
    @Published private(set) var snapshot = Snapshot()
    /// True while the popover is open; the die animation runs only then.
    @Published private(set) var running = false
    let chip: ChipInfo
    let anim = AnimState()          // smoothed values the die animation draws from
    let login = LoginItem()
    let prefs = Preferences()
    let clock = FrameClock()
    let layers = DieLayerCache()       // pre-rendered static parts of the die
    /// Frames per second while running (1 with Reduce Motion).
    var reduceMotion = false { didSet { if running { runClock() } } }
    private var fpsSubscription: Any?

    private let sampler: SystemSampler?
    private let feed: (() -> Snapshot)?
    /// Debug: values come from a synthetic load, not this Mac.
    var simulated: Bool { feed != nil }
    private let queue = DispatchQueue(label: "siliconmeter.sampler", qos: .utility)
    private var timer: DispatchSourceTimer?

    init(chip: ChipInfo, feed: (() -> Snapshot)? = nil) {
        self.chip = chip
        self.feed = feed
        self.sampler = feed == nil ? SystemSampler(chip: chip) : nil
        fpsSubscription = prefs.$fps.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { if self?.running == true { self?.runClock() } }
        }
    }

    private func runClock() {
        clock.run(fps: reduceMotion ? 1 : Double(prefs.fps))
    }

    func start() {
        guard timer == nil else { return }
        running = true
        runClock()
        if let feed {
            snapshot = feed()
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now() + 1, repeating: 1.0, leeway: .milliseconds(100))
            t.setEventHandler { [weak self] in self?.snapshot = feed() }
            t.resume()
            timer = t
            return
        }
        guard let sampler else { return }
        queue.async { _ = sampler.sample() }   // baseline for the first delta
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: 1.0, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in
            let snap = sampler.sample()
            DispatchQueue.main.async { self?.snapshot = snap }
        }
        t.resume()
        timer = t
    }

    /// Debug: take a new synthetic sample now (after the load scenario changes).
    func refresh() {
        if let feed { snapshot = feed() }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        running = false
        clock.stop()
    }
}
