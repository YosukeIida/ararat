#ifndef ARARAT_ARARAT_HISTORY_SEQUENCE_H_
#define ARARAT_ARARAT_HISTORY_SEQUENCE_H_

#include "ararat/core/ararat_history_files.h"
#include "base/functional/callback_forward.h"
#include "base/threading/sequence_bound.h"

namespace ararat::tab_history {

class FileSequence {
 public:
  explicit FileSequence(base::FilePath user_data);
  void Ensure(std::string profile, base::OnceCallback<void(std::optional<std::string>)> reply);
  void Clear(std::string profile, std::string generation, base::OnceCallback<void(bool)> reply);
  void Purge(std::string profile, std::string item, uint64_t changed_at, base::OnceCallback<void(bool)> reply);
  void Write(std::string profile, std::string item, std::string generation,
             uint64_t admitted_at, Restore history, base::OnceCallback<void(bool)> reply);
  void WriteCurrent(std::string profile, std::string item, uint64_t admitted_at,
                    Restore history, base::OnceCallback<void(bool)> reply);
  void Read(std::string profile, std::string item, std::string row_url,
            base::OnceCallback<void(std::optional<Restore>)> reply);
  void Inspect(std::string profile, std::string item, base::OnceCallback<void(FileState)> reply);

 private:
  base::SequenceBound<Files> files_;
};
}  // namespace ararat::tab_history
#endif
