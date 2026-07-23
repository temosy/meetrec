# MeetRec

Mac のオンライン会議画面とシステム音声を録画・録音する小さなアプリです。GUI と CLI の両方で使えます。

- 画面: ScreenCaptureKit でウィンドウ単体またはディスプレイ全体を録画
- 音声: Mac のシステム出力音声を録音
- マイク: 既定では録音しません。必要な時だけ ON にできます
- 録音のみ: 画面なしで Mac 音声を `.m4a` に保存
- 出力: 録画は `mp4` / H.264 / AAC、録音のみは `m4a` / AAC
- GUI: 日本語 / English 切替、入力ソース選択、音声レベルメーター付き

## ライセンス

MeetRec は MIT License で公開しています。詳細は [LICENSE](LICENSE) を参照してください。

## 使い方

```sh
meetrec list
meetrec start --app "Google Chrome"
meetrec start --window-id 12345
meetrec start --display
meetrec start --audio-only
meetrec stop
```

録画中のターミナルで `Ctrl-C` を押しても停止できます。

既定の保存先は `~/Movies/Meetings/` です。

全画面再生で黒余白を避けたい場合は、ウィンドウ指定ではなく `--display` を使います。画面全体の録画では Dock を除外し、カーソルも既定では録画しません。画質は Retina 解像度の高画質モードと、容量を抑える半分モードから選べます。ウィンドウ録画は元ウィンドウの縦横比で保存されるため、再生画面の縦横比と違うとプレイヤー側で黒余白が出ます。

```sh
meetrec start --app Safari --fps 60 --out ~/Movies/Meetings
meetrec start --display
meetrec start --display --half-resolution
meetrec start --audio-only
meetrec start --audio-only --include-mic
meetrec start --app "Google Chrome" --include-mic
meetrec start --app "Google Chrome" --mic-device-id BuiltInMicrophoneDevice
```

## GUI

```sh
swift run MeetRecGUI
```

アプリ化する場合:

```sh
scripts/build-app.sh
open MeetRec.app
```

システム設定の権限一覧にも安定して反映させる場合:

```sh
scripts/install-app.sh
open /Applications/MeetRec.app
```

ビルドスクリプトは、利用可能な `Apple Development` コード署名証明書を自動で使います。証明書がない環境では ad-hoc 署名にフォールバックします。

GUI では、録画 / 録音のみの切替、録画対象の更新、ウィンドウ/画面全体の選択、FPS、画質、カーソル録画、自分の声の録音、入力ソース選択、保存先選択、開始/停止ができます。画面全体の録画では Dock を除外します。カーソル録画と自分の声の録音は既定で OFF です。

Mac 音声とマイク音声は、それぞれ入力レベルメーターで確認できます。UI は日本語 / English を画面上で切り替えられます。

アプリアイコンは `assets/MeetRecIcon.png` から生成します。

```sh
scripts/make-icon.sh
```

## ビルド

```sh
swift build -c release
install -m 755 .build/release/meetrec ~/.local/bin/meetrec
```

## App Store

MeetRec は無料アプリとして Mac App Store でも公開する予定です。App Store 向けには、App Store Connect のアプリ登録、正式な Bundle ID、配布用署名、Sandbox 対応、権限説明文、審査用メタデータとスクリーンショットの準備が必要です。

## 初回権限

初回実行時に macOS の「画面とシステムオーディオの収録」許可が必要です。許可対象は `meetrec` を起動したターミナルアプリです。

自分の声も録音する設定を ON にした場合のみ、マイク権限を要求します。入力ソースのIDは `meetrec list` の `Microphones` で確認できます。

## 注意

会議録画は参加者の同意を得てから行ってください。NDA 案件などの録画データは、保存先と保持期間にも注意してください。
