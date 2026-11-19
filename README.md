# ExpClassicMenu

Windows 11 の Explorer で右クリックしたとき、Windows 11 形式の新しいメニューではなく、従来(Windows 10 形式)のコンテキストメニューを表示させる常駐アプリです。

Explorer 上の右クリックを Shift+右クリックとして扱わせることで、従来メニューを表示させます。

## 動作環境

- Windows 11(64bit)

## 使い方

1. `ExpClassicMenu.exe` を起動します。タスクトレイにアイコンが表示されます。
2. Explorer のファイル一覧、ナビゲーションペイン、デスクトップで右クリックすると、従来のメニューが表示されます。

二重起動はできません。

### タスクトレイのアイコン

| 有効 | 無効 |
|:---:|:---:|
| ![有効時のアイコン](docs/tray-icon-on.png) | ![無効時のアイコン](docs/tray-icon-off.png) |

無効のときは、アイコンが灰色になります。

### タスクトレイのメニュー

アイコンを右クリックすると、次のメニューが表示されます。

![タスクトレイのメニュー](docs/tray-menu.png)

| 項目 | 内容 |
|---|---|
| 有効 | 機能のオン/オフを切り替えます。アイコンのダブルクリックでも切り替わります |
| 他アプリのファイルダイアログにも適用 | 他のアプリの「開く」「保存」ダイアログでも従来メニューを表示します(初期値はオフ) |
| Windows 起動時に実行 | ログオン時に自動で起動するよう登録、または解除します |
| 終了 | アプリを終了します |

## 対象となる場所

- Explorer のファイル一覧(`SHELLDLL_DefView`)
- Explorer のナビゲーションペイン(`NamespaceTreeControl`)
- デスクトップ
- 他アプリのファイルダイアログ(設定でオンにした場合)

タスクバーと通知領域は対象外です。

## 仕組み

- 低レベルマウスフック(`WH_MOUSE_LL`)で右ボタンの操作を監視します。
- 対象となる場所で右ボタンが押されたら、その直後に Shift キーの押下を `SendInput` で送ります。
- 右ボタンを離してから 200ms 後に Shift キーを離します。
- 右ボタンの操作そのものは横取りしないので、右ドラッグ(コピー/移動メニュー)もいつもどおり使えます。
- 自分で Shift キーを押しているときは何もしません。

## 設定の保存先

| 内容 | 保存先 |
|---|---|
| 有効/無効、ファイルダイアログへの適用 | `HKEY_CURRENT_USER\Software\ExpClassicMenu` |
| Windows 起動時に実行 | `HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run` の値 `ExpClassicMenu` |

アンインストールするときは、「Windows 起動時に実行」のチェックを外してから終了し、exe を削除してください。上記のレジストリキーも不要なら削除してください。

## 注意事項

- 管理者権限で動いているウィンドウ上では動作しません(Windows の UIPI による制限)。
- 右クリック中、ほかのアプリからは Shift キーが押されているように見えます。

## ビルド

Delphi(RAD Studio)でビルドします。VCL は使わず、WinAPI だけで作っています。

- IDE の場合: `ExpClassicMenu.dproj` を開いてビルドします。
- コマンドラインの場合:

```
dcc64 -B "-NSWinapi;System;System.Win" -EWin64\Release -NUWin64\Release\dcu ExpClassicMenu.dpr
```

## ファイル構成

| ファイル | 内容 |
|---|---|
| `ExpClassicMenu.dpr` | プロジェクト本体 |
| `uExpClassicMenu.pas` | フック、トレイ、設定の処理 |
| `ExpClassicMenu.dproj` / `ExpClassicMenu.res` | IDE のプロジェクト設定とリソース |
| `docs/` | README で使っている画像 |
| `LICENSE` | ライセンス |

## ライセンス

[MIT License](LICENSE) です。

Copyright (c) 2026 mikekoma

## 連絡先

- mikekoma
- メール: mike@s-m-l.org
- Web: <https://www.s-m-l.org>
