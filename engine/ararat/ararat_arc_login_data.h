#ifndef ARARAT_CORE_ARARAT_ARC_LOGIN_DATA_H_
#define ARARAT_CORE_ARARAT_ARC_LOGIN_DATA_H_

#include <string>
#include <string_view>
#include <vector>

namespace base {
class FilePath;
}

namespace ararat {

// One row of Arc's `logins` table, decrypted. The caller zeroes `password`.
struct ArcLogin {
  std::string origin_url;
  std::string signon_realm;
  std::u16string username;
  std::string password;  // UTF-8, as Chromium stores it before encryption.
  int scheme = 0;
  bool blocked = false;
};

enum class ArcLoginDataStatus {
  kOk,
  kUnreadable,          // Not a SQLite file, or no `logins` / `meta` table.
  kUnsupportedVersion,  // `meta.version` outside the range we have tested.
};

struct ArcLoginDataResult {
  ArcLoginDataStatus status = ArcLoginDataStatus::kUnreadable;
  std::vector<ArcLogin> logins;
  // Rows whose value has no `v10` prefix or does not decrypt with the key.
  size_t undecryptable = 0;
};

// Reads a copy of Arc's `Login Data` (Chromium's login database) and decrypts
// each `password_value` with the key derived from `safe_storage_secret`, the
// "Arc Safe Storage" Keychain password. Blocking; call off the UI thread.
ArcLoginDataResult ReadArcLoginData(const base::FilePath& copy,
                                    std::string_view safe_storage_secret);

// The inverse of the decryption above, for fixtures.
std::string EncryptArcPasswordForTesting(std::string_view safe_storage_secret,
                                         std::string_view plaintext);

// Writes a version-43 `Login Data` with `logins` for fixtures. A login whose
// `password` starts with "raw:" is stored as the bytes after the marker,
// unencrypted, to model rows the key cannot open.
bool WriteArcLoginDataForTesting(const base::FilePath& path,
                                 std::string_view safe_storage_secret,
                                 const std::vector<ArcLogin>& logins);

}  // namespace ararat

#endif  // ARARAT_CORE_ARARAT_ARC_LOGIN_DATA_H_
