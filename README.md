# KULMS iOS

京都大学LMS (KULMS/Sakai) の課題一覧をiOSネイティブで確認できるアプリ。

[Chrome拡張版](https://github.com/Radian0523/kulms-extension)のiOS移植。

## 機能

- **SSO認証**: WKWebViewで京大のシングルサインオンに対応
- **課題一覧**: Sakai Direct APIから全科目の課題を取得し、緊急度別に表示
- **テスト/クイズ対応**: Sakai sam_pub APIからテスト・クイズも取得し課題と統合表示（未公開クイズは `startDate` で自動除外）
- **提出状態の正確な判定**: 個別課題APIで提出済み・評定済みを正確に判定
- **セッション切れ保護**: fetch 中にセッションが切れた場合もキャッシュを保護し、部分データで上書きしない
- **締切リマインド**: ローカル通知でリマインド（タイミングは設定画面で自由にカスタマイズ可能、10分前〜3日前・最大5個）
- **バックグラウンド更新**: 定期的に課題を再取得し通知をスケジュール
- **オフラインキャッシュ**: SwiftDataで課題をローカル保存。起動時はキャッシュを即座に表示し、更新ボタンで最新データを取得

## 緊急度の分類

| 色 | 分類 | 条件 |
|---|---|---|
| 🔴 | 緊急 | 24時間以内 / 期限切れ |
| 🟡 | 5日以内 | 5日以内 |
| 🟢 | 14日以内 | 14日以内 |
| ⚪ | その他 | 14日以上先 / 期限なし |

## アーキテクチャ

API呼び出しはすべてWKWebViewの`callAsyncJavaScript`経由の`fetch()`で実行。URLSessionではSakai のセッションcookieが認証されないため、SSOログインと同一のWKWebViewインスタンスを使用する設計。

ContentViewのZStackにLoginView（WKWebView保持）とAssignmentListViewを常に配置し、WKWebViewがビュー階層から外れないことを保証。

## 技術スタック

- Swift / SwiftUI / SwiftData
- iOS 17+
- WKWebView (SSO認証 + API呼び出し)
- UNUserNotificationCenter
- BGTaskScheduler

外部依存なし。

## ビルド

```bash
open KULMS.xcodeproj
```

Xcodeでビルド・実行。初回起動時にSSOでログインすると課題一覧が表示される。

## フィードバック

ご意見・要望は [こちらのフォーム](https://docs.google.com/forms/d/e/1FAIpQLSdmc4tCHa98mzt1j4Wxu9IJo88wKz3-VQHVYAQjbtJ3Jo_CPw/viewform) からお送りください。アプリの設定画面からもアクセスできます。
