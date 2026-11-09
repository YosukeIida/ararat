#include "ararat/core/ararat_history_sequence.h"

#include <utility>

#include "base/functional/callback.h"
#include "base/task/thread_pool.h"

namespace ararat::tab_history {
FileSequence::FileSequence(base::FilePath user_data)
    : files_(base::ThreadPool::CreateSequencedTaskRunner(
          {base::MayBlock(), base::TaskPriority::USER_VISIBLE,
           base::TaskShutdownBehavior::BLOCK_SHUTDOWN}), std::move(user_data)) {}

void FileSequence::Ensure(std::string profile, base::OnceCallback<void(std::optional<std::string>)> reply) {
  files_.AsyncCall(&Files::Ensure).WithArgs(std::move(profile)).Then(std::move(reply));
}
void FileSequence::Clear(std::string profile, std::string generation, base::OnceCallback<void(bool)> reply) {
  files_.AsyncCall(&Files::Clear).WithArgs(std::move(profile), std::move(generation)).Then(std::move(reply));
}
void FileSequence::Purge(std::string profile, std::string item, uint64_t changed_at, base::OnceCallback<void(bool)> reply) {
  files_.AsyncCall(&Files::Purge).WithArgs(std::move(profile), std::move(item), changed_at).Then(std::move(reply));
}
void FileSequence::Write(std::string profile, std::string item, std::string generation,
                         uint64_t admitted_at, Restore history, base::OnceCallback<void(bool)> reply) {
  files_.AsyncCall(&Files::Write).WithArgs(std::move(profile), std::move(item), std::move(generation),
                                          admitted_at, std::move(history)).Then(std::move(reply));
}
void FileSequence::Read(std::string profile, std::string item, std::string row_url,
                        base::OnceCallback<void(std::optional<Restore>)> reply) {
  files_.AsyncCall(&Files::Read).WithArgs(std::move(profile), std::move(item), std::move(row_url)).Then(std::move(reply));
}
void FileSequence::WriteCurrent(std::string profile, std::string item, uint64_t admitted_at,
                                Restore history, base::OnceCallback<void(bool)> reply) {
  files_.AsyncCall(&Files::WriteCurrent).WithArgs(std::move(profile), std::move(item), admitted_at,
                                                 std::move(history)).Then(std::move(reply));
}
void FileSequence::Inspect(std::string profile, std::string item, base::OnceCallback<void(FileState)> reply) {
  files_.AsyncCall(&Files::Inspect).WithArgs(std::move(profile), std::move(item)).Then(std::move(reply));
}
}  // namespace ararat::tab_history
