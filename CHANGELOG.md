# Changelog

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
