# LiveMinutes 設計書

会議中にMacのマイク音声をリアルタイムで文字起こしし、要点・決定事項・ToDoなどに自動で整理して表示するmacOSアプリ（LiveMinutesは仮称）。

- 対象環境: macOS 26 (Tahoe) 以降、Appleシリコン
- 言語/UI: Swift 6、SwiftUI
- 文字起こし: 端末内（Apple の `SpeechAnalyzer` / `SpeechTranscriber`）
- 整理・要約: OpenAI API。会議中の更新は Luna、終了時の議事録仕上げは Sol。API キーか、ChatGPT のプランでのログインで使う（ログインは [Phase 4B](tasks/phase-4b-chatgpt-sign-in.md)）
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
│   │   └── Resources/           プロンプトとスキーマ（Phase 3 で docs/ から移した）
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
  - `prepare(locale:progress:)`: 手順1〜4（ロケールの確認、モデルの導入、入力形式の決定）。同じロケールで一度成功すれば以後は呼ばない。認識言語は設定（§4.8）で選び、`SessionController` が新しいセッションの開始時に設定のロケールと準備済みのロケールを比べ、違えば `prepare` し直す（エンジンは作り直さない。再開では変えない）。実行中の `prepare` は `alreadyRunning` で断る（ロケールと入力形式が実行中のものと食い違わないように）
  - `start(source:) async throws -> AsyncThrowingStream<TranscriptEvent, Error>`: `AudioSource` を開始し、イベントのストリームを返す。録音中に認識が失敗したら、ソースを止めてからストリームをエラーで終える（マイクを点けたままにしない）
  - `stop()`: ソースを止め、最後の未確定分まで確定させてからストリームを終える
- `AppleSpeechEngine`（actor）: `SpeechAnalyzer` + `SpeechTranscriber` による実装。対象ロケールは `prepare(locale:progress:)` で渡す。設定画面の候補は `AppleSpeechEngine.supportedLocaleIdentifiers()`（BCP 47 の識別子）
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
7. `transcriber.results` を読む。`result.isFinal` が true なら確定、false なら未確定。本文は `String(result.text.characters)`、時刻は `result.range` から取る。空白だけの確定は捨てる。未確定の結果は、直前の未確定結果を置き換える。確定が来たら未確定表示を消す（`TranscriptStore.apply(_:)`）
8. 停止時は、ソースを止めて入力のストリームが閉じるのを待ち、`analyzer.finalizeAndFinishThroughEndOfInput()` を呼ぶ。呼ばないと最後の未確定分が確定されずに失われる。その後、結果の読み取りが終わるのを待つ。最終確定と結果の読み取りの両方に10秒の上限を設け、超えたら `cancelAndFinishNow()` で打ち切る（「確定中」のまま固まらないようにするため）

結果のストリームは、停止操作によらずに終わった場合（エラーの有無とも）も必ずエンジンに知らせ、ソースを止めてからイベントのストリームをエラーで終える。開始処理の途中で終わった場合は、開始そのものを失敗にする。

タイムスタンプは「投入した音声の累積時間」が基準になる（`AnalyzerInput` に `bufferStartTime` は渡さない）。`start` のたびに `SpeechAnalyzer` を作り直すので、時刻は `start` ごとに0から始まる。入力デバイスの切り替え中は音声を流さないので、壁時計の時刻とはわずかにずれる。表示用の時刻は会議開始からの録音経過時間として扱い、一時停止をまたぐ分のずらしは `SessionController` が行う（§4.10）。

### 4.3 Transcript

- `TranscriptStore`（`@MainActor`、`@Observable`）: 確定セグメントの配列と、現在の未確定テキストを持つ。`apply(_:)` で未確定は置き換え、確定は追加して未確定を消す。未確定テキストは頻繁に変わるので、確定セグメントとは別のプロパティにし、未確定の更新で一覧全体を再描画させない。時刻は録音経過時間に直したものを入れる
- `TranscriptExporter`: 書き出し用の整形（テキスト / Markdown）。各行に開始時刻（`HH:MM:SS`）を付け、確定セグメントだけを使う（画面の確定部分と一致させるため）
- `ElapsedTimeFormat`: 録音経過時間の表示（`HH:MM:SS`）

確定セグメントは届くたびに `transcript.jsonl` へ1行追記する。アプリが異常終了しても、そこまでの文字起こしが残るようにするため。

### 4.4 Notes

- `Notes`: `topics: [Topic]` と、採番用の `nextTopicNumber` / `nextItemNumber`（削除した番号を再利用しないため。Phase 4 で LLM に送る JSON には含めない）
- `Topic`: `id`、`title`、`items: [NoteItem]`
- `NoteItem`: `id`、`kind`（`NoteKind`）、`text`、`owner?`、`due?`
- `NoteKind`: `point`（要点）/ `decision`（決定事項）/ `action`（ToDo）/ `question`（未解決の質問）
- `NotesOp`: [notes-ops.schema.json](../LiveMinutesKit/Sources/LiveMinutesKit/Resources/notes-ops.schema.json) の1要素に対応する型
- `NotesReducer.apply(_:to:)`: opsをノートに適用する純粋関数。適用できなかったopの一覧も返す
- `NotesStore`（`@MainActor`、`@Observable`）: 現在のノート、直近に変更された項目ID（ハイライト用。4秒で消える）、ライブ更新の状態（`LiveNotesStatus`: 会議なし / APIキーなし / 待機 / 更新中 / 一時停止中 / 失敗）、「要約の送信を一時停止」のオン・オフを持つ。ノートの正は `NotesEngine` が持ち、適用した結果を `receive(_:)` で受け取る
- `NotesExporter`: ノートの Markdown（トピックを見出し、項目を `- [種類] 本文（担当: …、期限: …）`）

IDはアプリが採番する（トピックは `t1`, `t2` …、項目は `i1`, `i2` …）。モデルにIDを作らせると重複や衝突が起きるため。

`NotesReducer` の適用規則:

| op | 動作 | 無視する条件 |
|---|---|---|
| `add_topic` | 末尾にトピックを追加し、仮ID（`new-1` など）を実IDに対応づける | `title` が空 |
| `rename_topic` | タイトルを変更する | `topic_id` が存在しない、`title` が空 |
| `add_item` | 指定トピックの末尾に項目を追加する | `topic_id` が解決できない、`kind` か `text` がない |
| `update_item` | null でないフィールドだけ上書きする | `item_id` が存在しない |
| `remove_item` | 項目を削除する | `item_id` が存在しない |

無視したopは例外にせず、理由とともにログへ残す（ログには op の種類と理由だけを出し、`title` や `text` は会議の内容なので出さない）。1回の応答で適用するopは最大20件とし、超えた分は捨てる（モデルの暴走でノートが埋まるのを防ぐ）。

Phase 3 で決めた細かい規則:

- 20件の上限は応答の先頭から20件（無視したものも数える）。21件目以降は理由「上限超過」で無視する
- 仮IDは1回の適用の中だけで有効。`topic_id` は、まずこの応答内の仮IDとして解決し、なければ既存のIDとして探す（仮IDが `t1` のように実IDと同じ形でも、同じ応答の `add_topic` を優先する）。同じ仮IDが2回出たら、後の `add_topic` を指す
- `title` と `text` は前後の空白を除き、空白だけなら空として扱う。`update_item` では、null と空のフィールドは変えない。何も変わらなかった `update_item` はハイライトしない
- 同じ応答の中で追加して削除した項目は、変更されたIDに含めない

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

Phase 4 で決めた送信の細則:

- 「前回の完了」の初期値はセッションの開始時刻。したがって最初の送信も開始から8秒以内には行わない
- 1回に送るのは未送信の先頭から約2,000字分まで（セグメント単位）。1回の応答で適用する op は20件までなので、長い障害の後などに一度に送りすぎない。残りは次の周期で送る
- モデルIDと推論量は送信のたびに設定から読む（会議中に設定画面で直したら次の送信から効く）。送信条件の値、会議名、glossary はセッションの開始時の値を使う。送信条件の値は、0や負の値が入っていても間隔なしで送らないよう丸める（最短間隔は1秒以上、最長間隔は最短間隔以上）
- 同時に送るのは1本だけ。応答の適用・`notes.json` の保存・画面への反映を終えてから次の送信を判断する（古い状態が後から届かないように）
- 失敗の扱いは3通り:
  - 一時的な失敗（通信エラー、タイムアウト、レート制限、5xx）: 未送信のまま残し、最長間隔（20秒）たってから送り直す（120字以上たまっていても8秒では送らない）
  - 直らない失敗（APIキーなし、キーチェーンから読めない、認証エラー、権限エラー、利用上限の不足、リクエストの誤り）: 自動では送り直さない（キーの誤りで送り続けたり、キーチェーンのダイアログを繰り返し出したりしないため）。未送信はためておき、ノートペインの「再試行」かAPIキーの保存で再開する。止まっている間は、一時停止をオン・オフしてもエラーと「再試行」の表示に戻す。止まっていないときの「再試行」（APIキーの保存を含む）は、通常の条件で判断する
  - 入力の内容で決まる失敗（拒否、途中で終わった、出力不正、失敗）: 20秒後に送り直す。2回続いたらそのバッチを捨てて先へ進む（同じ入力で繰り返し失敗しうるため）。捨てた分は `recent_context` にも入れず、ノートペインに「一部の発言をノートに反映できませんでした」と出す
- 応答は op 単位で寛容に読む（読めない op だけを捨てる）
- 停止時の残りの送信は、飛行中の応答を待ってから残りを送る。全体で15秒を上限にし、超えたら打ち切る（飛行中はキャンセルし、その結果は適用しない）。送れなかった残りがあれば「一部の発言をノートに反映できませんでした」を出す。アプリの終了時は残りを送らない
- 送るバッチは、送信の直前（状態の報告とモデル設定の読み出しの後）に切り出す。その間に一時停止や終了が入った場合は送らない

「要約の送信を一時停止」がオンの間は何も送らない。その間のセグメントは、オフに戻した後も送らない（機微な話題をLLMに送らないための機能なので、後からまとめて送ると意味がなくなる）。該当区間は文字起こしには残る。

- オンにした時点でまだ送っていない発言も捨てる（機微な話が始まってからトグルを押すことが多く、その冒頭が含まれうるため。2026-11-15 に利用者が決めた）
- オンにした時点で飛行中のリクエストは、最後まで待って結果を適用する（すでに送ってあり、取り消しても秘匿にならないため）。それが失敗して未送信に戻った分は捨てる
- オン中に確定した発言は、`SessionController` が受け取った時点で `NotesEngine` に渡さない（`recent_context` にも入らない）
- 新しい会議を開始するとオフに戻す（2026-11-15 に利用者が決めた）。トグルは会議中（録音中・一時停止中）だけ押せる

Luna への入力（ユーザーメッセージ。JSON文字列）。トップレベルのキーはこの順に手でつなぐ（毎回変わる `new_transcript` を最後に置き、先頭一致で効くプロンプトキャッシュを効きやすくするため）。各部分の中はキーを並べ替えて固定する。ノートは採番用のカウンタを含めず、`owner` と `due` は値がなくても null を明示する。`recent_context` は送信に成功した発言を末尾からセグメント単位で400字に収まるだけ取る（1件で超えるときだけ末尾を切り出す）。`t` は録音経過時間:

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

Luna の出力（[notes-ops.schema.json](../LiveMinutesKit/Sources/LiveMinutesKit/Resources/notes-ops.schema.json) に従う）:

```json
{
  "ops": [
    { "op": "add_item", "topic_id": "t1", "item_id": null, "title": null, "kind": "decision", "text": "リリースを来週水曜に延期", "owner": null, "due": null },
    { "op": "add_item", "topic_id": "t1", "item_id": null, "title": null, "kind": "action", "text": "告知文を修正する", "owner": "佐藤", "due": "金曜" }
  ]
}
```

システムプロンプトは [live-notes.system.md](../LiveMinutesKit/Sources/LiveMinutesKit/Resources/live-notes.system.md)。リクエストごとに変わらないので、常に同じ文字列を先頭に置く（プロバイダ側のプロンプトキャッシュが効きやすくなる）。日時など変わる値をシステムプロンプトに埋め込まない。

長い会議でノートが大きくなった場合の扱いは Phase 6 で入れる（全トピックのタイトルと、直近3トピックの全項目だけを送る）。

### 4.6 MinutesWriter（議事録仕上げ）

`MinutesWriter` が、会議終了時に文字起こし全文とノートを Sol に送り、議事録のMarkdownを受け取る。応答はストリーミングで受け、届いた分から画面に表示する。

- システムプロンプト: [final-minutes.system.md](../LiveMinutesKit/Sources/LiveMinutesKit/Resources/final-minutes.system.md)
- 入力: `meeting`（会議名、開始日時、所要時間、glossary）、`transcript`（開始時刻つきの全文）、`notes`
- 出力: Markdown（構造化出力は使わない）
- 結果は `minutes.md` に保存する。作り直しもできる

### 4.7 LLM

- `LLMClient`（protocol）: 構造化出力のリクエストと、テキストのストリーミングリクエストの2つを持つ。`NotesEngine` と `MinutesWriter` はこのprotocolだけに依存する
- `OpenAIResponsesClient`: `URLSession` による実装（既定は応答をディスクに残さない `.ephemeral`）。外部ライブラリは使わない。`URLSession`、エンドポイント、資格情報（Phase 4B から `CredentialProvider`。API キーか ChatGPT のアクセストークン。§4.11）、再試行の待ち関数は init で渡す（テストでは `URLProtocol` のスタブを入れたセッションを渡す）
- `LLMError`: APIキーなし / キーチェーンから読めない / 認証エラー（401）/ 権限エラー（403）/ 利用上限の不足（429 の `insufficient_quota`）/ レート制限（429）/ サーバーエラー（5xx）/ リクエストの誤り（400・404 など。モデルIDの誤りを含み、API の説明文を持つ）/ タイムアウト / 通信エラー / 拒否 / 途中で終わった（`incomplete`）/ 出力不正 / 失敗（`failed`、error イベント）を区別する。Phase 4B で ChatGPT のプランの利用枠のエラーを足した（§4.11）。画面には日本語の説明を出す
- `LLMResources`: 同梱のプロンプトとスキーマ（`LiveMinutesKit/Sources/LiveMinutesKit/Resources/`）を `Bundle.module` から読む

再試行の方針: 429（`insufficient_quota` を除く）と 5xx と一時的な通信エラー（接続が切れた、ホストにつながらない、DNS の失敗など）は、1秒・2秒の間隔で最大2回まで再試行する。`Retry-After`（秒数か HTTP 日付）があればそれに従い、5秒を超えるなら待たずに失敗として返す（ライブ更新は次の周期で送り直すため）。401・403・400・404 などは再試行しない（設定の誤りなので、画面に出す）。ネットワークにつながっていない場合とタイムアウトも再試行しない。キャンセルは通信エラーとして扱わず、そのまま `CancellationError` で返す。

ストリーミングを読む側の Task がキャンセルされると、`AsyncThrowingStream` はエラーなしで終わる。途中までの結果（議事録など）を完了したものとして保存しないよう、読み終えた後に `try Task.checkCancellation()` を呼ぶ（Phase 5 の `MinutesWriter` で守る）。

タイムアウト: 構造化出力は、再試行を含むリクエスト全体に締め切りを設ける（ライブ更新は30秒）。APIキーの読み出し（キーチェーンの許可ダイアログを待つことがある）は締め切りの前に済ませる。ストリーミングは、応答が始まるまでと差分の間の無通信の時間に上限を設ける（既定180秒。推論中は無通信が続きうるため）。

リクエストの形（2026-11-15 に公式ドキュメントと公式 Python SDK で確認。§8 #4）:

```json
{
  "model": "<ライブ更新用モデルID>",
  "instructions": "<システムプロンプト>",
  "input": [{ "role": "user", "content": "<入力JSONの文字列>" }],
  "store": false,
  "reasoning": { "effort": "low" },
  "text": {
    "format": { "type": "json_schema", "name": "notes_ops", "strict": true, "schema": { } }
  }
}
```

- `store: false` は、応答を OpenAI 側に保存させないための指定（既定では30日保存される）。必ず送る
- `reasoning` は推論量の指定。設定値が空なら送らない（対応していないモデルで 400 にならないように）
- スキーマはリソースのバイト列をそのまま埋め込み、キーの順序を保つ（構造化出力はスキーマのプロパティの順に出力を作るため。`op` を先に書かせる）。他のフィールドは個別にエンコードしてつなぐ
- ストリーミングは `"stream": true` を足し、`instructions` 以降は同じ
- `input` は Phase 4B で、文字列から配列（ユーザーのメッセージ1件）に変える。ChatGPT プランの経路が配列しか受け付けないため。API キーの経路でも意味は同じ（§4.11）

応答の読み方:

- 構造化出力: まず `status`（`failed` なら `error`、`incomplete` なら `incomplete_details.reason`）を見る。次に `output` の type `message` の `content` を見て、type `refusal` があれば拒否、type `output_text` の `text` をすべてつなぐ（推論の項目が先に来るので、message 以外は無視する）。`output_text` をまとめるプロパティは SDK の便利機能で、生の JSON にはない。つないだ結果が JSON として読めなければ出力不正
- エラー応答の本文は `{"error": {"message", "type", "code", "param"}}`。401 の `message` はキーの一部を含むので、表示もログ出力もしない
- 応答の型は寛容に読む（未知の項目や想定外の形のフィールドは無視し、読めるものだけ読む）
- ストリーミング: SSE の `data:` 行の JSON を読む（`event:` 行は使わない。`data: [DONE]` は無視）。行の区切りは CR / LF だけにする（`AsyncBytes.lines` は U+2028 などでも行を切るので使わない）。`URLSession` は `Content-Type` のない応答では中身の判定のために先頭（最大512バイト）を溜めるので、差分がすぐ届くのはサーバーが `Content-Type: text/event-stream` を返す場合（テストのスタブで確認。OpenAI の実際の応答ヘッダは Phase 5 で確かめる）。`response.output_text.delta` の `delta` を順に返し、`response.completed` で正常に終わる。`response.refusal.delta` は拒否、`response.failed` / `response.incomplete` / `error` は失敗。`response.completed` を受けずに切れたら通信エラー。差分を返し始めた後は再試行しない（同じ文が重複するため）。エラー応答（2xx 以外）の本文は SSE ではなく JSON

ログ: `LLMError` は `logSummary`（ケース名、HTTP ステータス、エラーコードだけ）で出す。API の説明文、拒否の文、リクエストや応答の本文、API キーはログに出さない。

### 4.8 Settings

- `AppSettings`（`@MainActor`、`@Observable`）: モデルID（ライブ用 既定 `gpt-6-luna`・仕上げ用 既定 `gpt-6.1-sol`。リクエストには前後の空白を除いた `effectiveLiveModelID` / `effectiveFinalModelID` を使い、接続テストと本番で同じ値にする）、推論量（ライブ用 既定 `low`・仕上げ用 既定 `medium`。画面には出さない）、認識言語（既定 `ja-JP`。BCP 47 にそろえて保存する）、送信条件の各値、glossary、接続方法（`authMethod`。API キー / ChatGPT プラン。Phase 4B）。`UserDefaults` に保存する
- `SecretStore`（protocol）: APIキーの保存先。`KeychainStore` が実装し、テストではメモリ上の実装に差し替える
- `KeychainStore`: OpenAIのAPIキーを、従来のキーチェーン（ログインキーチェーン）に汎用パスワードとして保存する。データ保護キーチェーンは keychain-access-groups とチームの署名が要るので使わない。iCloud への同期はしない。保存は前後の空白と改行を除き、消してから追加する（今のビルドのアクセス権で作り直すため）。「保存済みか」は値を読まずに属性だけで確かめる。キーチェーンの操作は許可ダイアログの間止まるので、メインスレッド以外で行う
- `ConnectionTest`（`@MainActor`、`@Observable`）: 設定画面の「接続テスト」。ライブ更新用のモデルに、ノートのスキーマを使う構造化出力を1回求め、APIキー・モデルID・スキーマの受理をまとめて確かめる

- `CachingSecretStore`: 最初に読めたAPIキーをプロセス内（メモリ）に持つ包み。ライブ更新は8〜20秒ごとに送るので、毎回キーチェーンを読むと、ad-hoc 署名でビルドし直した後に許可ダイアログが繰り返し出うるため。同時の最初の読み出しは1本にまとめ、失敗はキャッシュしない。読み出しの途中で保存・削除・破棄があった場合は、読んだ値をキャッシュしない（削除したキーがメモリに戻らないように）。保存したら保存した値を持ち、削除したら捨てる。401 を受けたら捨てる（`OpenAIResponsesClient` の `onAuthenticationFailure`）。設定画面と LLM クライアントで同じものを使う

APIキーは `UserDefaults` やファイル、ログには書かない。起動時には読まず、最初に必要になったときにキーチェーンから読んでメモリに持つ。会議の開始時にキーがあるか（`hasAPIKey()`、値は読まない）を確かめ、なければライブ更新を動かさない。会議中にキーを保存すると、その時点からライブ更新を始める（それまでの発言は送らない）。モデルIDはコードに埋め込まず、設定値として持つ（モデルの世代交代でIDが変わっても、アプリを作り直さずに済むようにするため）。

ad-hoc 署名なので、ビルドし直した後の最初の読み出しで、キーチェーンのアクセス許可ダイアログが出ることがある（署名が変わるため）。

### 4.9 Persistence

- `SessionRepository`（actor）: セッションの作成・一覧・読み込み・削除。Phase 2 で作るのは作成、`meta.json` の読み書き、`transcript.jsonl` の追記と読み込み。一覧・削除は Phase 5 で足す。保存先のフォルダは init で渡す（テストでは一時フォルダを渡し、実際の保存先に書かない）
- `SessionMeta`: `id`、`title`（会議名）、`startedAt`（録音を始めた日時）、`duration`（一時停止を除く録音時間。終了時に書く）、`status`（`recording` / `finished`）。`status` が `recording` のまま残っていれば異常終了したセッションで、Phase 5 でそう扱う

保存先は `Application Support/LiveMinutes/sessions/<セッションID>/`。アプリは App Sandbox で動くので、実際の場所は `~/Library/Containers/<バンドルID>/Data/Library/Application Support/LiveMinutes/sessions/` になる（バンドルIDは今は仮の `com.example.LiveMinutes`。変えると保存先も変わる）。セッションIDは UUID。

- フォルダは文字起こしの開始に成功してから作る（失敗した開始で空のフォルダを残さない）。作成時に空の `transcript.jsonl` も作る
- `transcript.jsonl` は1行に `TranscriptSegment` の JSON を1件ずつ書く。セッション中はファイルを開いたままにし、行と改行を1回の書き込みで追記する。fsync はしない（書き込んだデータはカーネルに渡っているので、アプリが強制終了しても残る。失われるのは電源断などの場合だけ）
- 読み込みは、ファイルをバイト列のまま改行で分け、行ごとにデコードする。デコードできない行（異常終了で途中まで書かれた最後の行など）は飛ばす。ファイル全体を文字列にすると、最後の行がマルチバイト文字の途中で切れていたときに全体の変換に失敗するため
- 末尾が改行で終わっていないファイルに追記するときは、先に改行を足す
- `meta.json` はアトミックに書き換える。日時は ISO 8601

| ファイル | 内容 | 書き込みタイミング |
|---|---|---|
| `meta.json` | 会議名、開始日時、所要時間、状態 | 開始時・終了時 |
| `transcript.jsonl` | 確定セグメント（1行1件） | 確定のたびに追記 |
| `notes.json` | ノート（採番カウンタを含む） | ops適用でノートが変わるたび（アトミックに書き換える） |
| `minutes.md` | 議事録 | 生成完了時 |

音声は保存しない。

### 4.10 Session

- `SessionController`（`@MainActor`、`@Observable`）: 1回の会議の進行を束ねる。状態は `idle` → `preparing`（権限確認・モデル準備）→ `recording` ⇄ `paused` → `finishing`（最終確定・残りの送信・議事録生成）→ `finished`

Viewは `SessionController` と各Storeを読むだけにする。依存（`AudioSource`、`TranscriptionEngine`、`MicrophonePermission`、`SessionRepository`、時計、Phase 3 以降は `LLMClient`）は外から渡せるようにし、テストでは偽物に差し替える。

Phase 2 で決めたこと:

- **許されない操作は無視する**。開始は `idle` と `finished` のときだけ（`finished` から開始すると新しいセッション）、一時停止は `recording`、再開は `paused`、停止は `recording` と `paused` のときだけ受け付ける
- **操作は1つずつ**。開始・一時停止・再開・停止は処理中（`activity`）を持ち、その間はほかの操作を無視する。公開する状態は上の6つのままにし、「一時停止の確定中」「再開中」は `activity` で表す
- **一時停止は `TranscriptionEngine.stop()`、再開は `start(source:)`**。一時停止の時点で未確定分まで確定でき、マイクも止まる。`SpeechAnalyzer` を生かしたままソースだけ止める案は、入力のない analyzer を長く生かしたときの挙動が未確認なので採らない。再開時に analyzer を作り直す時間がかかる
- **再開後の時刻のずらし**: エンジンの時刻は再開のたびに0から始まるので、再開後のセグメントには `max(一時停止時点の録音経過時間, 直前の区間の最後の確定の end)` を足してから表示・保存する。録音経過時間を基準にするのは表示中の経過時間と揃えるため、下限を付けるのは停止を押してからマイクが止まるまでの分だけ確定の end が経過時間を超えることがあるため。ずらし幅はイベントを読む Task を作るときに決めて渡す
- **録音経過時間**は録音区間の合計で、一時停止中は進まない。時計はスリープ中に進まないもの（`SuspendingClock`）を使う（スリープ中はマイクも止まるため）
- イベントを読む Task の中で、`TranscriptStore` への反映と `transcript.jsonl` への追記を1件ずつ順に行う（保存の順序を保つため、別の Task に投げない）
- 追記に失敗しても文字起こしは続け、警告を1回だけ表示する。セッションのフォルダを作れない場合は、開始そのものを失敗にする
- **セッションの終了処理は1か所**（停止操作・認識の失敗・アプリの終了のどれからも通る）。最初の await より前に「現在のセッション」を消して二重に走らないようにし、イベントの Task はキャンセルせずストリームの終わりを待つ。順序は、最終確定 → `meta.json` に `duration` と `finished` を書く → `transcript.jsonl` を閉じる → ノートの残りを送る（Phase 4。上限15秒）→ `finished`。保存をノートの待ちより先に済ませるのは、ノートを待っている間に終了しても `meta.json` を `finished` にしておくため
- **ライブ更新との接続**（Phase 4）: セッションの開始時に `NotesEngine` を作る（APIキーがなければ作らず、ノートペインに案内を出す）。確定セグメントは、`TranscriptStore` への反映と `transcript.jsonl` への追記の後に `NotesEngine` へ渡す（一時停止トグルがオンなら渡さない）。アプリの終了時は、まず `NotesEngine` を止め（停止処理がノートの送信を待っている最中でもすぐ抜けるため）、残りは送らない
- 録音中に認識が失敗したら、そこまでを保存して `finished` に移り、問題を表示する（書き出しはできる）。再開に失敗したら `paused` のまま問題を表示する。認識の失敗と一時停止の操作が重なり、一時停止が先に通った場合も同じく `paused` のまま問題を表示する（再開か停止を選べる）。停止して保存できたら、こうした案内は消す。`finished` から開始に失敗したら、`finished` と前回の文字起こしを残す
- **アプリの終了**（Cmd+Q、ウィンドウを閉じる、Dock から終了）: `NSApplicationDelegate.applicationShouldTerminate` で、処理中の操作か録音中・一時停止中のセッションがあれば `.terminateLater` を返し、処理中の操作を待ってから停止して保存を終え、終了する。最終確定は最大10秒かかるので、12秒で打ち切って終了する（その場合 `meta.json` は `recording` のまま残る。再開の処理中に終了すると、再開の完了を待ってから最終確定に入るので、12秒を超えることがある。確定済みの分は `transcript.jsonl` に残っている）。確認ダイアログは出さない

### 4.11 ChatGPT でのログイン（Phase 4B）

API キーの代わりに、ChatGPT の有料プランの利用枠で OpenAI を使えるようにする（「Sign in with ChatGPT」の ChatGPT plan usage）。API キーの方式は残し、設定画面でどちらを使うかを選ぶ。

前提（2026-11-16 に公式文書で確認。developers.openai.com/siwc の Overview・Registration and sign-in・Accounts and sessions・Models and inference・Token reference・Errors and recovery・Preview limitations・UI/UX guidelines、cookbook の記事「Integrating Sign in with ChatGPT in your open-source app」、ヘルプ記事「Using your ChatGPT plan in other apps and sites」、`https://auth.openai.com/.well-known/openid-configuration`。文書の取得は要約を通したので、実装の最初に原文で確かめ直す）:

- cookbook に「ChatGPT plan usage is available to open-source projects, personal projects that run locally, and selected private apps」とある。LiveMinutes は自分の Mac で動かす個人用のアプリなので、対象と解釈する（対象の条件は文書で細かく定義されていない）。配布や有料化をするなら、OpenAI への申請（interest form）が要る
- 使えるプランは、ヘルプ記事では Go / Plus / Pro / Business、開発者向けの文書では Plus / Pro。プランやアプリごとの上限に達すると止まり、従量課金には切り替わらない
- アプリが受け取るのは OAuth のトークンだけ。API キーや ChatGPT の会話は渡らない

#### ログインの流れ

OAuth 2.0 と OpenID Connect。PKCE を使う公開クライアントで、クライアントの秘密はない。クライアントは最初のログインの中で登録される（動的登録）。発行される `client_id` は、ChatGPT のアカウント（ワークスペース）ごとの登録で、同じアカウントの次のログインでも使い回す。

1. **ホストID**: 最初のログインの前に作って `UserDefaults` に保存し、以後は同じ値を送る。形式は `urn:uuid:<UUID>`（文書の例の形。形式の決まりはない）。文書の指示により、認証情報として扱わず、メールアドレスなど利用者を識別できる値は使わない
2. **待ち受け**: `127.0.0.1` でコールバックの待ち受けを始めてから、ブラウザを開く（`localhost` は使わない、という指示）。ポートはまず 1455（文書の例）を試し、使えなければ OS に選ばせる。1455 は Codex CLI のログインでも使われるので、この切り替えは実際に起こる。パスは `/auth/callback`。2回目以降はポートが変わってよいと文書にある。初回の登録で 1455 以外でよいかは未確認（§8 #12）
3. **ブラウザで認可**: 既定のブラウザで `https://auth.openai.com/api/accounts/authorize` を開く。パラメータは次のとおり

   | パラメータ | 値 |
   |---|---|
   | `client_id` | 初回は `dynamic_agent_client`、2回目以降は発行された ID |
   | `agent_name_hint` | `LiveMinutes`（初回だけ） |
   | `ext_agent_host_id` | ホストID |
   | `id_token_hint` | 2回目以降で、前回のログインの ID トークンを持っていれば付ける（期限切れでもよい）。ログアウトの後は付けない |
   | `response_type` | `code` |
   | `redirect_uri` | `http://127.0.0.1:<ポート>/auth/callback` |
   | `scope` | `openid profile email offline_access resource.invoke chatgpt.tokens.use.direct` |
   | `resource` | `https://api.openai.com/v1` |
   | `state`、`nonce` | 毎回新しい乱数 |
   | `code_challenge_method`、`code_challenge` | `S256`、検証子の SHA-256 を base64url（パディングなし）にしたもの |

   任意の `login_hint`（メールアドレス）は送らない（メールアドレスを URL に載せないため）
4. **コールバック**
   - `state` が一致しない要求には 400 を返し、待ち続ける。ほかの Web ページやプロセスも `127.0.0.1` に要求を送れるので、ここでログインを失敗にすると妨害できてしまうため
   - `state` が一致して `error=access_denied` などがあれば、交換せずに終える
   - 初回は `client_id`（`oaiapp_…`）を受け取る。初回なのに `client_id` がなければ登録は完了していないものとして扱い、`dynamic_agent_client` を発行済みの ID として保存しない
   - 2回目以降は `client_id` がないこともある。あって保存済みの値と違えば拒否する
   - 受け取ったら、コードを含まないパス（`/auth/done`）へ 302 で移し、そこで「ブラウザでの手続きが終わりました。このタブを閉じて、LiveMinutes で結果を確認してください」を返す（アドレスバーと履歴にコードを残さないため。この後の交換や検証が失敗することもあるので、成功とは書かない）。ログインに成功したら、アプリを前面に出す
   - 決めたパス以外（favicon など）には 404、GET 以外には 405 を返して待ち続ける
   - 待ち受けは5分で打ち切る。設定画面のキャンセルでも止められる。同時に進めるログインは1つだけで、もう一度始めたら前のものをキャンセルし、その待ち受けが閉じてから始める
   - 待ち受けを閉じるのは、コールバックを受け取った場合だけ3秒後（完了のページを返し終えるため）。失敗やキャンセルではすぐ閉じる（1455 をつかんだままにしない）
   - ログインの途中の値（検証子、`state`、`nonce`）はメモリにだけ持ち、保存しない。成功するまでは何も保存しないので、途中でアプリを終了しても何も残らない
5. **コードの交換**: `https://auth.openai.com/api/accounts/oauth/token` に form 形式で送る（`grant_type=authorization_code`、`client_id`、`code`、`code_verifier`、認可と同じ `redirect_uri` と `resource`）。`invalid_grant` ならコードを捨てて、最初からやり直してもらう
6. **ID トークンの確認**: 文書の指示どおり、署名を OpenAI の JWKS で検証する
   - `jwks_uri`（`https://auth.openai.com/.well-known/jwks.json`）から鍵を取り、ヘッダの `kid` で選ぶ。知らない `kid` なら1回だけ取り直す
   - `alg` は RS256 だけを受け付ける（openid-configuration の `id_token_signing_alg_values_supported`）。`none` や HS256 は拒否する
   - 鍵は JWK の `n` と `e` から PKCS#1 の DER を組み立て、`SecKeyCreateWithData` で作る。検証は `SecKeyVerifySignature`（`.rsaSignatureMessagePKCS1v15SHA256`）。CryptoKit には RSA がないので Security.framework を使う（OS の標準なので、外部ライブラリには当たらない）
   - クレームは次を確かめる: `iss` が `https://auth.openai.com`、`aud` が発行された `client_id`（文字列でも配列でも受ける）、`exp` が過ぎていない（時刻のずれとして60秒まで許す）、`nonce` が送った値と同じ
   - アカウントは検証した `sub` で識別する
7. **アカウントの一致**: 保存済みの `client_id` でログインし直して、`sub` が前回と違えば拒否し、何も保存しない（文書の指示: 選んだアカウントの登録を置き換えない）。別のアカウントに替えるときは、設定画面の「別のアカウントでログイン」で新しく登録し直す（保存済みの登録を使わず `dynamic_agent_client` で始め、成功したら記録ごと置き換える）。アカウントは1つだけ扱う
8. **スコープの確認**: トークンの応答で付与されたスコープ（`scope`）に `chatgpt.tokens.use.direct` があるかを確かめる。ID トークンだけでは、プランの利用は許可されていないため。`scope` が応答にない場合も、許可されていないものとして扱う（文書に記載がないので、安全な側に決めた）。許可されていなければ、ログインは残すが「プランの利用が許可されていない」と表示し、リクエストは送らない。もう一度ログインして許可するか、API キーに切り替えるかを選んでもらう。許可し直すログインには `prompt=consent` を付ける（Errors and recovery: 同意の画面を出させる。`force_reconsent=true` は OpenAI が導入を知らせてから使うもので、それまでは `prompt=consent` が使える。`id_token_hint` を付けると同意の画面が省かれるため）

#### トークン

- アクセストークンの有効期間は1時間（`expires_in: 3600`）。リフレッシュトークンは30日で、更新のたびに新しい30日のものに置き換わる
- **期限の判定**は壁時計（`Date`）で行う。`SuspendingClock` で測ると、スリープから復帰した後に期限切れを見逃すため
- **更新の時機**: 期限の5分前を過ぎていたら、リクエストの前に更新する。トークンの応答には `earliest_refresh_at` もある（Token reference。意味と形の説明はない）。これより前は、期限まで30秒を切るまで更新を控える。形が分からないので、Unix 秒（数値か数字の文字列）と ISO 8601 の両方を読み、読めなければ無視する
- **更新の送り方**: token エンドポイントに `grant_type=refresh_token`、保存した `client_id`、`refresh_token`、`resource` を送る。`scope` は送らない
- **更新は1本にまとめる**。2本同時に走ると、使用済みのリフレッシュトークンを送って失敗するため。actor の再入に備え、最初の await より前に、走っている更新があるかを確かめて登録する
- **更新は待つ側のキャンセルや締め切りで打ち切らない**。`ChatGPTAuth` が持つ独立した Task で走らせ、最後まで終えて保存する。途中で打ち切ると、サーバー側では置き換えが済んでいるのに新しいリフレッシュトークンを受け取れず、次は再利用のエラーになってログインし直しになるため
- **保存の順序**: 新しいトークンは、使う前にキーチェーンへ保存する。保存に失敗したら、新しいトークンをメモリで使い続け、警告を出し、次の機会に保存し直す（捨てるとログインし直しになるため）
- **別のプロセスとの競合**: デバッグ版とビルド済みの版を同時に起動すると、同じキーチェーンの項目を2つのプロセスが使う。プロセス間のロックは作らず、次の2つで防ぐ
  - 更新の直前にキーチェーンを読み直す。同じ登録で、メモリより期限の新しいトークンがあれば、更新せずにそれを使う。保存に失敗している間（キーチェーンの方が古い）は読み直さない
  - 更新が終端のエラーを返しても、キーチェーンに失敗したものと違うトークンがあれば、消さずにそれで1回だけやり直す
- **更新の失敗**
  - `invalid_grant`、`invalid_refresh_token`、`token_expired`、`refresh_token_expired`、`refresh_token_invalidated`、`refresh_token_reused` のとき: 上のやり直しをしたうえで、トークンを捨て、「もう一度ログインが必要」にする
  - `invalid_client` のとき: 設定の誤りとして表示する。ログインし直させない
  - 通信エラー・429・5xx のとき: トークンを捨てない（429 はレート制限として表示する）
  - 終端のエラーでトークンを捨てるときも、ID トークンは残す（ログインし直すときの `id_token_hint` に使う。消すのはログアウトのときだけ）
- **保存**: キーチェーンに1項目だけ置く（文書の例は「所有者だけが読めるファイル（0600）」だが、より守られるキーチェーンにした）。API キーとは別の service 名にし、JSON で `client_id`、`sub`、メールアドレス、`refresh_token`、`access_token`、期限、付与されたスコープ、`id_token`（次のログインの `id_token_hint` に使う）を入れる
  - 「トークンを捨てる」は、項目を消すことではない。`client_id` と `sub` を残し、トークンだけを除いて書き換える（次のログインでアカウントの一致を確かめるため）
  - 書き換えは `SecItemUpdate` を先に試し、項目がなければ追加する。消してから追加する方式は、その間にアプリが落ちるとログインし直しになるため。1時間ごとに書き換えるので、ここは避ける
  - 読めたものはメモリにも持つ（`CachingSecretStore` と同じ理由）。起動時には読まず、設定画面で ChatGPT プランを表示したときか、最初にリクエストを送るときに読む（API キーで使う人にも許可ダイアログが出ないように）。同時の最初の読み出しは1本にまとめる
  - キーチェーンへの保存は、前の保存の後につなぐ（2つの保存の到着順が入れ替わり、古い記録で上書きしないように）。更新の結果は、保存する時点のメモリの記録を書く
  - キーチェーンを読めない場合（許可ダイアログで拒否されたなど）は「未ログイン」と区別し、上書きも削除もしない。ad-hoc 署名なので、ビルドし直した後はこの項目でも許可ダイアログが出る
- **書かない場所**: トークン、認可コード、PKCE の検証子を、`UserDefaults`、ファイル、ログに書かない。URL に載るのは、プロトコルで決まっているものだけにする（コールバックの `code` と、認可の `id_token_hint`）。ホストIDは秘密ではないので `UserDefaults` に置く
- **ログアウト**
  1. 新しいリクエストと新しい更新を止める。送信中の1本は、古いアクセストークンのまま終わることがある
  2. 走っている更新があれば、終わるのを待つ（上限10秒）。最新のリフレッシュトークンを取り消すため。上限の後に終わった更新の結果は使わず、受け取った新しいリフレッシュトークンも取り消す
  3. トークンと `id_token` を除いて書き換える。`client_id`、`sub`、ホストIDは残す。書き換えられなければ項目ごと消す。取り消しより先に消すのは、取り消し（時間がかかりうる）の間にアプリを終了してもトークンを残さないため（リフレッシュトークンはメモリにだけ残して取り消しに使う）
  4. `revocation_endpoint`（`https://auth.openai.com/api/accounts/oauth/revoke`）に、`token`、`token_type_hint=refresh_token`、`client_id` を送る。中身が空の 200 が返れば成功（すでに無効なトークンでも 200 になる）。通信エラーや 5xx のときは、間隔を空けて最大2回まで送り直す
  5. 取り消しを確かめられなかった場合は、その旨と、ChatGPT の設定からこのアプリを切断できることを表示する
  6. キーチェーンを読めない場合は、取り消しも消去もできないので、「取り消しを確かめられなかった」と返し、読めない状態のままにする
- **世代**: ログイン・ログアウト・キャンセルのたびに世代を進め、古い世代のログインや更新の結果は保存しない

#### リクエスト

プランの利用枠で送る場合の制限（Preview limitations・Models and inference）:

- エンドポイントは API キーのときと同じ `https://api.openai.com/v1/responses` で、`Authorization: Bearer <アクセストークン>` を付ける
- `store: false` と `stream: true` が必須。`input` は配列で送る（`[{"role": "user", "content": "…"}]`）。`instructions` は使える
- `max_output_tokens`、`temperature`、`metadata`、`user` などは使えない。今のアプリはどれも送っていない
- **構造化出力（ライブ更新）もストリーミングで送る**。差分は外に出さず、`response.completed` までためて、つないだものを今と同じ規則で JSON として読む。差分を外に出さないので、通信が途中で切れたときは今の再試行をそのまま使える。締め切り（ライブ更新は30秒）は今と同じく、再試行を含む全体にかける。`URLRequest` の無通信のタイムアウトは締め切り＋5秒にする
- 構造化出力（`text.format` の `json_schema`）と `reasoning.effort` が使えるかは、文書に書かれていない（§8 #9）。構造化出力は自動の代わりの手段を用意せず、使えなければ使えなかったパラメータ（`error.param`）を表示して止める。strict のスキーマがないと、ノートの更新の前提が崩れるため。`reasoning` は画面で変えられない設定なので、ChatGPT のときに限り、`param` が `reasoning` で始まる 400 を受けたら `reasoning` を外して1回だけ送り直し、そのプロセスの間、そのモデルでは外したままにする（もう一方のモデルには影響させない）（文書の回復手順「使えないものを外す。同じ内容では送り直さない」に沿う）
- 資格情報を先に取得し、それに合わせてボディを組み立てる（ChatGPT のときだけ `stream: true` になるため）
- API キーの方式でも `input` を配列にそろえる（組み立てを1つにするため。意味は同じ）。構造化出力を API キーで送るときは、今までどおりストリーミングにしない
- **モデル一覧**: 同じトークンで `GET https://api.openai.com/v1/models` を呼ぶ。応答は `models` 配列（API キーのときの `data` とは違う）で、各項目の `slug`・`display_name`・`visibility` を読み、`visibility == "list"` のものを使えるモデルとする。使い道は接続テストの補助だけ（設定したモデルIDが一覧にあるかを表示する）。一覧の取得や読み取りに失敗しても、接続テスト全体は失敗にしない。接続テストの本体は、今と同じ構造化出力のリクエスト

#### エラー

`error.code` から `LLMError` への対応付けは1つの関数にまとめ、HTTP のエラー応答、ストリームの途中の `response.failed`、`error` イベントの3か所で共有する。

| コード | HTTP | 扱い |
|---|---|---|
| `subscription_sharing_usage_limit_exceeded` | 429 | 使用量の上限。一般の 429（再試行の対象）より先に判定する。自動で送り直さず、ライブ更新を止める。「使用量を管理」へのリンクを出す。回復する時刻は推測しない（アプリ別の上限のこともあるため） |
| `subscription_sharing_usage_unavailable`、`subscription_sharing_user_unavailable` | 503 | 一時的。間隔を空けて送り直す（今の 5xx と同じ） |
| `subscription_sharing_user_not_eligible` | 403 | プランの対象外。止めて理由を出す。ログインをやり直させない |
| `subscription_sharing_invalid_user` と、そのほかの 401 | 401 | 下の「401 の扱い」 |
| `chatpass_v2_scope_not_authorized`、`chatpass_v2_invalid_authorization_context`、`subscription_sharing_route_not_supported` | 403 | 設定の誤り。止めて表示する |
| `subscription_sharing_unsupported_capability` | 400 | `error.param` を表示して止める。同じ内容では送り直さない（`reasoning` の例外は上） |
| コードのない 401 / 403 / 503 | | ストリームが始まる前の失敗は、本文が `{"detail": "…"}` のことがある（文は診断用で、決まったコードではない）。ステータスだけで分類する |
| `server_error`、`rate_limit_exceeded` などの一般のコード | | ストリームの途中で届いても、一時的な失敗として扱う（ノートの発言を捨てる対象にしない） |

**401 の扱い**: アクセストークンを1回だけ更新して送り直す（文書にはない、設計で決めた手順）。

- 更新できたのにまた 401 なら、トークンは捨てずにライブ更新を止め、理由を表示する。「再試行」と「ログインし直す」を出し、どちらにするかは利用者が選ぶ
- トークンを捨てて「もう一度ログインが必要」にするのは、更新が終端のエラーを返したときだけにする（文書の指示: ログインし直してもらうのは、取り消しを確かめたときか、更新が終端のエラーになったときだけ）
- 401 の送り直しは、今の再試行の回数（最大2回）とは別に数える。構造化出力とストリーミングの両方に入れる。ストリーミングで差分を外に出した後は、401 でも `reasoning` でも送り直さない（文が重複するため）
- 送り直すときに資格情報の種類が変わっていたら（リクエストの途中で接続方法が変わった）、送り直さずに失敗にする

ストリームの途中でも届くことは、Models and inference に書かれている（「usage-limit error can arrive as `response.failed` with `subscription_sharing_usage_limit_exceeded` or `subscription_sharing_usage_unavailable` after streaming has begun」。2026-11-16 に原文で確認）。ほかのコードがストリームの途中で届くかは書かれていないが、両方で同じに扱っておく（害はない）。

`LLMError` に、使用量の上限・要ログイン・プランの対象外・使えないパラメータの4つを足す。今の `.authentication`（「API キーが正しくありません」）は資格情報の種類ごとに文言を分ける。`NotesEngine` の分類では、4つとも「時間をおいても直らない失敗」として止める。止まったら「再試行」か、ログインし直しで再開する。

#### コードの形

- `LLMCredential`（enum）: `.apiKey(String)` / `.chatGPTPlan(accessToken: String)`。文字列にしても値が出ないようにする（`description` で伏せる）
- `CredentialProvider`（protocol）: 次の2つを持つ。`OpenAIResponsesClient` は API キーの読み出し関数の代わりにこれを受け取る
  - 今の資格情報を返す
  - 401 を受けたときに、失敗した資格情報を渡して呼ぶ。新しい資格情報で1回だけ送り直す価値があれば true を返す
    - API キーでは、今と同じくキャッシュを捨てて false を返す
    - ChatGPT では、今のトークンがすでに別のものなら更新せずに true を返す（接続テストとライブ更新が同時に 401 を受けて、2回続けて更新するのを防ぐため）。そうでなければ更新して、更新できたら true を返す
- `CredentialRouter`: リクエストのたびに設定の接続方法を読み（`AppSettings` は `@MainActor` なので、`modelSelection` と同じく MainActor のクロージャで読む）、`CachingSecretStore` か `ChatGPTAuth` から資格情報を返す。401 の知らせは、送った時点の方式の担当へ渡す
- `ChatGPTAuth`（actor）: ログインの状態（未ログイン / ログイン中 / ログイン済み / 要ログイン）を持つ。ログインの開始（開く URL と完了を待つ処理を返す）、キャンセル、ログアウト、アクセストークンの取得（期限が近ければ更新）、ID トークンの検証を受け持つ。外から渡すもの: `URLSession`、壁時計、トークンの保存先（protocol。キーチェーン版とメモリ版）、ホストIDの保存先、乱数
- `LoopbackCallbackServer`: Network.framework の `NWListener` を使う
  - `127.0.0.1:<ポート>` だけに結び付ける（`::1` や全インターフェースには結び付けない）
  - ポートが使用中のとき、`NWListener` は失敗ではなく待ちの状態になることがあるので、状態の変化で両方を見て、OS に選ばせるポートに切り替える。OS に選ばせたときは、待ち受けの準備ができてからポートを読み、`redirect_uri` を作る
  - 接続ごとに並行して処理し、接続ごとに数秒のタイムアウトを置く（ブラウザは何も送らない接続を先に張ることがあり、それで受け付けが詰まらないようにする）
  - 要求は CRLF CRLF まで読み、16KB で打ち切る（1回の受信に収まらないことがある）。パスは完全一致、クエリは `URLComponents` で解く
  - 応答には `Content-Length`、`Connection: close`、`Content-Type: text/html; charset=utf-8`、`Cache-Control: no-store` を付け、送り終わってから接続を閉じる
  - `NWListener` の呼び出しは DispatchQueue の上で来るので、完了の知らせが二重にならないようにし、キャンセルと5分の打ち切りを1か所で扱う
  - 具体的な API は SDK のヘッダで確かめてから使う
- **form と URL のエンコード**: 認可 URL のクエリ、token と revoke の本文は、RFC 3986 の予約されていない文字（英数字と `-._~`）だけを残し、ほかはすべて `%XX` にする自前のエンコードにする。`URLComponents` は `+` をエンコードしないため、トークンやコードに `+` が含まれると form の本文で壊れる
- `AppSettings.authMethod`: `apiKey`（既定）/ `chatGPTPlan`。`UserDefaults` に保存する
- `LiveNotesFactory` の「設定済みか」は、接続方法ごとに判断する。API キーなら「保存済みか」、ChatGPT なら「ログイン済みで、プランの利用が許可されているか」
- `SessionController.apiKeyDidChange()` は `credentialsDidChange()` に改める。キーの保存と削除・ログイン・ログアウト・接続方法の変更のどれでも呼ぶ
- 会議中に接続方法を切り替えても、エンジンは作り直さない（`credentialsDidChange` から `retryNow`）。設定されていない方へ切り替えたら、次の送信が「要ログイン」か「キーなし」で止まり、案内を出す。未設定の案内（`notConfigured`）の文言は、接続方法ごとに分ける
- ブラウザを開くのは App 側（`NSWorkspace.shared.open`）。PKCE の SHA-256 は CryptoKit、乱数は `SecRandomCopyBytes` を使う（どちらも OS の標準）
- entitlements に `com.apple.security.network.server` を足す（サンドボックスでは、ループバックでも待ち受けにこれが要るため）

#### 実装で決めたこと（4B-1、2026-11-16）

- `NotesEngine` の失敗の分類に、新しいエラーを入れた（`LLMError` の switch が網羅を求めるため、4B-2 を待たずに入れた）。`planUsageUnavailable` だけを一時的、残りを「時間をおいても直らない失敗」とした。ストリームの途中の一般のコード（`server_error` など）の扱いは 4B-2 で決める
- 設定画面が読む状態は `ChatGPTAccount`（`@MainActor`、`@Observable`）に持たせた。`ChatGPTAuth` の状態の変化を `AsyncStream` で受ける（順序が入れ替わらないように）。更新の失敗で要ログインになったときも、ライブ更新に知らせる
- ログインの成功後に、アプリを前面に戻す（`NSApplication.activate()`）
- ログアウトでトークンを除いた記録を書き換えられなかったときは、トークンを残さないよう項目ごと消す（`client_id` の対応は失われるが、次のログインは新しい登録になるだけ）
- 文書は複数のアカウントを扱うよう勧めている（Accounts and sessions）が、範囲外のまま1つだけ扱う
- キーチェーンを読めない場合でも、利用者がログインを選んだら新しい登録として上書きする（「読めない場合は上書きも削除もしない」の例外。利用者の操作なので）
- 構造化出力の締め切り（30秒）の中で 401 からトークンの更新に入ると、更新は打ち切らないので、締め切りを最大30秒ほど超えることがある。最初の資格情報の取得（キーチェーンの読み出しや期限切れの更新）は締め切りの外で行う
- 4B-1 の時点では、`LiveNotesFactory` はまだ API キーの有無でライブ更新を動かすかを決める（4B-2 で接続方法ごとに直す）。そのため、ChatGPT プランを選んでいて API キーも保存してあれば、ライブ更新は ChatGPT の経路で流れる。API キーがなければ「API キーがない」の案内になる

#### 進め方

構造化出力が ChatGPT プランで使えるか（§8 #9）で後半の前提が変わるので、2段に分け、間に人による確認を挟む。

1. **4B-1**: 認証（ログイン・更新・ログアウト・ID トークンの検証）、資格情報の抽象、`OpenAIResponsesClient` の変更、エラーの対応付け、接続テストとモデル一覧、設定画面のログインの部分
2. **人による確認**: ログインと接続テスト（§8 #9・#10・#12）
3. **4B-2**: `NotesEngine` と `LiveNotesFactory` の統合、ノートペインの表示、最初のログインのときの案内

API キーでの接続テスト（§8 #5）を先に済ませておくと、ChatGPT の経路で失敗したときに、原因がスキーマか経路かを切り分けられる。

## 5. 画面

メインウィンドウは2ペイン。

- 左: 文字起こし。確定テキストは通常の色、未確定テキストは薄い色。各行に開始時刻（録音経過時間）を付ける。新しい行が来たら自動で最下部へスクロールする。ユーザーが上にスクロールしている間は自動スクロールを止め、「最新へ」ボタンを出す
  - 実装: `ScrollPosition` と `onScrollGeometryChange` で、スクロール位置と最下部までの距離を追う。最下部から60pt以内なら追従し、上にスクロールして（位置が減って）最下部から離れたときだけ追従をやめる。行が増えただけ（位置が変わらない）では止めない。追従のスクロールにはアニメーションを付けない（途中の位置で誤判定するため）
  - ヘッダに会議名と書き出しメニュー（コピー、テキストとして保存、Markdown として保存）
- 開始時: 会議名を入力するシート。空なら開始日時から「2026-11-15 14:30 の会議」のように付ける
- 右: ノート。トピックごとに項目を並べ、種類（要点 / 決定 / ToDo / 質問）をバッジで示す。ToDoには担当と期限を添える。追加・更新された項目は数秒間ハイライトする
- ツールバー: 録音開始 / 一時停止 / 停止、経過時間、入力レベル、LLMの状態（更新中 / 待機 / エラー / 送信停止中）、「要約の送信を一時停止」トグル、設定
- 右ペインの案内: APIキーがない（設定を開くボタン）、失敗（理由。自動で送り直さない失敗では「再試行」と設定を開くボタン）、一時停止中、反映できなかった発言があった。ヘッダに Markdown のコピーボタン
- 終了後: 議事録の表示、Markdownのコピーと保存
- 設定画面（SwiftUI の `Settings` シーン。Cmd+, かツールバーの設定ボタン）: APIキーの入力（伏せ字。保存済みかだけを表示し、値は表示しない。保存後は入力欄を空にする）・保存・削除、モデルID（ライブ更新用・議事録の仕上げ用）、「接続テスト」、認識言語（次に開始する会議から反映）
- ChatGPT でのログイン（Phase 4B。§4.11）
  - 設定画面の「OpenAI」の節に「接続方法」（API キー / ChatGPT プラン）を置く
  - ChatGPT プランを選んだときの表示
    - 未ログインなら「ChatGPT で続ける」ボタン（ガイドラインの「Continue with ChatGPT」）と「別のアカウントでログイン」。公式のロゴ画像は同梱せず、文字だけにする（外部のファイルを取り込まないため）
    - プランの利用が許可されていなければ「もう一度ログインして許可する」（`prompt=consent` を付ける）
    - ログインの処理中は「ブラウザでログインしてください」とキャンセルボタン
    - ログイン済みならメールアドレス、「ChatGPT プランを使用中」、「使用量を管理」のリンク、「ログアウト」
  - 最初にログインしたときだけ、「ChatGPT プランを使います」の案内を出す（OK ボタン）。AI へのリクエストが ChatGPT のプランの利用枠を使うこと、使用量は ChatGPT の設定で管理できることを書く（ガイドラインの「You're using your ChatGPT plan」「Got it」に当たる）
  - 「使用量を管理」は `https://chatgpt.com/settings/usage` を既定のブラウザで開く
  - ChatGPT プランで動いている間は、ノートペインのヘッダに「ChatGPT プランを使用中」と「使用量を管理」を出す
  - 使用量の上限に達したら、ノートペインの案内に「使用量の上限に達しました」と「使用量を管理」ボタンを出す（ガイドラインの「Usage limit reached」。プランかこのアプリの上限を ChatGPT の設定で確かめるよう書く）。ログインし直しが必要なら「もう一度ログイン」ボタンを出す

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
- entitlements: `com.apple.security.app-sandbox`、`com.apple.security.device.audio-input`、`com.apple.security.network.client`、`com.apple.security.files.user-selected.read-write`（Phase 2 の書き出しで、利用者が選んだ場所に保存するため）、`com.apple.security.network.server`（Phase 4B の ChatGPT ログインで、`127.0.0.1` でコールバックを待ち受けるため）
- ウィンドウは1つだけ（`WindowGroup` ではなく `Window`）。会議は同時に1つしか扱わないため。単一の `Window` は、閉じるとアプリが終了する。録音中に閉じた（終了した）ときは、停止して保存を終えてから終了する（§4.10）。メニューバー常駐との両立は Phase 6 で決める

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
| 3 | OpenAI の Sol / Luna の正確なモデルID。設計時は公式サイトに接続できず、第三者の記事では `gpt-6.1-sol` / `gpt-6-luna` と `gpt-5.6-sol` / `gpt-5.6-luna` が混在していた | Phase 3 | 確認済み（2026-11-15、developers.openai.com/api/docs/models と各モデルのページ）。Flagship は `gpt-6-astra` / `gpt-6.1-sol` / `gpt-6.1-terra` / `gpt-6-luna`。Sol は `gpt-6.1-sol`、Luna は `gpt-6-luna`（どちらもスナップショットはこの1つだけで、Responses API・構造化出力・ストリーミングに対応）。これを既定値にした。`gpt-5.6-*` は前の世代。実際に呼べるかは人による接続テストで確かめる |
| 4 | Responses API の構造化出力のリクエスト形（§4.7）、応答から出力テキストと拒否を読み取る方法、`store` パラメータ、ストリーミングのイベント名 | Phase 3 | 確認済み（2026-11-15、公式ドキュメントの structured outputs・conversation state・streaming のガイドと、公式 Python SDK の型定義）。形は設計時の想定どおりで、§4.7 に応答の読み方とイベント名を書き足した。`store` は既定で保存（30日）で、`false` で保存しない。`output_text` の集約は SDK の便利機能で生の JSON にはない。API リファレンスのページは大きすぎて全体を読めなかったため、イベント名と応答のフィールドは公式 SDK のソースで確かめた。実際の応答での動作は人による接続テストで確かめる |
| 5 | [notes-ops.schema.json](../LiveMinutesKit/Sources/LiveMinutesKit/Resources/notes-ops.schema.json) がそのまま strict モードで受理されるか（null を含む `enum` の書き方など） | Phase 3 | 一部確認（2026-11-15）。公式の Supported schemas で、全プロパティ必須・`additionalProperties: false`・`["string", "null"]` の型配列・入れ子の `anyOf` が使えることを確認した。`enum` に `null` を含める書き方が許されるかは明記がなく確認できなかったため、`kind` を文書化された形 `anyOf: [{type: string, enum: [...]}, {type: null}]` に書き換えた（意味は同じ。§4.4・§4.5 の例は変更不要）。実際の API で受理されるかは、接続テストがこのスキーマを使うので、人による接続テストで確かめる。確認済み（2026-11-16、Phase 4B-1 の人による確認。ChatGPT プランの経路の接続テストが、このスキーマの strict の構造化出力で成功した。API キーの経路では未確認だが、スキーマの受理は経路によらないと見込む） |
| 6 | Sol / Luna で推論量を下げる指定（応答を速くするため）があるか、その名前 | Phase 3 | 確認済み（2026-11-15、reasoning ガイドと各モデルのページ）。`reasoning: {"effort": ...}`。`gpt-6-luna` は `none` / `low` / `medium`（既定）/ `high` / `xhigh` / `max`、`gpt-6.1-sol` は `low` / `medium`（既定）/ `high` / `xhigh` / `max`（`none` は不可）。`none` が最も速い。ライブ更新は `low`（追加か更新か、要点か決定かの判断に少し推論を残す。送信間隔が8〜20秒なので数秒の差は問題にならない）、議事録は `medium` を既定にした。`max_output_tokens` は推論のトークンも含み、小さいと出力が空のまま `incomplete` になるので指定しない |
| 7 | 専門用語を音声認識に反映させるAPIの有無と名前 | Phase 6 | 未確認 |
| 8 | システム音声の取り込み方法（Core Audio のプロセスtap など）と必要な権限 | Phase 7 | 未確認 |
| 9 | ChatGPT プランの利用枠で、構造化出力（`text.format` の `json_schema`、strict）と `reasoning.effort` が使えるか。公式文書には、使えないパラメータの一覧にも、使えるものの説明にも出てこない | Phase 4B | 構造化出力は確認済み（2026-11-16、人による確認。ChatGPT プランでログインし、`gpt-6-luna` への接続テストが成功した。strict の `json_schema` をストリーミングで受けて読めた）。`reasoning.effort` はおそらく使える（`reasoning` を外して送り直したときに出すログが、システムのログに見当たらなかった。ただし、このアプリのログ自体が1件も見つからなかったので、確証はない） |
| 10 | `gpt-6-luna` と `gpt-6.1-sol` が ChatGPT プランで使えるか（`GET /v1/models` に出るか） | Phase 4B | `gpt-6-luna` は確認済み（2026-11-16、人による確認。接続テストで「一覧にあります」と表示され、リクエストも成功した）。`gpt-6.1-sol` は未確認（議事録の仕上げを作る Phase 5 で確かめる） |
| 11 | 「使用量を管理」のリンク先（ChatGPT の設定の使用量の画面）の URL | Phase 4B | 文書で確認（2026-11-16、UI/UX guidelines）。`https://chatgpt.com/settings/usage`。実際にその画面が開くかは、人による確認で見る |
| 12 | 初回のログイン（動的登録）で `redirect_uri` のポートを固定する必要があるか。文書には「2回目以降は変わってよい」とだけある | Phase 4B | 未確認（原文は「from initial registration onward」「Later sign-ins may use another available port」）。1455 が使用中のときの初回のログインで確かめる |
