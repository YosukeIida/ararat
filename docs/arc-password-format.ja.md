# macOS で Arc のパスワード保存形式を確認する

[English](arc-password-format.md)

所有者の同席のもと、`ARC_KEYCHAIN_PATH` に所有者が選んだキーチェーンのパスを、`ARC_LOGIN_DATA_PATH` に確認対象の Arc プロファイルの `Login Data` のパスを指定します。次のコマンドは所有者の端末で実行します。キーチェーン項目の属性は端末内に留め、サービス名に一致する項目の有無、スキーマのバージョン、先頭 3 バイトだけを記録します。

```sh
/usr/bin/security find-generic-password -s 'Arc Safe Storage' "${ARC_KEYCHAIN_PATH:?select a keychain}"
/usr/bin/sqlite3 -readonly "${ARC_LOGIN_DATA_PATH:?select an Arc Login Data file}" \
  "SELECT value FROM meta WHERE key = 'version';"
/usr/bin/sqlite3 -readonly "${ARC_LOGIN_DATA_PATH:?select an Arc Login Data file}" \
  "SELECT hex(substr(password_value, 1, 3)) FROM logins WHERE blacklisted_by_user = 0 AND typeof(password_value) = 'blob' AND length(password_value) >= 3 LIMIT 1;"
```

`security` コマンドはキーチェーン項目の属性だけを取得します。Ararat が採用している Chromium のスキーマのバージョンは `43` です。`763130` は `v10` の 16 進表記です。該当行がない場合やクエリが失敗した場合は未確認と記録します。接頭辞の確認は取得した 1 行に限ります。
