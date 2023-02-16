# nostr-bot-traininfo

## 実行環境
- Ruby 2.7.7
- gem
```sh
gem install nostr_ruby
gem install open-uri
gem install parallel
```

## 設定ファイル
`config.example.json`を参考に`config.json`を作成してください
- `test` trueにするとポストしません
- `timeout` 1リレーごとのタイムアウト秒数
- `relay` ポスト先のリレー
- `traininfo` 運行情報の取得とnostr秘密鍵の指定(複数可)
  - `private_key` 秘密鍵(HEX)
  - `url` 対象ページのURL。`https://www3.nhk.../traffic/地方名/`
  - `jsonfile` 取得するJSONのパス。`traininfo_area_地方コード.json`。対象ページをブラウザで開いて開発者ツールで調べることができます

## 実行コマンド
```sh
ruby traininfo.rb
```
相手方の負荷に気をつけながら適宜cronに設定してください

## 生成ファイル
- `./`
  - `log.log` ログ
  - `data/`
    - `*.json` ダウンロードしたJSONファイル
    - `*.old.json` 1世代前のJSONファイル(デバッグ用)
