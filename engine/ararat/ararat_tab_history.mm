// Copyright 2026 Ardia. Apache-2.0; see third_party/ardia/LICENSE.Apache-2.0.
// Derived from Ardia (mantrakp04/ardia@ce5eb74,
// engine/chromium/src/chrome/browser/ardia/ac_tab_restore_history.cc, Apache-2.0).
#include "ararat/core/ararat_tab_history.h"

#import <Foundation/Foundation.h>

#include <algorithm>
#include <optional>
#include <cstdio>
#include <string_view>
#include <utility>

#include "ararat/core/public/AraratHostAPI.h"
#include "ararat/core/ararat_hooks.h"
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/no_destructor.h"
#include "base/scoped_multi_source_observation.h"
#include "base/scoped_observation.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/browsing_data/chrome_browsing_data_remover_constants.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/profiles/profile_manager_observer.h"
#include "chrome/browser/profiles/profile_observer.h"
#include "chrome/browser/history/history_service_factory.h"
#include "chrome/browser/sessions/session_common_utils.h"
#include "chrome/browser/sessions/exit_type_service.h"
#include "components/history/core/browser/history_service.h"
#include "components/history/core/browser/history_service_observer.h"
#include "components/history/core/browser/history_types.h"
#include "components/keyed_service/core/service_access_type.h"
#include "components/prefs/pref_service.h"
#include "components/sessions/content/content_serialized_navigation_builder.h"
#include "components/sessions/core/session_constants.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/browsing_data_remover.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/web_contents.h"
#include "url/gurl.h"

namespace ararat::tab_history {
namespace {
std::optional<Restore> Capture(content::WebContents* contents) {
  auto& controller = contents->GetController();
  const int current = controller.GetLastCommittedEntryIndex();
  auto* shown = controller.GetLastCommittedEntry();
  if (current < 0 || !shown || shown->IsInitialEntry()) return std::nullopt;
  Restore result;
  result.selected = -1;
  result.url = contents->GetLastCommittedURL().spec();
  const int first = std::max(0, current - sessions::gMaxPersistNavigationCount);
  const int end = std::min(controller.GetEntryCount(), current + sessions::gMaxPersistNavigationCount + 1);
  for (int i = first; i < end; ++i) {
    auto* entry = controller.GetEntryAtIndex(i);
    if (!entry || entry->IsInitialEntry() || !ShouldTrackURLForRestore(entry->GetVirtualURL())) continue;
    if (i == current) result.selected = static_cast<int>(result.entries.size());
    result.entries.push_back(sessions::ContentSerializedNavigationBuilder::FromNavigationEntry(i, entry));
  }
  if (result.selected < 0) return std::nullopt;
  return result;
}
}  // namespace

TabHistory::TabHistory() : sequence_(g_browser_process->profile_manager()->user_data_dir()) {}
TabHistory& TabHistory::Get() { static base::NoDestructor<TabHistory> instance; return *instance; }

std::string TabHistory::Generation(const std::string& profile) {
  auto& state = profiles_[profile];
  if (state.blocked) { RetryClear(profile); return {}; }
  if (state.generation.empty() && !state.loading) {
    state.loading = true;
    const auto epoch = state.clear_epoch;
    sequence_.Ensure(profile, base::BindOnce([](TabHistory* self, std::string profile, uint64_t epoch,
                                               std::optional<std::string> generation) {
      auto& state = self->profiles_[profile];
      state.loading = false;
      if (state.clear_epoch == epoch && generation) state.generation = *generation;
    }, base::Unretained(this), profile, epoch));
  }
  return state.generation;
}

std::unique_ptr<Writer> TabHistory::Bind(content::WebContents* contents, const std::string& item, uint64_t stamp) {
  auto* profile = Profile::FromBrowserContext(contents->GetBrowserContext());
  if (!profile || profile->IsOffTheRecord() || item.empty() || item.size() > 100) return nullptr;
  auto directory = profile->GetPath().BaseName().value();
  if (Blocked(directory)) return nullptr;
  auto key = std::make_pair(directory, item);
  if (auto found = writers_.find(key); found != writers_.end()) found->second->Fence();
  auto writer = std::make_unique<Writer>(contents, directory, item, stamp);
  writers_[key] = writer.get();
  Generation(directory);
  return writer;
}

void TabHistory::Remove(Writer* writer) {
  auto it = writers_.find({writer->profile(), writer->item()});
  if (it != writers_.end() && it->second == writer) writers_.erase(it);
}

Writer* TabHistory::FindWriter(const std::string& profile, const std::string& item) const {
  auto it = writers_.find({profile, item});
  return it == writers_.end() ? nullptr : it->second;
}

void TabHistory::Purge(std::string profile, std::string item, uint64_t changed_at,
                       base::OnceCallback<void(bool)> reply) {
  auto it = writers_.find({profile, item});
  if (it != writers_.end() && it->second->admitted_at() < changed_at) it->second->Fence();
  sequence_.Purge(profile, item, changed_at, base::BindOnce(
      [](TabHistory* self, std::string profile, std::string item, base::OnceCallback<void(bool)> reply, bool ok) {
        if (!ok) self->DeletionFailed("purge", profile, item);
        std::move(reply).Run(ok);
      }, base::Unretained(this), profile, item, std::move(reply)));
}

void TabHistory::Read(std::string profile, std::string item, std::string row_url,
                      base::OnceCallback<void(std::optional<Restore>)> reply) {
  auto& state = profiles_[profile];
  if (state.blocked) {
    RetryClear(profile);
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(std::move(reply), std::nullopt));
    return;
  }
  const auto epoch = state.clear_epoch;
  sequence_.Read(profile, std::move(item), std::move(row_url), base::BindOnce(
      [](TabHistory* self, std::string profile, uint64_t epoch,
         base::OnceCallback<void(std::optional<Restore>)> reply, std::optional<Restore> result) {
        const auto& state = self->profiles_[profile];
        if (state.blocked || state.clear_epoch != epoch) result.reset();
        std::move(reply).Run(std::move(result));
      }, base::Unretained(this), profile, epoch, std::move(reply)));
}

void TabHistory::ApplyInvalidationPolicy(const std::string& profile, InvalidationSource source) {
  if (source == InvalidationSource::Expiration) return;
  auto& state = profiles_[profile];
  ++state.clear_epoch;
  state.generation = NewGeneration();
  state.blocked = false;
  for (const auto& [key, writer] : writers_) if (key.first == profile) writer->Fence();
  PostClear(profile);
}

void TabHistory::PostClear(const std::string& profile) {
  auto& state = profiles_[profile];
  state.clearing = true;
  const auto epoch = state.clear_epoch;
  sequence_.Clear(profile, state.generation, base::BindOnce(
      [](TabHistory* self, std::string profile, uint64_t epoch, bool ok) {
        auto& state = self->profiles_[profile];
        if (state.clear_epoch != epoch) return;
        state.clearing = false;
        if (!ok) {
          self->DeletionFailed("clear", profile, "");
        } else state.blocked = false;
      }, base::Unretained(this), profile, epoch));
}

void TabHistory::RetryClear(const std::string& profile) {
  auto& state = profiles_[profile];
  if (state.blocked && !state.clearing) PostClear(profile);
}

void TabHistory::DeletionFailed(const char* kind, const std::string& profile, const std::string& item) {
  std::fprintf(stderr, "ararat-history: %s-failed profile=%s item=%s\n", kind, profile.c_str(), item.c_str());
  if (std::string_view(kind) == "clear") profiles_[profile].blocked = true;
}

uint64_t TabHistory::Epoch(const std::string& profile) { return profiles_[profile].clear_epoch; }
bool TabHistory::Allows(const std::string& profile, uint64_t epoch) {
  const auto& state = profiles_[profile];
  return !state.blocked && state.clear_epoch == epoch;
}
bool TabHistory::Blocked(const std::string& profile) {
  const bool blocked = profiles_[profile].blocked;
  if (blocked) RetryClear(profile);
  return blocked;
}

namespace {
class HistoryWatcher : public history::HistoryServiceObserver, public ProfileManagerObserver, public ProfileObserver {
 public:
  HistoryWatcher() {
    auto* manager = g_browser_process->profile_manager();
    profiles_.Observe(manager);
    for (auto* profile : manager->GetLoadedProfiles()) Watch(profile);
    g_ararat_history_deleting = [](history::HistoryService* service) { Get().Invalidate(service, InvalidationSource::Request); };
  }
  static HistoryWatcher& Get() { static base::NoDestructor<HistoryWatcher> watcher; return *watcher; }
  void OnProfileAdded(Profile* profile) override { Watch(profile); }
  void OnProfileManagerDestroying() override {
    g_ararat_history_deleting = nullptr;
    history_.RemoveAllObservations();
    directories_.clear();
    if (!recovery_finished_) for (auto& [profile, lock] : locks_) lock->Abandon();
    locks_.clear();
    observed_profiles_.RemoveAllObservations();
    profiles_.Reset();
  }
  void OnHistoryDeletions(history::HistoryService* service, const history::DeletionInfo& info) override {
    Invalidate(service, info.is_from_expiration() ? InvalidationSource::Expiration : InvalidationSource::Notification);
  }
  void HistoryServiceBeingDeleted(history::HistoryService* service) override {
    if (history_.IsObservingSource(service)) history_.RemoveObservation(service);
    directories_.erase(service);
  }
  void OnProfileWillBeDestroyed(Profile* profile) override {
    auto found = locks_.find(profile);
    if (found != locks_.end() && !recovery_finished_) found->second->Abandon();
    locks_.erase(profile);
    observed_profiles_.RemoveObservation(profile);
  }
  void FinishRecovery() {
    recovery_finished_ = true;
    locks_.clear();
  }
  void CheckExpiration(history::HistoryService* service) {
    history::DeletionInfo info(history::DeletionTimeRange::AllTime(), true, {}, {}, std::nullopt);
    OnHistoryDeletions(service, info);
  }
 private:
  void Watch(Profile* profile) {
    if (!profile || profile->IsOffTheRecord()) return;
    if (observed_profiles_.IsObservingSource(profile)) return;
    observed_profiles_.AddObservation(profile);
    if (auto* exit = ExitTypeService::GetInstanceForProfile(profile)) {
      auto lock = exit->CreateCrashedLock();
      if (lock && !recovery_finished_) locks_[profile] = std::move(lock);
    }
    auto directory = profile->GetPath().BaseName().value();
    TabHistory::Get().Generation(directory);
    auto* service = HistoryServiceFactory::GetForProfile(profile, ServiceAccessType::EXPLICIT_ACCESS);
    if (!service || history_.IsObservingSource(service)) return;
    directories_[service] = std::move(directory);
    history_.AddObservation(service);
  }
  void Invalidate(history::HistoryService* service, InvalidationSource source) {
    auto it = directories_.find(service);
    if (it != directories_.end()) TabHistory::Get().ApplyInvalidationPolicy(it->second, source);
  }
  std::map<history::HistoryService*, std::string> directories_;
  std::map<Profile*, std::unique_ptr<ExitTypeService::CrashedLock>> locks_;
  bool recovery_finished_ = false;
  base::ScopedMultiSourceObservation<history::HistoryService, history::HistoryServiceObserver> history_{this};
  base::ScopedMultiSourceObservation<Profile, ProfileObserver> observed_profiles_{this};
  base::ScopedObservation<ProfileManager, ProfileManagerObserver> profiles_{this};
};
}  // namespace

void StartHistoryWatcher() { HistoryWatcher::Get(); }
void FinishCrashRecovery() { HistoryWatcher::Get().FinishRecovery(); }

void CheckDeletionBarrier(std::string profile, base::OnceCallback<void(bool)> reply) {
  TabHistory::Get().sequence().Ensure(profile, base::BindOnce(
      [](std::string profile, base::OnceCallback<void(bool)> reply, std::optional<std::string> generation) {
        std::move(reply).Run(generation.has_value() && !TabHistory::Get().Blocked(profile));
      }, profile, std::move(reply)));
}

class CheckRemovalObserver : public content::BrowsingDataRemover::Observer {
 public:
  CheckRemovalObserver(content::BrowsingDataRemover* remover, std::string profile,
                       base::OnceCallback<void(bool)> reply)
      : profile_(std::move(profile)), reply_(std::move(reply)) { observation_.Observe(remover); }
  void OnBrowsingDataRemoverDone(uint64_t failed) override {
    observation_.Reset();
    if (failed) std::move(reply_).Run(false);
    else CheckDeletionBarrier(profile_, std::move(reply_));
    delete this;
  }
 private:
  std::string profile_;
  base::OnceCallback<void(bool)> reply_;
  base::ScopedObservation<content::BrowsingDataRemover, content::BrowsingDataRemover::Observer> observation_{this};
};

void CheckDelete(Profile* profile, NSInteger mode, base::OnceCallback<void(bool)> reply) {
  if (!profile || profile->IsOffTheRecord()) { std::move(reply).Run(false); return; }
  auto directory = profile->GetPath().BaseName().value();
  auto* service = HistoryServiceFactory::GetForProfile(profile, ServiceAccessType::EXPLICIT_ACCESS);
  if (!service) { std::move(reply).Run(false); return; }
  if (mode == 0) {
    auto* remover = profile->GetBrowsingDataRemover();
    auto* observer = new CheckRemovalObserver(remover, directory, std::move(reply));
    remover->RemoveAndReply(base::Time(), base::Time::Max(), chrome_browsing_data_remover::DATA_TYPE_HISTORY,
                            content::BrowsingDataRemover::ORIGIN_TYPE_UNPROTECTED_WEB, observer);
  } else if (mode == 1) {
    service->DeleteURLs({GURL("https://example.test/")});
    CheckDeletionBarrier(directory, std::move(reply));
  } else if (mode == 2) {
    HistoryWatcher::Get().CheckExpiration(service);
    CheckDeletionBarrier(directory, std::move(reply));
  } else {
    std::move(reply).Run(false);
  }
}

Writer::Writer(content::WebContents* contents, std::string profile, std::string item, uint64_t stamp)
    : profile_(std::move(profile)), item_(std::move(item)), admitted_at_(stamp) { Observe(contents); }
Writer::~Writer() { TabHistory::Get().Remove(this); }
void Writer::Fence() { fenced_ = true; timer_.Stop(); }
void Writer::ReplaceContents(content::WebContents* contents) { Observe(contents); }
void Writer::SaveSoon() {
  if (fenced_) { TabHistory::Get().Blocked(profile_); return; }
  unsaved_ = true;
  if (!timer_.IsRunning()) timer_.Start(FROM_HERE, base::Milliseconds(2500), base::BindOnce(
      [](Writer* writer) { writer->Save(base::DoNothing()); }, base::Unretained(this)));
}
void Writer::Save(base::OnceCallback<void(bool)> reply) {
  timer_.Stop();
  if (fenced_ || !web_contents()) {
    if (fenced_) TabHistory::Get().Blocked(profile_);
    std::move(reply).Run(false);
    return;
  }
  auto& service = TabHistory::Get();
  if (service.Blocked(profile_)) { std::move(reply).Run(false); return; }
  auto generation = service.Generation(profile_);
  auto history = Capture(web_contents());
  if (!history) { unsaved_ = false; std::move(reply).Run(false); return; }
  unsaved_ = false;
  if (generation.empty()) {
    service.sequence().WriteCurrent(profile_, item_, admitted_at_, std::move(*history), std::move(reply));
  } else {
    service.sequence().Write(profile_, item_, std::move(generation), admitted_at_, std::move(*history), std::move(reply));
  }
}
void Writer::NavigationEntryCommitted(const content::LoadCommittedDetails&) { SaveSoon(); }
void Writer::NavigationEntryChanged(const content::EntryChangedDetails&) { SaveSoon(); }
void Writer::NavigationListPruned(const content::PrunedDetails&) { SaveSoon(); }
void Writer::NavigationEntriesDeleted() { SaveSoon(); }
void Writer::WebContentsDestroyed() {
  timer_.Stop();
  if (unsaved_) Save(base::DoNothing());
}
}  // namespace ararat::tab_history

void AraratPurgeTabHistory(NSString* profile, NSString* itemId, uint64_t changedAt, void (^completion)(BOOL)) {
  ararat::tab_history::TabHistory::Get().Purge(base::SysNSStringToUTF8(profile), base::SysNSStringToUTF8(itemId),
                                                changedAt, base::BindOnce(^(bool ok) { completion(ok); }));
}

void AraratFinishCrashRecovery(void) { ararat::tab_history::FinishCrashRecovery(); }

void AraratCheckTabHistoryFile(NSString* profile, NSString* itemId, void (^completion)(NSDictionary*)) {
  auto callback = ^(ararat::tab_history::FileState state) {
    completion(@{ @"exists": @(state.exists), @"generation_current": @(state.generation_current),
                  @"admitted_at": @(state.admitted_at), @"count": @(state.count), @"selected": @(state.selected),
                  @"url": base::SysUTF8ToNSString(state.url), @"generation": base::SysUTF8ToNSString(state.generation) });
  };
  ararat::tab_history::TabHistory::Get().sequence().Inspect(base::SysNSStringToUTF8(profile),
      base::SysNSStringToUTF8(itemId), base::BindOnce(callback));
}

void AraratCheckDeleteHistory(NSString* directory, NSInteger mode, void (^completion)(BOOL)) {
  base::FilePath part(base::SysNSStringToUTF8(directory));
  if (part.empty() || part.IsAbsolute() || part.ReferencesParent() || part.BaseName() != part || part.value() == ".") {
    completion(NO); return;
  }
  auto* manager = g_browser_process->profile_manager();
  auto* profile = manager->GetProfileByPath(manager->user_data_dir().Append(part));
  ararat::tab_history::CheckDelete(profile, mode, base::BindOnce(^(bool ok) { completion(ok); }));
}

NSDictionary* AraratCheckCrashState(NSString* directory) {
  base::FilePath part(base::SysNSStringToUTF8(directory));
  if (part.empty() || part.IsAbsolute() || part.ReferencesParent() || part.BaseName() != part || part.value() == ".")
    return @{};
  auto* manager = g_browser_process->profile_manager();
  auto* profile = manager->GetProfileByPath(manager->user_data_dir().Append(part));
  if (!profile) return @{};
  auto* service = ExitTypeService::GetInstanceForProfile(profile);
  if (!service) return @{};
  return @{ @"last_exit_crashed": @(service->last_session_exit_type() == ExitType::kCrashed),
            @"waiting_for_ack": @(service->waiting_for_user_to_ack_crash()) };
}

void AraratCheckCommitProfilePrefs(NSString* directory, void (^completion)(BOOL)) {
  base::FilePath part(base::SysNSStringToUTF8(directory));
  if (part.empty() || part.IsAbsolute() || part.ReferencesParent() || part.BaseName() != part || part.value() == ".") {
    completion(NO); return;
  }
  auto* manager = g_browser_process->profile_manager();
  auto* profile = manager->GetProfileByPath(manager->user_data_dir().Append(part));
  if (!profile) { completion(NO); return; }
  profile->GetPrefs()->CommitPendingWrite(base::BindOnce(^{ completion(YES); }));
}
