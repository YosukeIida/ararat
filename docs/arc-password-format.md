# Check Arc’s password-store format on macOS

[日本語](arc-password-format.ja.md)

With the owner present, set `ARC_KEYCHAIN_PATH` to the path of the keychain the owner selected and `ARC_LOGIN_DATA_PATH` to the `Login Data` file for the Arc profile being checked. Run these commands locally. Keep the keychain attributes on the owner’s machine and record only whether the service was found, the schema version, and the three-byte prefix.

```sh
/usr/bin/security find-generic-password -s 'Arc Safe Storage' "${ARC_KEYCHAIN_PATH:?select a keychain}"
/usr/bin/sqlite3 -readonly "${ARC_LOGIN_DATA_PATH:?select an Arc Login Data file}" \
  "SELECT value FROM meta WHERE key = 'version';"
/usr/bin/sqlite3 -readonly "${ARC_LOGIN_DATA_PATH:?select an Arc Login Data file}" \
  "SELECT hex(substr(password_value, 1, 3)) FROM logins WHERE blacklisted_by_user = 0 AND typeof(password_value) = 'blob' AND length(password_value) >= 3 LIMIT 1;"
```

The Keychain command requests attributes only. The pinned Chromium build writes schema version `43`. The prefix `763130` is the hex encoding of `v10`. If a query returns no row or fails, record that observation as unconfirmed. The prefix describes only the sampled row.
