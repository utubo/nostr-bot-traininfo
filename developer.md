# nostr-bot-traininfo

## 実行環境
- Ruby 2.7.7
- gem
```sh
gem install nostr_ruby
gem install bskyrb
gem install open-uri
gem install parallel
```

## 設定ファイル
`config.example.json`を参考に`config.json`を作成してください
- `test` trueにするとポストしません
- `timeout` 1リレーごとのタイムアウト秒数
- `relay` ポスト先のリレー
- `traininfo` 運行情報の取得とnostr秘密鍵の指定(複数可)
  - `private_key` nostrの秘密鍵(HEX)
  - `bsky_username` Blueskyアカウントのユーザー名
  - `bsky_password` Blkeskyアカウントのパスワード
  - `url` 対象ページのURL。`https://www3.nhk.../traffic/地方名/`
  - `jsonfile` 取得するJSONのパス。`traininfo_area_地方コード.json`。対象ページをブラウザで開いて開発者ツールで調べることができます
  - `igrore_days` この日数の間変化がないものはスキップします
  - `ignore` 特定の条件でスキップします。配列で指定したオブジェクトのいずれかにマッチした場合スキップします

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
    - `*.dat.json` 以下のデータ
      - `history`: 各情報の最終取得日(n日間変わらないデータをスキップするため)
      - `last_post`: ポストした内容(同じ内容をポストしないために使用します)

