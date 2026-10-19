import SwiftUI
import WidgetKit

// The widget configuration and bundle; the views and timeline are in Shared/WidgetViews.swift, the Live Activity in
// PlayerLiveActivity.swift.

struct PlayerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: widgetKind, provider: PlayerProvider()) { PlayerWidgetView(entry: $0) }
            .configurationDisplayName("WreckBox Player")
            .description("Now playing in the WreckBox look. Tap to open the player.")
            .supportedFamilies([.systemSmall, .systemMedium])
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
