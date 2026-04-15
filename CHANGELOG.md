# Changelog

## v1.1.0

- **通知タイミングのカスタマイズ機能**
  - 締切リマインドの通知タイミングをユーザーが自由に設定可能に（10分前〜3日前、最大5個）
  - デフォルトは従来通り24時間前・1時間前の2段階
  - 設定画面の通知セクションに Chip UI + ピッカーを追加
  - タイミング追加・削除時に即座に通知を再スケジュール
  - 設定は UserDefaults に JSON で永続化（アプリ再起動後も保持）
  - iOS 64通知上限対策: 締切が近い順にソートし先頭64件のみスケジュール（BGTaskで1時間ごとに再スケジュールされるため溢れた分も後から登録）

## v1.0.5

- **提出済み課題のチェックボックスロックを廃止**
  - API誤判定時にユーザーが手動で修正できない問題を解消
  - 提出済み・再提出不可の課題でもチェックを操作可能に

## v1.0.4

- **クイズ・テストの自動提出判定を無効化**
  - Sakai `sam_pub` API は学生個人の提出データを返さないため、`submitted` フラグの信頼性が不明
  - クイズの `status` を常に空文字列に変更（手動チェックのみで完了管理）
  - 設定画面の説明にクイズ・テストは手動チェックのみである旨を追記

## v1.0.3

- **課題提出状態の判定ロジックを全面改修 (バグ修正)**
  - Sakai ソースコード解析に基づき、全12パターンの提出状態に対応（参照: kulms-extension/docs/sakai-submission-states.md）
  - `submission.graded` 単体で「評定済」と判定していたバグを修正
    - 状態#6（採点済み・未返却）: 「提出済」に修正（成績非公開の意図を尊重）
    - 状態#11（返却後に作業中）: 「取組中」に修正（前回の graded フラグ残存による誤判定を防止）
  - Sakai status 文字列を一次判定に変更し、Boolean フィールドの残存値による誤判定を防止
  - `RawSubmission` に `returned` フィールドを追加（採点済み+返却済みの正確な判定に必要）
  - `isSubmitted` に「再提出」「返却」「採点済」等のパターンを追加
  - バックグラウンドタスク（`KULMSApp.swift`）の判定ロジックも同様に修正

## v1.0.2

- **未公開クイズが課題一覧に表示される問題を修正**
  - Sakai の `sam_pub_collection` API は `startDate`（公開開始時刻）が未来のクイズも返すが、フィルタしていなかったため未公開のテスト・クイズが表示されていた
  - `RawQuiz` に `startDate` フィールドを追加し、`fetchQuizzes()` で `startDate > 現在時刻` のクイズを除外（ブラウザ拡張 v1.11.2 / Comfortable Sakai 準拠）
- **fetch 中のセッション切れ検知 + キャッシュ保護**
  - `checkSession()` 後に `fetchAllAssignments()` の途中でセッションが切れた場合、各 fetch が `try?` で空リストを返し `saveToCache()` で既存キャッシュが部分データに上書きされていた
  - WebViewFetcher の JS fetch 内でリダイレクト URL / Content-Type を検知し `APIError.sessionExpired` を送出
  - `fetchAllAssignments()` を `withThrowingTaskGroup` に変更し、sessionExpired を上位に伝播
  - `AssignmentStore.fetchAll()` で catch し、`saveToCache()` をスキップして既存キャッシュを保護
  - ブラウザ拡張 v1.11.1 の `LoggedOutError` 伝播方式と同等の挙動

## v1.0.1

- 「取組中」の課題が「完了済み」に誤分類されるバグを修正
  - Sakai API の `userSubmission` は下書き保存でも `true` になるため、`submitted && !draft` で判定するよう修正
  - サーバー計算の `status` フィールドを活用し「取組中」等を正しく表示

## v1.0.0

初回リリース。Chrome拡張版の主要機能をiOSネイティブに移植。

### 機能

- SSO認証: WKWebViewで京大シングルサインオンに対応
- 全科目課題一覧: Sakai Direct APIから取得し緊急度別に表示
- テスト/クイズ対応: `sam_pub` APIからクイズを取得し課題と統合表示
- 提出状態の正確な判定: 個別課題API (`/direct/assignment/item/`) で提出済み・評定済みを判定
- 締切リマインド: 24時間前・1時間前にローカル通知
- バックグラウンド更新: BGTaskSchedulerで定期的に課題を再取得
- オフラインキャッシュ: SwiftDataでローカル保存、起動時はキャッシュを即座に表示
- 手動更新: ナビバーの更新ボタン / プルダウンで最新データを取得
- セッション管理: セッション切れ時は更新ボタンからログイン画面へ遷移

### アーキテクチャ

- WKWebView `callAsyncJavaScript` 経由の `fetch()` で全API呼び出し
- 単一WKWebViewをSSO認証とAPI呼び出しの両方に使用
- ContentView ZStackで両ビューを常に保持しWebViewの生存を保証
