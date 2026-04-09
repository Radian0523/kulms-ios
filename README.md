# KULMS iOS

京都大学LMS (PandA/Sakai) の課題一覧をiOSネイティブで確認できるアプリ。

[Chrome拡張版](https://github.com/Radian0523/kulms-extension)のiOS移植。

## 機能

- **SSO認証**: WKWebViewで京大のシングルサインオンに対応
- **課題一覧**: Sakai Direct APIから全科目の課題を取得し、緊急度別に表示
- **締切リマインド**: 24時間前・1時間前にローカル通知
- **バックグラウンド更新**: 定期的に課題を再取得し通知をスケジュール
- **オフラインキャッシュ**: SwiftDataで課題をローカル保存（TTL: 30分）

## 緊急度の分類

| 色 | 分類 | 条件 |
|---|---|---|
| 🔴 | 緊急 | 24時間以内 / 期限切れ |
| 🟡 | 5日以内 | 5日以内 |
| 🟢 | 14日以内 | 14日以内 |
| ⚪ | その他 | 14日以上先 / 期限なし |

## 技術スタック

- Swift / SwiftUI / SwiftData
- iOS 17+
- WKWebView (SSO認証のみ)
- URLSession + Cookie認証
- UNUserNotificationCenter
- BGTaskScheduler

外部依存なし。

## ビルド

```bash
open KULMS.xcodeproj
```

Xcodeでビルド・実行。初回起動時にSSOでログインすると課題一覧が表示される。
