// U27x: Settings › Extensions' engine side. The pane lists one regular profile's extensions from
// Chromium's ExtensionRegistry (what chrome://extensions shows there), enables and disables them
// through the ExtensionRegistrar, writes the profile's user site access through
// ScriptingPermissionsModifier, pins an action in the profile's ToolbarActionsModel, shows
// Chromium's re-enable prompt for an extension disabled by a permissions increase, removes one
// through Chromium's uninstall dialog, and calls back when any profile's registry changes so the
// pane follows installs, removals and enable switches made elsewhere.
//
// The functions are exported C entry points (AraratHostAPI.h) rather than ARWindowHostAPI methods
// because the pane acts on a profile, not on one window's Browser (X1, X2, X5).

#import <AppKit/AppKit.h>

#include <algorithm>
#include <cstdio>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "ararat/core/public/AraratHostAPI.h"

#include "base/command_line.h"
#include "base/containers/flat_set.h"
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
#include "chrome/browser/extensions/shared_module_service_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_attributes_storage.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/profiles/profile_manager_observer.h"
#include "chrome/browser/ui/toolbar/toolbar_actions_model.h"
#include "extensions/browser/disable_reason.h"
#include "extensions/browser/extension_action_manager.h"
#include "extensions/browser/extension_prefs.h"
#include "extensions/browser/extension_registrar.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/extension_registry_observer.h"
#include "extensions/browser/extension_system.h"
#include "extensions/browser/management_policy.h"
#include "extensions/browser/permissions/scripting_permissions_modifier.h"
#include "extensions/browser/permissions_manager.h"
#include "extensions/browser/shared_module_service.h"
#include "extensions/browser/ui_util.h"
#include "extensions/browser/unpacked_installer.h"
#include "extensions/common/extension.h"
#include "extensions/common/icons/extension_icon_set.h"
#include "extensions/common/manifest.h"
#include "extensions/common/manifest_handlers/icons_handler.h"
#include "extensions/common/permissions/permission_set.h"
#include "ui/gfx/native_ui_types.h"
#include "ui/views/view.h"
#include "ui/views/widget/widget.h"
#include "ui/views/window/dialog_delegate.h"

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

// The profile directory as a child of the user-data dir, or an empty path when the value is not a
// plain directory name.
base::FilePath PathForDirectory(NSString* directory, ProfileManager* manager) {
  if (!manager || ![directory isKindOfClass:NSString.class] || directory.length == 0)
    return base::FilePath();
  base::FilePath name(base::SysNSStringToUTF8(directory));
  if (name.empty() || name.IsAbsolute() || name.ReferencesParent() || name.BaseName() != name)
    return base::FilePath();
  return manager->user_data_dir().Append(name);
}

// Writes act on a loaded profile only: an unloaded one answers "unknown", and the list's loading
// reply keeps the pane from offering a write before the profile is there.
Profile* LoadedProfileForDirectory(NSString* directory) {
  auto* manager = g_browser_process ? g_browser_process->profile_manager() : nullptr;
  base::FilePath path = PathForDirectory(directory, manager);
  if (path.empty()) return nullptr;
  Profile* profile = manager->GetProfileByPath(path);
  return IsRegularProfile(profile) ? profile : nullptr;
}

base::flat_set<std::string>& LoadingProfiles() {
  static base::NoDestructor<base::flat_set<std::string>> loading;
  return *loading;
}

// The icon Chromium's settings page shows. Small and read once per row on the UI thread, so the
// synchronous path is the one the pane pays for (an async load would make a row appear without
// its icon and then replace it).
NSImage* IconFor(const extensions::Extension& extension) {
  extensions::ExtensionResource resource = extensions::IconsInfo::GetIconResource(
      &extension, 32, ExtensionIconSet::Match::kBigger);
  if (resource.empty()) return nil;
  base::FilePath path = resource.GetFilePath();
  if (path.empty()) return nil;
  return [[NSImage alloc] initWithContentsOfFile:base::SysUTF8ToNSString(path.value())];
}

// X2's summary, in the developer_private vocabulary: "all", "specific", "click", or "none" for an
// extension that requests no host permission at all (it has no site access to change). Disabled
// extensions read "Off" in the app, not here.
NSString* SiteAccessFor(Profile* profile, const extensions::Extension& extension) {
  auto* permissions = extensions::PermissionsManager::Get(profile);
  auto* prefs = extensions::ExtensionPrefs::Get(profile);
  if (!permissions || !prefs) return @"all";
  if (!permissions->CanAffectExtension(extension)) return @"none";
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

// Chrome's own page's rule for whether the enable toggle is offered (item_util.ts:61-87): the user
// may modify the extension, it is not blocklisted, it has no dependents, and none of the reasons
// that pin the state is present. A policy-installed or blocked extension therefore shows no
// switch, as in Chrome.
bool CanDisable(Profile* profile, const extensions::Extension& extension) {
  auto* registry = extensions::ExtensionRegistry::Get(profile);
  auto* system = extensions::ExtensionSystem::Get(profile);
  auto* policy = system ? system->management_policy() : nullptr;
  auto* prefs = extensions::ExtensionPrefs::Get(profile);
  if (!registry || !policy || !prefs) return false;
  if (registry->blocklisted_extensions().Contains(extension.id())) return false;
  if (!policy->UserMayModifySettings(&extension, nullptr)) return false;
  // A shared module another extension imports cannot be switched (Chrome's dependentExtensions).
  if (extension.is_shared_module()) {
    auto* modules = extensions::SharedModuleServiceFactory::GetForBrowserContext(profile);
    if (auto dependents = modules ? modules->GetDependentExtensions(&extension) : nullptr) {
      if (!dependents->empty()) return false;
    }
  }
  for (const auto reason :
       {extensions::disable_reason::DISABLE_CORRUPTED,
        extensions::disable_reason::DISABLE_NOT_VERIFIED,
        extensions::disable_reason::DISABLE_UPDATE_REQUIRED_BY_POLICY,
        extensions::disable_reason::DISABLE_PUBLISHED_IN_STORE_REQUIRED_BY_POLICY,
        extensions::disable_reason::DISABLE_BLOCKED_BY_POLICY,
        extensions::disable_reason::DISABLE_UNSUPPORTED_DEVELOPER_EXTENSION,
        extensions::disable_reason::DISABLE_UNSUPPORTED_MANIFEST_VERSION}) {
    if (prefs->HasDisableReason(extension.id(), reason)) return false;
  }
  return true;
}

// The pane's own change signal: one observer for every regular profile's registry, and one for its
// ToolbarActionsModel. The toolbar observer re-lists when an action is added or removed or the pins
// change, so a pin made from the URL field reaches the pane. Site access writes notify directly
// because they fire no registry event. A profile loaded on demand reaches the pane through
// OnProfileAdded.
class ExtensionWatcher;

class ToolbarWatcher : public ToolbarActionsModel::Observer {
 public:
  ToolbarWatcher(ToolbarActionsModel* model, ExtensionWatcher* owner);
  ~ToolbarWatcher() override;

  // ToolbarActionsModel::Observer:
  void OnToolbarActionAdded(const ToolbarActionsModel::ActionId& action_id) override;
  void OnToolbarActionRemoved(const ToolbarActionsModel::ActionId& action_id) override;
  void OnToolbarActionUpdated(const ToolbarActionsModel::ActionId& action_id) override;
  void OnToolbarModelInitialized() override;
  void OnToolbarPinnedActionsChanged() override;
  void OnToolbarActionsModelShutdown() override;

 private:
  raw_ptr<ToolbarActionsModel> model_;
  raw_ptr<ExtensionWatcher> owner_;
};

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

  // A ToolbarWatcher that saw its model shut down hands itself over here: the model is gone, so the
  // watcher must not remove itself from it, and erasing the entry deletes the watcher.
  void ForgetToolbar(ToolbarWatcher* watcher) {
    for (auto it = toolbars_.begin(); it != toolbars_.end(); ++it) {
      if (it->second.get() == watcher) {
        toolbars_.erase(it);
        return;
      }
    }
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
    if (auto* registry = extensions::ExtensionRegistry::Get(profile)) {
      if (!registries_.IsObservingSource(registry)) registries_.AddObservation(registry);
    }
    if (toolbars_.contains(profile)) return;
    if (auto* model = ToolbarActionsModel::Get(profile)) {
      toolbars_.emplace(profile, std::make_unique<ToolbarWatcher>(model, this));
    }
  }

  bool started_ = false;
  base::ScopedObservation<ProfileManager, ProfileManagerObserver> profiles_{this};
  base::ScopedMultiSourceObservation<extensions::ExtensionRegistry,
                                     extensions::ExtensionRegistryObserver>
      registries_{this};
  std::map<Profile*, std::unique_ptr<ToolbarWatcher>> toolbars_;
  void (^handler_)(void) = nil;
};

ToolbarWatcher::ToolbarWatcher(ToolbarActionsModel* model, ExtensionWatcher* owner)
    : model_(model), owner_(owner) {
  model_->AddObserver(this);
}

ToolbarWatcher::~ToolbarWatcher() {
  if (model_) model_->RemoveObserver(this);
}

void ToolbarWatcher::OnToolbarActionAdded(const ToolbarActionsModel::ActionId&) {
  owner_->NotifyChanged();
}

void ToolbarWatcher::OnToolbarActionRemoved(const ToolbarActionsModel::ActionId&) {
  owner_->NotifyChanged();
}

// The action's badge or state changed; the pin state did not, and a re-list on every badge would
// churn the pane for nothing.
void ToolbarWatcher::OnToolbarActionUpdated(const ToolbarActionsModel::ActionId&) {}

void ToolbarWatcher::OnToolbarModelInitialized() {
  owner_->NotifyChanged();
}

void ToolbarWatcher::OnToolbarPinnedActionsChanged() {
  owner_->NotifyChanged();
}

void ToolbarWatcher::OnToolbarActionsModelShutdown() {
  auto* model = model_.get();
  model_ = nullptr;
  if (model) model->RemoveObserver(this);
  // Erasing the entry deletes this watcher; nothing below may touch a member.
  owner_->ForgetToolbar(this);
}

// Lists an existing but not yet loaded profile on demand: LoadProfileByPath never creates one, and
// a profile that Chromium has never created has no extensions, so its empty list is true. A path
// with no profile-attributes entry is therefore answered empty without a load: LoadProfileByPath
// would run its callback synchronously with nullptr, and notifying from that callback would make
// the pane re-list and load forever. While a real load runs the list answers "loading" and the pane
// keeps its rows; only a load that produced a profile notifies the pane.
Profile* ListProfileForDirectory(NSString* directory, bool* loading) {
  auto* manager = g_browser_process ? g_browser_process->profile_manager() : nullptr;
  base::FilePath path = PathForDirectory(directory, manager);
  if (path.empty()) return nullptr;
  Profile* profile = manager->GetProfileByPath(path);
  if (profile) return IsRegularProfile(profile) ? profile : nullptr;
  if (!manager->GetProfileAttributesStorage().GetProfileAttributesWithPath(path)) return nullptr;
  const std::string key = path.value();
  auto& pending = LoadingProfiles();
  if (pending.contains(key)) {
    if (loading) *loading = true;
    return nullptr;
  }
  pending.insert(key);
  manager->LoadProfileByPath(path, /*incognito=*/false, base::BindOnce(^(Profile* loaded) {
    LoadingProfiles().erase(key);
    if (loaded) ExtensionWatcher::Get().NotifyChanged();
  }));
  if (loading) *loading = true;
  return nullptr;
}

// The two registry sets the pane lists, plus terminated (a crashed extension stays listed in
// chrome://extensions and reads enabled). Sorted by name, then id for a stable tie-break.
std::vector<scoped_refptr<const extensions::Extension>> ListedExtensions(Profile* profile) {
  auto* registry = extensions::ExtensionRegistry::Get(profile);
  std::vector<scoped_refptr<const extensions::Extension>> extensions;
  if (!registry) return extensions;
  for (const auto* set : {&registry->enabled_extensions(), &registry->terminated_extensions(),
                          &registry->disabled_extensions()}) {
    for (const auto& extension : *set) {
      // X2 (design): what Chromium's own extensions page shows, external-pref installs included;
      // component extensions stay out through this helper.
      if (extensions::ui_util::ShouldDisplayInExtensionSettings(*extension))
        extensions.push_back(extension);
    }
  }
  std::sort(extensions.begin(), extensions.end(),
            [](const scoped_refptr<const extensions::Extension>& a,
               const scoped_refptr<const extensions::Extension>& b) {
              const int name = base::CompareCaseInsensitiveASCII(a->name(), b->name());
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
// permissions increase. This object owns the prompt until the dialog reports, then grants and
// enables through the same registrar call the management API's enable path uses.
class ReviewRequest {
 public:
  static void Start(Profile* profile, const extensions::Extension* extension,
                    gfx::NativeWindow parent, void (^completion)(BOOL)) {
    auto* request = new ReviewRequest(profile, extension, completion);
    auto prompt_type = ExtensionInstallPrompt::GetReEnablePromptTypeForExtension(profile, extension);
    request->prompt_ = std::make_unique<ExtensionInstallPrompt>(
        profile, parent, std::make_unique<extensions::InstallPromptData>(prompt_type));
    // The request owns `prompt_`; the dialog takes the prompt data, and may report synchronously
    // when no dialog can be shown.
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
    // The prompt only lives through its callback; delete the request after the stack unwinds.
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

// Check-only: installs a fixture directory into one loaded profile.
void InstallUnpacked(Profile* profile, const base::FilePath& directory, void (^report)(NSString*)) {
  auto installer = extensions::UnpackedInstaller::Create(profile);
  installer->set_be_noisy_on_failure(false);
  installer->set_completion_callback(
      base::BindOnce(^(const extensions::Extension* extension, const base::FilePath&,
                       const std::u16string& error) {
        if (!report) return;
        report(extension ? @"loaded" : base::SysUTF16ToNSString(error));
      }));
  installer->Load(directory);
}

}  // namespace

NSArray<NSDictionary<NSString*, id>*>* AraratExtensions(NSString* profile) {
  bool loading = false;
  Profile* target = ListProfileForDirectory(profile, &loading);
  if (loading) return @[ @{@"loading": @YES} ];
  NSMutableArray<NSDictionary<NSString*, id>*>* result = [NSMutableArray array];
  if (!target) return result;
  auto* registry = extensions::ExtensionRegistry::Get(target);
  auto* prefs = extensions::ExtensionPrefs::Get(target);
  auto* toolbar = ToolbarActionsModel::Get(target);
  if (!registry || !prefs) return result;
  for (const auto& extension : ListedExtensions(target)) {
    const extensions::DisableReasonSet reasons = prefs->GetDisableReasons(extension->id());
    const bool enabled = registry->enabled_extensions().Contains(extension->id()) ||
                         registry->terminated_extensions().Contains(extension->id());
    NSMutableArray<NSNumber*>* encoded_reasons = [NSMutableArray array];
    for (int reason : reasons) [encoded_reasons addObject:@(reason)];
    const bool needs_review = reasons.contains(extensions::disable_reason::DISABLE_PERMISSIONS_INCREASE);
    const bool can_pin = toolbar && toolbar->HasAction(extension->id());
    if (IsCheckRun() &&
        base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-screen") ==
            "settings-extensions") {
      // The toolbar model is created lazily and initializes after the profile's extensions load;
      // the check needs to see where it stands when a row's pin is read.
      auto* actions = extensions::ExtensionActionManager::Get(target);
      std::fprintf(stderr,
                   "ararat-trace: extension-row id=%s toolbar=%d initialized=%d has_action=%d "
                   "action_manager_has=%d action_ids=%zu\n",
                   extension->id().c_str(), toolbar != nullptr,
                   toolbar ? toolbar->actions_initialized() : false, can_pin,
                   actions && actions->GetExtensionAction(*extension) != nullptr,
                   toolbar ? static_cast<size_t>(toolbar->action_ids().size()) : 0u);
    }
    [result addObject:@{
      @"id": base::SysUTF8ToNSString(extension->id()),
      @"name": base::SysUTF16ToNSString(
          extensions::ui_util::GetFixupExtensionNameForUIDisplay(extension->name())),
      @"icon": IconFor(*extension) ?: NSNull.null,
      @"enabled": @(enabled),
      @"needsReview": @(needs_review),
      @"disableReasons": encoded_reasons,
      @"siteAccess": SiteAccessFor(target, *extension),
      @"pinned": @(can_pin && toolbar->IsActionPinned(extension->id())),
      @"canPin": @(can_pin && !toolbar->IsActionForcePinned(extension->id())),
      @"canDisable": @(CanDisable(target, *extension)),
      @"removable": @(CanRemove(target, extension.get())),
    }];
  }
  return result;
}

NSString* AraratSetExtensionEnabled(NSString* profile, NSString* identifier, BOOL enabled) {
  Profile* target = LoadedProfileForDirectory(profile);
  if (!target || ![identifier isKindOfClass:NSString.class] || identifier.length == 0) return @"unknown";
  const std::string id = base::SysNSStringToUTF8(identifier);
  auto* registry = extensions::ExtensionRegistry::Get(target);
  auto* prefs = extensions::ExtensionPrefs::Get(target);
  auto* registrar = extensions::ExtensionRegistrar::Get(target);
  const extensions::Extension* extension = registry ? registry->GetInstalledExtension(id) : nullptr;
  if (!extension || !prefs || !registrar) return @"unknown";
  auto* system = extensions::ExtensionSystem::Get(target);
  auto* policy = system ? system->management_policy() : nullptr;
  const bool currently_enabled = registry->enabled_extensions().Contains(id) ||
                                 registry->terminated_extensions().Contains(id);
  if (!enabled) {
    if (!currently_enabled) return @"unchanged";
    if (!CanDisable(target, *extension)) return @"policy";
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
  if (!policy || !policy->UserMayModifySettings(extension, nullptr)) return @"policy";
  registrar->EnableExtension(id);
  ExtensionWatcher::Get().NotifyChanged();
  return @"done";
}

NSString* AraratSetExtensionSiteAccess(NSString* profile, NSString* identifier, NSString* access) {
  Profile* target = LoadedProfileForDirectory(profile);
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
  Profile* target = LoadedProfileForDirectory(profile);
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
  Profile* target = LoadedProfileForDirectory(profile);
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
    // Nothing to review (the state changed since the row was drawn): run the same enable the
    // switch would, with its policy check.
    NSString* result = AraratSetExtensionEnabled(profile, identifier, YES);
    if (report) report([result isEqual:@"done"] || [result isEqual:@"unchanged"]);
    return;
  }
  ReviewRequest::Start(target, extension.get(), gfx::NativeWindow(window), report);
}

void AraratRemoveExtension(NSString* profile, NSString* identifier, NSWindow* window,
                           void (^completion)(NSString* result, NSString* detail)) {
  void (^report)(NSString*, NSString*) = [completion copy];
  Profile* target = LoadedProfileForDirectory(profile);
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
// two profiles with different extensions. The profile is loaded when it exists and created when it
// does not (the check seeds the workspace's second profile, whose space was never shown). Unpacked
// installs are trusted locations, so a newer version of the same fixture does not disable the
// extension for a permissions increase; the check marks that state through
// AraratCheckDisableExtensionForReview below.
void AraratCheckLoadUnpackedExtension(NSString* profile, NSString* path,
                                      void (^completion)(NSString* result)) {
  void (^report)(NSString*) = [completion copy];
  if (!IsCheckRun()) {
    if (report) report(@"refused");
    return;
  }
  auto* manager = g_browser_process ? g_browser_process->profile_manager() : nullptr;
  base::FilePath profile_path = PathForDirectory(profile, manager);
  base::FilePath directory([path isKindOfClass:NSString.class] ? base::SysNSStringToUTF8(path) : std::string());
  if (profile_path.empty() || directory.empty() || !directory.IsAbsolute()) {
    if (report) report(@"unknown");
    return;
  }
  Profile* loaded = manager->GetProfileByPath(profile_path);
  if (loaded) {
    InstallUnpacked(loaded, directory, report);
    return;
  }
  // A load that fails for a path that does not exist yet is answered with a profile creation; the
  // workspace can name a profile Chrome has not made yet. The callback also runs synchronously
  // when that is the case, so it is the one place that creates and installs.
  manager->LoadProfileByPath(
      profile_path, /*incognito=*/false, base::BindOnce(^(Profile* profile_loaded) {
        if (profile_loaded) {
          InstallUnpacked(profile_loaded, directory, report);
          return;
        }
        manager->CreateProfileAsync(profile_path, base::BindOnce(^(Profile* created) {
          if (created) {
            InstallUnpacked(created, directory, report);
          } else if (report) {
            report(@"unknown");
          }
        }));
      }));
}

// Check-only: the state Chromium sets when an update asks for more permissions, without needing
// a store-installed CRX (an unpacked update is a trusted location and is never disabled).
void AraratCheckDisableExtensionForReview(NSString* profile, NSString* identifier) {
  if (!IsCheckRun()) return;
  Profile* target = LoadedProfileForDirectory(profile);
  auto* registry = target ? extensions::ExtensionRegistry::Get(target) : nullptr;
  auto* registrar = target ? extensions::ExtensionRegistrar::Get(target) : nullptr;
  if (!registry || !registrar || ![identifier isKindOfClass:NSString.class]) return;
  const std::string id = base::SysNSStringToUTF8(identifier);
  if (!registry->GetInstalledExtension(id)) return;
  registrar->DisableExtension(id, {extensions::disable_reason::DISABLE_PERMISSIONS_INCREASE});
}

// Check-only: accepts or cancels the Views dialog a Settings action opened, and returns the
// dialog's contents class ("ExtensionInstallDialogView" for the re-enable prompt; the uninstall
// dialog's own class otherwise), or an empty string when no such dialog is up. It is the seam
// accept-download-close uses (views::Widget::GetWidgetForNativeWindow, then the dialog delegate),
// because the VM's in-process accessibility tree is empty.
//
// What the seam may touch is restricted: "accept" accepts only the re-enable prompt
// (ExtensionInstallDialogView), wherever it was parented; "cancel" cancels a Views dialog that is a
// sheet or child of the settings window, and never an unrelated bubble. Every other Views dialog
// stays untouched.
namespace {

// The contents class of a Views dialog window, and the dialog itself; empty class means the window
// is not a Views dialog.
std::string DialogClassForWindow(NSWindow* window, views::DialogDelegate** dialog) {
  *dialog = nullptr;
  views::Widget* widget = views::Widget::GetWidgetForNativeWindow(gfx::NativeWindow(window));
  views::WidgetDelegate* delegate = widget ? widget->widget_delegate() : nullptr;
  views::DialogDelegate* resolved = delegate ? delegate->AsDialogDelegate() : nullptr;
  if (!resolved) return std::string();
  views::View* contents = delegate->GetContentsView();
  *dialog = resolved;
  return contents ? std::string(contents->GetClassName()) : std::string();
}

}  // namespace

NSString* AraratCheckExtensionDialog(NSWindow* parent, NSString* action) {
  if (!IsCheckRun() || !parent || ![action isKindOfClass:NSString.class]) return @"";
  const bool accept = [action isEqual:@"accept"];
  constexpr char kInstallDialogClass[] = "ExtensionInstallDialogView";
  // The parent-linked passes: the settings window's sheet, its sheets, its children, and windows
  // whose parentWindow is the settings window.
  NSMutableArray<NSWindow*>* linked = [NSMutableArray array];
  if (parent.attachedSheet) [linked addObject:parent.attachedSheet];
  for (NSWindow* sheet in parent.sheets) {
    if (sheet != parent.attachedSheet) [linked addObject:sheet];
  }
  for (NSWindow* child in parent.childWindows) [linked addObject:child];
  for (NSWindow* window in NSApp.windows) {
    if (window != parent && window.parentWindow == parent) [linked addObject:window];
  }
  auto resolve = [&](NSWindow* window, const char* pass) -> NSString* {
    if (!window.isVisible) return nil;
    views::DialogDelegate* dialog = nullptr;
    const std::string name = DialogClassForWindow(window, &dialog);
    if (!dialog || name.empty()) return nil;
    // Accepting is the re-enable prompt's alone; a parent-linked cancel may take any Views dialog
    // the settings window opened (the uninstall dialog's contents class is not ours to name).
    if (accept && name != kInstallDialogClass) return nil;
    std::fprintf(stderr, "ararat-trace: extension-dialog pass=%s action=%s class=%s\n", pass,
                 action.UTF8String, name.c_str());
    if (accept) {
      dialog->AcceptDialog();
    } else {
      dialog->CancelDialog();
    }
    return base::SysUTF8ToNSString(name);
  };
  for (NSWindow* window in linked) {
    if (NSString* name = resolve(window, "linked")) return name;
  }
  // A views dialog parented to a non-Browser window can be a window of its own; only the re-enable
  // prompt is accepted from that pass, so no unrelated bubble is touched.
  if (accept) {
    for (NSWindow* window in NSApp.windows) {
      if (window == parent) continue;
      if (NSString* name = resolve(window, "unrestricted")) return name;
    }
  }
  return @"";
}
