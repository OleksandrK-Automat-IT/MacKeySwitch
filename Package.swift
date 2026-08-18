// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LayoutSwitcher",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "ObjCExceptionGuard",
            path: "Sources/ObjCExceptionGuard",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "LayoutSwitcher",
            dependencies: ["ObjCExceptionGuard"],
            path: "Sources/LayoutSwitcher",
            resources: [
                .copy("Resources/en_words.txt"),
                .copy("Resources/ua_words.txt"),
                // `.copy` rather than `.process`: the app picks its own `.lproj` at runtime
                // (Settings → Interface language), so the directories have to survive into
                // the bundle verbatim instead of being folded into SwiftPM's own
                // localization handling.
                .copy("Resources/en.lproj"),
                .copy("Resources/uk.lproj"),
            ],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("Cocoa"),
            ]
        ),
        .testTarget(
            name: "LayoutSwitcherTests",
            dependencies: ["LayoutSwitcher"],
            path: "Tests/LayoutSwitcherTests"
        ),
    ]
)
