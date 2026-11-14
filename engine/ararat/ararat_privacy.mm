// U27p: Settings › Privacy's engine side. The app's core settings record is the source of the
// third-party cookie mode, the Global Privacy Control signal and the browsing-history retention.
// This file pushes the record into every regular profile (the cookie-controls pref and the GPC
// pref), sets the history expiry's retention, clears a range of browsing data, and carries the
// check's history fixtures.
//
// The functions are exported C entry points (AraratHostAPI.h) rather than ARWindowHostAPI
// methods because a pane acts on every profile, not on one window's Browser.

#import <Foundation/Foundation.h>

#include <atomic>
#include <cstdio>
#include <string>
#include <vector>

#include "ararat/core/public/AraratHostAPI.h"

#include "base/files/file_path.h"
#include "base/functional/bind.h"
#include "base/no_destructor.h"
#include "base/scoped_observation.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/cancelable_task_tracker.h"
#include "base/time/time.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/browsing_data/chrome_browsing_data_remover_constants.h"
#include "chrome/browser/history/history_service_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/profiles/profile_manager_observer.h"
#include "components/content_settings/core/browser/cookie_settings.h"
#include "components/content_settings/core/common/pref_names.h"
#include "components/history/core/browser/expire_history_backend.h"
#include "components/history/core/browser/history_service.h"
#include "components/history/core/browser/history_types.h"
#include "components/keyed_service/core/service_access_type.h"
#include "components/prefs/pref_service.h"
#include "components/universal_optout/prefs.h"
#include "content/public/browser/browsing_data_remover.h"
#include "url/gurl.h"

namespace {

// The cookie-controls pref's two values the pane writes: Block third-party cookies and the off
// mode (kOff behaves as kIncognitoOnly since June 2025, so third-party cookies stay in regular
// windows and are blocked in private ones).
constexpr int kCookiesBlock = static_cast<int>(content_settings::CookieControlsMode::kBlockThirdParty);
constexpr int kCookiesAllow = static_cast<int>(content_settings::CookieControlsMode::kOff);

std::vector<Profile*> RegularProfiles() {
  std::vector<Profile*> profiles;
  auto* manager = g_browser_process ? g_browser_process->profile_manager() : nullptr;
  if (!manager) return profiles;
  for (Profile* profile : manager->GetLoadedProfiles()) {
    if (profile && profile->IsRegularProfile()) profiles.push_back(profile);
  }
  return profiles;
}

Profile* ProfileForDirectory(NSString* directory) {
  auto* manager = g_browser_process ? g_browser_process->profile_manager() : nullptr;
  if (!manager || ![directory isKindOfClass:NSString.class] || directory.length == 0) return nullptr;
  base::FilePath name(base::SysNSStringToUTF8(directory));
  if (name.empty() || name.IsAbsolute() || name.ReferencesParent() || name.BaseName() != name) return nullptr;
  Profile* profile = manager->GetProfileByPath(manager->user_data_dir().Append(name));
  return profile && profile->IsRegularProfile() ? profile : nullptr;
}

// Applies the remembered record to a profile. Chromium's CookieSettings observes the pref, so a
// change reaches a loaded profile's renderers without a relaunch; the GPC pref is read by
// chrome/browser/renderer_preferences_util.cc, which needs kUniversalOptOut and
// kUniversalOptOutSettings enabled in the process (AraratMain adds them).
void ApplyToProfile(Profile* profile, int cookies, bool gpc) {
  if (!profile || !profile->IsRegularProfile()) return;
  PrefService* prefs = profile->GetPrefs();
  if (!prefs) return;
  prefs->SetInteger(prefs::kCookieControlsMode, cookies);
  prefs->SetBoolean(universal_optout::prefs::kUniversalOptOutEnabled, gpc);
}

// Remembers the last record and applies it to a profile created later, so a second profile gets
// the record the app applied at startup without the app observing profiles itself.
class PrivacyWatcher : public ProfileManagerObserver {
 public:
  PrivacyWatcher() {
    if (auto* manager = g_browser_process ? g_browser_process->profile_manager() : nullptr) {
      profiles_.Observe(manager);
    }
  }
  static PrivacyWatcher& Get() {
    static base::NoDestructor<PrivacyWatcher> watcher;
    return *watcher;
  }
  void Set(int cookies, bool gpc) { cookies_ = cookies; gpc_ = gpc; }
  void OnProfileAdded(Profile* profile) override { ApplyToProfile(profile, cookies_, gpc_); }
  void OnProfileManagerDestroying() override { profiles_.Reset(); }

 private:
  int cookies_ = kCookiesBlock;
  bool gpc_ = true;
  base::ScopedObservation<ProfileManager, ProfileManagerObserver> profiles_{this};
};

// One BrowsingDataRemover task's reply. `failed` is a bitmask of the data types that failed, not
// a count; the remover reports failures only at shutdown.
class ClearObserver : public content::BrowsingDataRemover::Observer {
 public:
  ClearObserver(content::BrowsingDataRemover* remover, void (^completion)(uint64_t))
      : completion_([completion copy]) {
    observation_.Observe(remover);
  }
  void OnBrowsingDataRemoverDone(uint64_t failed_data_types) override {
    observation_.Reset();
    if (completion_) completion_(failed_data_types);
    delete this;
  }

 private:
  void (^completion_)(uint64_t);
  base::ScopedObservation<content::BrowsingDataRemover, content::BrowsingDataRemover::Observer> observation_{this};
};

}  // namespace

void AraratApplyPrivacySettings(NSDictionary<NSString*, id>* settings) {
  if (![settings isKindOfClass:NSDictionary.class]) return;
  NSString* cookiesWord = settings[@"cookies"];
  const int cookies = [cookiesWord isEqual:@"allow"] ? kCookiesAllow : kCookiesBlock;
  NSNumber* gpcNumber = settings[@"gpc"];
  const bool gpc = [gpcNumber isKindOfClass:NSNumber.class] ? gpcNumber.boolValue : true;
  NSNumber* daysNumber = settings[@"history_days"];
  int days = -1;
  if ([daysNumber isKindOfClass:NSNumber.class]) {
    days = daysNumber.intValue;
    if (days < 0) days = -1;
  }
  // The expiry loop reads this on its next pass (30 s), so shortening the retention deletes the
  // older visits without a relaunch; 0 is the pane's Forever and -1 leaves Chromium's threshold.
  history::g_ararat_history_retention_days.store(days, std::memory_order_relaxed);
  auto& watcher = PrivacyWatcher::Get();
  watcher.Set(cookies, gpc);
  for (Profile* profile : RegularProfiles()) ApplyToProfile(profile, cookies, gpc);
}

void AraratClearBrowsingData(NSString* profile, double begin_seconds, double end_seconds,
                             uint64_t types, void (^completion)(uint64_t failed)) {
  void (^report)(uint64_t) = [completion copy];
  Profile* target = ProfileForDirectory(profile);
  auto* remover = target ? target->GetBrowsingDataRemover() : nullptr;
  if (!remover) {
    if (report) report(0);
    return;
  }
  // The app's three bits: 1 history, 2 cookies and other site data, 4 cache. Site data is
  // Chrome's own "cookies and other site data" mask, so storage and site metadata go with the
  // cookies, as Chromium's clear-browsing-data dialog clears them.
  uint64_t mask = 0;
  if (types & 1) mask |= chrome_browsing_data_remover::DATA_TYPE_HISTORY;
  if (types & 2) mask |= chrome_browsing_data_remover::DATA_TYPE_SITE_DATA;
  if (types & 4) mask |= content::BrowsingDataRemover::DATA_TYPE_CACHE;
  if (!mask) {
    if (report) report(0);
    return;
  }
  const base::Time begin = begin_seconds > 0 ? base::Time::FromSecondsSinceUnixEpoch(begin_seconds)
                                             : base::Time();
  const base::Time end = end_seconds > 0 ? base::Time::FromSecondsSinceUnixEpoch(end_seconds)
                                         : base::Time::Max();
  auto* observer = new ClearObserver(remover, report);
  remover->RemoveAndReply(begin, end, mask, content::BrowsingDataRemover::ORIGIN_TYPE_UNPROTECTED_WEB,
                          observer);
}

void AraratCheckSeedHistoryVisit(NSString* profile, NSString* url, double days_ago,
                                 void (^completion)(BOOL done)) {
  Profile* target = ProfileForDirectory(profile);
  const GURL gurl([url isKindOfClass:NSString.class] ? base::SysNSStringToUTF8(url) : std::string());
  auto* service = target ? HistoryServiceFactory::GetForProfile(target, ServiceAccessType::EXPLICIT_ACCESS)
                         : nullptr;
  if (!service || !gurl.is_valid()) {
    if (completion) completion(NO);
    return;
  }
  const base::Time when = base::Time::Now() - base::Seconds(days_ago * 86400.0);
  service->AddPage(gurl, when, history::SOURCE_BROWSED);
  if (completion) completion(YES);
}

void AraratCheckHistoryVisitTimes(NSString* profile, NSString* url,
                                  void (^completion)(NSArray<NSNumber*>* times)) {
  Profile* target = ProfileForDirectory(profile);
  const GURL gurl([url isKindOfClass:NSString.class] ? base::SysNSStringToUTF8(url) : std::string());
  auto* service = target ? HistoryServiceFactory::GetForProfile(target, ServiceAccessType::EXPLICIT_ACCESS)
                         : nullptr;
  if (!service || !gurl.is_valid()) {
    if (completion) completion(@[]);
    return;
  }
  static base::NoDestructor<base::CancelableTaskTracker> tracker;
  service->QueryURLAndVisits(
      gurl, history::VisitQuery404sPolicy::kExclude404s,
      base::BindOnce(^(history::QueryURLAndVisitsResult result) {
        NSMutableArray<NSNumber*>* times = [NSMutableArray array];
        if (result.success) {
          for (const history::VisitRow& visit : result.visits) {
            [times addObject:@(visit.visit_time.InSecondsFSinceUnixEpoch())];
          }
        }
        if (completion) completion(times);
      }),
      tracker.get());
}
