#include "ararat/core/ararat_history_files.h"
#include "ararat/core/ararat_history_sequence.h"

#include <string>
#include <utility>

#include "base/files/file_util.h"
#include "base/files/scoped_temp_dir.h"
#include "base/functional/bind.h"
#include "base/pickle.h"
#include "base/strings/string_number_conversions.h"
#include "base/test/task_environment.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace ararat::tab_history {
namespace {
class HistoryFilesTest : public testing::Test {
 protected:
  void SetUp() override { ASSERT_TRUE(temp_.CreateUniqueTempDir()); }
  base::FilePath Path(const std::string& profile, const std::string& item) {
    return temp_.GetPath().AppendASCII(profile).AppendASCII("Ararat Tab History")
        .AppendASCII(base::HexEncode(item));
  }
  Restore History() {
    Restore result;
    result.selected = 0;
    result.url = "https://example.test/";
    sessions::SerializedNavigationEntry entry;
    entry.set_index(0);
    result.entries.push_back(std::move(entry));
    return result;
  }
  bool WriteFixture(const std::string& generation, const std::string& stored_item,
                    int selected, int count, bool entry, bool trailing) {
    base::Pickle pickle;
    pickle.WriteString(stored_item);
    pickle.WriteString("https://example.test/");
    pickle.WriteInt(selected);
    pickle.WriteInt(count);
    if (entry) for (int i = 0; i < count; ++i) History().entries[0].WriteToPickle(256 * 1024, &pickle);
    if (trailing) pickle.WriteInt(42);
    std::string bytes = "ARH1" + generation + std::string(8, '\0');
    bytes.append(pickle.AsStringView());
    return base::WriteFile(Path("Default", "item"), bytes);
  }
  base::ScopedTempDir temp_;
};

TEST_F(HistoryFilesTest, PersistsHistoryAndRejectsDifferentRowURL) {
  Files files(temp_.GetPath());
  auto generation = files.Ensure("Default");
  ASSERT_TRUE(generation);
  ASSERT_TRUE(files.Write("Default", "item", *generation, 8, History()));
  auto inspected = files.Inspect("Default", "item");
  EXPECT_TRUE(inspected.exists);
  EXPECT_TRUE(inspected.generation_current);
  EXPECT_EQ(inspected.admitted_at, 8u);
  EXPECT_EQ(inspected.count, 1);
  EXPECT_EQ(inspected.selected, 0);
  EXPECT_EQ(inspected.url, "https://example.test/");
  Files reopened(temp_.GetPath());
  auto history = reopened.Read("Default", "item", "https://example.test/");
  ASSERT_TRUE(history);
  EXPECT_EQ(history->selected, 0);
  EXPECT_EQ(history->entries.size(), 1u);
  EXPECT_FALSE(reopened.Read("Default", "item", "https://other.test/"));
  EXPECT_FALSE(base::PathExists(Path("Default", "item")));
}

TEST_F(HistoryFilesTest, CorruptHistoryIsRejectedAndRemoved) {
  Files files(temp_.GetPath());
  ASSERT_TRUE(files.Ensure("Default"));
  ASSERT_TRUE(base::WriteFile(Path("Default", "item"), "garbage"));
  EXPECT_FALSE(files.Read("Default", "item", "https://example.test/"));
  EXPECT_FALSE(base::PathExists(Path("Default", "item")));
}

TEST_F(HistoryFilesTest, TruncatedPickleIsRejectedAndRemoved) {
  Files files(temp_.GetPath());
  auto generation = files.Ensure("Default");
  ASSERT_TRUE(generation);
  ASSERT_TRUE(files.Write("Default", "item", *generation, 1, History()));
  std::string bytes;
  ASSERT_TRUE(base::ReadFileToString(Path("Default", "item"), &bytes));
  bytes.resize(48);
  ASSERT_TRUE(base::WriteFile(Path("Default", "item"), bytes));
  EXPECT_FALSE(files.Read("Default", "item", "https://example.test/"));
  EXPECT_FALSE(base::PathExists(Path("Default", "item")));
}

TEST_F(HistoryFilesTest, RejectsExcessiveCountAndInvalidSelection) {
  Files files(temp_.GetPath());
  auto generation = files.Ensure("Default");
  ASSERT_TRUE(generation);
  ASSERT_TRUE(WriteFixture(*generation, "item", 0, 14, true, false));
  EXPECT_FALSE(files.Read("Default", "item", "https://example.test/"));
  EXPECT_FALSE(base::PathExists(Path("Default", "item")));
  ASSERT_TRUE(WriteFixture(*generation, "item", 1, 1, true, false));
  EXPECT_FALSE(files.Read("Default", "item", "https://example.test/"));
  EXPECT_FALSE(base::PathExists(Path("Default", "item")));
}

TEST_F(HistoryFilesTest, RejectsTrailingDataAndWrongItem) {
  Files files(temp_.GetPath());
  auto generation = files.Ensure("Default");
  ASSERT_TRUE(generation);
  ASSERT_TRUE(WriteFixture(*generation, "item", 0, 1, true, true));
  EXPECT_FALSE(files.Read("Default", "item", "https://example.test/"));
  EXPECT_FALSE(base::PathExists(Path("Default", "item")));
  ASSERT_TRUE(WriteFixture(*generation, "other", 0, 1, true, false));
  EXPECT_FALSE(files.Read("Default", "item", "https://example.test/"));
  EXPECT_FALSE(base::PathExists(Path("Default", "item")));
}

TEST_F(HistoryFilesTest, RejectsOldGenerationDuringRead) {
  Files files(temp_.GetPath());
  auto generation = files.Ensure("Default");
  ASSERT_TRUE(generation);
  auto old_generation = NewGeneration();
  ASSERT_NE(old_generation, *generation);
  ASSERT_TRUE(WriteFixture(old_generation, "item", 0, 1, true, false));
  EXPECT_FALSE(files.Read("Default", "item", "https://example.test/"));
  EXPECT_FALSE(base::PathExists(Path("Default", "item")));
}

TEST_F(HistoryFilesTest, PurgePreservesNewerAdmissionAndRemovesOlder) {
  Files files(temp_.GetPath());
  auto generation = files.Ensure("Default");
  ASSERT_TRUE(generation);
  ASSERT_TRUE(files.Write("Default", "item", *generation, 10, History()));
  EXPECT_TRUE(files.Purge("Default", "item", 10));
  EXPECT_TRUE(files.Read("Default", "item", "https://example.test/"));
  EXPECT_TRUE(files.Purge("Default", "item", 11));
  EXPECT_FALSE(base::PathExists(Path("Default", "item")));
  EXPECT_TRUE(files.Purge("Default", "item", 11));
}

TEST_F(HistoryFilesTest, PurgeDoesNotDependOnRemovingUnrelatedStrayFiles) {
  Files original(temp_.GetPath());
  auto generation = original.Ensure("Default");
  ASSERT_TRUE(generation);
  ASSERT_TRUE(original.Write("Default", "item", *generation, 1, History()));
  auto stray = Path("Default", "item").DirName().AppendASCII("stray");
  ASSERT_TRUE(base::CreateDirectory(stray));
  ASSERT_TRUE(base::WriteFile(stray.AppendASCII("child"), "x"));
  ASSERT_TRUE(base::SetPosixFilePermissions(stray, 0500));
  Files reopened(temp_.GetPath());
  EXPECT_TRUE(reopened.Purge("Default", "item", 2));
  EXPECT_FALSE(base::PathExists(Path("Default", "item")));
  EXPECT_TRUE(base::SetPosixFilePermissions(stray, 0700));
}

TEST_F(HistoryFilesTest, InvalidMarkerInvalidatesOldHistory) {
  Files files(temp_.GetPath());
  auto generation = files.Ensure("Default");
  ASSERT_TRUE(generation);
  ASSERT_TRUE(files.Write("Default", "item", *generation, 1, History()));
  auto marker = temp_.GetPath().AppendASCII("Default").AppendASCII("Ararat Tab History Generation");
  ASSERT_TRUE(base::WriteFile(marker, "invalid"));
  Files reopened(temp_.GetPath());
  auto replacement = reopened.Ensure("Default");
  ASSERT_TRUE(replacement);
  EXPECT_NE(*generation, *replacement);
  EXPECT_FALSE(base::PathExists(Path("Default", "item")));
}

TEST_F(HistoryFilesTest, MarkerWriteFailureRejectsProfile) {
  auto profile = temp_.GetPath().AppendASCII("Default");
  ASSERT_TRUE(base::CreateDirectory(profile.AppendASCII("Ararat Tab History Generation")));
  Files files(temp_.GetPath());
  EXPECT_FALSE(files.Ensure("Default"));
  EXPECT_FALSE(files.Clear("Default", NewGeneration()));
  ASSERT_TRUE(base::DeleteFile(profile.AppendASCII("Ararat Tab History Generation")));
  EXPECT_FALSE(files.Ensure("Default"));
  auto generation = NewGeneration();
  EXPECT_TRUE(files.Clear("Default", generation));
  EXPECT_EQ(files.Ensure("Default"), generation);
}

TEST_F(HistoryFilesTest, FailedClearCanRetryTheSameGeneration) {
  Files files(temp_.GetPath());
  auto generation = files.Ensure("Default");
  ASSERT_TRUE(generation);
  ASSERT_TRUE(files.Write("Default", "item", *generation, 1, History()));
  auto stray = Path("Default", "item").DirName().AppendASCII("stray");
  ASSERT_TRUE(base::CreateDirectory(stray));
  ASSERT_TRUE(base::WriteFile(stray.AppendASCII("child"), "x"));
  ASSERT_TRUE(base::SetPosixFilePermissions(stray, 0500));
  auto next = NewGeneration();
  EXPECT_FALSE(files.Clear("Default", next));
  EXPECT_TRUE(base::SetPosixFilePermissions(stray, 0700));
  EXPECT_TRUE(files.Clear("Default", next));
  EXPECT_FALSE(files.Read("Default", "item", "https://example.test/"));
  EXPECT_EQ(files.Ensure("Default"), next);
}

TEST_F(HistoryFilesTest, ProfilesAreIsolatedAndClearRejectsOldGeneration) {
  Files files(temp_.GetPath());
  auto first = files.Ensure("Default");
  auto second = files.Ensure("Profile 1");
  ASSERT_TRUE(first);
  ASSERT_TRUE(second);
  ASSERT_TRUE(files.Write("Default", "item", *first, 1, History()));
  ASSERT_TRUE(files.Write("Profile 1", "item", *second, 1, History()));
  const auto fresh = NewGeneration();
  ASSERT_TRUE(files.Clear("Default", fresh));
  EXPECT_FALSE(files.Write("Default", "item", *first, 1, History()));
  EXPECT_FALSE(files.Read("Default", "item", "https://example.test/"));
  EXPECT_TRUE(files.Read("Profile 1", "item", "https://example.test/"));
  EXPECT_TRUE(files.Write("Default", "item", fresh, 2, History()));
}

TEST_F(HistoryFilesTest, RejectsUnsafeProfileAndOversizedItem) {
  Files files(temp_.GetPath());
  EXPECT_FALSE(files.Ensure("../other"));
  EXPECT_FALSE(files.Ensure(std::string("Default\0other", 13)));
  auto generation = files.Ensure("Default");
  ASSERT_TRUE(generation);
  EXPECT_FALSE(files.Write("Default", std::string(101, 'a'), *generation, 1, History()));
  EXPECT_TRUE(files.Purge("Default", std::string(101, 'a'), 1));
}

TEST_F(HistoryFilesTest, SequenceOrdersWritesPurgesAndReads) {
  base::test::TaskEnvironment tasks;
  FileSequence files(temp_.GetPath());
  std::optional<std::string> generation;
  files.Ensure("Default", base::BindOnce([](std::optional<std::string>* out, std::optional<std::string> value) {
    *out = std::move(value);
  }, &generation));
  tasks.RunUntilIdle();
  ASSERT_TRUE(generation);
  bool written = false;
  bool purged = false;
  std::optional<Restore> result;
  files.Write("Default", "item", *generation, 2, History(),
      base::BindOnce([](bool* out, bool value) { *out = value; }, &written));
  files.Purge("Default", "item", 3,
      base::BindOnce([](bool* out, bool value) { *out = value; }, &purged));
  files.Read("Default", "item", "https://example.test/",
      base::BindOnce([](std::optional<Restore>* out, std::optional<Restore> value) { *out = std::move(value); }, &result));
  tasks.RunUntilIdle();
  EXPECT_TRUE(written);
  EXPECT_TRUE(purged);
  EXPECT_FALSE(result);
}

TEST_F(HistoryFilesTest, InitialWriteCompletesBeforeFollowingClear) {
  base::test::TaskEnvironment tasks;
  FileSequence files(temp_.GetPath());
  bool written = false;
  bool cleared = false;
  files.WriteCurrent("Default", "item", 2, History(),
      base::BindOnce([](bool* out, bool value) { *out = value; }, &written));
  files.Clear("Default", NewGeneration(),
      base::BindOnce([](bool* out, bool value) { *out = value; }, &cleared));
  tasks.RunUntilIdle();
  EXPECT_TRUE(written);
  EXPECT_TRUE(cleared);
  EXPECT_FALSE(base::PathExists(Path("Default", "item")));
}
}  // namespace
}  // namespace ararat::tab_history
