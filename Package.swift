// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LayoutSwitcher",
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
