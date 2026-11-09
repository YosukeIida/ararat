// Copyright 2026 Ardia. Apache-2.0; see third_party/ardia/LICENSE.Apache-2.0.
// Derived from Ardia (mantrakp04/ardia@ce5eb74,
// engine/chromium/src/chrome/browser/ardia/ac_tab_restore_history.cc, Apache-2.0).

#include "ararat/core/ararat_history_files.h"

#include <algorithm>
#include <array>
#include <string_view>
#include <utility>

#include "base/containers/span.h"
#include "base/files/file.h"
#include "base/files/file_enumerator.h"
#include "base/files/file_util.h"
#include "base/files/important_file_writer.h"
#include "base/pickle.h"
#include "base/rand_util.h"
#include "base/strings/string_number_conversions.h"
#include "base/time/time.h"

namespace ararat::tab_history {
namespace {
constexpr char kDirectory[] = "Ararat Tab History";
constexpr char kMarker[] = "Ararat Tab History Generation";
constexpr size_t kPrefix = 44;
constexpr size_t kMaxFile = 4 * 1024 * 1024;
constexpr int kMaxEntry = 256 * 1024;

bool ValidGeneration(std::string_view value) {
  return value.size() == 32 && std::all_of(value.begin(), value.end(), [](char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
  });
}

bool ValidItem(std::string_view item) { return !item.empty() && item.size() <= 100; }

bool ValidName(std::string_view name) {
  return !name.empty() && name.size() <= 200 && name.size() % 2 == 0 &&
      std::all_of(name.begin(), name.end(), [](char c) {
        return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'F');
      });
}

bool PrefixMatches(std::string_view bytes, std::string_view generation) {
  return bytes.size() >= kPrefix && bytes.substr(0, 4) == "ARH1" &&
      bytes.substr(4, 32) == generation;
}

uint64_t Stamp(std::string_view bytes) {
  uint64_t value = 0;
  for (int i = 0; i < 8; ++i)
    value |= static_cast<uint64_t>(static_cast<unsigned char>(bytes[36 + i])) << (8 * i);
  return value;
}

bool DeleteDirectoryContents(const base::FilePath& dir) {
  if (!base::CreateDirectory(dir)) return false;
  base::FileEnumerator files(dir, false,
      base::FileEnumerator::FILES | base::FileEnumerator::DIRECTORIES | base::FileEnumerator::SHOW_SYM_LINKS,
      {}, base::FileEnumerator::FolderSearchPolicy::ALL,
      base::FileEnumerator::ErrorPolicy::STOP_ENUMERATION);
  bool ok = true;
  for (auto path = files.Next(); !path.empty(); path = files.Next())
    ok = base::DeletePathRecursively(path) && ok;
  return files.GetError() == base::File::FILE_OK && ok;
}

bool Prune(const base::FilePath& dir, const std::string& generation) {
  if (!base::CreateDirectory(dir)) return false;
  base::FileEnumerator files(dir, false,
      base::FileEnumerator::FILES | base::FileEnumerator::DIRECTORIES | base::FileEnumerator::SHOW_SYM_LINKS,
      {}, base::FileEnumerator::FolderSearchPolicy::ALL,
      base::FileEnumerator::ErrorPolicy::STOP_ENUMERATION);
  const auto cutoff = base::Time::Now() - base::Days(90);
  bool ok = true;
  for (auto path = files.Next(); !path.empty(); path = files.Next()) {
    std::array<char, kPrefix> prefix;
    int count = base::ReadFile(path, prefix.data(), prefix.size());
    if (!ValidName(path.BaseName().value()) || files.GetInfo().GetLastModifiedTime() < cutoff ||
        count != static_cast<int>(kPrefix) || !PrefixMatches(std::string_view(prefix.data(), kPrefix), generation))
      ok = base::DeletePathRecursively(path) && ok;
  }
  return files.GetError() == base::File::FILE_OK && ok;
}
}  // namespace

std::string NewGeneration() { return base::HexEncodeLower(base::RandBytesAsString(16)); }

bool RowAcceptsHistory(const std::string& file_url, const std::string& row_url) {
  return file_url == row_url;
}

Files::Files(base::FilePath user_data) : user_data_(std::move(user_data)) {}

base::FilePath Files::ProfilePath(const std::string& profile) const {
  base::FilePath part(profile);
  if (profile.find('\0') != std::string::npos || part.empty() || part.IsAbsolute() ||
      part.ReferencesParent() || part.BaseName() != part || part.value() == ".")
    return {};
  return user_data_.Append(part);
}

base::FilePath Files::HistoryPath(const std::string& profile, const std::string& item) const {
  auto path = ProfilePath(profile);
  if (path.empty() || !ValidItem(item)) return {};
  return path.AppendASCII(kDirectory).AppendASCII(base::HexEncode(item));
}

std::optional<std::string> Files::Ensure(const std::string& profile) {
  if (blocked_.contains(profile)) return std::nullopt;
  if (auto found = generations_.find(profile); found != generations_.end()) return found->second;
  auto root = ProfilePath(profile);
  if (root.empty()) return std::nullopt;
  std::string generation;
  auto marker = root.AppendASCII(kMarker);
  if (!base::ReadFileToStringWithMaxSize(marker, &generation, 64) || !ValidGeneration(generation)) {
    generation = NewGeneration();
    if (!base::CreateDirectory(root) || !base::ImportantFileWriter::WriteFileAtomically(marker, generation))
      return std::nullopt;
    if (!DeleteDirectoryContents(root.AppendASCII(kDirectory))) return std::nullopt;
  }
  if (!Prune(root.AppendASCII(kDirectory), generation)) return std::nullopt;
  generations_.emplace(profile, generation);
  return generation;
}

bool Files::Clear(const std::string& profile, const std::string& generation) {
  auto root = ProfilePath(profile);
  if (root.empty() || !ValidGeneration(generation)) return false;
  bool marker = base::CreateDirectory(root) &&
      base::ImportantFileWriter::WriteFileAtomically(root.AppendASCII(kMarker), generation);
  if (marker) {
    generations_[profile] = generation;
    blocked_.erase(profile);
  } else {
    generations_.erase(profile);
    blocked_.insert(profile);
  }
  bool deleted = DeleteDirectoryContents(root.AppendASCII(kDirectory));
  return marker && deleted;
}

bool Files::Purge(const std::string& profile, const std::string& item, uint64_t changed_at) {
  if (!ValidItem(item)) return !ProfilePath(profile).empty();
  auto path = HistoryPath(profile, item);
  if (path.empty()) return false;
  (void)Ensure(profile);
  base::File file(path, base::File::FLAG_OPEN | base::File::FLAG_READ);
  if (!file.IsValid()) return file.error_details() == base::File::FILE_ERROR_NOT_FOUND;
  std::array<uint8_t, kPrefix> prefix;
  auto count = file.ReadAtCurrentPos(prefix);
  if (!count) return false;
  std::string_view bytes(reinterpret_cast<const char*>(prefix.data()), *count);
  bool remove = bytes.size() < kPrefix || bytes.substr(0, 4) != "ARH1" || Stamp(bytes) < changed_at;
  file.Close();
  return !remove || base::DeleteFile(path);
}

bool Files::Write(const std::string& profile, const std::string& item,
                  const std::string& generation, uint64_t admitted_at, const Restore& history) {
  auto path = HistoryPath(profile, item);
  auto current = Ensure(profile);
  if (path.empty() || !current || *current != generation || history.entries.empty() ||
      history.entries.size() > 13 || history.selected < 0 ||
      static_cast<size_t>(history.selected) >= history.entries.size()) return false;
  base::Pickle pickle;
  pickle.WriteString(item);
  pickle.WriteString(history.url);
  pickle.WriteInt(history.selected);
  pickle.WriteInt(static_cast<int>(history.entries.size()));
  for (const auto& entry : history.entries) entry.WriteToPickle(kMaxEntry, &pickle);
  std::string bytes = "ARH1" + generation;
  for (int i = 0; i < 8; ++i) bytes.push_back(static_cast<char>(admitted_at >> (8 * i)));
  bytes.append(pickle.AsStringView());
  return bytes.size() <= kMaxFile && base::CreateDirectory(path.DirName()) &&
      base::ImportantFileWriter::WriteFileAtomically(path, bytes);
}

bool Files::WriteCurrent(const std::string& profile, const std::string& item,
                         uint64_t admitted_at, const Restore& history) {
  auto generation = Ensure(profile);
  return generation && Write(profile, item, *generation, admitted_at, history);
}

std::optional<Restore> Files::Read(const std::string& profile, const std::string& item,
                                   const std::string& row_url) {
  auto path = HistoryPath(profile, item);
  auto generation = Ensure(profile);
  if (path.empty() || !generation) return std::nullopt;
  std::string bytes;
  if (!base::ReadFileToStringWithMaxSize(path, &bytes, kMaxFile) || !PrefixMatches(bytes, *generation)) {
    base::DeleteFile(path);
    return std::nullopt;
  }
  auto pickle = base::PickleIterator::WithData(base::as_byte_span(std::string_view(bytes).substr(kPrefix)));
  std::string stored_item;
  Restore result;
  int count;
  if (!pickle.ReadString(&stored_item) || stored_item != item || !pickle.ReadString(&result.url) ||
      !RowAcceptsHistory(result.url, row_url) || !pickle.ReadInt(&result.selected) ||
      !pickle.ReadInt(&count) || count <= 0 || count > 13 || result.selected < 0 || result.selected >= count) {
    base::DeleteFile(path);
    return std::nullopt;
  }
  for (int i = 0; i < count; ++i) {
    sessions::SerializedNavigationEntry entry;
    if (!entry.ReadFromPickle(&pickle)) { base::DeleteFile(path); return std::nullopt; }
    result.entries.push_back(std::move(entry));
  }
  if (!pickle.ReachedEnd()) { base::DeleteFile(path); return std::nullopt; }
  return result;
}

FileState Files::Inspect(const std::string& profile, const std::string& item) {
  FileState state;
  auto path = HistoryPath(profile, item);
  auto generation = Ensure(profile);
  if (path.empty() || !generation) return state;
  state.generation = *generation;
  state.exists = base::PathExists(path);
  std::string bytes;
  if (!state.exists || !base::ReadFileToStringWithMaxSize(path, &bytes, kMaxFile) || bytes.size() < kPrefix)
    return state;
  state.generation_current = PrefixMatches(bytes, *generation);
  if (!state.generation_current) return state;
  state.admitted_at = Stamp(bytes);
  auto pickle = base::PickleIterator::WithData(base::as_byte_span(std::string_view(bytes).substr(kPrefix)));
  std::string stored_item;
  if (!pickle.ReadString(&stored_item) || stored_item != item || !pickle.ReadString(&state.url)) return state;
  auto history = Read(profile, item, state.url);
  if (history) {
    state.count = static_cast<int>(history->entries.size());
    state.selected = history->selected;
  }
  return state;
}
}  // namespace ararat::tab_history
