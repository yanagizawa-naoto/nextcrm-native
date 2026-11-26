# 配布版のログイン設定

メニューまたは左側の「アカウントを接続…」が共通の入口です。メール、予定、AIは別々に接続できます。アプリを受け取る各人が自分のMac・自分のCRMデータで利用する構成で、複数のMacのデータを共同利用するサーバー機能ではありません。

アプリを受け取った人が OAuth クライアント ID を入力する必要はありません。配布元が Google のアプリ登録を済ませたビルドでは、Google カレンダー画面の「Google にログイン…」を押し、普段使うブラウザでアカウントとアクセス許可を選びます。予定の編集が必要なときだけ「予定の編集も許可してログイン…」を使います。接続済みアカウントは画面から認証し直したり削除したりできます。

設定のないソースビルドでは、Google ログインが未設定と表示され、ログインボタンは無効になります。架空の ID や開発者のトークンを同梱して接続済みに見せることはありません。Google のログインはカレンダー／メールとの連携であり、CRM のローカルデータを Google へ丸ごと同期する機能ではありません。

## 配布元が一度行うこと

Google Cloud で「デスクトップ アプリ」の OAuth クライアントを作成し、必要な API を有効にします。Web アプリ用クライアントとは区別してください。アプリはシステムブラウザ、ランダムな loopback ポート、state と PKCE を使います。Google はデスクトップアプリを公開クライアントとして扱い、現行のトークン交換・更新仕様では `client_secret` を省略できます。[Google のデスクトップ OAuth 仕様](https://developers.google.com/identity/protocols/oauth2/native-app)

公開する Google アプリには、配布元を正しく示す名前、サポート窓口、ホームページ、プライバシーポリシーを用意し、同意画面と実際のアクセス範囲を一致させてください。カレンダーの読み取りでは `calendar.readonly`、予定編集ではこれに `calendar.events` を加えます。公開配布では必要な Google の審査を済ませます。開発用のテストユーザー登録だけを、一般の受取人が使える公開設定と扱わないでください。[Calendar のアクセス範囲](https://developers.google.com/workspace/calendar/api/auth)、[機密性の高いスコープの審査](https://developers.google.com/identity/protocols/oauth2/production-readiness/sensitive-scope-verification)

Gmail の IMAP/SMTP を使う構成は `https://mail.google.com/` の権限が必要で、Google の制限付きスコープの要件も確認します。データを配布元のサーバー経由に変更する場合は、追加のセキュリティ評価が必要になる場合があります。審査済みかどうかをアプリの設定ファイルだけで証明することはできません。[Gmail の OAuth](https://developers.google.com/workspace/gmail/imap/xoauth2-protocol)、[制限付きスコープの審査](https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification)

## 公開設定ファイル

`desktop/native/config/DistributionConfiguration.example.json` を別の作業場所へコピーしてください。初期値の `google: null` は未設定です。Google Cloud で作成した **公開クライアント ID だけ**を指定します。

```json
{
  "version": 1,
  "google": {
    "desktopClientID": "1234567890-youractualdesktopclient.apps.googleusercontent.com"
  }
}
```

上の ID は形式例で、ログインには使えません。実際に発行した ID に置き換えます。`client_secret`、アクセストークン、更新トークン、サービスアカウント鍵、利用者の情報は入れられません。

```sh
python3 desktop/native/validate-distribution-configuration.py /path/to/DistributionConfiguration.json --require-google
NEXTCRM_DISTRIBUTION_CONFIG=/path/to/DistributionConfiguration.json zsh desktop/native/build.sh
```

ビルドは検証したファイルを `Contents/Resources/DistributionConfiguration.json` に入れてから署名します。`--require-google` は配布前の確認用です。設定を同梱しないビルドも CRM 本体を利用できますが、Google ログインは未設定になります。

OAuth のクライアント ID は公開情報です。設定ファイルを秘匿するために利用者へ手入力を求める必要はありません。一方、利用者が同意した後の認証情報は各 Mac のキーチェーンに保存され、SQLite には参照だけが残ります。

## 詳細設定とアプリ更新

自分でビルドする人や独自の OAuth アプリを使う人向けに、カレンダー画面の「詳細設定（開発者向け）…」から従来の手動設定を使えます。共有設定の変更は従来どおり CRM 管理者だけに許可されます。保存済みの手動設定は配布版の設定より優先し、シークレットが必要な独自構成ではキーチェーンに保存します。

配布版のクライアント ID を後から変更しても、既存接続の更新トークンを別のクライアントへ黙って渡しません。接続には認証時のクライアント設定が保存されています。旧 OAuth クライアントを廃止する場合は、配布元が移行を案内し、利用者が接続を認証し直します。ブラウザ認証の途中で設定が変更された場合は保存を拒否してやり直します。

## 配布署名と動作確認

Google の OAuth 登録・審査と、macOS の Developer ID 署名／公証は別の手続きです。Google の設定が正しくても、Apple の署名や公証が済んだことにはなりません。配布物には署名後の変更を加えず、別 Mac で起動・ブラウザ同意・再起動後の利用・接続削除を確認してください。

同梱の自動テストでは合成のアカウント、注入した認証応答、私有 SQLite、メモリ上の資格情報ストアを使います。実際の Google アプリ登録、審査、公開クライアントの認証成功や macOS 公証を代替しません。開発者自身の Google アカウントに、配布テストだけのため自動ログインすることもありません。

## ChatGPTと利用者自身のAPI契約

「ChatGPTを接続…」から「Continue with ChatGPT」を選ぶと、標準ブラウザで本人のアカウントに接続します。OpenAIのOSS向けSign in with ChatGPTの動的クライアント登録を使うため、配布元の共用APIキーやCodexの保存済み認証情報を同梱しません。PKCE・state・nonce、IDトークンの署名・発行元・宛先を検証します。[サインイン仕様](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)

ログインできることと、ChatGPTの利用枠で推論できることは別です。必要な利用権限が付いた接続のみ、アカウントで利用可能なモデルを読み込んで選べます。本人のプラン・クレジット・ワークスペース設定と上限が適用されます。画面には使用する方式と利用状況へのリンクを表示します。[モデル・推論の仕様](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)

対応範囲は接続画面での手動要約・文章作成と、メールテンプレート編集画面のAI作成です。入力した文章や生成指示はOpenAIへ送ります。検索用の埋め込み、文書・メールの自動処理、企業調査など既存の別経路を、ChatGPT契約だけで利用できるとは扱いません。これらは各利用者のAPIキーや追加サービス設定を使います。

「APIキー方式を使用」を選ぶと、対応する既存処理は本人が設定したAPIキーを使います。ChatGPTの利用制限・認証エラーからAPI課金へ自動で切り替えません。APIの利用料は利用者のAPI契約に発生し、ChatGPTプランの利用枠とは別です。配布元がAI利用料を立て替える仕組みはありません。

接続・更新トークンはCRMの保存場所と所有者に結び付けてMacのキーチェーンに保持します。アカウント切替、サインアウト、終了時は進行中の処理を取り消し、古い結果を新しいアカウントの結果として採用しません。サインアウト時にリモート失効を確認できなければ、その旨を画面に表示します。

バックグラウンド利用の同意は初期状態で無効です。接続しただけで既存の予約処理を開始しません。現在のChatGPT接続は上記の手動処理を対象にしており、同意を有効にしても未対応の自動処理をChatGPTへ切り替えません。配布・改変時は、本人の端末で本人の利用枠を使うOSS向けの条件を確認してください。[Sign in with ChatGPT利用条件](https://openai.com/policies/sign-in-with-chatgpt-terms/)

自動テストは合成の署名済みトークン、ローカルのコールバック、注入した推論応答を使います。実ChatGPTアカウントのプラン適格性、実際のクライアント登録、課金枠の消費までを検証したものではありません。
