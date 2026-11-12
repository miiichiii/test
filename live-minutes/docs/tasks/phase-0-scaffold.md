# Phase 0: 雛形

## 目的

ビルドとテストが通る空のアプリを作る。以降のフェーズが、機能の実装だけに集中できる状態にする。

## 先に読むもの

- [AGENTS.md](../../AGENTS.md)
- [DESIGN.md](../DESIGN.md) §3（リポジトリ構成）、§7（ビルドと権限）

## 最初に確認すること

次のコマンドで環境を確認し、結果を最終報告に書く。macOS 26 未満、または Xcode 26 未満の場合は、作業を始めずに報告する。

```bash
sw_vers
```

```bash
xcodebuild -version
```

```bash
swift --version
```

## 作業内容

1. `LiveMinutesKit/` にSwift Packageを作る
   - ライブラリターゲット `LiveMinutesKit` とテストターゲット `LiveMinutesKitTests`
   - プラットフォームは macOS 26、Swift 6 の言語モード
   - DESIGN.md §3 のディレクトリ（`Audio/`、`Transcription/` など）は、中身を実装するフェーズで作ればよい
   - 動作確認用に、バージョン文字列を返すだけの公開APIと、それを確かめるテストを1つ置く
2. `project.yml`（XcodeGen）を作る
   - アプリターゲット `LiveMinutes`（macOS、デプロイメントターゲット 26.0）
   - ローカルパッケージ `LiveMinutesKit` に依存させる
   - バンドルIDは `com.example.LiveMinutes`（利用者が後で変える前提の仮の値）
   - 署名はローカル実行用（Sign to Run Locally）
   - 厳格な並行性チェックを有効にする
3. `App/` にアプリの最小構成を置く
   - `LiveMinutesApp.swift`: ウィンドウを1つ開く
   - メイン画面: 左右2ペインの枠だけ（左「文字起こし」、右「ノート」の見出しと空の領域）
   - `Info.plist`: `NSMicrophoneUsageDescription` と `NSSpeechRecognitionUsageDescription`（日本語の説明文）
   - `LiveMinutes.entitlements`: DESIGN.md §7 の3つ
4. `.gitignore` を置く（`*.xcodeproj`、`.build/`、`DerivedData/`、`xcuserdata/`、`.DS_Store`）

## 範囲外

- マイク、音声認識、LLM に関するコード
- 設定画面

## 受け入れ条件

- `xcodegen generate` が成功する
- AGENTS.md の `xcodebuild … build` が成功する
- `cd LiveMinutesKit && swift test` が成功する
- `.xcodeproj` がコミット対象に含まれていない

## 人が確認する項目

- Xcodeで `LiveMinutes.xcodeproj` を開いて実行すると、2ペインのウィンドウが開く
