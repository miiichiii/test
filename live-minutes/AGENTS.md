# AGENTS.md — LiveMinutes

このファイルは `live-minutes/` 配下の作業に適用する。リポジトリ直下の `*.html` は別の用途のファイルなので、読む必要も変更する必要もない。

## このプロジェクト

会議中にMacのマイク音声をリアルタイムで文字起こしし、要点・決定事項・ToDoに整理して表示するmacOSアプリ。設計は [docs/DESIGN.md](docs/DESIGN.md) にある。作業を始める前に必ず読むこと。

- macOS 26 以降、Appleシリコン、Swift 6、SwiftUI
- 文字起こしは端末内（`SpeechAnalyzer` / `SpeechTranscriber`）
- 整理・要約は OpenAI API（会議中は Luna、議事録仕上げは Sol）

## 進め方

実装は [docs/tasks/](docs/tasks/) のフェーズ順に行う。

- 1回の作業で扱うのは、指示された1フェーズだけにする。先のフェーズの機能を先取りしない
- フェーズファイルの「受け入れ条件」をすべて満たしたら完了とする
- 設計と違う判断をした場合は、`docs/DESIGN.md` の該当箇所を同じコミットで更新し、最終報告に理由を書く
- `docs/DESIGN.md` §8 の未確認事項は、該当フェーズの最初に確認し、結果を表に書き込む

## 構成

```
project.yml          XcodeGen の定義
App/                 アプリターゲット（SwiftUIのViewと起動処理だけ）
LiveMinutesKit/      ローカルSwift Package（UI以外のすべて）とそのテスト
docs/                設計書、プロンプト、スキーマ、フェーズ別の指示
```

ロジックは `LiveMinutesKit` に置き、`App/` にはViewだけを置く。

## コマンド

初回だけ:

```bash
brew install xcodegen
```

プロジェクト生成とビルド（`live-minutes/` で実行）:

```bash
xcodegen generate
```

```bash
xcodebuild -project LiveMinutes.xcodeproj -scheme LiveMinutes -destination 'platform=macOS' build
```

テスト:

```bash
cd LiveMinutesKit && swift test
```

作業を終える前に、ビルドとテストの両方を実行して通ることを確認する。

## 規約

- Swift 6 の厳格な並行性チェックを通す。`@unchecked Sendable` や `nonisolated(unsafe)` を使う場合は、安全である理由をコメントに書く
- 非同期処理は async/await と actor で書く
- 外部ライブラリは追加しない。必要だと考えた場合は、追加せずに理由を報告する
- 強制アンラップ（`!`）と `try!` は、テストコード以外では使わない
- テストは Swift Testing（`import Testing`）で書く
- 画面に出す文言は日本語にする
- `.xcodeproj` は生成物なのでコミットしない

## 新しいAPIの扱い

`SpeechAnalyzer` / `SpeechTranscriber` は macOS 26 で入った新しいAPIで、OpenAI の現行モデルと Responses API も更新が速い。記憶に頼って書くと古い形や存在しない名前になりやすい。

- Apple のAPIは、SDKのヘッダ（Xcodeの定義へのジャンプや `.swiftinterface`）か公式ドキュメントで確認してから使う
- OpenAI のAPIは、公式ドキュメントでリクエストとレスポンスの形を確認してから使う
- 確認できなかった場合は、推測で埋めずに報告する

## 秘密情報

- APIキーをソース、テスト、設定ファイル、ログに書かない。保存先はKeychainだけ
- 文字起こしやノートの本文をログに出さない（会議の内容が含まれるため）
- 自動テストから実際の OpenAI API を呼ばない。`URLProtocol` のスタブか偽の `LLMClient` を使う

## 自動では確認できないこと

マイク入力と音声認識を使う動作は、エージェントの環境からは確認できない。各フェーズファイルの「人が確認する項目」は実行せず、最終報告に「未確認。人による確認が必要」として列挙する。確認していないことを確認済みと書かない。

## 最終報告に書くこと

- 何を実装したか
- 実行したコマンドと結果（ビルド、テスト）
- 受け入れ条件ごとの達成状況
- 人による確認が必要な項目
- 設計から変えた点と理由
