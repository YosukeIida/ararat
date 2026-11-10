#ifndef ARARAT_ARARAT_TAB_HISTORY_H_
#define ARARAT_ARARAT_TAB_HISTORY_H_

#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <utility>

#include "ararat/core/ararat_history_sequence.h"
#include "base/functional/callback.h"
#include "base/timer/timer.h"
#include "content/public/browser/web_contents_observer.h"

namespace content { class WebContents; }
namespace ararat::tab_history {
class Writer;
enum class InvalidationSource { Request, Notification, Expiration };

class TabHistory {
 public:
  TabHistory();
  static TabHistory& Get();
  std::unique_ptr<Writer> Bind(content::WebContents* contents, const std::string& item, uint64_t stamp);
  void Purge(std::string profile, std::string item, uint64_t changed_at, base::OnceCallback<void(bool)> reply);
  void Read(std::string profile, std::string item, std::string row_url,
            base::OnceCallback<void(std::optional<Restore>)> reply);
  void ApplyInvalidationPolicy(const std::string& profile, InvalidationSource source);
  uint64_t Epoch(const std::string& profile);
  bool Allows(const std::string& profile, uint64_t epoch);
  bool Blocked(const std::string& profile);
  void Remove(Writer* writer);
  std::string Generation(const std::string& profile);
  Writer* FindWriter(const std::string& profile, const std::string& item) const;
  FileSequence& sequence() { return sequence_; }

 private:
  struct ProfileState { std::string generation; bool loading = false; bool blocked = false; bool clearing = false; uint64_t clear_epoch = 0; };
  void PostClear(const std::string& profile);
  void RetryClear(const std::string& profile);
  void DeletionFailed(const char* kind, const std::string& profile, const std::string& item);
  std::map<std::string, ProfileState> profiles_;
  std::map<std::pair<std::string, std::string>, Writer*> writers_;
  FileSequence sequence_;
};
void StartHistoryWatcher();

class Writer : public content::WebContentsObserver {
 public:
  Writer(content::WebContents* contents, std::string profile, std::string item, uint64_t stamp);
  ~Writer() override;
  void Fence();
  void ReplaceContents(content::WebContents* contents);
  void Save(base::OnceCallback<void(bool)> reply);
  void NavigationEntryCommitted(const content::LoadCommittedDetails&) override;
  void NavigationEntryChanged(const content::EntryChangedDetails&) override;
  void NavigationListPruned(const content::PrunedDetails&) override;
  void NavigationEntriesDeleted() override;
  void WebContentsDestroyed() override;
  const std::string& profile() const { return profile_; }
  const std::string& item() const { return item_; }
  uint64_t admitted_at() const { return admitted_at_; }
  bool fenced() const { return fenced_; }

 private:
  void SaveSoon();
  std::string profile_;
  std::string item_;
  uint64_t admitted_at_;
  bool fenced_ = false;
  bool unsaved_ = false;
  base::OneShotTimer timer_;
};
}  // namespace ararat::tab_history
#endif
