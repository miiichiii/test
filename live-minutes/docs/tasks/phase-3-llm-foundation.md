# Phase 3: OpenAI接続とノートの土台

## 目的

OpenAI API を呼ぶクライアント、設定画面、ノートのデータモデルと差分適用を作る。ライブ更新のループ（Phase 4）に必要な部品を、マイクなしでテストできる形で揃える。

## 先に読むもの

- [AGENTS.md](../../AGENTS.md)（特に「新しいAPIの扱い」「秘密情報」）
- [DESIGN.md](../DESIGN.md) §4.4（Notes）、§4.7（LLM）、§4.8（Settings）
- [notes-ops.schema.json](../schemas/notes-ops.schema.json)

## 最初に確認すること

DESIGN.md §8 の #3〜#6 を OpenAI の公式ドキュメントで確認し、結果を表に書き込む。

- **Sol と Luna の現行のモデルID**。設計時には確定できなかった。公式のモデル一覧で確認し、ライブ更新用（Luna）と議事録仕上げ用（Sol）の既定値として使う。確認できなかった場合は既定値を空にし、設定画面で入力を求める形にして、その旨を報告する
- Responses API の構造化出力のリクエスト形、応答から出力テキストと拒否を読み取る方法、ストリーミングのイベント名
- 応答をOpenAI側に保存させない指定（設計時の想定は `store: false`）
- `notes-ops.schema.json` が strict モードでそのまま受理されるか。受理されない書き方があれば、意味を変えずにスキーマを直し、DESIGN.md §4.4 と §4.5 の例も合わせる
- 推論量を下げて応答を速くする指定の有無

DESIGN.md §4.7 の想定形と違っていたら、設計書を実際の形に直す。

## 作業内容

1. `Notes/`: `Notes`、`Topic`、`NoteItem`、`NoteKind`、`NotesOp`、`NotesReducer`、`NotesStore`
   - 適用規則は DESIGN.md §4.4 の表のとおり
   - IDの採番は `NotesReducer` が行う。仮ID（`new-1` など）は1回の適用の中だけで有効
2. `LLM/`: `LLMClient`、`OpenAIResponsesClient`、`LLMError`
   - 構造化出力のリクエスト（スキーマを渡し、JSONを受け取る）
   - テキストのストリーミングリクエスト（届いた差分を順に返す）
   - 再試行とタイムアウトは DESIGN.md §4.7 のとおり
   - `URLSession` を外から渡せるようにする（テストでスタブに差し替える）
3. `Settings/`: `AppSettings`、`KeychainStore`
4. プロンプトとスキーマをパッケージのリソースにする
   - `docs/prompts/` と `docs/schemas/` のファイルを `git mv` で `LiveMinutesKit/Sources/LiveMinutesKit/Resources/` に移し、置き場所を1か所にする
   - README.md、AGENTS.md、DESIGN.md、各フェーズファイル内のリンクを新しい場所に直す
   - リソースを読み込むAPIを用意する
5. 設定画面
   - APIキーの入力（伏せ字表示）、保存、削除
   - モデルID（ライブ更新用、議事録仕上げ用）
   - 認識言語
   - 「接続テスト」ボタン: 短いリクエストを1回送り、成功か失敗の理由を表示する
6. テスト
   - `NotesReducer`: 各opの正常系、無視する条件のすべて、仮IDの解決、20件の上限、空のops
   - `NotesOp` のデコード: DESIGN.md §4.5 の出力例がそのままデコードできること
   - `OpenAIResponsesClient`（`URLProtocol` のスタブを使う）: 成功、拒否、401（再試行しない）、429と5xx（再試行する）、タイムアウト、JSONとして壊れた出力
   - リクエストにAPIキーとスキーマが正しく入っていること

## 範囲外

- ライブ更新のループとノートの画面（Phase 4）
- 議事録の生成（Phase 5）

## 受け入れ条件

- ビルドとテストが通る
- 自動テストが実際の OpenAI API を呼んでいない
- APIキーがKeychain以外（`UserDefaults`、ファイル、ログ）に書かれていない
- `docs/prompts/` と `docs/schemas/` が残っておらず、文書内のリンクが切れていない
- DESIGN.md §8 の #3〜#6 に確認結果が書かれている

## 人が確認する項目

- 設定画面でAPIキーを保存し、アプリを再起動しても保持されている
- 「接続テスト」が、正しいキーで成功し、誤ったキーで認証エラーと表示される
- モデルIDを存在しない値にして「接続テスト」をすると、原因が分かるエラーが表示される
