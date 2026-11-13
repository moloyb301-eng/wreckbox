// swift-tools-version:5.9
import PackageDescription

// WreckBox Player for Mac: the Android WreckBox Player's features as a native Mac app (scripts/make-app.sh wraps it
// into "WreckBox Player.app" with its widget extension).
let package = Package(
    name: "WreckBoxPlayer",
    platforms: [.macOS(.v14)],
    targets: [
        // What the app and its widget both know: the widget's snapshot, where it lives, the widget's link commands.
        .target(name: "Shared", path: "Sources/Shared"),
        // Fonts in Resources are copied into the .app by scripts/make-app.sh.
        .executableTarget(name: "WreckBoxPlayer", dependencies: ["Shared"], path: "Sources/WreckBoxPlayer", exclude: ["Resources"]),
        // The macOS widget (Notification Centre / desktop). Packed into PlugIns/WreckBoxPlayerWidget.appex.
        .executableTarget(name: "PlayerWidget", dependencies: ["Shared"], path: "Sources/PlayerWidget",
                          swiftSettings: [.unsafeFlags(["-application-extension"])],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-application_extension"])]),
    ]
)
