// swift-tools-version: 6.2
import PackageDescription

// アプリターゲット（project.yml）と同じ upcoming feature を有効にする。
// NonisolatedNonsendingByDefault は nonisolated な async 関数の実行場所を変えるので、
// 途中で切り替えると挙動が変わる。最初から有効にしておく（docs/DESIGN.md §7）。
let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "LiveMinutesKit",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "LiveMinutesKit", targets: ["LiveMinutesKit"]),
    ],
    targets: [
        .target(
            name: "LiveMinutesKit",
            // プロンプトとスキーマ。Bundle.module から読む（LLMResources）。
            resources: [.copy("Resources")],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "LiveMinutesKitTests",
            dependencies: ["LiveMinutesKit"],
            swiftSettings: swiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
