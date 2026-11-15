# LiveMinutes（仮称）

会議中にMacのマイク音声をリアルタイムで文字起こしし、要点・決定事項・ToDoに自動で整理して表示するmacOSアプリの設計一式。

このフォルダにあるのは設計とCodex向けの指示だけで、アプリのコードはまだない。実装はCodexで、フェーズごとに進める。

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
- OpenAI の APIキー（Phase 3 以降で使う。Codexの契約とは別に、APIの利用料がかかる）

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
| [5](docs/tasks/phase-5-minutes.md) | 議事録と履歴 | 終了時に議事録ができ、過去の会議を開ける |
| [6](docs/tasks/phase-6-polish.md) | 仕上げ | エラー表示、用語登録、メニューバー常駐など |
| [7](docs/tasks/phase-7-system-audio.md) | Mac内音声（将来） | オンライン会議の相手の声も文字になる |

Phase 2 まで終われば、文字起こしアプリとして単体で使える。Phase 5 までで当初の目的は一通り満たせる。

## 設計時に確認できなかったこと

[docs/DESIGN.md §8](docs/DESIGN.md#8-未確認事項) に一覧がある。特に OpenAI の Sol / Luna の正確なモデルIDは確定できていないため、Phase 3 の最初にCodexが公式ドキュメントで確認する手順にしてある。モデルIDはアプリの設定画面でいつでも変更できる。

## 使うときの注意

- 録音・文字起こしをする場合は、参加者に伝えて了承を得る
- 整理・要約のために、確定した文字起こしのテキストがOpenAIに送られる。送りたくない話題のときは、ツールバーの「要約の送信を一時停止」を使う（その間も文字起こしは端末内で続く）
