// U27w: Settings › Websites' engine side. The app's core settings record is the source of the
// seven permission defaults; this file pushes them into every regular profile's
// HostContentSettingsMap, lists the user-set per-site exceptions the pane shows, writes and
// resets one origin's exception, and clears one site's cookies and storage.
//
// The functions are exported C entry points (AraratHostAPI.h) rather than ARWindowHostAPI
// methods because a pane acts on every profile, not on one window's Browser.

#import <Foundation/Foundation.h>

#include <cstdio>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "ararat/core/public/AraratHostAPI.h"

#include "base/check.h"
#include "base/functional/bind.h"
#include "base/no_destructor.h"
#include "base/scoped_observation.h"
#include "base/strings/sys_string_conversions.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/content_settings/host_content_settings_map_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/profiles/profile_manager_observer.h"
#include "components/content_settings/core/browser/host_content_settings_map.h"
#include "components/content_settings/core/browser/permission_settings_registry.h"
#include "components/content_settings/core/browser/website_settings_registry.h"
#include "components/content_settings/core/common/content_settings.h"
#include "components/content_settings/core/common/content_settings_pattern.h"
#include "content/public/browser/browsing_data_filter_builder.h"
#include "content/public/browser/browsing_data_remover.h"
#include "net/base/registry_controlled_domains/registry_controlled_domain.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace {

// The seven kinds, in the pane's board order. The names are Chromium's website-settings names
// (the same words SiteState uses), which is what the app sends.
constexpr const char* kKinds[] = {
    "media-stream-camera", "media-stream-mic", "geolocation", "notifications",
    "popups", "automatic-downloads", "sound",
};

NSString* Option(PermissionOption value) {
  switch (value) {
    case PermissionOption::kAllowed: return @"allow";
    case PermissionOption::kDenied: return @"block";
    case PermissionOption::kAsk: return @"ask";
  }
  return @"unsupported";
}

std::optional<PermissionOption> ParseOption(NSString* value) {
  if ([value isEqual:@"allow"]) return PermissionOption::kAllowed;
  if ([value isEqual:@"block"]) return PermissionOption::kDenied;
  if ([value isEqual:@"ask"]) return PermissionOption::kAsk;
  return std::nullopt;
}

// The permission-setting dictionary the site snapshot uses, so one vocabulary crosses the
// boundary for a popover row and a Websites row alike.
NSDictionary* Encode(const PermissionSetting& value) {
  if (const auto* setting = std::get_if<ContentSetting>(&value)) {
    NSString* name = @"unsupported";
    switch (*setting) {
      case CONTENT_SETTING_ALLOW: name = @"allow"; break;
      case CONTENT_SETTING_BLOCK: name = @"block"; break;
      case CONTENT_SETTING_ASK: name = @"ask"; break;
      case CONTENT_SETTING_SESSION_ONLY: name = @"session_only"; break;
      default: break;
    }
    return @{ @"kind": @"content", @"value": name };
  }
  if (const auto* geo = std::get_if<GeolocationSetting>(&value)) {
    return @{ @"kind": @"geolocation", @"approximate": Option(geo->approximate),
              @"precise": Option(geo->precise) };
  }
  return @{ @"kind": @"unsupported" };
}

std::optional<PermissionSetting> Decode(NSDictionary* value) {
  if (![value isKindOfClass:NSDictionary.class]) return std::nullopt;
  if ([value[@"kind"] isEqual:@"content"]) {
    NSString* name = value[@"value"];
    if ([name isEqual:@"allow"]) return PermissionSetting(CONTENT_SETTING_ALLOW);
    if ([name isEqual:@"block"]) return PermissionSetting(CONTENT_SETTING_BLOCK);
    if ([name isEqual:@"ask"]) return PermissionSetting(CONTENT_SETTING_ASK);
    if ([name isEqual:@"session_only"]) return PermissionSetting(CONTENT_SETTING_SESSION_ONLY);
  } else if ([value[@"kind"] isEqual:@"geolocation"]) {
    auto approximate = ParseOption(value[@"approximate"]);
    auto precise = ParseOption(value[@"precise"]);
    if (approximate && precise) return PermissionSetting(GeolocationSetting{*approximate, *precise});
  }
  return std::nullopt;
}

ContentSettingsType TypeForKind(const std::string& name) {
  const auto* info = content_settings::WebsiteSettingsRegistry::GetInstance()->GetByName(name);
  return info ? info->type() : ContentSettingsType::DEFAULT;
}

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

NSString* DirectoryForProfile(Profile* profile) {
  if (!profile) return @"";
  return base::SysUTF8ToNSString(profile->GetPath().BaseName().value());
}

// Applies the remembered defaults to a profile. The values are the app's core record; nothing is
// read back from Chromium's prefs into them (W1).
void ApplyToProfile(Profile* profile, const std::map<std::string, std::string>& values) {
  if (!profile || !profile->IsRegularProfile()) return;
  auto* map = HostContentSettingsMapFactory::GetForProfile(profile);
  auto* permissions = content_settings::PermissionSettingsRegistry::GetInstance();
  if (!map || !permissions) return;
  for (const auto& [name, word] : values) {
    const ContentSettingsType type = TypeForKind(name);
    if (type == ContentSettingsType::DEFAULT) continue;
    const auto* info = permissions->Get(type);
    if (!info) continue;
    ContentSetting setting = CONTENT_SETTING_ASK;
    if (word == "allow") setting = CONTENT_SETTING_ALLOW;
    else if (word == "block") setting = CONTENT_SETTING_BLOCK;
    else if (word != "ask") continue;
    PermissionSetting value = info->delegate().ToPermissionSetting(setting);
    if (!info->delegate().IsDefaultSettingValid(value)) {
      // Unreachable through the app: the core's record refuses a value its kind cannot take
      // (SiteDefaults::invalid), so the pane and Chromium cannot disagree. A trace, not a silent
      // skip, in case a stored record reached here another way.
      std::fprintf(stderr, "ararat-trace: site-default-refused kind=%s value=%s\n", name.c_str(), word.c_str());
      continue;
    }
    map->SetDefaultPermissionSetting(type, value);
  }
}

// Remembers the last records given and applies them to a profile created later, so a second
// profile gets the record the app applied at startup without the app observing profiles itself.
class SiteDefaultsWatcher : public ProfileManagerObserver {
 public:
  SiteDefaultsWatcher() {
    if (auto* manager = g_browser_process ? g_browser_process->profile_manager() : nullptr) {
      profiles_.Observe(manager);
    }
  }
  static SiteDefaultsWatcher& Get() {
    static base::NoDestructor<SiteDefaultsWatcher> watcher;
    return *watcher;
  }
  void Set(const std::map<std::string, std::string>& values) { values_ = values; }
  void OnProfileAdded(Profile* profile) override { ApplyToProfile(profile, values_); }
  void OnProfileManagerDestroying() override { profiles_.Reset(); }

 private:
  std::map<std::string, std::string> values_;
  base::ScopedObservation<ProfileManager, ProfileManagerObserver> profiles_{this};
};

// One BrowsingDataRemover task's reply. `failed` is a bitmask of the data types that failed, not
// a count (browsing_data_remover.h's Observer::OnBrowsingDataRemoverDone); the remover reports
// failures only at shutdown. The app shows nothing, so the value is only carried.
class SiteDataClearObserver : public content::BrowsingDataRemover::Observer {
 public:
  SiteDataClearObserver(content::BrowsingDataRemover* remover, void (^completion)(uint64_t))
      : completion_([completion copy]) {
    observation_.Observe(remover);
  }
  void OnBrowsingDataRemoverDone(uint64_t failed_data_types) override {
    observation_.Reset();
    completion_(failed_data_types);
    delete this;
  }

 private:
  void (^completion_)(uint64_t);
  base::ScopedObservation<content::BrowsingDataRemover, content::BrowsingDataRemover::Observer> observation_{this};
};

}  // namespace

void AraratApplySiteDefaults(NSDictionary<NSString*, NSString*>* defaults) {
  if (![defaults isKindOfClass:NSDictionary.class]) return;
  std::map<std::string, std::string> values;
  for (NSString* name in defaults) {
    NSString* word = defaults[name];
    if (![name isKindOfClass:NSString.class] || ![word isKindOfClass:NSString.class]) continue;
    values[base::SysNSStringToUTF8(name)] = base::SysNSStringToUTF8(word);
  }
  auto& watcher = SiteDefaultsWatcher::Get();
  watcher.Set(values);
  for (Profile* profile : RegularProfiles()) ApplyToProfile(profile, values);
}

NSArray<NSDictionary<NSString*, id>*>* AraratSiteExceptions(void) {
  NSMutableArray<NSDictionary<NSString*, id>*>* result = [NSMutableArray array];
  auto* permissions = content_settings::PermissionSettingsRegistry::GetInstance();
  if (!permissions) return result;
  for (Profile* profile : RegularProfiles()) {
    auto* map = HostContentSettingsMapFactory::GetForProfile(profile);
    if (!map) continue;
    NSString* directory = DirectoryForProfile(profile);
    for (const char* name : kKinds) {
      const ContentSettingsType type = TypeForKind(name);
      if (type == ContentSettingsType::DEFAULT) continue;
      const auto* info = permissions->Get(type);
      if (!info) continue;
      for (const auto& source : map->GetSettingsForOneType(type)) {
        // User-set single-origin rules only: no default (wildcard), policy, extension,
        // one-time-permission or installed-web-app entries (W2).
        if (source.IsExpired()) continue;
        if (source.incognito) continue;
        if (source.source != content_settings::mojom::ProviderType::kPrefProvider) continue;
        if (!source.primary_pattern.MatchesSingleOrigin()) continue;
        const GURL url = source.primary_pattern.ToRepresentativeUrl();
        if (!url.is_valid()) continue;
        const auto setting = info->delegate().FromValue(source.setting_value);
        if (!setting) continue;
        [result addObject:@{
          @"profile": directory,
          @"origin": base::SysUTF8ToNSString(url::Origin::Create(url).Serialize()),
          @"kind": base::SysUTF8ToNSString(name),
          @"value": Encode(*setting),
        }];
      }
    }
  }
  return result;
}

BOOL AraratSetSiteException(NSString* profile, NSString* origin, NSString* kind,
                            NSDictionary<NSString*, id>* setting) {
  Profile* target = ProfileForDirectory(profile);
  if (!target || ![origin isKindOfClass:NSString.class] || ![kind isKindOfClass:NSString.class]) return NO;
  const GURL url(base::SysNSStringToUTF8(origin));
  const auto parsed = url::Origin::Create(url);
  if (!url.SchemeIsHTTPOrHTTPS() || parsed.opaque()) return NO;
  const ContentSettingsType type = TypeForKind(base::SysNSStringToUTF8(kind));
  if (type == ContentSettingsType::DEFAULT) return NO;
  const auto* info =
      content_settings::PermissionSettingsRegistry::GetInstance()->Get(type);
  auto* map = HostContentSettingsMapFactory::GetForProfile(target);
  if (!info || !map) return NO;
  if (setting == nil || setting == NSNull.null) {
    // A nil setting is the pane's Reset for one kind: the same call Chromium's own site settings
    // use, with an empty setting deleting the rule.
    map->SetPermissionSettingDefaultScope(parsed.GetURL(), parsed.GetURL(), type, std::nullopt);
    return YES;
  }
  auto decoded = Decode(setting);
  if (!decoded || !info->delegate().IsValid(*decoded)) return NO;
  // The stored form must be the uniform value the pane's menu offered: a mixed geolocation pair
  // is displayable but not writable from this pane.
  map->SetPermissionSettingDefaultScope(parsed.GetURL(), parsed.GetURL(), type, *decoded);
  return YES;
}

void AraratClearSiteData(NSString* profile, NSString* origin, void (^completion)(uint64_t failed)) {
  void (^report)(uint64_t) = [completion copy];
  Profile* target = ProfileForDirectory(profile);
  const GURL url([origin isKindOfClass:NSString.class] ? base::SysNSStringToUTF8(origin) : std::string());
  if (!target || !url.SchemeIsHTTPOrHTTPS() || url.host().empty()) {
    if (report) report(0);
    return;
  }
  std::string domain = net::registry_controlled_domains::GetDomainAndRegistry(
      url, net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES);
  if (domain.empty()) domain = url.host();
  auto* remover = target->GetBrowsingDataRemover();
  if (!remover) {
    if (report) report(0);
    return;
  }
  // One task for all three kinds: W3 clears "that site's registrable domain … cookies, storage,
  // cache for that domain". A domain filter reaches all three — storage compares the key's
  // top-level site registrable domain (browsing_data_filter_builder_impl.cc:74-81 with
  // storage_key.cc:846-851), the network-service cache filter carries the domains
  // (browsing_data_filter_builder_impl.cc:301-303), and cookies take domains only (:310) — so a
  // subdomain's localStorage and a subdomain's cookies go together. The knowledge note's advice
  // to split the filters applies when cache must stay origin-scoped, as in the header's Clear
  // Cache; W3 asks for the domain.
  auto filter = content::BrowsingDataFilterBuilder::Create(content::BrowsingDataFilterBuilder::Mode::kDelete);
  filter->AddRegisterableDomain(domain);
  auto* observer = new SiteDataClearObserver(remover, report);
  remover->RemoveWithFilterAndReply(
      base::Time(), base::Time::Max(),
      content::BrowsingDataRemover::DATA_TYPE_COOKIES |
          content::BrowsingDataRemover::DATA_TYPE_DOM_STORAGE |
          content::BrowsingDataRemover::DATA_TYPE_CACHE,
      content::BrowsingDataRemover::ORIGIN_TYPE_UNPROTECTED_WEB, std::move(filter), observer);
}
