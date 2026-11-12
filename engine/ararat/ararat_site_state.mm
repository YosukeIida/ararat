#include "ararat/core/ararat_site_state.h"

#include <optional>
#include <string>
#include <variant>
#include <vector>

#include "base/check.h"
#include "base/functional/bind.h"
#include "base/memory/weak_ptr.h"
#include "base/memory/scoped_refptr.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "chrome/browser/content_settings/host_content_settings_map_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ssl/chrome_security_state_util.h"
#include "chrome/browser/ui/page_info/chrome_page_info_delegate.h"
#include "components/content_settings/browser/page_specific_content_settings.h"
#include "components/content_settings/core/browser/content_settings_observer.h"
#include "components/content_settings/core/browser/host_content_settings_map.h"
#include "components/content_settings/core/browser/permission_settings_registry.h"
#include "components/page_info/page_info.h"
#include "components/page_info/page_info_ui.h"
#include "components/dom_distiller/core/url_constants.h"
#include "components/security_state/core/security_state.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/weak_document_ptr.h"
#include "net/cert/x509_certificate.h"
#include "third_party/boringssl/src/include/openssl/pool.h"
#include "url/origin.h"
#include "url/url_constants.h"
#include "extensions/common/constants.h"

namespace {
using Settings = content_settings::PageSpecificContentSettings;

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

NSString* Source(content_settings::SettingSource source) {
  switch (source) {
    case content_settings::SettingSource::kNone: return @"none";
    case content_settings::SettingSource::kPolicy: return @"policy";
    case content_settings::SettingSource::kExtension: return @"extension";
    case content_settings::SettingSource::kUser: return @"user";
    case content_settings::SettingSource::kAllowList: return @"allowlist";
    case content_settings::SettingSource::kSupervised: return @"supervised";
    case content_settings::SettingSource::kInstalledWebApp: return @"installed_web_app";
    case content_settings::SettingSource::kOsJavascriptOptimizer: return @"os_javascript_optimizer";
    case content_settings::SettingSource::kTest: return @"test";
  }
  return @"unknown";
}

class SiteUI : public PageInfoUI {
 public:
  void SetPermissionInfo(const PermissionInfoList& permissions,
                         ChosenObjectInfoList) override;
  std::vector<PageInfo::PermissionInfo> rows;
};

class SiteState : public content::WebContentsObserver,
                  public content_settings::Observer,
                  public Settings::PermissionUsageObserver {
 public:
  using content_settings::Observer::OnContentSettingChanged;
  explicit SiteState(void (^changed)(void)) : changed_([changed copy]) {}
  ~SiteState() override { Reset(); }

  void SetContents(content::WebContents* contents) {
    if (!pending_switch_ && web_contents() == contents && !rebind_) return;
    pending_contents_ = contents ? contents->GetWeakPtr() : nullptr;
    pending_switch_ = true;
    rebind_ = true;
    Queue();
  }

  void PrimaryPageChanged(content::Page&) override { rebind_ = true; Queue(); }
  void DidChangeVisibleSecurityState() override { Queue(); }
  void WebContentsDestroyed() override {
    if (map_) map_->RemoveObserver(this);
    map_ = nullptr;
    rebind_ = true;
    Queue();
  }
  void OnPermissionUsageChange() override { Queue(); }
  void OnContentSettingChanged(const ContentSettingsPattern&,
                               const ContentSettingsPattern&,
                               ContentSettingsTypeSet types) override {
    if (types.ContainsAllTypes() ||
        content_settings::PermissionSettingsRegistry::GetInstance()->Get(types.GetType())) Queue();
  }

  void Queue() {
    if (queued_) return;
    queued_ = true;
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&SiteState::Flush, weak_.GetWeakPtr()));
  }

  void Flush() {
    queued_ = false;
    if (pending_switch_) {
      Reset();
      pending_switch_ = false;
      auto* contents = pending_contents_.get();
      Observe(contents);
      if (contents) {
        map_ = HostContentSettingsMapFactory::GetForProfile(
            Profile::FromBrowserContext(contents->GetBrowserContext()));
        map_->AddObserver(this);
      }
    }
    if (rebind_) Rebind();
    else if (presenter_) presenter_->UpdatePermissions();
    if (changed_) changed_();
  }

  void Rebind() {
    rebind_ = false;
    ResetPage();
    auto* contents = web_contents();
    if (!contents || contents->IsBeingDestroyed() || !contents->GetPrimaryMainFrame()) return;
    document_ = contents->GetPrimaryMainFrame()->GetWeakDocumentPtr();
    ++generation_;
    auto* settings = Settings::GetForFrame(contents->GetPrimaryMainFrame());
    if (settings) settings->AddPermissionUsageObserver(this);
    const GURL& url = contents->GetLastCommittedURL();
    internal_ = !url.is_valid() || url.is_empty() || PageInfo::IsFileOrInternalPage(url) ||
                url.SchemeIs("chrome-untrusted") || url.SchemeIs(extensions::kExtensionScheme) ||
                url.SchemeIs(dom_distiller::kDomDistillerScheme) ||
                (url.SchemeIs(url::kAboutScheme) && url.spec() != url::kAboutBlankURL);
    if (internal_) return;
    ui_ = std::make_unique<SiteUI>();
    presenter_ = std::make_unique<PageInfo>(
        std::make_unique<ChromePageInfoDelegate>(contents), contents,
        contents->GetLastCommittedURL());
    presenter_->InitializeUiState(ui_.get(),
        base::BindOnce(&SiteState::Queue, weak_.GetWeakPtr()));
  }

  void ResetPage() {
    auto* frame = document_.AsRenderFrameHostIfValid();
    auto* settings = frame ? Settings::GetForFrame(frame) : nullptr;
    if (settings) {
      settings->RemovePermissionUsageObserver(this);
      if (presenter_) settings->RemovePermissionUsageObserver(presenter_.get());
    }
    presenter_.reset();
    ui_.reset();
    document_ = content::WeakDocumentPtr();
    internal_ = false;
    changed_permission_ = false;
  }

  void Reset() {
    ResetPage();
    if (map_) map_->RemoveObserver(this);
    map_ = nullptr;
    Observe(nullptr);
  }

  NSDictionary* Snapshot();
  NSString* Document() const {
    if (!web_contents() || (!presenter_ && !internal_) || rebind_ ||
        !document_.AsRenderFrameHostIfValid()) return nil;
    return [NSString stringWithFormat:@"%llu", (unsigned long long)generation_];
  }
  bool Change(NSDictionary* request);
  void Close() {
    if (changed_permission_ && presenter_) {
      bool reload = false;
      presenter_->OnUIClosing(&reload);
      changed_permission_ = false;
    }
  }

 private:
  bool Mutable(const PageInfo::PermissionInfo& row) const {
    const auto& value = row.setting ? *row.setting : row.default_setting;
    return Decode(Encode(value)).has_value() &&
           row.source == content_settings::SettingSource::kUser &&
           content_settings::PermissionSettingsRegistry::GetInstance()->Get(row.type);
  }
  void (^changed_)(void);
  scoped_refptr<HostContentSettingsMap> map_;
  base::WeakPtr<content::WebContents> pending_contents_;
  content::WeakDocumentPtr document_;
  std::unique_ptr<SiteUI> ui_;
  std::unique_ptr<PageInfo> presenter_;
  uint64_t generation_ = 0;
  bool changed_permission_ = false;
  bool queued_ = false;
  bool rebind_ = false;
  bool pending_switch_ = false;
  bool internal_ = false;
  base::WeakPtrFactory<SiteState> weak_{this};
};

void SiteUI::SetPermissionInfo(const PermissionInfoList& permissions,
                               ChosenObjectInfoList) {
  rows = permissions;
}

NSDictionary* SiteState::Snapshot() {
  auto* contents = web_contents();
  if (!contents || (!presenter_ && !internal_) || rebind_ || !document_.AsRenderFrameHostIfValid()) return @{};
  const GURL site = contents->GetLastCommittedURL();
  NSMutableArray* rows = [NSMutableArray array];
  bool blocked = false;
  auto* registry = content_settings::PermissionSettingsRegistry::GetInstance();
  auto* settings = Settings::GetForFrame(contents->GetPrimaryMainFrame());
  if (settings) {
    for (const auto* info : *registry) {
      const auto type = info->website_settings_info()->type();
      if (type == ContentSettingsType::AUTOMATIC_DOWNLOADS ||
          type == ContentSettingsType::STORAGE_ACCESS) continue;
      if (settings->IsContentBlocked(type)) {
        blocked = true;
        break;
      }
    }
  }
  if (internal_) return @{ @"document": [NSString stringWithFormat:@"%llu", (unsigned long long)generation_],
                            @"origin": base::SysUTF8ToNSString(url::Origin::Create(site).Serialize()),
                            @"security": @"none", @"certificateChain": @[], @"permissions": @[],
                            @"blocked": @(blocked), @"internal": @YES };
  for (const auto& row : ui_->rows) {
    const auto* info = registry->Get(row.type);
    if (!info) continue;
    const auto& value = row.setting ? *row.setting : row.default_setting;
    if (auto roundtrip = Decode(Encode(value))) DCHECK(*roundtrip == value);
    const GURL requester = row.requesting_origin ? row.requesting_origin->GetURL() : site;
    content_settings::SettingInfo metadata;
    PermissionSetting persisted = map_->GetPermissionSetting(requester, site, row.type, &metadata);
    bool specific = metadata.primary_pattern != ContentSettingsPattern::Wildcard() ||
                    metadata.secondary_pattern != ContentSettingsPattern::Wildcard();
    bool specific_block = specific && info->delegate().IsBlocked(persisted);
    blocked |= specific_block;
    NSMutableArray* allowed = [NSMutableArray array];
    if (Mutable(row)) {
      for (ContentSetting candidate : {CONTENT_SETTING_ALLOW, CONTENT_SETTING_BLOCK,
                                       CONTENT_SETTING_ASK, CONTENT_SETTING_SESSION_ONLY}) {
        if (candidate == CONTENT_SETTING_SESSION_ONLY &&
            !std::holds_alternative<ContentSetting>(value)) continue;
        PermissionSetting transition = info->delegate().ToPermissionSetting(candidate);
        if (info->delegate().IsValid(transition)) [allowed addObject:Encode(transition)];
      }
      if (std::holds_alternative<GeolocationSetting>(value)) {
        for (PermissionOption approximate : {PermissionOption::kAllowed, PermissionOption::kDenied, PermissionOption::kAsk}) {
          for (PermissionOption precise : {PermissionOption::kAllowed, PermissionOption::kDenied, PermissionOption::kAsk}) {
            if (approximate == precise) continue;
            PermissionSetting transition = GeolocationSetting{approximate, precise};
            if (info->delegate().IsValid(transition)) [allowed addObject:Encode(transition)];
          }
        }
      }
    }
    NSString* origin = row.requesting_origin
        ? base::SysUTF8ToNSString(row.requesting_origin->Serialize()) : @"";
    [rows addObject:@{ @"type": base::SysUTF8ToNSString(info->website_settings_info()->name()),
                       @"requestingOrigin": origin,
                       @"embeddingOrigin": base::SysUTF8ToNSString(url::Origin::Create(site).Serialize()),
                       @"setting": row.setting ? (id)Encode(*row.setting) : (id)NSNull.null,
                       @"defaultSetting": Encode(row.default_setting),
                       @"source": Source(row.source), @"mutable": @(Mutable(row) && allowed.count),
                       @"allowed": allowed, @"siteSpecificBlock": @(specific_block) }];
  }
  NSString* level = @"none";
  switch (chrome_security_state::GetSecurityLevel(contents)) {
    case security_state::SECURE: level = @"secure"; break;
    case security_state::DANGEROUS: level = @"error"; break;
    case security_state::WARNING: level = @"not_secure"; break;
    default: break;
  }
  NSMutableArray* chain = [NSMutableArray array];
  auto state = chrome_security_state::GetVisibleSecurityState(contents);
  if (state && state->certificate) {
    for (const auto& buffer : state->certificate->cert_buffers()) {
      [chain addObject:[NSData dataWithBytes:CRYPTO_BUFFER_data(buffer.get())
                                    length:CRYPTO_BUFFER_len(buffer.get())]];
    }
  }
  return @{ @"document": [NSString stringWithFormat:@"%llu", (unsigned long long)generation_],
            @"origin": base::SysUTF8ToNSString(url::Origin::Create(site).Serialize()),
            @"security": level, @"certificateChain": chain,
            @"permissions": rows, @"blocked": @(blocked), @"internal": @NO };
}

bool SiteState::Change(NSDictionary* request) {
  if (![request isKindOfClass:NSDictionary.class] || !presenter_ || rebind_ ||
      !document_.AsRenderFrameHostIfValid() ||
      ![request[@"document"] isEqual:[NSString stringWithFormat:@"%llu", (unsigned long long)generation_]]) return false;
  auto* registry = content_settings::PermissionSettingsRegistry::GetInstance();
  for (const auto& entry : ui_->rows) {
    const auto row = entry;
    const auto* info = registry->Get(row.type);
    if (!info || !Mutable(row) ||
        ![request[@"type"] isEqual:base::SysUTF8ToNSString(info->website_settings_info()->name())]) continue;
    NSString* origin = row.requesting_origin ? base::SysUTF8ToNSString(row.requesting_origin->Serialize()) : @"";
    if (![request[@"requestingOrigin"] isEqual:origin]) continue;
    const GURL site = web_contents()->GetLastCommittedURL();
    const GURL requester = row.requesting_origin ? row.requesting_origin->GetURL() : site;
    content_settings::SettingInfo metadata;
    map_->GetPermissionSetting(requester, site, row.type, &metadata);
    if (metadata.source != content_settings::SettingSource::kUser) return false;
    id raw = request[@"setting"];
    std::optional<PermissionSetting> setting;
    if (raw != NSNull.null) {
      setting = Decode(raw);
      const auto& previous = row.setting ? *row.setting : row.default_setting;
      if (!setting || setting->index() != previous.index() ||
          !info->delegate().IsValid(*setting)) return false;
    }
    presenter_->OnSitePermissionChanged(row.type, setting, row.requesting_origin, false);
    changed_permission_ = true;
    Queue();
    return true;
  }
  return false;
}
}  // namespace

@implementation ARSiteState {
  std::unique_ptr<SiteState> state_;
}
- (instancetype)initWithChanged:(void (^)(void))changed {
  if ((self = [super init])) state_ = std::make_unique<SiteState>(changed);
  return self;
}
- (void)setContents:(content::WebContents*)contents { state_->SetContents(contents); }
- (NSDictionary*)snapshot { return state_->Snapshot(); }
- (NSString*)document { return state_->Document(); }
- (BOOL)change:(NSDictionary*)request { return state_->Change(request); }
- (void)close { state_->Close(); }
@end
