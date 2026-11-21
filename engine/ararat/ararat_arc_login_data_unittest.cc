#include "ararat/core/ararat_arc_login_data.h"

#include "base/files/scoped_temp_dir.h"
#include "sql/database.h"
#include "sql/statement.h"
#include "sql/test/test_helpers.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace ararat {
namespace {

constexpr char kSecret[] = "fixture-arc-secret";

class ArcLoginDataTest : public testing::Test {
 protected:
  void SetUp() override {
    ASSERT_TRUE(dir_.CreateUniqueTempDir());
    path_ = dir_.GetPath().AppendASCII("Login Data");
  }

  void Create(int version) {
    sql::Database db(sql::test::kTestTag);
    ASSERT_TRUE(db.Open(path_));
    ASSERT_TRUE(db.Execute("CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE "
                           "PRIMARY KEY, value LONGVARCHAR)"));
    sql::Statement meta(db.GetUniqueStatement(
        "INSERT INTO meta(key, value) VALUES('version', ?)"));
    meta.BindInt(0, version);
    ASSERT_TRUE(meta.Run());
    ASSERT_TRUE(db.Execute(
        "CREATE TABLE logins(origin_url VARCHAR, signon_realm VARCHAR, "
        "username_value VARCHAR, password_value BLOB, scheme INTEGER, "
        "blacklisted_by_user INTEGER)"));
  }

  void Add(std::string_view url, std::string_view user, std::string value,
           bool blocked = false) {
    sql::Database db(sql::test::kTestTag);
    ASSERT_TRUE(db.Open(path_));
    sql::Statement row(db.GetUniqueStatement(
        "INSERT INTO logins VALUES(?, ?, ?, ?, 0, ?)"));
    row.BindString(0, url);
    row.BindString(1, url);
    row.BindString(2, user);
    row.BindBlob(3, base::as_byte_span(value));
    row.BindBool(4, blocked);
    ASSERT_TRUE(row.Run());
  }

  base::ScopedTempDir dir_;
  base::FilePath path_;
};

TEST_F(ArcLoginDataTest, DecryptsRowsWithTheSafeStorageKey) {
  Create(43);
  Add("https://example.test/", "ann",
      EncryptArcPasswordForTesting(kSecret, "s3cr\"et, \xC3\xA9"));
  Add("https://never.test/", "", "", /*blocked=*/true);
  auto result = ReadArcLoginData(path_, kSecret);
  ASSERT_EQ(result.status, ArcLoginDataStatus::kOk);
  ASSERT_EQ(result.logins.size(), 2u);
  EXPECT_EQ(result.logins[0].username, u"ann");
  EXPECT_EQ(result.logins[0].password, "s3cr\"et, \xC3\xA9");
  EXPECT_TRUE(result.logins[1].blocked);
  EXPECT_EQ(result.undecryptable, 0u);
}

// The ciphertext comes from openssl with a key from Python's hashlib, so the
// format is checked against tools independent of this file.
TEST_F(ArcLoginDataTest, MatchesAnIndependentlyMadeValue) {
  Create(43);
  const uint8_t cipher[] = {0xc4, 0x59, 0x01, 0x67, 0xb9, 0x23, 0x81, 0xb3,
                            0x3c, 0x53, 0x28, 0x76, 0x91, 0x26, 0x38, 0xf6};
  std::string value = "v10";
  value.append(std::begin(cipher), std::end(cipher));
  Add("https://example.test/", "ann", value);
  auto result = ReadArcLoginData(path_, kSecret);
  ASSERT_EQ(result.logins.size(), 1u);
  EXPECT_EQ(result.logins[0].password, "hello arc");
  EXPECT_EQ(EncryptArcPasswordForTesting(kSecret, "hello arc"), value);
}

TEST_F(ArcLoginDataTest, CountsRowsTheKeyCannotOpen) {
  Create(43);
  Add("https://a.test/", "a", EncryptArcPasswordForTesting("other", "x"));
  Add("https://b.test/", "b", "v11whatever");
  Add("https://c.test/", "c", "plain");
  auto result = ReadArcLoginData(path_, kSecret);
  ASSERT_EQ(result.status, ArcLoginDataStatus::kOk);
  EXPECT_TRUE(result.logins.empty());
  EXPECT_EQ(result.undecryptable, 3u);
}

TEST_F(ArcLoginDataTest, RefusesUntestedVersions) {
  Create(44);
  EXPECT_EQ(ReadArcLoginData(path_, kSecret).status,
            ArcLoginDataStatus::kUnsupportedVersion);
}

TEST_F(ArcLoginDataTest, RefusesFilesThatAreNotLoginData) {
  EXPECT_EQ(ReadArcLoginData(path_, kSecret).status,
            ArcLoginDataStatus::kUnreadable);
}

}  // namespace
}  // namespace ararat
