# Phase 2: 録音制御と保存

## 目的

1回の会議を「セッション」として扱い、一時停止・停止・保存・書き出しができるようにする。このフェーズが終わると、文字起こしアプリとして単体で使える。

## 先に読むもの

- [AGENTS.md](../../AGENTS.md)
- [DESIGN.md](../DESIGN.md) §4.3（Transcript）、§4.9（Persistence）、§4.10（Session）、§5（画面）

## 作業内容

1. `Transcript/`: `TranscriptStore`
   - 確定セグメントの配列と、現在の未確定テキストを持つ
   - Phase 1 の画面用の配列をこれに置き換える
2. `Persistence/`: `SessionRepository`
   - セッションの作成、`meta.json` の読み書き、`transcript.jsonl` への追記と読み込み
   - `transcript.jsonl` の最後の行が途中で切れていても、読める行までを読み込む（異常終了への備え）
3. `Session/`: `SessionController`
   - 状態遷移 `idle` → `preparing` → `recording` ⇄ `paused` → `finishing` → `finished`
   - 一時停止中はマイクを止め、音声を流さない
   - 録音経過時間（一時停止中は進まない）
   - 依存（`AudioSource`、`TranscriptionEngine`、時計、保存先）を外から渡せるようにする
4. 画面
   - ツールバー: 開始 / 一時停止 / 再開 / 停止、経過時間、入力レベル
   - 開始時に会議名を入力できる（省略時は日時から自動で付ける）
   - 左ペインの自動スクロール。上にスクロールしている間は止め、「最新へ」ボタンを出す
   - 各セグメントに開始時刻（録音経過時間）を表示する
   - 文字起こしのコピーと、テキスト / Markdown での保存
5. テスト
   - `SessionController` の状態遷移（偽の `AudioSource` と `TranscriptionEngine` を使う）
   - 許されない遷移（`idle` で停止など）を無視すること
   - `transcript.jsonl` の読み書きと、途中で切れたファイルの読み込み
   - 経過時間が一時停止中に進まないこと（偽の時計を使う）

## 範囲外

- 過去のセッションの一覧と再表示（Phase 5）
- LLM に関するコード

## 受け入れ条件

- ビルドとテストが通る
- Viewが `AVAudioEngine` や `SpeechAnalyzer` を直接触っていない（`SessionController` 経由になっている）

## 人が確認する項目

- 一時停止中に話した内容は文字にならず、再開すると続きから文字になる
- 停止後、`~/Library/Application Support/LiveMinutes/sessions/` にセッションのフォルダと `transcript.jsonl` ができている
- 録音中にアプリを強制終了しても、そこまでの `transcript.jsonl` が残っている
- 上にスクロールして過去の発言を読んでいる間、画面が勝手に動かない
- 書き出したファイルの内容が画面と一致する
