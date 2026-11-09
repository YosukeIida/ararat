#ifndef ARARAT_ARARAT_HISTORY_FILES_H_
#define ARARAT_ARARAT_HISTORY_FILES_H_

#include <cstdint>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <vector>

#include "base/files/file_path.h"
#include "components/sessions/core/serialized_navigation_entry.h"

namespace ararat::tab_history {

struct Restore {
  std::vector<sessions::SerializedNavigationEntry> entries;
  int selected;
  std::string url;
};

struct FileState {
  bool exists = false;
  bool generation_current = false;
  uint64_t admitted_at = 0;
  int count = 0;
  int selected = -1;
  std::string url;
  std::string generation;
};

class Files {
 public:
  explicit Files(base::FilePath user_data);
  std::optional<std::string> Ensure(const std::string& profile);
  bool Clear(const std::string& profile, const std::string& generation);
  bool Purge(const std::string& profile, const std::string& item, uint64_t changed_at);
  bool Write(const std::string& profile, const std::string& item,
             const std::string& generation, uint64_t admitted_at,
             const Restore& history);
  bool WriteCurrent(const std::string& profile, const std::string& item,
                    uint64_t admitted_at, const Restore& history);
  std::optional<Restore> Read(const std::string& profile, const std::string& item,
                              const std::string& row_url);
  FileState Inspect(const std::string& profile, const std::string& item);

 private:
  base::FilePath ProfilePath(const std::string& profile) const;
  base::FilePath HistoryPath(const std::string& profile, const std::string& item) const;
  base::FilePath user_data_;
  std::map<std::string, std::string> generations_;
  std::set<std::string> blocked_;
};

bool RowAcceptsHistory(const std::string& file_url, const std::string& row_url);
std::string NewGeneration();

}  // namespace ararat::tab_history
#endif
