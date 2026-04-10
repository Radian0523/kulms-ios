# Contributing

KULMS iOS への貢献を歓迎します。

## 開発環境のセットアップ

1. リポジトリをフォーク & クローン
   ```bash
   git clone https://github.com/<your-username>/kulms-ios.git
   ```
2. Xcode でプロジェクトを開く
   ```bash
   open KULMS.xcodeproj
   ```
3. 実機またはシミュレータでビルド・実行（iOS 17+）
4. 初回起動時に SSO でログインして動作確認

## プロジェクト構成

```
Models/          # SwiftData モデル (Assignment, Course)
Services/        # SakaiAPIClient, WebViewFetcher
Stores/          # AssignmentStore (状態管理)
Views/           # SwiftUI ビュー
KULMSApp.swift   # App エントリポイント + ContentView
```

### アーキテクチャのポイント

- API 呼び出しは `WebViewFetcher` 経由の WKWebView `callAsyncJavaScript` で実行（URLSession は Sakai セッション cookie が認証されないため不使用）
- SSO ログインと API 呼び出しに同一の WKWebView インスタンスを使用
- `ContentView` の ZStack に LoginView と AssignmentListView を常に配置し、WKWebView がビュー階層から外れないことを保証

## コーディング規約

- 外部依存は追加しない
- SwiftUI + SwiftData を使用
- `@MainActor` で UI 更新を保証
- `SakaiAPIClient` は `actor` で並行安全性を確保

## Pull Request の流れ

1. `master` から作業ブランチを作成
2. 変更を実装し、Xcode でビルドが通ることを確認
3. コミットメッセージは変更内容を日本語で簡潔に記述
4. Pull Request を作成し、変更内容を説明

## Issue

バグ報告・機能リクエストは [Issue テンプレート](https://github.com/Radian0523/kulms-ios/issues/new/choose) を使用してください。
