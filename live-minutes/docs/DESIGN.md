# LiveMinutes 設計書

会議中にMacのマイク音声をリアルタイムで文字起こしし、要点・決定事項・ToDoなどに自動で整理して表示するmacOSアプリ（LiveMinutesは仮称）。

- 対象環境: macOS 26 (Tahoe) 以降、Appleシリコン
- 言語/UI: Swift 6、SwiftUI
- 文字起こし: 端末内（Apple の `SpeechAnalyzer` / `SpeechTranscriber`）
- 整理・要約: OpenAI API。会議中の更新は Luna、終了時の議事録仕上げは Sol
- 音声ソース: v1 はマイクのみ。Mac内の音声の取り込みは [Phase 7](tasks/phase-7-system-audio.md)

## 1. やること・やらないこと

v1 でやること:

- マイク音声を1〜2秒程度の遅れで文字にして表示する（未確定の途中結果も表示）
- 確定したテキストを20秒前後の間隔で整理し、トピックごとの箇条書きにする
- 会議終了時に議事録（Markdown）を作る
- 文字起こし・ノート・議事録を端末内に保存し、後から開ける

v1 でやらないこと:

- 話者の識別
- 音声ファイルの保存
- 他サービスへの自動投稿や共有機能
- 複数言語の同時認識（言語は設定で1つ選ぶ）

## 2. 全体の流れ

```
マイク
  └─ AVAudioEngine の入力tap
       └─ AVAudioConverter（analyzer が求める形式へ変換）
            └─ AsyncStream<AnalyzerInput>
                 └─ SpeechAnalyzer + SpeechTranscriber
                      └─ TranscriptEvent（.volatile / .final）
                           └─ TranscriptStore ──────────────▶ 左ペイン（文字起こし）
                                └─ NotesEngine
                                     │  確定テキストだけを送る
                                     ▼
                                OpenAI（Luna）──▶ 差分ops ──▶ NotesStore ──▶ 右ペイン（ノート）

会議終了時: 文字起こし全文 + ノート ──▶ OpenAI（Sol）──▶ 議事録Markdown
```

外部に出るのは確定済みのテキストだけで、音声は端末の外に出ない。

## 3. リポジトリ構成

`live-minutes/` 直下に次の構成で実装する。

```
live-minutes/
├── .gitignore
├── project.yml                  XcodeGen の定義（.xcodeproj は生成物でコミットしない）
├── App/                         アプリターゲット（薄いUI層）
│   ├── LiveMinutesApp.swift
│   ├── Views/
│   ├── Info.plist
│   └── LiveMinutes.entitlements
├── LiveMinutesKit/              ローカルSwift Package（UI以外のすべて）
│   ├── Package.swift
│   ├── Sources/LiveMinutesKit/
│   │   ├── Audio/
│   │   ├── Transcription/
│   │   ├── Transcript/
│   │   ├── Notes/
│   │   ├── LLM/
│   │   ├── Settings/
│   │   ├── Persistence/
│   │   ├── Session/
│   │   └── Resources/           プロンプトとスキーマ（Phase 3 で docs/ から移す）
│   └── Tests/LiveMinutesKitTests/
└── docs/
```

UI以外をすべて `LiveMinutesKit` に置くのは、`swift test` だけでロジックを検証できるようにするため。アプリターゲットにはSwiftUIのViewと起動処理だけを置く。

`.xcodeproj` を手書きせず XcodeGen で生成するのは、プロジェクトファイルが壊れやすく差分も読みにくいため。

## 4. モジュール

型名とおおよその責務を示す。シグネチャは目安で、Swift 6 の並行性制約（`Sendable` など）に合わせて調整してよい。型名を変えた場合はこの節を更新する。

### 4.1 Audio

- `AudioSource`（protocol、actor で実装）: 次の3つを持つ
  - `start(outputFormat:) async throws -> AsyncStream<AudioChunk>`: 指定した形式（文字起こし側が求める形式）に変換した音声を流す。変換はソース側で行う
  - `stop() async`: ストリームを終える。`stop()` の後にもう一度 `start` すると、新しいストリームを返す（Phase 2 の一時停止で使う）
  - `levels: AsyncStream<Float>`: 入力レベル（0…1）。開始・停止をまたいで1本だけ存在し、読み手は画面用モデル1つだけ。文字起こしのイベントには混ぜない
- `AudioChunk`: 変換済みの `AVAudioPCMBuffer` 1つ分。送った後は誰も書き換えないことを理由に `@unchecked Sendable`
- `MicrophoneSource`: `AVAudioEngine` の `inputNode` にtapを付けて実装する
- `StreamingAudioConverter`: `AVAudioConverter` をバッファをまたいで使い続ける変換。入力ブロックで `.endOfStream` を返さない（返すと以後何も出力しなくなる）。内部に数十ms分を溜めるので、出力は入力より少し遅れる
- `FakeAudioSource`: 用意したバッファを流すテスト用の実装（Kit 本体に置き、以降のフェーズのテストでも使う）
- `MicrophonePermission`（protocol）: マイクの許可。テストでは偽物に差し替える

Phase 7 でシステム音声用の実装を足せるよう、文字起こし側は `AudioSource` だけに依存する。

注意点:

- tapのブロックは、リアルタイムの I/O スレッドではなく、メイン以外のスレッドで呼ばれる（`AVAudioNodeTapBlock` に `CA_REALTIME_API` は付いていない）。そこで行うのは「変換」「レベル計算」「`AsyncStream` への yield」の3つだけにする。自前のロック（`NSLock`、`Mutex`、`DispatchQueue.sync`）、actor への移動、await、ログ出力、ファイル入出力、変換器の生成はしない。yield は内部で短いロックを取るが、ストリームで受け渡す設計（§2）なので許容する
- tapのブロックは `@Sendable` を明示した、actor に分離されないクロージャにする。分離されたクロージャをオーディオのスレッドから呼ぶと、Swift 6 の実行時の分離チェックで落ちる。tap 内で使う変換器などは、付け直すたびに新しく作るオブジェクト（`TapProcessor`）にまとめ、そのスレッドだけが触る
- tap の `bufferSize` の対応範囲は 100〜400ms。遅延を抑えるため 100ms にする
- macOSには `AVAudioSession` がない。マイク権限は `AVCaptureDevice.requestAccess(for: .audio)` で求める。未決定のままエンジンを始めると無音になるので、開始のたびに先に確かめる
- 入力形式のサンプルレートかチャンネル数が0（入力デバイスがない）のまま `installTap` すると、Swift で捕まえられない例外になる。必ず確かめ、0なら `AudioSourceError.noInputDevice` にする
- 録音中に入力デバイスが変わると（AirPodsの接続など）`AVAudioEngineConfigurationChange` 通知が来てエンジンが止まる。通知を受けたら少し待ち、`AVAudioEngine` ごと作り直して tap を付け直し、録音を続ける（停止後も古い入力形式が残ることがあるため、tap の付け直しだけにしない）。デバイスがまだない場合は、音声のストリームを開いたまま再試行を続ける。なお、ヘッダによると通知が来るのは入出力ハードウェアのチャンネル数かサンプルレートが変わったときで、同じ形式のデバイスへの切り替えで来るかは未確認
- 通知は `addObserver`（`engine.start()` より前に付ける）で受けて `AsyncStream<Int>`（最新1件だけ溜める）に流し、actor 内の1本の Task で直列に処理する。流す値はエンジンの世代番号で、今のエンジンのものでない通知は捨てる（通知は続けて来るので、作り直した直後のエンジンを古い通知でもう一度壊さないため）。待っている間に停止された場合も何もしない。`NotificationCenter.notifications(named:)` は `Notification` が Sendable でないため使わない
- `installTap(onBus:bufferSize:format:block:)` は macOS 27 で非推奨になり、エラーを返す版が追加された。デプロイメントターゲットが macOS 26 なので旧版を使う（警告は出ない）。ターゲットを 27 に上げるときに置き換える
- 入力レベル（メーター表示用）はtapのバッファ（変換前）から計算する

### 4.2 Transcription

- `TranscriptionEngine`（protocol）: 次の3つを持つ
  - `prepare(progress:)`: 手順1〜4（ロケールの確認、モデルの導入、入力形式の決定）。一度成功すれば以後は呼ばない
  - `start(source:) async throws -> AsyncThrowingStream<TranscriptEvent, Error>`: `AudioSource` を開始し、イベントのストリームを返す。録音中に認識が失敗したら、ソースを止めてからストリームをエラーで終える（マイクを点けたままにしない）
  - `stop()`: ソースを止め、最後の未確定分まで確定させてからストリームを終える
- `AppleSpeechEngine`（actor）: `SpeechAnalyzer` + `SpeechTranscriber` による実装。対象ロケールは init で渡す（Phase 1 は `ja-JP` 固定。設定から選べるようにするのは後のフェーズ）
- `TranscriptEvent`: `.volatile(text)`（未確定の途中結果）と `.final(TranscriptSegment)`（確定）
- `TranscriptSegment`: `id`、`start`（秒）、`end`（秒）、`text`
- `TranscriptionError`: 端末で使えない / ロケール非対応 / モデルのダウンロード失敗 / 入力形式なし / 準備前 / 二重開始 を区別する

`SpeechAnalyzer` は一度 finish すると再利用できないため、`start` のたびに `SpeechTranscriber` と `SpeechAnalyzer` を作り直す。`prepare` で保持するのはロケールと入力形式だけ。actor は await で再入するので、状態（idle / starting / running / stopping）は最初の await より前に書き換え、二重の開始を防ぐ。

`AppleSpeechEngine` の手順（WWDC25 session 277 のサンプルコードで確認済みのAPI。macOS 27.2 SDK でも一致を確認）:

1. `SpeechTranscriber(locale:transcriptionOptions:reportingOptions:attributeOptions:)` を作る。`reportingOptions: [.volatileResults]`、`attributeOptions: [.audioTimeRange]`
2. `SpeechTranscriber.isAvailable` を確かめ、`SpeechTranscriber.supportedLocale(equivalentTo:)` で対象ロケールに対応する Locale を得る（`supportedLocales` に含まれるかを直接比べない）。得られなければエラーを表示して終了する。以降は得られた Locale で transcriber を作る
3. `AssetInventory.assetInstallationRequest(supporting:)` が non-nil なら `downloadAndInstall()` でモデルを入れる。`progress` を画面に出す
4. `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])`（static）で入力形式を得る。`SpeechAnalyzer(modules: [transcriber])` は `start` のたびに作る（手順5）
5. `AsyncStream<AnalyzerInput>.makeStream()` を作り、`analyzer.prepareToAnalyze(in:)` でモデルを先に読み込んでから `analyzer.start(inputSequence:)` を呼ぶ。続けて `transcriber.results` を読む Task を起こし、最後に `AudioSource.start(outputFormat:)` を呼ぶ（モデルの読み込み中にマイクの音声が溜まらないようにするため）
6. マイクのバッファを手順4の形式に変換し、`AnalyzerInput(buffer:)` にしてストリームへ流す。変換はソース側（§4.1）で行う。入力のストリームを閉じるのは、ソースのストリームが終わったときの1か所だけにする
7. `transcriber.results` を読む。`result.isFinal` が true なら確定、false なら未確定。本文は `String(result.text.characters)`、時刻は `result.range` から取る。空白だけの確定は捨てる。未確定の結果は、直前の未確定結果を置き換える。確定が来たら未確定表示を消す（`TranscriptBuffer.apply(_:)`）
8. 停止時は、ソースを止めて入力のストリームが閉じるのを待ち、`analyzer.finalizeAndFinishThroughEndOfInput()` を呼ぶ。呼ばないと最後の未確定分が確定されずに失われる。その後、結果の読み取りが終わるのを待つ。最終確定と結果の読み取りの両方に10秒の上限を設け、超えたら `cancelAndFinishNow()` で打ち切る（「確定中」のまま固まらないようにするため）

結果のストリームは、停止操作によらずに終わった場合（エラーの有無とも）も必ずエンジンに知らせ、ソースを止めてからイベントのストリームをエラーで終える。開始処理の途中で終わった場合は、開始そのものを失敗にする。

タイムスタンプは「投入した音声の累積時間」が基準になる（`AnalyzerInput` に `bufferStartTime` は渡さない）。一時停止中や入力デバイスの切り替え中は音声を流さないので、壁時計の時刻とはずれる。表示用の時刻は会議開始からの録音経過時間として扱う。

Phase 1 では、画面用の単純なモデル `LiveTranscriptionModel`（`@MainActor`、`@Observable`）が、開始・停止、権限の確認、確定セグメントと未確定テキスト（`TranscriptBuffer`）、入力レベルを持つ。Phase 2 で `SessionController` と `TranscriptStore` に置き換える。

### 4.3 Transcript

- `TranscriptStore`（`@MainActor`、`@Observable`）: 確定セグメントの配列と、現在の未確定テキストを持つ

確定セグメントは届くたびに `transcript.jsonl` へ1行追記する。アプリが異常終了しても、そこまでの文字起こしが残るようにするため。

### 4.4 Notes

- `Notes`: `topics: [Topic]`
- `Topic`: `id`、`title`、`items: [NoteItem]`
- `NoteItem`: `id`、`kind`（`NoteKind`）、`text`、`owner?`、`due?`
- `NoteKind`: `point`（要点）/ `decision`（決定事項）/ `action`（ToDo）/ `question`（未解決の質問）
- `NotesOp`: [notes-ops.schema.json](schemas/notes-ops.schema.json) の1要素に対応する型
- `NotesReducer.apply(_:to:)`: opsをノートに適用する純粋関数。適用できなかったopの一覧も返す
- `NotesStore`（`@MainActor`、`@Observable`）: 現在のノートと、直近に変更された項目ID（ハイライト用）を持つ

IDはアプリが採番する（トピックは `t1`, `t2` …、項目は `i1`, `i2` …）。モデルにIDを作らせると重複や衝突が起きるため。

`NotesReducer` の適用規則:

| op | 動作 | 無視する条件 |
|---|---|---|
| `add_topic` | 末尾にトピックを追加し、仮ID（`new-1` など）を実IDに対応づける | `title` が空 |
| `rename_topic` | タイトルを変更する | `topic_id` が存在しない、`title` が空 |
| `add_item` | 指定トピックの末尾に項目を追加する | `topic_id` が解決できない、`kind` か `text` がない |
| `update_item` | null でないフィールドだけ上書きする | `item_id` が存在しない |
| `remove_item` | 項目を削除する | `item_id` が存在しない |

無視したopは例外にせず、理由とともにログへ残す。1回の応答で適用するopは最大20件とし、超えた分は捨てる（モデルの暴走でノートが埋まるのを防ぐ）。

### 4.5 NotesEngine（ライブ更新）

`NotesEngine`（actor）が、確定セグメントをためて Luna に送り、返ってきたopsを `NotesStore` に適用する。

設計の核は「ノート全体を書き直させず、差分だけを返させる」こと。理由は3つある。

- すでに表示されている箇条書きが、更新のたびに並び替わったり言い換えられたりしない
- 出力が短いので応答が速い
- 出力トークンが少ないので費用が抑えられる

送信の条件（値は設定で変更可）:

- 未送信の確定テキストが120文字以上たまった、または
- 未送信の確定テキストがあり、前回のリクエスト完了から20秒たった
- ただし、前回のリクエスト完了から8秒以内は送らない
- 同時に飛ばすリクエストは1本だけ。応答待ちの間に届いたセグメントは次回にまとめて送る
- 録音停止時は、残りを条件に関係なく送る

失敗時は、送ろうとしたセグメントを未送信のまま保持して次回に再送する。文字起こしはLLMの成否に関係なく続ける。

「要約の送信を一時停止」がオンの間は何も送らない。その間のセグメントは、オフに戻した後も送らない（機微な話題をLLMに送らないための機能なので、後からまとめて送ると意味がなくなる）。該当区間は文字起こしには残る。

Luna への入力（ユーザーメッセージ。JSON文字列）:

```json
{
  "meeting": { "title": "週次定例", "glossary": ["LiveMinutes", "XcodeGen"] },
  "notes": {
    "topics": [
      {
        "id": "t1",
        "title": "リリース日程",
        "items": [
          { "id": "i1", "kind": "point", "text": "テストが2日遅れている", "owner": null, "due": null }
        ]
      }
    ]
  },
  "recent_context": "…直前に送信済みの確定テキスト（最大400文字程度）…",
  "new_transcript": [
    { "t": "00:12:31", "text": "じゃあリリースは来週の水曜に延ばしましょう" },
    { "t": "00:12:38", "text": "佐藤さん、金曜までに告知文を直してもらえますか" }
  ]
}
```

Luna の出力（[notes-ops.schema.json](schemas/notes-ops.schema.json) に従う）:

```json
{
  "ops": [
    { "op": "add_item", "topic_id": "t1", "item_id": null, "title": null, "kind": "decision", "text": "リリースを来週水曜に延期", "owner": null, "due": null },
    { "op": "add_item", "topic_id": "t1", "item_id": null, "title": null, "kind": "action", "text": "告知文を修正する", "owner": "佐藤", "due": "金曜" }
  ]
}
```

システムプロンプトは [live-notes.system.md](prompts/live-notes.system.md)。リクエストごとに変わらないので、常に同じ文字列を先頭に置く（プロバイダ側のプロンプトキャッシュが効きやすくなる）。日時など変わる値をシステムプロンプトに埋め込まない。

長い会議でノートが大きくなった場合の扱いは Phase 6 で入れる（全トピックのタイトルと、直近3トピックの全項目だけを送る）。

### 4.6 MinutesWriter（議事録仕上げ）

`MinutesWriter` が、会議終了時に文字起こし全文とノートを Sol に送り、議事録のMarkdownを受け取る。応答はストリーミングで受け、届いた分から画面に表示する。

- システムプロンプト: [final-minutes.system.md](prompts/final-minutes.system.md)
- 入力: `meeting`（会議名、開始日時、所要時間、glossary）、`transcript`（開始時刻つきの全文）、`notes`
- 出力: Markdown（構造化出力は使わない）
- 結果は `minutes.md` に保存する。作り直しもできる

### 4.7 LLM

- `LLMClient`（protocol）: 構造化出力のリクエストと、テキストのストリーミングリクエストの2つを持つ。`NotesEngine` と `MinutesWriter` はこのprotocolだけに依存する
- `OpenAIResponsesClient`: `URLSession` による実装。外部ライブラリは使わない
- `LLMError`: 認証エラー / レート制限 / サーバーエラー / タイムアウト / 拒否 / 出力不正 を区別する

再試行の方針: 429 と 5xx と通信エラーは、間隔を空けて最大2回まで再試行する。401・400 は再試行しない（設定の誤りなので、画面に出す）。ライブ更新のタイムアウトは30秒。

OpenAI Responses API の想定形（**未確認。§8 を参照し、実装前に公式ドキュメントで確認する**）:

```json
{
  "model": "<ライブ更新用モデルID>",
  "instructions": "<システムプロンプト>",
  "input": "<入力JSONの文字列>",
  "text": {
    "format": { "type": "json_schema", "name": "notes_ops", "strict": true, "schema": { } }
  },
  "store": false
}
```

`store: false` は、応答をOpenAI側に保存させないための指定。

### 4.8 Settings

- `AppSettings`: モデルID（ライブ用・仕上げ用）、認識言語（既定 `ja-JP`）、送信条件の各値、glossary。`UserDefaults` に保存する
- `KeychainStore`: OpenAIのAPIキーをKeychainに保存する

APIキーは `UserDefaults` やファイルには書かない。モデルIDはコードに埋め込まず、設定値として持つ（モデルの世代交代でIDが変わっても、アプリを作り直さずに済むようにするため）。

### 4.9 Persistence

- `SessionRepository`: セッションの作成・一覧・読み込み・削除

保存先は `~/Library/Application Support/LiveMinutes/sessions/<セッションID>/`。

| ファイル | 内容 | 書き込みタイミング |
|---|---|---|
| `meta.json` | 会議名、開始日時、所要時間、状態 | 開始時・終了時 |
| `transcript.jsonl` | 確定セグメント（1行1件） | 確定のたびに追記 |
| `notes.json` | ノート | ops適用のたび |
| `minutes.md` | 議事録 | 生成完了時 |

音声は保存しない。

### 4.10 Session

- `SessionController`（`@MainActor`、`@Observable`）: 1回の会議の進行を束ねる。状態は `idle` → `preparing`（権限確認・モデル準備）→ `recording` ⇄ `paused` → `finishing`（最終確定・残りの送信・議事録生成）→ `finished`

Viewは `SessionController` と各Storeを読むだけにする。依存（`AudioSource`、`TranscriptionEngine`、`LLMClient`、時計）は外から渡せるようにし、テストでは偽物に差し替える。

## 5. 画面

メインウィンドウは2ペイン。

- 左: 文字起こし。確定テキストは通常の色、未確定テキストは薄い色。新しい行が来たら自動で最下部へスクロールする。ユーザーが上にスクロールしている間は自動スクロールを止め、「最新へ」ボタンを出す（Phase 1 は最下部への自動スクロールだけ。止める動作と「最新へ」ボタンは Phase 2）
- 右: ノート。トピックごとに項目を並べ、種類（要点 / 決定 / ToDo / 質問）をバッジで示す。ToDoには担当と期限を添える。追加・更新された項目は数秒間ハイライトする
- ツールバー: 録音開始 / 一時停止 / 停止、経過時間、入力レベル、LLMの状態（更新中 / 待機 / エラー）、「要約の送信を一時停止」トグル、設定
- 終了後: 議事録の表示、Markdownのコピーと保存

色だけに頼らず、種類はラベルの文字でも分かるようにする。

## 6. プライバシーと障害時の動作

- 音声は端末内で処理し、保存も送信もしない
- OpenAIに送るのは確定済みのテキスト、ノート、会議名、glossary
- 「要約の送信を一時停止」中のテキストは送らない（§4.5）
- APIキーがない、またはネットワークがない場合でも、文字起こしだけで動く。ノートペインには理由を表示する
- LLMのエラーで録音や文字起こしを止めない

## 7. ビルドと権限

- Xcode 26 以降、Swift 6（厳格な並行性チェックを有効にする）
- `Package.swift` と `project.yml` のデプロイメントターゲットは macOS 26
- 署名はローカル実行用（Sign to Run Locally）。`project.yml` では `CODE_SIGN_IDENTITY: "-"`、チームなしで表す
- `Info.plist`: `NSMicrophoneUsageDescription`、`NSSpeechRecognitionUsageDescription`。手書きのファイル（`App/Info.plist`）を `INFOPLIST_FILE` で参照する。XcodeGen の `info:` / `entitlements:` キーは、生成のたびにファイルを書き出すので使わない
- entitlements: `com.apple.security.app-sandbox`、`com.apple.security.device.audio-input`、`com.apple.security.network.client`
- ウィンドウは1つだけ（`WindowGroup` ではなく `Window`）。会議は同時に1つしか扱わないため。単一の `Window` は、閉じるとアプリが終了する。録音中に閉じたときの扱いは Phase 2、メニューバー常駐との両立は Phase 6 で決める

並行性の設定（Phase 0 で決めた。途中で変えると挙動が変わるので、アプリとパッケージで揃えて固定する）:

| 項目 | アプリ（`project.yml`） | パッケージ（`Package.swift`） |
|---|---|---|
| 言語モード | `SWIFT_VERSION: "6.0"` | `swift-tools-version: 6.2`、`swiftLanguageModes: [.v6]` |
| 既定のアクター分離 | `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor`（Viewだけなので） | 指定しない（nonisolated）。Store と `SessionController` にだけ `@MainActor` を明示する |
| `NonisolatedNonsendingByDefault` | 有効 | 有効 |
| `InferIsolatedConformances` | 有効 | 有効 |

- Swift 6 モードでは厳格な並行性チェックが常に complete になる。`SWIFT_STRICT_CONCURRENCY` は Swift 5 以下でだけ効く設定なので書かない
- `NonisolatedNonsendingByDefault` が有効だと、nonisolated な async 関数は呼び出し元のアクター上で動く。メインスレッドから呼ばれうる重い処理は、actor に置くか `@concurrent` を付ける
- `swift-tools-version` が 6.2 なのは、`.macOS(.v26)` が使える最小の版だから

コマンドは [AGENTS.md](../AGENTS.md) を参照。

## 8. 未確認事項

設計時点で確認できなかった項目。該当フェーズの最初に実機か公式ドキュメントで確認し、結果をこの表に書き込む。

| # | 項目 | 確認するフェーズ | 確認結果 |
|---|---|---|---|
| 1 | 実機の `SpeechTranscriber.supportedLocales` に `ja-JP` が含まれるか | Phase 1 | 含まれる（2026-11-15、macOS 27.2 / Xcode 27.2 の実機で確認）。対応ロケールは45件で、`supportedLocale(equivalentTo: ja-JP)` も `ja-JP` を返す。この機種では `installedLocales` にも `ja-JP` があり、`assetInstallationRequest(supporting:)` は nil（ダウンロード不要）だった。ただし、その呼び出し前の `AssetInventory.status(forModules:)` は `.supported` で、呼び出し後に `.installed` に変わった。状態の判定に `status` を使わず、§4.2 の手順3どおり `assetInstallationRequest` の結果で判断する |
| 2 | `SpeechAnalyzer` の利用に音声認識の権限（`NSSpeechRecognitionUsageDescription`）が必要か。不要でも Info.plist に入れておいて害はない | Phase 1 | 不要と判断（2026-11-15）。Info.plist も権限要求もない、サンドボックスなしのコマンドラインツールで、日本語の音声ファイルを `SpeechAnalyzer` + `SpeechTranscriber` で最後まで文字起こしでき、許可のダイアログも出なかった。サンドボックス下のアプリでも出ないかは、Phase 1 の人による確認で見る。キーは Info.plist に残す |
| 3 | OpenAI の Sol / Luna の正確なモデルID。設計時は公式サイトに接続できず、第三者の記事では `gpt-6.1-sol` / `gpt-6-luna` と `gpt-5.6-sol` / `gpt-5.6-luna` が混在していた | Phase 3 | 未確認 |
| 4 | Responses API の構造化出力のリクエスト形（§4.7）、応答から出力テキストと拒否を読み取る方法、`store` パラメータ、ストリーミングのイベント名 | Phase 3 | 未確認 |
| 5 | [notes-ops.schema.json](schemas/notes-ops.schema.json) がそのまま strict モードで受理されるか（null を含む `enum` の書き方など） | Phase 3 | 未確認 |
| 6 | Sol / Luna で推論量を下げる指定（応答を速くするため）があるか、その名前 | Phase 3 | 未確認 |
| 7 | 専門用語を音声認識に反映させるAPIの有無と名前 | Phase 6 | 未確認 |
| 8 | システム音声の取り込み方法（Core Audio のプロセスtap など）と必要な権限 | Phase 7 | 未確認 |
