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
    dependencies: [
        // ローカルの Whisper（Phase 4D）。利用者が 2026-11-16 に了承した外部ライブラリ（AGENTS.md の例外）。
        // MIT（一部は NOTICES のとおり Apache 2.0）。版は固定する。
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1"),
    ],
    targets: [
        .target(
            name: "LiveMinutesKit",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
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
