# ビルドと確認

ビルド対象はApple Silicon（arm64）、macOS 13以降です。Intel Mac向け・Windows向けのビルド手順は提供していません。

## 必要な環境

- Apple SDK、`swiftc`、`clang`、`xcrun`、`codesign`を利用できるmacOS開発環境
- Python 3、zsh
- Node.js 22.12.0以降
- pnpm 11.20.0（`package.json`の`packageManager`に指定）と、ロックファイルに固定したNode依存

アプリ本体はSwift・Cでビルドします。Node.jsは、元のTypeScriptコードからプロンプトやリモート実行用のコードを生成する処理などに必要です。`desktop/native`だけでなく、`prisma`、`lib`などの参照先も含めてリポジトリを用意してください。

## 依存関係を用意する

リポジトリ直下で実行します。初回はネットワークから依存を取得します。

```sh
pnpm install --frozen-lockfile --ignore-scripts
```

元Web版のコードも生成処理と原典との比較用に含みますが、このリポジトリの目的はネイティブ版です。ネイティブ版をビルドするためにWeb版のサーバーを起動する必要はありません。

## 本体をビルドする

依存導入後、同じリポジトリ直下から実行します。通常のビルド処理は追加の依存ダウンロードを行いません。

```sh
zsh desktop/native/build.sh
```

スクリプトはスキーマなどの生成、Cブリッジと表示・画像用ヘルパーのビルド、本体の最適化ビルド、アドホック署名と署名検査を行います。出力は次の場所です。

```text
desktop/native/build/NextCRM Native.app
```

実行時にNode.js、Web版サーバー、PostgreSQLは不要です。ソースからのビルド成果物に対するアドホック署名は、Developer ID署名やAppleの公証を意味しません。

アプリを起動すると個人用のデータを用意します。データ保存先は `~/Library/Application Support/NextCRMNative` です。旧データを復元した場合は、利用者と処理内容を確認してからローカル編集や必要な連携を再開します。[使い方](../desktop/native/使い方.txt)を参照してください。

## 公開用の確認

公開ファイルの検査と、小さなDBのスモークテストを実行できます。

```sh
python3 scripts/verify-publication.py
zsh desktop/native/smoke-test.sh
python3 desktop/native/test-provider-review.py
```

公開CIはmacOS 15のarm64環境で、これらの確認、復元後のメール・Google予定に関する433チェック、既存の生成・ビルド処理を実行します。外部サービスへの実接続や、全機能のAppKit操作を検証するCIではありません。

機能別の検証スクリプトは`desktop/native`にあります。Swift・SQLiteの検証、元TypeScriptとの比較、AppKitの操作検証などが含まれます。全体の入口は`zsh desktop/native/test.sh`ですが、GUIセッションや追加の合成フィクスチャなど、各検証の前提を確認して使用してください。多数のバイナリと合成データを生成するため、本体だけのビルドより時間とディスク容量を使います。公開CIでこの全体スイートを実行したという意味にはなりません。[記録された検証範囲](VERIFICATION.md)を参照してください。
