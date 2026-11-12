#include "ararat/core/ararat_downloads.h"

#include <map>
#include <set>
#include <string>

#include "base/check.h"
#include "base/strings/sys_string_conversions.h"
#include "chrome/browser/download/download_commands.h"
#include "chrome/browser/download/download_core_service.h"
#include "chrome/browser/download/download_core_service_factory.h"
#include "chrome/browser/download/download_item_model.h"
#include "chrome/browser/download/download_prefs.h"
#include "chrome/browser/download/bubble/download_bubble_utils.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/download/download_bubble_security_view_info.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/common/pref_names.h"
#include "components/download/public/common/download_item.h"
#include "components/download/public/common/download_danger_type.h"
#include "components/prefs/pref_service.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/download_manager.h"
#include "content/public/browser/download_item_utils.h"

namespace {
using Item = download::DownloadItem;

bool IsScanning(Item* item) {
  auto type = item->GetDangerType();
  return IsPendingDeepScanning(item) || type == download::DOWNLOAD_DANGER_TYPE_ASYNC_SCANNING ||
      type == download::DOWNLOAD_DANGER_TYPE_ASYNC_LOCAL_PASSWORD_SCANNING ||
      type == download::DOWNLOAD_DANGER_TYPE_PROMPT_FOR_LOCAL_PASSWORD_SCANNING;
}

NSArray* Actions(Item* item, DownloadItemModel& model) {
  DownloadCommands commands(model.GetWeakPtr());
  NSMutableArray* actions = [NSMutableArray array];
  if (commands.IsCommandEnabled(DownloadCommands::SHOW_IN_FOLDER)) [actions addObject:@"show"];
  if (model.IsDangerous() || model.IsInsecure() || IsScanning(item)) {
    DownloadBubbleSecurityViewInfo info;
    info.InitializeForDownload(model);
    for (auto command : {DownloadCommands::KEEP, DownloadCommands::BYPASS_DEEP_SCANNING, DownloadCommands::DISCARD}) {
      bool offered = (info.has_primary_button() && info.primary_button().command == command) ||
                     (info.has_secondary_button() && info.secondary_button().command == command);
      NSString* action = command == DownloadCommands::DISCARD ? @"discard" : @"keep";
      if (offered && commands.IsCommandEnabled(command) && ![actions containsObject:action])
        [actions addObject:action];
    }
    return actions;
  }
  if (item->GetState() == Item::COMPLETE && commands.IsCommandEnabled(DownloadCommands::OPEN_WHEN_COMPLETE)) [actions addObject:@"open"];
  if (commands.IsCommandEnabled(DownloadCommands::CANCEL)) [actions addObject:@"cancel"];
  if (item->GetState() == Item::INTERRUPTED && commands.IsCommandEnabled(DownloadCommands::RESUME)) [actions addObject:@"resume"];
  if (item->GetState() != Item::IN_PROGRESS) [actions addObject:@"remove"];
  return actions;
}
}

class AraratDownloads::Impl : public content::DownloadManager::Observer, public Item::Observer {
 public:
  Impl(Profile* profile, void (^changed)(NSArray*, NSString*, BrowserWindowInterface*))
      : profile_(profile), manager_(profile->GetDownloadManager()), changed_([changed copy]) {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    manager_->AddObserver(this);
    content::DownloadManager::DownloadVector items;
    manager_->GetAllDownloads(&items);
    for (Item* item : items) Observe(item);
    auto* service = DownloadCoreServiceFactory::GetForBrowserContext(profile);
    if (service && !profile->IsOffTheRecord()) service->InitializeHistory(DownloadCoreService::DownloadHistoryLoadTrigger::kDownloadsPage);
  }
  ~Impl() override { Clear(); }
  void Clear() {
    for (const auto& [guid, item] : items_) item->RemoveObserver(this);
    items_.clear();
    pending_.clear();
    if (manager_) manager_->RemoveObserver(this);
    manager_ = nullptr;
    profile_ = nullptr;
  }
  void Observe(Item* item) {
    if (items_.emplace(item->GetGuid(), item).second) item->AddObserver(this);
  }
  void Notify(NSString* new_guid = nil, BrowserWindowInterface* origin = nullptr) { if (changed_) changed_(Snapshot(), new_guid, origin); }
  void OnDownloadCreated(content::DownloadManager*, Item* item) override {
    bool fresh = !items_.contains(item->GetGuid());
    Observe(item);
    bool created = item->GetDownloadCreationType() != Item::TYPE_HISTORY_IMPORT && !item->IsTransient();
    if (fresh && created) pending_.insert(item->GetGuid());
    Notify();
  }
  void OnManagerInitialized() override { Notify(); }
  void ManagerGoingDown(content::DownloadManager*) override { Clear(); Notify(); }
  void OnDownloadUpdated(Item* item) override {
    NSString* identifier = nil;
    BrowserWindowInterface* origin = nullptr;
    if (item->GetState() == Item::CANCELLED) pending_.erase(item->GetGuid());
    else if (pending_.contains(item->GetGuid()) && !item->GetTargetFilePath().empty() && DownloadItemModel(item).ShouldShowInUi()) {
      pending_.erase(item->GetGuid());
      identifier = base::SysUTF8ToNSString(item->GetGuid());
      auto* contents = content::DownloadItemUtils::GetWebContents(item);
      if (contents) origin = GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(contents);
      if (origin && origin->GetTabStripModel()->GetActiveWebContents() != contents) origin = nullptr;
    }
    Notify(identifier, origin);
  }
  void OnDownloadRemoved(Item* item) override {
    item->RemoveObserver(this);
    pending_.erase(item->GetGuid());
    items_.erase(item->GetGuid());
    Notify();
  }
  void OnDownloadDestroyed(Item* item) override {
    item->RemoveObserver(this);
    pending_.erase(item->GetGuid());
    items_.erase(item->GetGuid());
    Notify();
  }
  NSArray* Snapshot() {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    NSMutableArray* result = [NSMutableArray array];
    if (!profile_) return result;
    // A private profile's list is this observer's live items only: no history is loaded, and
    // the model lives with the window (U26f).
    NSString* profile = base::SysUTF8ToNSString(profile_->GetPath().BaseName().value());
    for (const auto& [guid, item] : items_) {
      DownloadItemModel model(item);
      if (!model.ShouldShowInUi()) continue;
      [result addObject:@{ @"profile": profile, @"private": @(profile_->IsOffTheRecord()),
        @"id": base::SysUTF8ToNSString(guid),
        @"restored": @(item->GetDownloadCreationType() == Item::TYPE_HISTORY_IMPORT),
        @"name": base::SysUTF16ToNSString(item->GetFileNameToReportUser().LossyDisplayName()),
        @"state": @(item->GetState()), @"danger": @(item->GetDangerType()),
        @"start": @(item->GetStartTime().InSecondsFSinceUnixEpoch()),
        @"received": @(item->GetReceivedBytes()), @"total": @(item->GetTotalBytes()),
        @"interrupt": @(item->GetLastReason()), @"paused": @(item->IsPaused()),
        @"running": @(item->GetState() == Item::IN_PROGRESS && !item->IsPaused() && !model.IsDangerous() && !model.IsInsecure() && !IsScanning(item)),
        @"insecure": @(item->GetInsecureDownloadStatus()),
        @"scanning": @(IsScanning(item)),
        @"status": base::SysUTF16ToNSString(model.GetStatusText()),
        @"actions": Actions(item, model) }];
    }
    return result;
  }
  bool Perform(NSString* guid, NSString* action) {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    if (!manager_ || !profile_) return false;
    Item* item = manager_->GetDownloadByGuid(base::SysNSStringToUTF8(guid));
    if (!item) return false;
    DownloadItemModel model(item);
    if (![Actions(item, model) containsObject:action]) return false;
    DownloadCommands commands(model.GetWeakPtr());
    if ([action isEqualToString:@"remove"]) { item->Remove(); return true; }
    DownloadCommands::Command command;
    if ([action isEqualToString:@"show"]) command = DownloadCommands::SHOW_IN_FOLDER;
    else if ([action isEqualToString:@"open"]) command = DownloadCommands::OPEN_WHEN_COMPLETE;
    else if ([action isEqualToString:@"cancel"]) command = DownloadCommands::CANCEL;
    else if ([action isEqualToString:@"resume"]) command = DownloadCommands::RESUME;
    else if ([action isEqualToString:@"keep"]) {
      DownloadBubbleSecurityViewInfo info;
      info.InitializeForDownload(model);
      bool bypass = (info.has_primary_button() && info.primary_button().command == DownloadCommands::BYPASS_DEEP_SCANNING) ||
                    (info.has_secondary_button() && info.secondary_button().command == DownloadCommands::BYPASS_DEEP_SCANNING);
      command = bypass ? DownloadCommands::BYPASS_DEEP_SCANNING : DownloadCommands::KEEP;
    }
    else if ([action isEqualToString:@"discard"]) command = DownloadCommands::DISCARD;
    else return false;
    commands.ExecuteCommand(command);
    return true;
  }
 private:
  Profile* profile_;
  content::DownloadManager* manager_;
  std::map<std::string, Item*> items_;
  std::set<std::string> pending_;
  void (^changed_)(NSArray*, NSString*, BrowserWindowInterface*);
};

AraratDownloads::AraratDownloads(Profile* profile, void (^changed)(NSArray*, NSString*, BrowserWindowInterface*)) : impl_(std::make_unique<Impl>(profile, changed)) {}
AraratDownloads::~AraratDownloads() = default;
NSArray* AraratDownloads::Snapshot() { return impl_->Snapshot(); }
bool AraratDownloads::Perform(NSString* guid, NSString* action) { return impl_->Perform(guid, action); }

void AraratConfigurePrivateDownloads(Profile* profile) {
  if (!profile || !profile->IsOffTheRecord()) return;
  auto* service = DownloadCoreServiceFactory::GetForBrowserContext(profile);
  if (!service || !service->GetDownloadManagerDelegate()) return;
  auto* regular = DownloadPrefs::FromBrowserContext(profile->GetOriginalProfile());
  if (!regular) return;
  profile->GetPrefs()->SetFilePath(prefs::kDownloadDefaultDirectory, regular->DownloadPath());
  profile->GetPrefs()->SetBoolean(prefs::kPromptForDownload, false);
}
