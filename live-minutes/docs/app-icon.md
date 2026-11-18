# LiveMinutes のアプリアイコン

音声波形とノート、決定事項を示すチェックマークを組み合わせたアイコン。
`App/Assets.xcassets/AppIcon.appiconset/` に macOS 用の各解像度を置き、
`project.yml` の `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` で指定する。
元となる最大サイズは `icon_512x512@2x.png`（1024 × 1024）。

2026-11-18 に組み込みの `image_gen` で生成。外部ライブラリや API キーは使っていない。
各サイズへの変換には macOS 標準の `sips` を使用した。

## 生成プロンプト

Use case: logo-brand. Asset type: production macOS application icon for LiveMinutes,
a private local meeting transcription and meeting-notes app. Create one polished
standalone app icon, straight-on orthographic, square composition. A simple
rounded-square tile, ocean teal to cobalt blue gentle gradient. A crisp ivory
white rounded note sheet centered, with five rounded audio waveform bars in teal
and blue flowing into three short note lines and a small checkmark. Recognizable
at 32px, generous negative space, macOS-native soft layered material, minimal
detail, calm professional feel. Equal transparent padding outside the tile.
No letters, typography, watermark, microphone, or mockup.

仕上げ指示: Preserve the central tile, white note, waveform, checkmark and colors.
Remove scattered flecks, noise, haze, halos and debris outside the rounded square.
Use a smooth antialiased edge and a true transparent background.
