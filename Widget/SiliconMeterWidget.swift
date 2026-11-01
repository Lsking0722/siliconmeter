//
//  SiliconMeterWidget.swift
//  Desktop widget: this Mac's chip, drawn as its die, standing still. Widgets can't animate,
//  so the widget shows the drawing only; a click opens SiliconMeter's floating window, where
//  the die runs live.
//
//  Sizes: small (the die), medium (the die beside the chip's name and core counts) and large
//  (the die, as big as it fits). Every chip drawing is taller than wide, and macOS has no
//  tall widget, so tall chips fill the height and leave room at the sides.
//
//  The widget finds the chip itself (sysctl and the I/O registry), the same way the app does,
//  so it needs no data from the app and no shared App Group.
//
import SwiftUI
import WidgetKit

struct DieEntry: TimelineEntry {
    let date: Date
}

struct DieProvider: TimelineProvider {
    func placeholder(in context: Context) -> DieEntry { DieEntry(date: Date()) }

    func getSnapshot(in context: Context, completion: @escaping (DieEntry) -> Void) {
        completion(DieEntry(date: Date()))
    }

    /// The picture never changes (the chip doesn't), so one entry and no reloads.
    func getTimeline(in context: Context, completion: @escaping (Timeline<DieEntry>) -> Void) {
        completion(Timeline(entries: [DieEntry(date: Date())], policy: .never))
    }
}

/// Detected once per extension process.
enum WidgetChip {
    static let chip = ChipInfo.detect()
    static let drawing = WidgetArt.dieOnly(ChipLayout.build(for: chip))
}

/// The drawing itself is shared with the app (WidgetArt.swift); this only maps WidgetKit's
/// size and rendering mode onto it.
struct DieWidgetView: View {
    let entry: DieEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        WidgetContent(chip: WidgetChip.chip, drawing: WidgetChip.drawing,
                      family: family == .systemMedium ? .medium : family == .systemLarge ? .large : .small,
                      tinted: renderingMode != .fullColor)
            .widgetURL(URL(string: "siliconmeter://window"))
            .containerBackground(for: .widget) { Color.black }
    }
}

struct DieWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SiliconMeterDie", provider: DieProvider()) { entry in
            DieWidgetView(entry: entry)
        }
        .configurationDisplayName("Chip")
        .description("Your Mac's chip, drawn as its die. Click it to open the live view.")
        // Ultra chips (two dies stacked, very tall) offer only medium and large.
        .supportedFamilies(WidgetArt.families(for: WidgetChip.chip).map { f -> WidgetFamily in
            switch f {
            case .small: return .systemSmall
            case .medium: return .systemMedium
            case .large: return .systemLarge
            }
        })
        // Our own, tighter padding: the die fills the widget.
        .contentMarginsDisabled()
    }
}

@main
struct SiliconMeterWidgets: WidgetBundle {
    var body: some Widget {
        DieWidget()
    }
}
