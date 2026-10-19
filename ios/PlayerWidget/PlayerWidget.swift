import SwiftUI
import WidgetKit

// The widget configuration and bundle; the views and timeline are in Shared/WidgetViews.swift (the app renders them
// too, for testing: wreckbox://widgetlab).

struct PlayerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: widgetKind, provider: PlayerProvider()) { PlayerWidgetView(entry: $0) }
            .configurationDisplayName("WreckBox Player")
            .description("The WreckBox player: LCD, jog pad, and Equaliser / Queue / Options.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

@main
struct PlayerWidgets: WidgetBundle {
    init() { WreckFonts.register() }
    var body: some Widget {
        PlayerWidget()
        PlayerLiveActivity()
    }
}
