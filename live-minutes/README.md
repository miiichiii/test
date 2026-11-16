# LiveMinutes（仮称）

会議中にMacのマイク音声をリアルタイムで文字起こしし、要点・決定事項・ToDoに自動で整理して表示するmacOSアプリの設計一式。

設計・Codex 向けの指示・アプリのコードが入っている。フェーズごとに実装を進めている（今の状況は下の「今の状況と引き継ぎ」）。

## 何ができるアプリか

- 話した内容が1〜2秒ほどの遅れで文字になる（文字起こしは端末内で行い、音声は外に出ない）
- 文字起こしが20秒前後ごとに整理され、トピック別の箇条書きになる
- 会議が終わると議事録（Markdown）ができる

## 中身

| ファイル | 内容 |
|---|---|
| [docs/DESIGN.md](docs/DESIGN.md) | 設計書 |
| [AGENTS.md](AGENTS.md) | Codexが従うルール（コマンド、規約、禁止事項） |
| [docs/tasks/](docs/tasks/) | フェーズ別のCodex向け指示（Phase 0〜7） |
| [LiveMinutesKit/Sources/LiveMinutesKit/Resources/](LiveMinutesKit/Sources/LiveMinutesKit/Resources/) | 整理・要約に使うLLMのシステムプロンプトと、ライブ更新の出力スキーマ（アプリに同梱するリソース） |

## 用意するもの

- macOS 26 (Tahoe) 以降の Appleシリコン Mac
- Xcode 26 以降
- Homebrew（XcodeGen を入れるため）
- Codex
- 整理・要約に使う OpenAI への接続（Phase 3 以降。どちらか）
  - OpenAI の APIキー（Codexの契約とは別に、APIの利用料がかかる）
  - ChatGPT の有料プラン（Plus / Pro など。Phase 4B から、アプリの設定画面でログインして使える）

## Codexでの進め方

1. このリポジトリをMacに clone し、`live-minutes/` でCodexを起動する

   ```bash
   cd live-minutes
   ```

   ```bash
   codex
   ```

2. フェーズを1つずつ依頼する。例:

   ```
   docs/tasks/phase-0-scaffold.md を読んで、その内容を実装してください。
   ```

3. Codexの作業が終わったら、フェーズファイルの「人が確認する項目」を自分で試す。マイクを使う動作はCodexからは確認できないため

4. 問題がなければコミットし、次のフェーズへ進む

フェーズは順番に依存しているので、番号順に進める。

| Phase | 内容 | 終わるとできること |
|---|---|---|
| [0](docs/tasks/phase-0-scaffold.md) | 雛形 | ビルドが通り、空のウィンドウが開く |
| [1](docs/tasks/phase-1-transcription.md) | マイクと文字起こし | 話した内容がリアルタイムで表示される |
| [2](docs/tasks/phase-2-session.md) | 録音制御と保存 | 一時停止・停止・保存・書き出しができる |
| [3](docs/tasks/phase-3-llm-foundation.md) | OpenAI接続とノートの土台 | APIキーを設定し、接続を確認できる |
| [4](docs/tasks/phase-4-live-notes.md) | ライブ整理 | 会議中に箇条書きが増えていく |
| [4B](docs/tasks/phase-4b-chatgpt-sign-in.md) | ChatGPT でのログイン（追加） | API キーの代わりに ChatGPT のプランで使える |
| [4C](docs/tasks/phase-4c-microphone-selection.md) | マイクの選択（追加） | 使うマイクを設定画面で選べる |
| [4D](docs/tasks/phase-4d-whisper-local.md) | Whisper（ローカル）での書き起こし（追加） | Apple と Whisper の書き起こしを選んで比べられる |
| [5](docs/tasks/phase-5-minutes.md) | 議事録と履歴 | 終了時に議事録ができ、過去の会議を開ける |
| [6](docs/tasks/phase-6-polish.md) | 仕上げ | エラー表示、用語登録、メニューバー常駐など |
| [7](docs/tasks/phase-7-system-audio.md) | Mac内音声（将来） | オンライン会議の相手の声も文字になる |

Phase 2 まで終われば、文字起こしアプリとして単体で使える。Phase 5 までで当初の目的は一通り満たせる。

## 今の状況と引き継ぎ（2026-11-16）

ここまでは Claude Code（ブランチ `claude/epic-ride-nzumve`）で実装した。続きは Codex でも Claude Code でも進められる。

### 終わったフェーズ（利用者が了承し、コミット済み）

| Phase | コミット |
|---|---|
| 0 雛形 | `114cffb` |
| 1 マイクと文字起こし | `0f95eed` |
| 2 録音制御と保存 | `45f00c9` |
| 3 OpenAI 接続とノートの土台 | `7f73be8` |
| 4 ライブ整理 | `3e3fa23` |
| 4B ChatGPT でのログイン | `d000174`（4B-1）、`383d4ca`（4B-2） |
| 4C マイクの選択 | `0f3331d` |
| 4D Whisper（ローカル）での書き起こし | `679c44f` |

自動テストは 283 件あり、すべて通る（`cd LiveMinutesKit && swift test`）。

### 次にやること（この順）

1. **[Phase 5](docs/tasks/phase-5-minutes.md)**: 議事録と履歴
2. **[Phase 6](docs/tasks/phase-6-polish.md)**: 仕上げ
3. **[Phase 7](docs/tasks/phase-7-system-audio.md)**: Mac 内の音声（オンライン会議の相手の声）。利用者は、物理的なマイクと合わせて取り込みたい意向を示している（詳しい要望は未確認なので、始める前に聞く）

### まだ確かめていないこと

- [docs/DESIGN.md §8](docs/DESIGN.md#8-未確認事項) の「未確認」の行（音声認識への用語の反映、Mac 内の音声、ChatGPT ログインの初回のポート、マイクの選択の実機での動作、Whisper の精度など）。Phase 3 で確定できなかったモデルIDは、Phase 3・4B で確認済み
- 各フェーズの指示書の「人が確認する項目」のうち、利用者がまだ試していないもの。確認済みなのは、Phase 1〜2 の基本の動作、Phase 4B-1 の ChatGPT へのログインと接続テスト（`gpt-6-luna`）など。実際の会議でのノートの整理（Phase 4・4B-2）とマイクの選択（4C）は、まだ十分に試していない

### 進め方の決まり（利用者が決めたもの）

- フェーズは1つずつ実装し、終わったら報告して止まる。利用者が「人が確認する項目」を試して了承してから、そのフェーズをコミットし、次へ進む。プッシュは頼まれたときだけ
- 報告は日本語で、次を入れる: 実装した内容、実行したコマンドと結果、受け入れ条件ごとの状況、設計から変えた点と理由、人が確認する項目（未確認と書く）
- 設計と違う判断をしたら、同じコミットで docs/DESIGN.md を直す
- API キーやログインの情報を、チャットやファイルに書かせない（利用者がアプリの設定画面で入力する）
- リポジトリ直下の `*.html` は触らない
- 環境に足りないものがあれば、回避策を取らずに知らせる

### Codex への頼み方の例

```
README.md の「今の状況と引き継ぎ」と AGENTS.md を読み、docs/tasks/phase-5-minutes.md を実装してください。
終わったら、AGENTS.md の「最終報告に書くこと」に従って日本語で報告し、そこで止めてください。コミットはしないでください。
```

## 設計時に確認できなかったこと

[docs/DESIGN.md §8](docs/DESIGN.md#8-未確認事項) に一覧がある。各フェーズの最初に確かめ、結果を表に書き込む。モデルIDはアプリの設定画面でいつでも変更できる。

## 使うときの注意

- 録音・文字起こしをする場合は、参加者に伝えて了承を得る
- 整理・要約のために、確定した文字起こしのテキストがOpenAIに送られる（音声は送らない。Whisper を選んだ場合も Mac の中で書き起こす）。送りたくない話題のときは、ツールバーの「要約の送信を一時停止」を使う（その間も文字起こしは端末内で続く）
