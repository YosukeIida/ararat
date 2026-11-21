#include "ararat/core/ararat_arc_login_data.h"

#include <array>
#include <optional>

#include "base/containers/span.h"
#include "base/files/file_path.h"
#include "crypto/aes_cbc.h"
#include "crypto/secure_util.h"
#include "sql/database.h"
#include "sql/statement.h"
#include "third_party/boringssl/src/include/openssl/evp.h"

namespace ararat {

namespace {

// Chromium's macOS OSCrypt format (components/os_crypt/async/browser/
// keychain_key_provider.mm and os_crypt_mac.mm), which Arc inherits.
constexpr std::string_view kPrefix = "v10";
constexpr auto kSalt = std::to_array<uint8_t>(
    {'s', 'a', 'l', 't', 'y', 's', 'a', 'l', 't'});
constexpr unsigned kIterations = 1003;
constexpr size_t kKeySize = 16;
constexpr std::array<uint8_t, crypto::aes_cbc::kBlockSize> kIv = [] {
  std::array<uint8_t, crypto::aes_cbc::kBlockSize> iv{};
  iv.fill(' ');
  return iv;
}();

// Login database versions written by the Chromium releases Arc has shipped on
// and checked against our fixture. Anything else is refused rather than read.
constexpr int kMinVersion = 40;
constexpr int kMaxVersion = 43;

std::array<uint8_t, kKeySize> DeriveKey(std::string_view secret) {
  std::array<uint8_t, kKeySize> key{};
  PKCS5_PBKDF2_HMAC_SHA1(secret.data(), secret.size(), kSalt.data(),
                         kSalt.size(), kIterations, key.size(), key.data());
  return key;
}

}  // namespace

ArcLoginDataResult ReadArcLoginData(const base::FilePath& copy,
                                    std::string_view safe_storage_secret) {
  ArcLoginDataResult result;
  sql::Database db(sql::DatabaseOptions().set_read_only(true), "Passwords");
  if (!db.Open(copy))
    return result;
  sql::Statement version(
      db.GetUniqueStatement("SELECT value FROM meta WHERE key='version'"));
  if (!version.is_valid() || !version.Step())
    return result;
  const int schema = version.ColumnInt(0);
  if (schema < kMinVersion || schema > kMaxVersion) {
    result.status = ArcLoginDataStatus::kUnsupportedVersion;
    return result;
  }
  sql::Statement rows(db.GetUniqueStatement(
      "SELECT origin_url, signon_realm, username_value, password_value, "
      "scheme, blacklisted_by_user FROM logins"));
  if (!rows.is_valid())
    return result;
  auto key = DeriveKey(safe_storage_secret);
  while (rows.Step()) {
    ArcLogin login;
    login.origin_url = rows.ColumnString(0);
    login.signon_realm = rows.ColumnString(1);
    login.username = rows.ColumnString16(2);
    login.scheme = rows.ColumnInt(4);
    login.blocked = rows.ColumnBool(5);
    auto value = rows.ColumnBlob(3);
    if (login.blocked && value.empty()) {
      result.logins.push_back(std::move(login));
      continue;
    }
    if (value.size() <= kPrefix.size() ||
        !std::equal(kPrefix.begin(), kPrefix.end(), value.begin())) {
      ++result.undecryptable;
      continue;
    }
    std::optional<std::vector<uint8_t>> plain =
        crypto::aes_cbc::Decrypt(key, kIv, value.subspan(kPrefix.size()));
    if (!plain) {
      ++result.undecryptable;
      continue;
    }
    login.password.assign(plain->begin(), plain->end());
    crypto::SecureZeroBuffer(base::span(*plain));
    result.logins.push_back(std::move(login));
  }
  crypto::SecureZeroBuffer(base::span(key));
  result.status = rows.Succeeded() ? ArcLoginDataStatus::kOk
                                   : ArcLoginDataStatus::kUnreadable;
  return result;
}

std::string EncryptArcPasswordForTesting(std::string_view safe_storage_secret,
                                         std::string_view plaintext) {
  auto key = DeriveKey(safe_storage_secret);
  std::vector<uint8_t> cipher =
      crypto::aes_cbc::Encrypt(key, kIv, base::as_byte_span(plaintext));
  std::string out(kPrefix);
  out.append(cipher.begin(), cipher.end());
  return out;
}

}  // namespace ararat
