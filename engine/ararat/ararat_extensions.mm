// U27x: Settings › Extensions' engine side. The pane lists one regular profile's user-installed
// and unpacked extensions from Chromium's ExtensionRegistry, enables and disables them through the
// ExtensionRegistrar, writes the profile's user site access through ScriptingPermissionsModifier,
// pins an action in the profile's ToolbarActionsModel, shows Chromium's re-enable prompt for an
// extension disabled by a permissions increase, removes one through Chromium's uninstall dialog,
// and calls back when any profile's registry changes so the pane follows installs, removals and
// enable switches made elsewhere.
//
// The functions are exported C entry points (AraratHostAPI.h) rather than ARWindowHostAPI methods
// because the pane acts on a profile, not on one window's Browser (X1, X2, X5).

#import <Foundation/Foundation.h>

#include <algorithm>
#include <memory>
#include <string>
#include <vector>

#include "ararat/core/public/AraratHostAPI.h"

#include "base/command_line.h"
#include "base/files/file_path.h"
#include "base/functional/bind.h"
#include "base/memory/raw_ptr.h"
#include "base/no_destructor.h"
#include "base/scoped_multi_source_observation.h"
#include "base/scoped_observation.h"
#include "base/strings/string_util.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/extensions/extension_install_prompt.h"
#include "chrome/browser/extensions/extension_uninstall_dialog.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/profiles/profile_manager_observer.h"
#include "chrome/browser/ui/toolbar/toolbar_actions_model.h"
#include "extensions/browser/disable_reason.h"
#include "extensions/browser/extension_prefs.h"
#include "extensions/browser/extension_registrar.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/extension_registry_observer.h"
#include "extensions/browser/extension_system.h"
#include "extensions/browser/management_policy.h"
#include "extensions/browser/permissions/scripting_permissions_modifier.h"
#include "extensions/browser/permissions_manager.h"
#include "extensions/browser/ui_util.h"
#include "extensions/browser/unpacked_installer.h"
#include "extensions/common/extension.h"
#include "extensions/common/icons/extension_icon_set.h"
#include "extensions/common/manifest.h"
#include "extensions/common/manifest_handlers/icons_handler.h"
#include "extensions/common/permissions/permission_set.h"
#include "ui/gfx/native_ui_types.h"

namespace {

bool IsCheckRun() {
  auto* command = base::CommandLine::ForCurrentProcess();
  return command->HasSwitch("ararat-check") || command->HasSwitch("ararat-screen");
}

bool IsRegularProfile(Profile* profile) {
  return profile && profile->IsRegularProfile();
}

std::vector<Profile*> RegularProfiles() {
  std::vector<Profile*> profiles;
  auto* manager = g_browser_process ? g_browser_process->profile_manager() : nullptr;
  if (!manager) return profiles;
  for (Profile* profile : manager->GetLoadedProfiles()) {
    if (IsRegularProfile(profile)) profiles.push_back(profile);
  }
  return profiles;
}

Profile* ProfileForDirectory(NSString* directory) {
  auto* manager = g_browser_process ? g_browser_process->profile_manager() : nullptr;
  if (!manager || ![directory isKindOfClass:NSString.class] || directory.length == 0) return nullptr;
  base::FilePath name(base::SysNSStringToUTF8(directory));
  if (name.empty() || name.IsAbsolute() || name.ReferencesParent() || name.BaseName() != name) return nullptr;
  Profile* profile = manager->GetProfileByPath(manager->user_data_dir().Append(name));
  return IsRegularProfile(profile) ? profile : nullptr;
}

// The icon Chromium's settings page shows. Small and read once per row on the UI thread, so the
// synchronous path is the one the pane pays for (an async load would make a row appear without
// its icon and then replace it).
NSImage* IconFor(const extensions::Extension& extension) {
  extensions::ExtensionResource resource = extensions::IconsInfo::GetIconResource(
      &extension, 32, extensions::ExtensionIconSet::Match::kBigger);
  if (resource.empty()) return nil;
  base::FilePath path = resource.GetFilePath();
  if (path.empty()) return nil;
  return [[NSImage alloc] initWithContentsOfFile:base::SysUTF8ToNSString(path.value())];
}

// X2's summary, in the developer_private vocabulary: "all", "specific" or "click". Disabled
// extensions read "Off" in the app, not here.
NSString* SiteAccessFor(Profile* profile, const extensions::Extension& extension) {
  auto* permissions = extensions::PermissionsManager::Get(profile);
  auto* prefs = extensions::ExtensionPrefs::Get(profile);
  if (!permissions || !prefs) return @"all";
  if (!permissions->HasWithheldHostPermissions(extension)) return @"all";
  std::unique_ptr<const extensions::PermissionSet> granted =
      prefs->GetRuntimeGrantedPermissions(extension.id());
  if (!granted || granted->effective_hosts().is_empty()) return @"click";
  constexpr bool kIncludeApiPermissions = false;
  if (granted->ShouldWarnAllHosts(kIncludeApiPermissions)) return @"all";
  return @"specific";
}

// The pane removes what Chrome's own toolbar menu removes: a component or a policy-held
// extension is not the user's to remove.
bool CanRemove(Profile* profile, const extensions::Extension* extension) {
  if (!profile || !extension || extensions::Manifest::IsComponentLocation(extension->location()))
    return false;
  auto* system = extensions::ExtensionSystem::Get(profile);
  auto* policy = system ? system->management_policy() : nullptr;
  return policy && policy->UserMayModifySettings(extension, nullptr) &&
         !policy->MustRemainInstalled(extension, nullptr);
}

// "User-installed and unpacked" (X2): the Web Store's INTERNAL installs and the unpacked ones
// the owner loads. Component, policy and external installs are not the pane's business.
bool IsListed(const extensions::Extension& extension) {
  if (!extensions::ui_util::ShouldDisplayInExtensionSettings(extension)) return false;
  return extensions::Manifest::IsUnpackedLocation(extension.location()) ||
         extension.location() == extensions::mojom::ManifestLocation::kInternal;
}

// X5: one observer for every regular profile's registry. The pane re-reads its list when an
// extension is installed, removed, enabled or disabled anywhere; site access writes notify
// directly because they fire no registry event.
class ExtensionWatcher : public extensions::ExtensionRegistryObserver,
                         public ProfileManagerObserver {
 public:
  static ExtensionWatcher& Get() {
    static base::NoDestructor<ExtensionWatcher> watcher;
    return *watcher;
  }

  void Start() {
    if (started_) return;
    started_ = true;
    if (auto* manager = g_browser_process ? g_browser_process->profile_manager() : nullptr)
      profiles_.Observe(manager);
    for (Profile* profile : RegularProfiles()) Watch(profile);
  }

  void SetHandler(void (^handler)(void)) { handler_ = [handler copy]; }

  void NotifyChanged() {
    if (!handler_) return;
    void (^handler)(void) = handler_;
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(^{ handler(); }));
  }

  // ExtensionRegistryObserver:
  void OnExtensionLoaded(content::BrowserContext*, const extensions::Extension*) override { NotifyChanged(); }
  void OnExtensionUnloaded(content::BrowserContext*, const extensions::Extension*,
                           extensions::UnloadedExtensionReason) override { NotifyChanged(); }
  void OnExtensionInstalled(content::BrowserContext*, const extensions::Extension*, bool) override { NotifyChanged(); }
  void OnExtensionUninstalled(content::BrowserContext*, const extensions::Extension*,
                              extensions::UninstallReason) override { NotifyChanged(); }
  void OnShutdown(extensions::ExtensionRegistry* registry) override {
    registries_.RemoveObservation(registry);
  }

  // ProfileManagerObserver:
  void OnProfileAdded(Profile* profile) override {
    if (IsRegularProfile(profile)) {
      Watch(profile);
      NotifyChanged();
    }
  }
  void OnProfileManagerDestroying() override {
    profiles_.Reset();
    registries_.RemoveAllObservations();
  }

 private:
  void Watch(Profile* profile) {
    if (auto* registry = extensions::ExtensionRegistry::Get(profile))
      registries_.AddObservation(registry);
  }

  bool started_ = false;
  base::ScopedObservation<ProfileManager, ProfileManagerObserver> profiles_{this};
  base::ScopedMultiSourceObservation<extensions::ExtensionRegistry,
                                     extensions::ExtensionRegistryObserver>
      registries_{this};
  void (^handler_)(void) = nil;
};

// Sorts the two registry sets into the pane's row order: name, then id for a stable tie-break.
std::vector<scoped_refptr<const extensions::Extension>> ListedExtensions(Profile* profile) {
  auto* registry = extensions::ExtensionRegistry::Get(profile);
  std::vector<scoped_refptr<const extensions::Extension>> extensions;
  if (!registry) return extensions;
  for (const auto& extension : registry->enabled_extensions()) {
    if (IsListed(*extension)) extensions.push_back(extension);
  }
  for (const auto& extension : registry->disabled_extensions()) {
    if (IsListed(*extension)) extensions.push_back(extension);
  }
  std::sort(extensions.begin(), extensions.end(),
            [](const scoped_refptr<const extensions::Extension>& a,
               const scoped_refptr<const extensions::Extension>& b) {
              int name = base::CompareCaseInsensitiveASCII(base::SysUTF16ToUTF8(a->name()),
                                                           base::SysUTF16ToUTF8(b->name()));
              return name != 0 ? name < 0 : a->id() < b->id();
            });
  return extensions;
}

// One notification after Chromium's uninstall dialog closed, as the window host's Remove… does.
void PostRemoveResult(void (^completion)(NSString*, NSString*), NSString* result, NSString* detail) {
  if (!completion) return;
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(^{ completion(result, detail); }));
}

class UninstallRequest : public extensions::ExtensionUninstallDialog::Delegate {
 public:
  static void Start(Profile* profile, gfx::NativeWindow parent,
                    const extensions::Extension* extension,
                    void (^completion)(NSString*, NSString*)) {
    auto* request = new UninstallRequest(completion);
    request->dialog_ = extensions::ExtensionUninstallDialog::Create(profile, parent, request);
    request->dialog_->ConfirmUninstall(extension, extensions::UNINSTALL_REASON_USER_INITIATED,
                                       extensions::UNINSTALL_SOURCE_TOOLBAR_CONTEXT_MENU);
  }

 private:
  explicit UninstallRequest(void (^completion)(NSString*, NSString*))
      : completion_([completion copy]) {}
  ~UninstallRequest() override = default;
  void OnExtensionUninstallDialogClosed(bool started, const std::u16string& error) override {
    void (^completion)(NSString*, NSString*) = completion_;
    NSString* detail = base::SysUTF16ToNSString(error);
    NSString* result = started ? @"removed" : @"notRemoved";
    delete this;
    PostRemoveResult(completion, result, detail);
  }
  void (^completion_)(NSString*, NSString*);
  std::unique_ptr<extensions::ExtensionUninstallDialog> dialog_;
};

// Chromium's re-enable prompt (X3), the dialog Chrome shows for an extension it disabled for a
// permissions increase. The prompt owns the permission list; this object outlives it until the
// dialog reports, then grants and enables through the same registrar call the management API's
// enable path uses.
class ReviewRequest {
 public:
  static void Start(Profile* profile, const extensions::Extension* extension,
                    gfx::NativeWindow parent, void (^completion)(BOOL)) {
    auto* request = new ReviewRequest(profile, extension, completion);
    auto prompt_type = ExtensionInstallPrompt::GetReEnablePromptTypeForExtension(profile, extension);
    request->prompt_ = std::make_unique<ExtensionInstallPrompt>(
        profile, parent, std::make_unique<extensions::InstallPromptData>(prompt_type));
    // `ShowDialog` keeps the prompt alive until the dialog closes; the callback may be
    // synchronous when no dialog can be shown.
    ExtensionInstallPrompt* prompt = request->prompt_.get();
    prompt->ShowDialog(
        base::BindOnce(^(ExtensionInstallPrompt::DoneCallbackPayload payload) {
          request->Finish(payload.result == ExtensionInstallPrompt::Result::ACCEPTED);
        }),
        extension, nullptr, ExtensionInstallPrompt::GetDefaultShowDialogCallback());
  }

 private:
  ReviewRequest(Profile* profile, const extensions::Extension* extension,
                void (^completion)(BOOL))
      : profile_(profile), extension_(extension), completion_([completion copy]) {}

  void Finish(bool accepted) {
    if (accepted && extension_) {
      if (auto* registrar = extensions::ExtensionRegistrar::Get(profile_))
        registrar->GrantPermissionsAndEnableExtension(*extension_);
    }
    void (^completion)(BOOL) = completion_;
    // The prompt is inside its own callback; delete it after the stack unwinds.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(^{
          if (completion) completion(accepted);
          delete this;
        }));
  }

  raw_ptr<Profile> profile_;
  scoped_refptr<const extensions::Extension> extension_;
  void (^completion_)(BOOL);
  std::unique_ptr<ExtensionInstallPrompt> prompt_;
};

}  // namespace

NSArray<NSDictionary<NSString*, id>*>* AraratExtensions(NSString* profile) {
  NSMutableArray<NSDictionary<NSString*, id>*>* result = [NSMutableArray array];
  Profile* target = ProfileForDirectory(profile);
  if (!target) return result;
  auto* prefs = extensions::ExtensionPrefs::Get(target);
  auto* toolbar = ToolbarActionsModel::Get(target);
  if (!prefs) return result;
  for (const auto& extension : ListedExtensions(target)) {
    const extensions::DisableReasonSet reasons = prefs->GetDisableReasons(extension->id());
    const bool enabled = extensions::ExtensionRegistry::Get(target)->enabled_extensions().Contains(extension->id());
    NSMutableArray<NSNumber*>* encoded_reasons = [NSMutableArray array];
    for (int reason : reasons) [encoded_reasons addObject:@(reason)];
    const bool needs_review = reasons.contains(extensions::disable_reason::DISABLE_PERMISSIONS_INCREASE);
    const bool can_pin = toolbar && toolbar->HasAction(extension->id());
    [result addObject:@{
      @"id": base::SysUTF8ToNSString(extension->id()),
      @"name": base::SysUTF16ToNSString(extensions::ui_util::GetFixupExtensionNameForUIDisplay(*extension)),
      @"icon": IconFor(*extension) ?: NSNull.null,
      @"enabled": @(enabled),
      @"needsReview": @(needs_review),
      @"disableReasons": encoded_reasons,
      @"siteAccess": SiteAccessFor(target, *extension),
      @"pinned": @(can_pin && toolbar->IsActionPinned(extension->id())),
      @"canPin": @(can_pin && !toolbar->IsActionForcePinned(extension->id())),
      @"removable": @(CanRemove(target, extension.get())),
      @"unpacked": @(extensions::Manifest::IsUnpackedLocation(extension->location())),
    }];
  }
  return result;
}

NSString* AraratSetExtensionEnabled(NSString* profile, NSString* identifier, BOOL enabled) {
  Profile* target = ProfileForDirectory(profile);
  if (!target || ![identifier isKindOfClass:NSString.class] || identifier.length == 0) return @"unknown";
  const std::string id = base::SysNSStringToUTF8(identifier);
  auto* registry = extensions::ExtensionRegistry::Get(target);
  auto* prefs = extensions::ExtensionPrefs::Get(target);
  auto* registrar = extensions::ExtensionRegistrar::Get(target);
  const extensions::Extension* extension = registry ? registry->GetInstalledExtension(id) : nullptr;
  if (!extension || !prefs || !registrar) return @"unknown";
  auto* system = extensions::ExtensionSystem::Get(target);
  auto* policy = system ? system->management_policy() : nullptr;
  const bool currently_enabled = registry->enabled_extensions().Contains(id);
  if (!enabled) {
    if (!currently_enabled) return @"unchanged";
    if (policy && !policy->UserMayModifySettings(extension, nullptr)) return @"policy";
    registrar->DisableExtension(id, {extensions::disable_reason::DISABLE_USER_ACTION});
    ExtensionWatcher::Get().NotifyChanged();
    return @"done";
  }
  if (currently_enabled) return @"unchanged";
  // Chromium disabled it for a permissions increase: only the prompt may enable it again (X3).
  if (prefs->HasDisableReason(id, extensions::disable_reason::DISABLE_PERMISSIONS_INCREASE) ||
      prefs->HasDisableReason(id, extensions::disable_reason::DISABLE_REMOTE_INSTALL)) {
    return @"review";
  }
  if (policy && policy->MustRemainDisabled(extension, nullptr)) return @"policy";
  registrar->EnableExtension(id);
  ExtensionWatcher::Get().NotifyChanged();
  return @"done";
}

NSString* AraratSetExtensionSiteAccess(NSString* profile, NSString* identifier, NSString* access) {
  Profile* target = ProfileForDirectory(profile);
  if (!target || ![identifier isKindOfClass:NSString.class] || identifier.length == 0 ||
      ![access isKindOfClass:NSString.class]) {
    return @"unknown";
  }
  const std::string id = base::SysNSStringToUTF8(identifier);
  auto* registry = extensions::ExtensionRegistry::Get(target);
  scoped_refptr<const extensions::Extension> extension =
      registry ? registry->GetInstalledExtension(id) : nullptr;
  auto* permissions = extensions::PermissionsManager::Get(target);
  if (!extension || !permissions) return @"unknown";
  if (!permissions->CanAffectExtension(*extension)) return @"unsupported";
  // "specific" is a state Chromium can report when sites were granted one by one; the pane
  // sends only the two modes that need no site picker (X2). The picker stays Chromium's page.
  if ([access isEqual:@"all"]) {
    extensions::ScriptingPermissionsModifier(target, extension)
        .SetWithholdHostPermissions(false);
    ExtensionWatcher::Get().NotifyChanged();
    return @"done";
  }
  if ([access isEqual:@"click"]) {
    extensions::ScriptingPermissionsModifier modifier(target, extension);
    modifier.SetWithholdHostPermissions(true);
    modifier.RemoveAllGrantedHostPermissions();
    ExtensionWatcher::Get().NotifyChanged();
    return @"done";
  }
  return @"unsupported";
}

NSString* AraratSetExtensionPinned(NSString* profile, NSString* identifier, BOOL pinned) {
  Profile* target = ProfileForDirectory(profile);
  if (!target || ![identifier isKindOfClass:NSString.class] || identifier.length == 0) return @"unknown";
  if (target->IsOffTheRecord()) return @"incognito";
  auto* model = ToolbarActionsModel::Get(target);
  const std::string id = base::SysNSStringToUTF8(identifier);
  if (!model || !model->HasAction(id)) return @"unknown";
  if (model->IsActionForcePinned(id)) return @"forced";
  if (model->IsActionPinned(id) == static_cast<bool>(pinned)) return @"unchanged";
  model->SetActionVisibility(id, pinned);
  return @"done";
}

void AraratReviewExtension(NSString* profile, NSString* identifier, NSWindow* window,
                           void (^completion)(BOOL allowed)) {
  void (^report)(BOOL) = [completion copy];
  Profile* target = ProfileForDirectory(profile);
  auto* registry = target ? extensions::ExtensionRegistry::Get(target) : nullptr;
  auto* prefs = target ? extensions::ExtensionPrefs::Get(target) : nullptr;
  scoped_refptr<const extensions::Extension> extension =
      registry && [identifier isKindOfClass:NSString.class]
          ? registry->GetInstalledExtension(base::SysNSStringToUTF8(identifier))
          : nullptr;
  if (!target || !prefs || !extension) {
    if (report) report(NO);
    return;
  }
  const bool escalated =
      prefs->HasDisableReason(extension->id(), extensions::disable_reason::DISABLE_PERMISSIONS_INCREASE) ||
      prefs->HasDisableReason(extension->id(), extensions::disable_reason::DISABLE_REMOTE_INSTALL);
  if (!escalated) {
    // Nothing to review (the state changed since the row was drawn): the ordinary enable is
    // what Chrome would do, so the click still has its effect.
    extensions::ExtensionRegistrar::Get(target)->EnableExtension(extension->id());
    if (report) report(YES);
    return;
  }
  ReviewRequest::Start(target, extension.get(), gfx::NativeWindow(window), report);
}

void AraratRemoveExtension(NSString* profile, NSString* identifier, NSWindow* window,
                           void (^completion)(NSString* result, NSString* detail)) {
  void (^report)(NSString*, NSString*) = [completion copy];
  Profile* target = ProfileForDirectory(profile);
  auto* registry = target ? extensions::ExtensionRegistry::Get(target) : nullptr;
  const extensions::Extension* extension =
      registry && [identifier isKindOfClass:NSString.class]
          ? registry->GetInstalledExtension(base::SysNSStringToUTF8(identifier))
          : nullptr;
  if (!target || !extension) {
    PostRemoveResult(report, @"unknown", @"");
    return;
  }
  if (!CanRemove(target, extension)) {
    PostRemoveResult(report, @"forced", @"");
    return;
  }
  UninstallRequest::Start(target, gfx::NativeWindow(window), extension, report);
}

void AraratSetExtensionsChangedHandler(void (^handler)(void)) {
  auto& watcher = ExtensionWatcher::Get();
  watcher.Start();
  watcher.SetHandler(handler);
}

// Check-only: installs an unpacked fixture into one profile, so `settings-extensions` can show
// two profiles with different extensions. Unpacked installs are trusted locations, so a newer
// version of the same fixture does not disable the extension for a permissions increase; the
// check marks that state through AraratCheckDisableExtensionForReview below.
void AraratCheckLoadUnpackedExtension(NSString* profile, NSString* path,
                                      void (^completion)(NSString* result)) {
  void (^report)(NSString*) = [completion copy];
  if (!IsCheckRun()) {
    if (report) report(@"refused");
    return;
  }
  Profile* target = ProfileForDirectory(profile);
  base::FilePath directory([path isKindOfClass:NSString.class] ? base::SysNSStringToUTF8(path) : std::string());
  if (!target || directory.empty() || !directory.IsAbsolute()) {
    if (report) report(@"unknown");
    return;
  }
  auto installer = extensions::UnpackedInstaller::Create(target);
  installer->set_be_noisy_on_failure(false);
  installer->set_completion_callback(
      base::BindOnce(^(const extensions::Extension* extension, const base::FilePath&,
                       const std::u16string& error) {
        if (report) report(extension ? @"loaded" : base::SysUTF16ToNSString(error));
      }));
  installer->Load(directory);
}

// Check-only: the state Chromium sets when an update asks for more permissions, without needing
// a store-installed CRX (an unpacked update is a trusted location and is never disabled).
void AraratCheckDisableExtensionForReview(NSString* profile, NSString* identifier) {
  if (!IsCheckRun()) return;
  Profile* target = ProfileForDirectory(profile);
  auto* registry = target ? extensions::ExtensionRegistry::Get(target) : nullptr;
  auto* registrar = target ? extensions::ExtensionRegistrar::Get(target) : nullptr;
  if (!registry || !registrar || ![identifier isKindOfClass:NSString.class]) return;
  const std::string id = base::SysNSStringToUTF8(identifier);
  if (!registry->GetInstalledExtension(id)) return;
  registrar->DisableExtension(id, {extensions::disable_reason::DISABLE_PERMISSIONS_INCREASE});
}
