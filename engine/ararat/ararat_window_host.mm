
#include "ararat/core/ararat_window_host.h"

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <cmath>
#include <utility>
#include <cstdio>
#include <set>
#include <string>
#include <vector>
#include <unistd.h>

#include "ararat/core/ararat_browser_window.h"
#include "ararat/core/ararat_extensions_container.h"
#include "ararat/core/ararat_hooks.h"
#include "ararat/core/ararat_tab.h"
#include "base/check.h"
#include "base/auto_reset.h"
#include "base/command_line.h"
#include "base/functional/bind.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/i18n/rtl.h"
#include "base/observer_list.h"
#include "base/process/process.h"
#include "base/scoped_observation.h"
#include "base/strings/sys_string_conversions.h"
#include "base/supports_user_data.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
#include "content/public/browser/weak_document_ptr.h"
#include "content/public/browser/render_frame_host.h"
#include "chrome/app/chrome_command_ids.h"
#include "chrome/browser/profiles/keep_alive/profile_keep_alive_types.h"
#include "chrome/browser/profiles/keep_alive/scoped_profile_keep_alive.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_observer.h"
#include "chrome/browser/prefs/session_startup_pref.h"
#include "chrome/browser/sessions/session_service.h"
#include "chrome/browser/sessions/session_service_factory.h"
#include "chrome/browser/lifetime/application_lifetime_desktop.h"
#include "chrome/browser/lifetime/browser_shutdown.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/devtools/devtools_contents_resizing_strategy.h"
#include "chrome/browser/devtools/devtools_toggle_action.h"
#include "chrome/browser/devtools/devtools_ui_bindings.h"
#include "chrome/browser/devtools/devtools_window.h"
#include "chrome/browser/extensions/commands/command_service.h"
#include "chrome/browser/extensions/extension_commands_global_registry.h"
#include "chrome/browser/renderer_context_menu/render_view_context_menu.h"
#include "chrome/browser/chrome_browser_application_mac.h"
#include "chrome/browser/ui/browser_tabstrip.h"
#include "chrome/browser/ui/browser_commands.h"
#include "chrome/browser/ui/dialogs/browser_dialogs.h"
#include "chrome/browser/ui/browser_command_controller.h"
#include "chrome/browser/global_keyboard_shortcuts_mac.h"
#import "chrome/browser/ui/cocoa/browser_window_command_handler.h"
#import "chrome/browser/ui/cocoa/chrome_command_dispatcher_delegate.h"
#import "components/remote_cocoa/app_shim/native_widget_ns_window_bridge.h"
#include "components/input/native_web_keyboard_event.h"
#include "ui/base/accelerators/global_accelerator_listener/global_accelerator_listener.h"
#include "ui/views/focus/focus_manager.h"
#include "chrome/browser/ui/browser_window.h"
#include "chrome/browser/ui/bubble_anchor_util.h"
#include "chrome/browser/ui/exclusive_access/exclusive_access_manager.h"
#include "chrome/browser/ui/exclusive_access/exclusive_access_context.h"
#include "chrome/browser/ui/exclusive_access/fullscreen_controller.h"
#include "chrome/browser/ui/find_bar/find_bar.h"
#include "chrome/browser/ui/find_bar/find_bar_controller.h"
#include "chrome/browser/ui/extensions/extension_action_view_model.h"
#include "chrome/browser/ui/unload_controller.h"
#include "chrome/browser/ui/browser_init_state.h"
#include "chrome/browser/ui/browser_active_state_manager/browser_active_state_manager.h"
#include "chrome/browser/ui/navigator/browser_navigator.h"
#include "chrome/browser/ui/navigator/browser_navigator_params.h"
#include "chrome/browser/ui/startup/startup_tab.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface_iterator.h"
#include "chrome/browser/ui/browser_window/public/create_browser_window.h"
#include "chrome/browser/ui/tabs/tab_enums.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/tabs/tab_strip_model_observer.h"
#include "content/public/browser/navigation_controller.h"
#include "chrome/browser/ui/toolbar/toolbar_action_view_model.h"
#include "chrome/browser/ui/views/extensions/extension_popup.h"
#include "chrome/browser/ui/views/extensions/extension_keybinding_registry_views.h"
#include "chrome/browser/ui/views/bubble_anchor_util_views.h"
#include "chrome/browser/ui/views/file_system_access/file_system_access_restore_permission_bubble_view.h"
#include "chrome/browser/web_applications/web_app_helpers.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_widget_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/visibility.h"
#include "content/public/browser/web_contents_delegate.h"
#include "content/public/browser/storage_partition.h"
#include "net/cookies/canonical_cookie.h"
#include "net/cookies/cookie_options.h"
#include "net/cookies/cookie_partition_key_collection.h"
#include "services/network/public/mojom/cookie_manager.mojom.h"
#include "components/javascript_dialogs/app_modal_dialog_controller.h"
#include "components/javascript_dialogs/app_modal_dialog_manager.h"
#include "components/javascript_dialogs/app_modal_dialog_view.h"
#include "components/permissions/chooser_controller.h"
#include "components/find_in_page/find_tab_helper.h"
#include "components/find_in_page/find_types.h"
#include "ui/gfx/range/range.h"
#include "components/prefs/pref_service.h"
#include "components/prefs/pref_change_registrar.h"
#include "components/tabs/public/tab_interface.h"
#include "components/web_modal/web_contents_modal_dialog_host.h"
#include "components/web_modal/web_contents_modal_dialog_manager.h"
#include "components/web_modal/web_contents_modal_dialog_manager_delegate.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/extension_host.h"
#include "extensions/browser/extension_host_registry.h"
#include "components/remote_cocoa/common/native_widget_ns_window.mojom.h"
#include "components/input/native_web_keyboard_event.h"
#include "chrome/common/pref_names.h"
#include "chrome/common/chrome_constants.h"
#include "chrome/grit/generated_resources.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/image/image.h"
#include "ui/base/l10n/l10n_util_mac.h"
#include "ui/display/types/display_constants.h"
#include "ui/events/keycodes/keyboard_codes.h"
#import "ui/base/cocoa/command_dispatcher.h"
#import "ui/base/cocoa/user_interface_item_command_handler.h"
#include "ui/views/controls/native/native_view_host.h"
#include "ui/views/layout/fill_layout.h"
#include "ui/views/view.h"
#import "ui/base/cocoa/find_pasteboard.h"
#include "ui/views/view_class_properties.h"
#include "ui/views/widget/widget.h"
#include "ui/views/widget/native_widget_mac.h"
#include "ui/views/cocoa/native_widget_mac_ns_window_host.h"
#include "ui/views/widget/widget_delegate.h"
#include "ui/views/widget/widget_observer.h"
#include "ui/views/window/client_view.h"
#include "url/gurl.h"
#include "url/origin.h"

@interface NSObject (AraratCommandDispatch)
- (void)commandDispatch:(id)sender;
- (void)commandDispatchUsingKeyModifiers:(id)sender;
- (void)windowDidBecomeMain:(NSNotification*)notification;
- (Profile*)lastProfileIfLoaded;
@end

bool AraratIsKeyboardShortcut(const input::NativeWebKeyboardEvent& event) {
  NSEvent* native = event.os_event.Get();
  if (!native || !EventUsesPerformKeyEquivalent(native)) return false;
  int command = CommandForKeyEvent(native).chrome_command;
  if (command == -1) command = DelayedWebContentsCommandForKeyEvent(native);
  return command != -1;
}

bool AraratRedispatchKeyboardEvent(AraratWindowHostCore* host, const input::NativeWebKeyboardEvent& event) {
  if (event.skip_if_unhandled || event.GetType() == input::NativeWebKeyboardEvent::Type::kChar ||
      !event.os_event || event.os_event.Get().type != NSEventTypeKeyDown) return false;
  auto* window_host = views::NativeWidgetMacNSWindowHost::GetFromNativeWindow(host->GetNativeWindow());
  return window_host && window_host->RedispatchKeyEvent(event.os_event.Get());
}

namespace {

bool IsDevToolsCheck() {
  auto* command = base::CommandLine::ForCurrentProcess();
  return command->GetSwitchValueASCII("ararat-check") == "devtools" ||
         command->GetSwitchValueASCII("ararat-screen") == "devtools" ||
         command->GetSwitchValueASCII("ararat-check") == "keyboard" ||
         command->GetSwitchValueASCII("ararat-screen") == "keyboard";
}

class ExtensionPopupCheck : public extensions::ExtensionHostRegistry::Observer {
 public:
  explicit ExtensionPopupCheck(Profile* profile) {
    observation_.Observe(extensions::ExtensionHostRegistry::Get(profile));
  }
  void OnExtensionHostCompletedFirstLoad(content::BrowserContext*, extensions::ExtensionHost* host) override {
    if (host->extension_host_type() == extensions::mojom::ViewType::kExtensionPopup) {
      current = host;
      ++loaded;
    }
  }
  void OnExtensionHostDestroyed(content::BrowserContext*, extensions::ExtensionHost* host) override {
    if (current == host) { current = nullptr; ++destroyed; }
  }
  void OnExtensionHostRegistryShutdown(extensions::ExtensionHostRegistry*) override {
    current = nullptr;
    observation_.Reset();
  }
  raw_ptr<extensions::ExtensionHost> current = nullptr;
  int loaded = 0;
  int destroyed = 0;
  bool api_callback = false;
 private:
  base::ScopedObservation<extensions::ExtensionHostRegistry, extensions::ExtensionHostRegistry::Observer> observation_{this};
};

bool IsCloseCheck() {
  return base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII(
             "ararat-check") == "close";
}

bool IsProfileCheck() {
  auto* command = base::CommandLine::ForCurrentProcess();
  const auto check = command->GetSwitchValueASCII("ararat-check");
  return check == "profiles" || check == "ext-windows" || check == "incognito" ||
         command->GetSwitchValueASCII("ararat-screen") == "profiles";
}

void PinStartupPref(Profile* profile) {
  auto pref = SessionStartupPref::GetStartupPref(profile);
  if (pref.type != SessionStartupPref::DEFAULT) {
    pref.type = SessionStartupPref::DEFAULT;
    SessionStartupPref::SetStartupPref(profile, pref);
  }
}

struct HostedProfile : ProfileObserver {
  HostedProfile(Profile* profile, std::unique_ptr<ScopedProfileKeepAlive> keep_alive)
      : profile(profile), keep_alive(std::move(keep_alive)) {
    registrar.Init(profile->GetPrefs());
    registrar.Add(prefs::kRestoreOnStartup, base::BindRepeating(&PinStartupPref, base::Unretained(profile)));
    observation.Observe(profile);
    PinStartupPref(profile);
  }
  void OnProfileWillBeDestroyed(Profile* destroyed) override {
    if (base::CommandLine::ForCurrentProcess()->HasSwitch("ararat-check") ||
        base::CommandLine::ForCurrentProcess()->HasSwitch("ararat-screen"))
      std::fprintf(stderr, "ararat-trace: hosted-profile-will-be-destroyed name=%s\n",
                   destroyed->GetPath().BaseName().value().c_str());
    registrar.Reset();
    observation.Reset();
    profile = nullptr;
  }
  raw_ptr<Profile> profile;
  std::unique_ptr<ScopedProfileKeepAlive> keep_alive;
  PrefChangeRegistrar registrar;
  base::ScopedObservation<Profile, ProfileObserver> observation{this};
};

NSUInteger g_check_page_only_save_count = 0;

class HostNativeWidgetMac : public views::NativeWidgetMac {
 public:
  HostNativeWidgetMac(views::Widget* widget, AraratWindowHostCore* host)
      : NativeWidgetMac(widget), host_(host) {}

 protected:
  void OnWindowInitialized() override {
    if (auto* bridge = GetInProcessNSWindowBridge())
      bridge->SetCommandDispatcher([[ChromeCommandDispatcherDelegate alloc] init], [[BrowserWindowCommandHandler alloc] init]);
  }
  void ValidateUserInterfaceItem(int32_t command, remote_cocoa::mojom::ValidateUserInterfaceItemResult* result) override {
    auto* window = host_->window();
    auto* browser = window ? window->browser() : nullptr;
    if (host_->popup() && (command == IDC_FOCUS_LOCATION || command == IDC_FOCUS_SEARCH)) { result->enable = false; return; }
    if (!host_->popup() && !host_->closing() && !host_->closed() &&
        (command == IDC_NEW_TAB || command == IDC_FOCUS_LOCATION || command == IDC_FOCUS_SEARCH)) { result->enable = true; return; }
    result->enable = browser && !browser->IsDeleteScheduled() ? chrome::IsCommandEnabled(browser, command) : host_->ValidateEmptyCommand(command);
  }
  bool WillExecuteCommand(int32_t command, WindowOpenDisposition disposition, bool before) override {
    auto* window = host_->window();
    auto* browser = window ? window->browser() : nullptr;
    if (host_->closing() || host_->closed() || (browser && browser->IsDeleteScheduled())) return false;
    if (!before) return true;
    if (ui::GlobalAcceleratorListener::GetInstance() && ui::GlobalAcceleratorListener::GetInstance()->IsShortcutHandlingSuspended()) return false;
    if (!host_->popup() && (command == IDC_NEW_TAB || command == IDC_FOCUS_LOCATION || command == IDC_FOCUS_SEARCH || command == IDC_CLOSE_TAB)) return true;
    if (!browser) return false;
    input::NativeWebKeyboardEvent event(blink::WebInputEvent::Type::kKeyDown, 0, base::TimeTicks());
    auto* controller = chrome::BrowserCommandController::From(browser);
    return controller && controller->IsReservedCommandOrKey(command, event);
  }
  bool ExecuteCommand(int32_t command, WindowOpenDisposition disposition, bool before) override {
    if (!WillExecuteCommand(command, disposition, before)) return false;
    if (host_->DispatchWorkspaceCommand(command)) return true;
    auto* window = host_->window();
    auto* browser = window ? window->browser() : nullptr;
    if (!browser) return host_->ExecuteEmptyCommand(command);
    if (command == IDC_NEW_WINDOW && base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check") == "incognito")
      std::fprintf(stderr, "ararat-trace: incognito-new-window dispatch popup=%d otr=%d\n", host_->popup(), browser->GetProfile()->IsOffTheRecord());
    if (host_->popup() && command == IDC_SAVE_PAGE &&
        base::CommandLine::ForCurrentProcess()->HasSwitch("ararat-page-only-menu-check")) ++g_check_page_only_save_count;
    chrome::ExecuteCommandWithDisposition(browser, command, disposition);
    return true;
  }
  void OnWindowFullscreenTransitionStart() override {
    host_->FullscreenTransitionStarting();
  }
  void OnWindowFullscreenTransitionComplete() override {
    host_->FullscreenStateChanged();
  }
  void PopulateCreateWindowParams(
      const views::Widget::InitParams& widget_params,
      remote_cocoa::mojom::CreateWindowParams* params) override {
    params->style_mask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                         NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable |
                         NSWindowStyleMaskFullSizeContentView;
    params->titlebar_appears_transparent = true;
    params->window_title_hidden = true;
  }
 private:
  raw_ptr<AraratWindowHostCore> host_;
};

NSUInteger g_check_dialog_count = 0;
NSUInteger g_check_cancel_dialog = 1;
NSMutableArray<NSString*>* g_check_beforeunload_profiles;
NSMutableArray<NSDictionary*>* g_check_dialog_pages;
__weak ARWindowHost* g_check_dialog_host;
bool g_check_dialog_failed = false;
bool g_check_dialog_installed = false;
NSUInteger g_check_dialog_limit = 0;
struct CheckDocument {
  base::WeakPtr<content::WebContents> contents;
  content::WeakDocumentPtr document;
  uint64_t generation;
};
std::map<std::string, CheckDocument> g_check_beforeunload_lives;
uint64_t g_check_document_generation = 0;
uint64_t g_check_attempt_generation = 0;
struct CheckRequest {
  std::string live;
  uint64_t document_generation;
  uint64_t attempt_generation;
  bool cancel;
  bool claimed;
};
std::map<uint64_t, CheckRequest> g_check_requests;
uint64_t g_check_request_serial = 1;
uint64_t g_check_scripted_request = 0;
uint64_t g_check_ready_request = 0;
NSUInteger g_check_admitted_count = 0;
std::set<std::string> g_check_dialog_seen;
bool g_fullscreen_completion_called = false;
bool g_fullscreen_completion_without_browser = false;

class CheckChooserController : public permissions::ChooserController {
 public:
  CheckChooserController() : ChooserController(u"Ararat chooser fixture") {}
  std::u16string GetNoOptionsText() const override { return u"No devices"; }
  std::u16string GetOkButtonLabel() const override { return u"Connect"; }
  std::pair<std::u16string, std::u16string> GetThrobberLabelAndTooltip() const override { return {u"Searching", u"Searching"}; }
  size_t NumOptions() const override { return 0; }
  std::u16string GetOption(size_t) const override { return {}; }
  void Select(const std::vector<size_t>&) override {}
  void Cancel() override {}
  void Close() override {}
  void OpenHelpCenterUrl() const override {}
};

bool CheckRequestCurrent(const CheckRequest& request) {
  auto it = g_check_beforeunload_lives.find(request.live);
  if (it == g_check_beforeunload_lives.end() || !g_check_dialog_host ||
      request.attempt_generation != g_check_attempt_generation ||
      request.document_generation != it->second.generation) return false;
  auto* contents = it->second.contents.get();
  return contents && contents->GetPrimaryMainFrame() &&
         it->second.document.AsRenderFrameHostIfValid() == contents->GetPrimaryMainFrame();
}

class CheckDialog : public javascript_dialogs::AppModalDialogView {
 public:
  CheckDialog(std::unique_ptr<javascript_dialogs::AppModalDialogController> controller, bool expected,
              uint64_t request, bool cancel)
      : controller_(std::move(controller)), expected_(expected), cancel_(cancel), request_(request) {}
  void ShowAppModalDialog() override {
    if (IsCloseCheck()) std::fprintf(stderr, "ararat-trace: dialog-shown\n");
    ++g_check_dialog_count;
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&CheckDialog::Respond, weak_factory_.GetWeakPtr()));
  }
  void ActivateAppModalDialog() override {}
  void CloseAppModalDialog() override {
    auto weak = weak_factory_.GetWeakPtr();
    controller_->OnClose();
    if (weak) delete this;
  }
  void AcceptAppModalDialog() override {
    Resolve(true, false);
  }
  void CancelAppModalDialog() override {
    Resolve(false, false);
  }
  bool IsShowing() const override { return true; }
 private:
  void Respond() {
    if (g_check_dialog_count <= 32) std::fprintf(stderr, "ararat-check-dialog: response pid=%d count=%lu expected=%d cancel=%d\n", getpid(), (unsigned long)g_check_dialog_count, expected_, cancel_);
    Resolve(!cancel_, true);
  }
  void Resolve(bool accept, bool scripted) {
    auto it = g_check_requests.find(request_);
    bool valid = expected_ && it != g_check_requests.end() && CheckRequestCurrent(it->second) &&
                 controller_->web_contents() == g_check_beforeunload_lives[it->second.live].contents.get() &&
                 accept == !it->second.cancel;
    if (!scripted || !valid) { g_check_dialog_failed = true; accept = false; }
    auto weak = weak_factory_.GetWeakPtr();
    const uint64_t request = request_;
    base::AutoReset<uint64_t> ready(&g_check_ready_request, 0);
    base::OnceClosure authorize;
    if (scripted && valid) authorize = base::BindOnce([](uint64_t token) { g_check_ready_request = token; }, request);
    if (accept) controller_->OnAccept(u"", false, std::move(authorize));
    else { chrome_browser_application_mac::CancelTerminate(); controller_->OnCancel(false, std::move(authorize)); }
    if (request && g_check_requests.erase(request)) g_check_dialog_failed = true;
    if (weak) delete this;
  }
  std::unique_ptr<javascript_dialogs::AppModalDialogController> controller_;
  bool expected_;
  bool cancel_ = true;
  uint64_t request_;
  base::WeakPtrFactory<CheckDialog> weak_factory_{this};
};

BrowserWindow* AraratCreateBrowserWindowForPendingHost(
    BrowserWindowInterface* browser);

AraratWindowHostCore* g_pending_window_host = nullptr;
std::string g_pending_profile;
class HostClientView : public views::ClientView {
 public:
  HostClientView(views::Widget* widget, views::View* contents,
                 AraratWindowHostCore* host)
      : views::ClientView(widget, contents), host_(host) {}
  views::CloseRequestResult OnWindowCloseRequested() override {
    if (IsCloseCheck()) std::fprintf(stderr, "ararat-trace: close-requested\n");
    if (host_->windows().empty()) return views::CloseRequestResult::kCanClose;
    host_->Close();
    return views::CloseRequestResult::kCannotClose;
  }
 private:
  raw_ptr<AraratWindowHostCore> host_;
};

class HostWidgetDelegate : public views::WidgetDelegate {
 public:
  explicit HostWidgetDelegate(AraratWindowHostCore* host) : host_(host) {}
  bool OnCloseRequested(views::Widget::ClosedReason) override {
    if (host_->windows().empty()) return true;
    host_->Close();
    return false;
  }
 private:
  raw_ptr<AraratWindowHostCore> host_;
};
std::set<BrowserWindowInterface*>& AraratWindows() {
  static base::NoDestructor<std::set<BrowserWindowInterface*>> windows;
  return *windows;
}

bool g_restore_omitted = true;
int g_restore_checked = 0;
bool g_restore_devtools_checked = false;

std::set<AraratWindowHostCore*>& AraratHosts() {
  static base::NoDestructor<std::set<AraratWindowHostCore*>> hosts;
  return *hosts;
}

void AraratSetPendingWindowHost(AraratWindowHostCore* host, const std::string& profile = {}) {
  g_pending_window_host = host;
  g_pending_profile = profile;
}

AraratWindowHostCore* AraratTakePendingWindowHost(const std::string& profile) {
  if (!g_pending_window_host || g_pending_profile != profile) return nullptr;
  AraratWindowHostCore* host = g_pending_window_host;
  AraratSetPendingWindowHost(nullptr);
  return host;
}

BrowserWindow* AraratCreateBrowserWindowForPendingHost(
    BrowserWindowInterface* browser) {
  const auto incoming_name = browser->GetProfile()->GetPath().BaseName().value();
  AraratWindowHostCore* core = browser->GetProfile()->IsOffTheRecord() ||
                                       browser->GetType() != BrowserWindowInterface::TYPE_NORMAL
      ? nullptr : AraratTakePendingWindowHost(incoming_name);
  auto* command_line = base::CommandLine::ForCurrentProcess();
  if (command_line->GetSwitchValueASCII("ararat-check") == "profiles") {
    auto* state = BrowserInitState::From(browser);
    g_restore_omitted &= state && state->omit_from_session_restore() &&
                         !state->should_trigger_session_restore();
    ++g_restore_checked;
    if (browser->GetType() == BrowserWindowInterface::TYPE_DEVTOOLS)
      g_restore_devtools_checked = true;
  }
  bool checking = command_line->HasSwitch("ararat-check") ||
                  command_line->HasSwitch("ararat-screen");
  if (checking) std::fprintf(stderr, "ararat-trace: browser-factory type=%d pending=%d\n", browser->GetType(), core != nullptr);
  if (checking && g_pending_window_host && !core)
    std::fprintf(stderr, "ararat-trace: browser-factory pending-mismatch requested=%s incoming=%s otr=%d\n",
                 g_pending_profile.c_str(), incoming_name.c_str(), browser->GetProfile()->IsOffTheRecord());
  if (!core) {
    Profile* profile = browser->GetProfile();
    auto type = browser->GetType();
    auto* state = BrowserInitState::From(browser);
    auto* registry = extensions::ExtensionRegistry::Get(profile);
    const bool extension_popup = type == BrowserWindowInterface::TYPE_APP_POPUP &&
        state && registry && registry->GetExtensionById(
            web_app::GetAppIdFromApplicationName(state->create_params().app_name),
            extensions::ExtensionRegistry::ENABLED);
    const auto name = profile->GetPath().BaseName().value();
    bool hosted = std::any_of(AraratHosts().begin(), AraratHosts().end(),
                              [&name, profile, type](AraratWindowHostCore* host) {
                                if (host->closed() || host->closing()) return false;
                                if (!host->popup()) return host->HasProfile(name);
                                auto* window = host->windowForProfile(name);
                                return type == BrowserWindowInterface::TYPE_DEVTOOLS && !host->devtools() &&
                                       window && window->browser()->GetProfile() == profile;
                              });
    if (type != BrowserWindowInterface::TYPE_NORMAL &&
        type != BrowserWindowInterface::TYPE_POPUP &&
        type != BrowserWindowInterface::TYPE_DEVTOOLS && !extension_popup) {
      if (checking) std::fprintf(stderr, "ararat-trace: browser-factory fallback=type\n");
      return nullptr;
    }
    if (!hosted && (extension_popup || !profile->IsOffTheRecord())) {
      if (checking) std::fprintf(stderr, "ararat-trace: browser-factory fallback=profile-mismatch\n");
      return nullptr;
    }
    if (!AraratHasHostCallback()) {
      if (checking) std::fprintf(stderr, "ararat-trace: browser-factory fallback=callback-null\n");
      return nullptr;
    }
    gfx::Rect bounds = state->create_params().initial_bounds;
    if (type == BrowserWindowInterface::TYPE_DEVTOOLS) {
      const auto* placement = profile->GetPrefs()->GetDict(prefs::kAppWindowPlacement).FindDict(DevToolsWindow::kDevToolsApp);
      if (placement) {
        int left = placement->FindInt("left").value_or(100);
        int top = placement->FindInt("top").value_or(100);
        int right = placement->FindInt("right").value_or(740);
        int bottom = placement->FindInt("bottom").value_or(740);
        bounds = gfx::Rect(left, top, std::max(0, right - left), std::max(0, bottom - top));
      }
    }
    void* owner = AraratRequestHost(type == BrowserWindowInterface::TYPE_POPUP || type == BrowserWindowInterface::TYPE_DEVTOOLS || extension_popup || profile->IsOffTheRecord(), name, bounds);
    if (!owner) {
      if (checking) std::fprintf(stderr, "ararat-trace: browser-factory fallback=host-unavailable\n");
      return nullptr;
    }
    core = [(__bridge ARWindowHost*)owner hostCore];
    if (checking) std::fprintf(stderr, "ararat-trace: browser-factory host=%d\n", core != nullptr);
    if (!core || core->windowForProfile(name) || core->closed() || core->closing()) {
      if (checking) std::fprintf(stderr, "ararat-trace: browser-factory fallback=host-unusable\n");
      return nullptr;
    }
  }
  if (core->closed() || core->closing() || core->windowForProfile(incoming_name)) {
    if (checking) std::fprintf(stderr, "ararat-trace: browser-factory fallback=pending-unusable\n");
    return nullptr;
  }
  auto* window = new AraratBrowserWindow(browser, core);
  AraratWindows().insert(browser);
  g_ararat_is_window = [](BrowserWindowInterface* candidate) {
    return AraratWindows().contains(candidate);
  };
  core->SetWindow(window);
  return window;
}

}  // namespace

bool AraratCheckDialogIntegrity() { return !g_check_dialog_failed && g_check_requests.empty(); }

bool AraratCheckRejectJavaScriptDialog() {
  auto* args = base::CommandLine::ForCurrentProcess();
  const auto check = args->GetSwitchValueASCII("ararat-check");
  if (args->HasSwitch("ararat-screen") || (check != "profiles" && check != "keyboard" && check != "quit-cancel" && check != "close")) return false;
  g_check_dialog_failed = true;
  static unsigned count = 0;
  if (count++ < 32) std::fprintf(stderr, "ararat-check-dialog: unexpected javascript pid=%d\n", getpid());
  return true;
}

bool AraratCheckRegisterBeforeUnload(const std::string& live, content::WebContents* contents) {
  auto* args = base::CommandLine::ForCurrentProcess();
  if (!args->HasSwitch("ararat-screen") && args->HasSwitch("ararat-check")) {
    for (auto it = g_check_beforeunload_lives.begin(); it != g_check_beforeunload_lives.end();) {
      auto* current = it->second.contents.get();
      if (!current || !current->GetPrimaryMainFrame() || it->second.document.AsRenderFrameHostIfValid() != current->GetPrimaryMainFrame()) it = g_check_beforeunload_lives.erase(it);
      else ++it;
    }
    if (!g_check_dialog_installed || live.empty() || !contents || !contents->GetPrimaryMainFrame() ||
        (g_check_beforeunload_lives.size() >= 64 && !g_check_beforeunload_lives.contains(live))) {
      g_check_dialog_failed = true;
      return false;
    }
    g_check_beforeunload_lives.insert_or_assign(live, CheckDocument{contents->GetWeakPtr(), contents->GetPrimaryMainFrame()->GetWeakDocumentPtr(), ++g_check_document_generation});
  }
  return true;
}

void AraratCheckUnregisterBeforeUnload(const std::string& live, content::WebContents* contents) {
  auto* args = base::CommandLine::ForCurrentProcess();
  if (!args->HasSwitch("ararat-screen") && args->HasSwitch("ararat-check")) {
    auto it = g_check_beforeunload_lives.find(live);
    if (it != g_check_beforeunload_lives.end() && it->second.contents.get() == contents) { g_check_beforeunload_lives.erase(it); ++g_check_document_generation; }
  }
}

void AraratCheckRevokeChangedDocument(const std::string& live, content::WebContents* contents) {
  auto it = g_check_beforeunload_lives.find(live);
  if (it != g_check_beforeunload_lives.end() && it->second.contents.get() == contents &&
      it->second.document.AsRenderFrameHostIfValid() != contents->GetPrimaryMainFrame()) { g_check_beforeunload_lives.erase(it); ++g_check_document_generation; }
}

uint64_t AraratCheckDocumentRevision() { return g_check_document_generation; }

void AraratInstallWindowFactory() {
  g_ararat_create_browser_window = &AraratCreateBrowserWindowForPendingHost;
  g_ararat_devtools_changed = [](content::WebContents* inspected, content::WebContents*) {
    for (auto* host : AraratHosts()) {
      for (const auto& [name, window] : host->windows()) {
        if (window->browser()->GetTabStripModel()->GetIndexOfWebContents(inspected) != TabStripModel::kNoTab) {
          host->DevToolsChanged(inspected);
          return;
        }
      }
    }
  };
  g_ararat_shown_browser = [](NSWindow* window, bool* recognized) -> BrowserWindowInterface* {
    for (auto* host : AraratHosts()) {
      if (host->GetNativeWindow().GetNativeNSWindow() != window) continue;
      *recognized = true;
      return host->window() ? host->window()->browser() : nullptr;
    }
    *recognized = false;
    return nullptr;
  };
}

void AraratOpenOffTheRecordURLs(Profile* profile, NSArray* urls) {
  if (!profile || !profile->IsOffTheRecord()) return;
  auto* browser = CreateBrowserWindow(BrowserWindowCreateParams(profile, true));
  if (!browser) return;
  for (NSDictionary* entry in urls) {
    NSURL* url = entry[@"url"];
    if (!url) continue;
    NavigateParams params(browser, GURL(url.absoluteString.UTF8String), ui::PAGE_TRANSITION_AUTO_TOPLEVEL);
    params.disposition = WindowOpenDisposition::NEW_FOREGROUND_TAB;
    if ([entry[@"untrusted"] boolValue]) params.initiator_origin = url::Origin();
    Navigate(&params);
  }
  browser->GetWindow()->Show();
}

// Based on Ardia's engine/ardiacore/src/ardia/core/ac_modal_dialog_host.mm (GPL-3.0).
class AraratModalDialogHost : public web_modal::WebContentsModalDialogHost,
                              public views::WidgetObserver {
 public:
  explicit AraratModalDialogHost(AraratWindowHostCore* host) : host_(host) {
    host_->widget()->AddObserver(this);
  }
  ~AraratModalDialogHost() override {
    observers_.Notify(&web_modal::ModalDialogHostObserver::OnHostDestroying);
    if (observing_) host_->widget()->RemoveObserver(this);
  }
  gfx::NativeView GetHostView() const override {
    return host_->widget()->GetNativeView();
  }
  gfx::Point GetDialogPosition(const gfx::Size& size) override {
    const auto& page = host_->page_rect();
    int x = std::max(page.x() + (page.width() - size.width()) / 2, 0);
    x = std::min(x, std::max(0, host_->widget()->GetWindowBoundsInScreen().width() - size.width()));
    return gfx::Point(x, page.y());
  }
  bool ShouldActivateDialog() const override {
    if (base::CommandLine::ForCurrentProcess()->HasSwitch("ararat-check")) return false;
    auto* window = host_->window();
    return window && GetLastActiveBrowserWindowInterfaceWithAnyProfile() == window->browser();
  }
  gfx::Size GetMaximumDialogSize() override { return host_->page_rect().size(); }
  void AddObserver(web_modal::ModalDialogHostObserver* observer) override {
    observers_.AddObserver(observer);
  }
  void RemoveObserver(web_modal::ModalDialogHostObserver* observer) override {
    observers_.RemoveObserver(observer);
  }
  void NotifyPositionRequiresUpdate() override {
    observers_.Notify(&web_modal::ModalDialogHostObserver::OnPositionRequiresUpdate);
  }
  void OnWidgetBoundsChanged(views::Widget*, const gfx::Rect&) override {
    NotifyPositionRequiresUpdate();
  }
  void OnWidgetDestroying(views::Widget* widget) override {
    widget->RemoveObserver(this);
    observing_ = false;
  }
 private:
  raw_ptr<AraratWindowHostCore> host_;
  bool observing_ = true;
  base::ObserverList<web_modal::ModalDialogHostObserver> observers_;
};

AraratWindowHostCore::AraratWindowHostCore(gfx::NativeView app_content_view,
                                           void* owner)
    : owner_(owner) {
  AraratHosts().insert(this);
  delegate_ = std::make_unique<HostWidgetDelegate>(this);
  delegate_->SetClientViewFactory(base::BindOnce(
      [](AraratWindowHostCore* host, views::Widget* widget, views::View* contents)
          -> std::unique_ptr<views::ClientView> {
        return std::make_unique<HostClientView>(widget, contents, host);
      }, base::Unretained(this)));
  delegate_->SetCanResize(true);
  delegate_->SetCanMaximize(true);
  auto contents = std::make_unique<views::View>();
  contents->SetLayoutManager(std::make_unique<views::FillLayout>());
  auto* native_host =
      contents->AddChildView(std::make_unique<views::NativeViewHost>());
  extension_anchor_ = contents->AddChildView(std::make_unique<views::View>());
  extension_anchor_->SetProperty(views::kViewIgnoredByLayoutKey, true);
  extension_anchor_->SetCanProcessEventsWithinSubtree(false);
  if (AraratUsesSharedCompositor()) {
    page_host_ = native_host->AddChildView(std::make_unique<views::NativeViewHost>());
  }
  delegate_->SetContentsView(std::move(contents));
  widget_ = std::make_unique<views::Widget>();
  views::Widget::InitParams params(
      views::Widget::InitParams::CLIENT_OWNS_WIDGET);
  params.delegate = delegate_.get();
  params.name = "AraratWindowHost";
  params.bounds = gfx::Rect(0, 0, 800, 600);
  params.remove_standard_frame = true;
  params.native_widget = new HostNativeWidgetMac(widget_.get(), this);
  widget_->Init(std::move(params));
  modal_dialog_host_ = std::make_unique<AraratModalDialogHost>(this);
  native_host->Attach(app_content_view);
  widget_->LayoutRootViewIfNecessary();
}

web_modal::WebContentsModalDialogHost* AraratWindowHostCore::modal_dialog_host() const {
  return modal_dialog_host_.get();
}

AraratWindowHostCore::~AraratWindowHostCore() {
  AraratHosts().erase(this);
  CHECK(windows_.empty());
  if (g_pending_window_host == this) {
    AraratSetPendingWindowHost(nullptr);
  }
}

AraratBrowserWindow* AraratWindowHostCore::window() const {
  return windowForProfile(profile_name_);
}

AraratBrowserWindow* AraratWindowHostCore::windowForProfile(const std::string& name) const {
  auto it = windows_.find(name);
  return it == windows_.end() ? nullptr : it->second.get();
}

bool AraratWindowHostCore::HasProfile(const std::string& name) const {
  return [(__bridge ARWindowHost*)owner_ hasProfileDirectory:[NSString stringWithUTF8String:name.c_str()]];
}

gfx::NativeWindow AraratWindowHostCore::GetNativeWindow() const {
  return widget_->GetNativeWindow();
}

void AraratWindowHostCore::SetTitle(const std::u16string& title) {
  delegate_->SetTitle(title);
}

void AraratWindowHostCore::SetPageFullscreen(bool fullscreen) {
  ARWindowHost* owner = (__bridge ARWindowHost*)owner_;
  [owner.delegate windowHost:owner pageFullscreenChanged:fullscreen];
}

void AraratWindowHostCore::SetWindowFullscreen(bool fullscreen) {
  ARWindowHost* owner = (__bridge ARWindowHost*)owner_;
  [owner.delegate windowHost:owner windowFullscreenChanged:fullscreen];
}

bool AraratWindowHostCore::IsFullscreen() const {
  return base::CommandLine::ForCurrentProcess()->HasSwitch("ararat-check")
      ? check_fullscreen_ : widget_->IsFullscreen();
}

void AraratWindowHostCore::SetFullscreen(bool fullscreen, int64_t display_id) {
  FullscreenStateChanging();
  if (!base::CommandLine::ForCurrentProcess()->HasSwitch("ararat-check")) {
    widget_->SetFullscreen(fullscreen, display_id);
    return;
  }
  check_fullscreen_ = fullscreen;
  auto weak = weak_factory_.GetWeakPtr();
  FullscreenTransitionStarting();
  if (!weak) return;
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&AraratWindowHostCore::FullscreenStateChanged,
                                weak));
}

void AraratWindowHostCore::FullscreenTransitionStarting() {
  fullscreen_transitioning_ = true;
  ++fullscreen_transition_generation_;
  auto weak = weak_factory_.GetWeakPtr();
  FullscreenStateChanging();
  SetWindowFullscreen(IsFullscreen());
  if (!weak || !window()) return;
  auto* manager = ExclusiveAccessManager::From(window()->browser());
  if (manager) SetPageFullscreen(manager->fullscreen_controller()->IsWindowFullscreenForTabOrPending());
}

void AraratWindowHostCore::FullscreenStateChanging() {
  if (fullscreen_transition_controller_ || !window()) return;
  auto* manager = ExclusiveAccessManager::From(window()->browser());
  if (manager) fullscreen_transition_controller_ = manager->fullscreen_controller()->GetWeakPtr();
}

void AraratWindowHostCore::FullscreenStateChanged() {
  const auto generation = fullscreen_transition_generation_;
  auto weak = weak_factory_.GetWeakPtr();
  SetWindowFullscreen(IsFullscreen());
  if (!weak) return;
  auto previous = fullscreen_transition_controller_;
  fullscreen_transition_controller_.reset();
  auto* manager = window() ? ExclusiveAccessManager::From(window()->browser()) : nullptr;
  auto current = manager ? manager->fullscreen_controller()->GetWeakPtr() : nullptr;
  if (previous) previous->WindowFullscreenStateChanged();
  if (!weak) return;
  if (current && current.get() != previous.get()) current->WindowFullscreenStateChanged();
  if (!weak) return;
  manager = window() ? ExclusiveAccessManager::From(window()->browser()) : nullptr;
  SetPageFullscreen(manager && manager->fullscreen_controller()->IsWindowFullscreenForTabOrPending());
  if (weak) SynchronizeFullscreenForCheck();
  if (weak && generation == fullscreen_transition_generation_)
    fullscreen_transitioning_ = false;
}

void AraratWindowHostCore::SynchronizeFullscreenForCheck() {
  if (!base::CommandLine::ForCurrentProcess()->HasSwitch("ararat-check") || !window()) return;
  auto* strip = window()->browser()->GetTabStripModel();
  for (int i = 0; i < strip->count(); ++i) {
    auto* view = strip->GetWebContentsAt(i)->GetRenderWidgetHostView();
    if (view) view->GetRenderWidgetHost()->SynchronizeVisualProperties();
  }
}

void AraratWindowHostCore::AttachPage(gfx::NativeView view) {
  if (!page_host_ || page_host_->native_view() == view) return;
  page_host_->Detach();
  if (view) page_host_->Attach(view);
}

void AraratWindowHostCore::PositionPage(const gfx::Rect& rect) {
  page_rect_ = rect;
  modal_dialog_host_->NotifyPositionRequiresUpdate();
  if (page_host_) page_host_->SetBoundsRect(rect);
}

void AraratWindowHostCore::SetExtensionAnchor(const gfx::Rect& bounds) {
  extension_anchor_->SetBoundsRect(bounds);
}

void AraratWindowHostCore::ShowBrowserProfile(BrowserWindowInterface* browser) {
  [(__bridge ARWindowHost*)owner_ showBrowserProfile:browser];
}

void AraratWindowHostCore::DevToolsChanged(content::WebContents* inspected) {
  [(__bridge ARWindowHost*)owner_ devToolsChanged:inspected];
}

void AraratWindowHostCore::Close() {
  auto* args = base::CommandLine::ForCurrentProcess();
  if (args->GetSwitchValueASCII("ararat-check") == "profiles" && args->HasSwitch("ararat-cross-window-reverse-check")) {
    static unsigned count = 0;
    if (count++ < 64) std::fprintf(stderr, "ararat-teardown: host close windows=%zu closing=%d\n", windows_.size(), closing_);
  }
  if (!windows_.empty()) {
    if (closing_) return;
    closing_ = true;
    [(__bridge ARWindowHost*)owner_ beginClosing];
    ConfirmClose();
  } else {
    closed_ = true;
    widget_->Close();
  }
}

void AraratWindowHostCore::ConfirmClose() {
  auto* args = base::CommandLine::ForCurrentProcess();
  bool trace = args->GetSwitchValueASCII("ararat-check") == "profiles" && args->HasSwitch("ararat-cross-window-reverse-check");
  static unsigned count = 0;
  bool log = trace && count++ < 64;
  if (log) std::fprintf(stderr, "ararat-teardown: confirm close windows=%zu\n", windows_.size());
  for (const auto& [name, window] : windows_) {
    auto* controller = UnloadController::From(window->browser());
    if (controller->GetBrowserClosingStatus() == BrowserWindowInterface::ClosingStatus::kDeniedByPolicy) {
      if (log) std::fprintf(stderr, "ararat-teardown: close denied by policy\n");
      CloseConfirmed(false);
      return;
    }
    if (close_warnings_confirmed_.contains(name)) continue;
    auto weak = weak_factory_.GetWeakPtr();
    std::string profile_name = name;
    auto result = controller->MaybeWarnBeforeClosing(base::BindOnce(^(UnloadController::WarnBeforeClosingResult answer) {
      if (log) std::fprintf(stderr, "ararat-teardown: warning callback deny=%d\n", answer == UnloadController::WarnBeforeClosingResult::kDoNotClose);
      if (!weak || !weak->closing()) return;
      if (answer == UnloadController::WarnBeforeClosingResult::kDoNotClose) {
        weak->CloseConfirmed(false);
        return;
      }
      weak->close_warnings_confirmed_.insert(profile_name);
      weak->ConfirmClose();
    }));
    if (log) std::fprintf(stderr, "ararat-teardown: warning return deny=%d\n", result == UnloadController::WarnBeforeClosingResult::kDoNotClose);
    if (result == UnloadController::WarnBeforeClosingResult::kDoNotClose) return;
    close_warnings_confirmed_.insert(name);
  }
  for (const auto& [name, window] : windows_) {
    auto* controller = UnloadController::From(window->browser());
    bool needs_beforeunload = controller->TabsNeedBeforeUnloadFired();
    if (log) std::fprintf(stderr, "ararat-teardown: beforeunload needed=%d\n", needs_beforeunload);
    if (needs_beforeunload) {
      [(__bridge ARWindowHost*)owner_ showBrowserProfileForClose:window->browser()];
      if (IsProfileCheck()) {
        NSString* shown = [(__bridge ARWindowHost*)owner_ profileDirectory];
        [g_check_beforeunload_profiles addObject:shown];
        std::fprintf(stderr, "ararat-trace: beforeunload profile=%s shown=%s\n", name.c_str(), shown.UTF8String);
      }
    }
    bool pending = controller->RunBeforeUnloadForShutdown(
            false, base::BindRepeating(&AraratWindowHostCore::CloseConfirmed,
                                       weak_factory_.GetWeakPtr()));
    if (log) std::fprintf(stderr, "ararat-teardown: beforeunload pending=%d\n", pending);
    if (pending) return;
  }
  std::vector<AraratBrowserWindow*> windows;
  for (const auto& [name, window] : windows_) windows.push_back(window);
  for (auto* window : windows) window->RequestClose();
}

void AraratWindowHostCore::CloseConfirmed(bool proceed) {
  auto* args = base::CommandLine::ForCurrentProcess();
  if (args->GetSwitchValueASCII("ararat-check") == "profiles" && args->HasSwitch("ararat-cross-window-reverse-check")) {
    static unsigned count = 0;
    if (count++ < 64) std::fprintf(stderr, "ararat-teardown: close confirmed proceed=%d closing=%d\n", proceed, closing_);
  }
  if (!closing_) return;
  if (proceed) { ConfirmClose(); return; }
  for (const auto& [name, window] : windows_)
    UnloadController::From(window->browser())->ResetBeforeUnloadForShutdown();
  OnCloseCancelled();
}

void AraratWindowHostCore::OnCloseCancelled() {
  if (!closing_) return;
  closing_ = false;
  close_warnings_confirmed_.clear();
  [(__bridge ARWindowHost*)owner_ closeCancelled];
}

void AraratWindowHostCore::SetPending(const std::string& profile) {
  AraratSetPendingWindowHost(this, profile);
}

void AraratWindowHostCore::ClearPending() {
  if (g_pending_window_host == this) AraratSetPendingWindowHost(nullptr);
}

void AraratWindowHostCore::SetWindow(AraratBrowserWindow* window) {
  [(__bridge ARWindowHost*)owner_ pinProfile:window->browser()->GetProfile()];
  windows_[window->browser()->GetProfile()->GetPath().BaseName().value()] = window;
  devtools_ = window->browser()->GetType() == BrowserWindowInterface::TYPE_DEVTOOLS;
  popup_ = devtools_ || window->browser()->GetType() == BrowserWindowInterface::TYPE_POPUP ||
           window->browser()->GetType() == BrowserWindowInterface::TYPE_APP_POPUP ||
           window->browser()->GetProfile()->IsOffTheRecord();
  if (devtools_) {
    NSWindow* native_window = GetNativeWindow().GetNativeNSWindow();
    native_window.titleVisibility = NSWindowTitleVisible;
  }
  __weak ARWindowHost* owner = (__bridge ARWindowHost*)owner_;
  BrowserWindowInterface* browser = window->browser();
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(^{ [owner browserCreated:browser]; }));
}

void AraratWindowHostCore::SetShortcutWindow(AraratBrowserWindow* window, bool active) {
  if (shortcut_window_ == window) { SetShortcutActivation(active); return; }
  if (shortcut_window_ && shortcut_window_->extensions()) shortcut_window_->extensions()->SetShortcutActive(false);
  shortcut_registry_.reset();
  shortcut_window_ = nullptr;
  if (!window || popup_ || !widget_->GetFocusManager()) return;
  shortcut_window_ = window;
  shortcut_registry_ = std::make_unique<ExtensionKeybindingRegistryViews>(
      window->browser(), extensions::ExtensionKeybindingRegistry::ALL_EXTENSIONS, widget_->GetFocusManager());
  if (window->extensions()) window->extensions()->SetShortcutActive(true);
  SetShortcutActivation(active);
}

void AraratWindowHostCore::SetShortcutActivation(bool active) {
  if (shortcut_registry_) shortcut_registry_->OnHostActivationChanged(active);
}

bool AraratWindowHostCore::ShortcutActivationMatches(bool active) const {
  if (!shortcut_registry_ || !shortcut_window_) return !active;
  auto* global = extensions::ExtensionCommandsGlobalRegistry::Get(shortcut_window_->browser()->GetProfile());
  return global && (global->registry_for_active_window() == shortcut_registry_.get()) == active;
}

void AraratWindowHostCore::OnWindowDestroyed(BrowserWindowInterface* browser) {
  if (popup_ && base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check") == "popup")
    std::fprintf(stderr, "ararat-trace: popup browser destroyed\n");
  if (IsCloseCheck()) std::fprintf(stderr, "ararat-trace: browser-destroyed closing=%d\n", closing_);
  AraratWindows().erase(browser);
  const auto name = browser->GetProfile()->GetPath().BaseName().value();
  windows_.erase(name);
  [(__bridge ARWindowHost*)owner_ browserDestroyed:browser];
  if ((closing_ || popup_) && windows_.empty()) {
    if (IsCloseCheck()) std::fprintf(stderr, "ararat-trace: widget-close\n");
    closed_ = true;
    widget_->Close();
  }
}

namespace {
const char kTabIdentityKey[] = "ararat.tab.identity";
struct TabIdentity : public base::SupportsUserData::Data {
  TabIdentity(NSString* live, NSString* item) : live_id([live copy]), item_id([item copy]) {}
  __strong NSString* live_id;
  __strong NSString* item_id;
};

uint64_t g_epoch = 0;
uint64_t g_revision = 0;

class StripObserver : public TabStripModelObserver {
 public:
  StripObserver(TabStripModel* strip, ARWindowHost* host) : strip_(strip), host_(host) {
    strip_->AddObserver(this);
  }
  ~StripObserver() override {
    if (strip_) strip_->RemoveObserver(this);
  }
  void OnTabStripModelChanged(TabStripModel*, const TabStripModelChange&,
                              const TabStripSelectionChange&) override;
  void OnTabCloseCancelled(const tabs::TabInterface* tab) override;
  void OnTabStripModelDestroyed(TabStripModel*) override { strip_ = nullptr; }

 private:
  raw_ptr<TabStripModel> strip_;
  __weak ARWindowHost* host_;
};
}  // namespace

@interface ARWindowHost (TabState)
- (void)updateActive:(BOOL)active;
- (void)stripChanged:(const TabStripModelChange&)change;
- (NSDictionary*)stripSnapshot:(BOOL)consumeNavigation;
- (void)emitCause:(id)cause;
- (void)emitOpenFailure:(NSString*)commandId;
- (void)transactionWithCause:(id)cause setEmptyReported:(BOOL)setEmptyReported retainHost:(BOOL)retainHost;
- (void)syncTabs;
- (void)closeCancelled:(const tabs::TabInterface*)tab;
- (void)drainPendingOpens;
- (void)discardPendingOpens;
- (TabStripModel*)stripForTab:(ARTab*)tab;
- (void)ensureProfileBrowser:(NSString*)directory;
- (BOOL)openURL:(NSString*)url commandId:(NSString*)commandId itemId:(NSString*)itemId external:(BOOL)external untrusted:(BOOL)untrusted profile:(NSString*)profile;
- (void)profileLoaded:(BOOL)loaded;
- (void)positionPage;
- (BOOL)dispatchWorkspaceCommand:(NSInteger)command;
- (NSString*)findLiveId;
- (NSDictionary*)checkDialogPage:(content::WebContents*)contents;
@end

uint64_t AraratCheckBeginBeforeUnload(content::WebContents* contents, content::RenderFrameHost* frame, bool guest) {
  auto* args = base::CommandLine::ForCurrentProcess();
  const auto check = args->GetSwitchValueASCII("ararat-check");
  if (args->HasSwitch("ararat-screen") || (check != "profiles" && check != "keyboard" && check != "quit-cancel" && check != "close")) return 0;
  ARWindowHost* host = g_check_dialog_host;
  NSDictionary* page = host && contents ? [host checkDialogPage:contents] : nil;
  NSString* value = page[@"live"];
  std::string live = value.length ? base::SysNSStringToUTF8(value) : std::string();
  auto it = g_check_beforeunload_lives.find(live);
  bool valid = g_check_dialog_installed && host && !guest && contents && frame &&
      frame == contents->GetPrimaryMainFrame() && [page[@"item"] length] &&
      it != g_check_beforeunload_lives.end() && it->second.contents.get() == contents &&
      it->second.document.AsRenderFrameHostIfValid() == frame &&
      g_check_admitted_count < g_check_dialog_limit && !g_check_dialog_seen.contains(live) &&
      g_check_requests.size() < 64 && g_check_request_serial != UINT64_MAX;
  if (!valid) { g_check_dialog_failed = true; return 1; }
  ++g_check_admitted_count;
  g_check_dialog_seen.insert(live);
  uint64_t token = ++g_check_request_serial;
  g_check_requests.emplace(token, CheckRequest{live, it->second.generation, g_check_attempt_generation,
                                                g_check_admitted_count == g_check_cancel_dialog, false});
  return token;
}

bool AraratCheckFinishBeforeUnload(uint64_t token, bool success) {
  auto it = g_check_requests.find(token);
  bool valid = it != g_check_requests.end() && g_check_scripted_request == token &&
               CheckRequestCurrent(it->second) && success == !it->second.cancel;
  g_check_scripted_request = 0;
  if (!valid) g_check_dialog_failed = true;
  if (it != g_check_requests.end()) g_check_requests.erase(it);
  return valid && success;
}

uint64_t AraratCheckEnterBeforeUnloadManager(uint64_t token) {
  uint64_t previous = g_check_scripted_request;
  g_check_scripted_request = g_check_ready_request == token ? token : 0;
  g_check_ready_request = 0;
  return previous;
}

void AraratCheckLeaveBeforeUnloadManager(uint64_t previous) {
  g_check_scripted_request = previous;
}

void AraratWindowHostCore::ShowCommandBar(bool search) {
  [(__bridge ARWindowHost*)owner_ dispatchWorkspaceCommand:search ? IDC_FOCUS_SEARCH : IDC_FOCUS_LOCATION];
}

bool AraratWindowHostCore::DispatchWorkspaceCommand(int command) {
  return [(__bridge ARWindowHost*)owner_ dispatchWorkspaceCommand:command];
}

bool AraratWindowHostCore::ValidateEmptyCommand(int command) {
  if (!popup_ && (command == IDC_NEW_TAB || command == IDC_FOCUS_LOCATION || command == IDC_FOCUS_SEARCH)) return true;
  NSMenuItem* item = [[NSMenuItem alloc] init];
  item.tag = command;
  item.action = @selector(commandDispatch:);
  return [(id)NSApp.delegate validateUserInterfaceItem:item];
}

bool AraratWindowHostCore::ExecuteEmptyCommand(int command) {
  NSMenuItem* item = [[NSMenuItem alloc] init];
  item.tag = command;
  item.action = @selector(commandDispatch:);
  [(id)NSApp.delegate commandDispatch:item];
  return true;
}

void AraratWindowHostCore::UpdateFindBar(BrowserWindowInterface* browser, const std::u16string& text,
                                         unsigned int start, unsigned int end, int matches, int ordinal, int request_id, bool final_update,
                                         bool visible, bool focus) {
  if (!window() || window()->browser() != browser || closing() || closed()) return;
  ARWindowHost* owner = (__bridge ARWindowHost*)owner_;
  NSString* value = base::SysUTF16ToNSString(text);
  NSString* live = [owner findLiveId] ?: @"";
  [owner.delegate windowHost:owner updateFindBar:@{ @"text": value, @"start": @(start), @"end": @(end),
      @"matches": @(matches), @"ordinal": @(ordinal), @"request_id": @(request_id), @"final_update": @(final_update), @"visible": @(visible), @"focus": @(focus),
      @"live": live, @"profile": owner.profileDirectory }];
}

bool AraratWindowHostCore::FindBarHasFocus(BrowserWindowInterface* browser) const {
  ARWindowHost* owner = (__bridge ARWindowHost*)owner_;
  return window() && window()->browser() == browser && [owner.delegate findBarHasFocusForWindowHost:owner];
}

@interface ARPagePositionView : NSView
@property(nonatomic, weak) ARWindowHost* host;
@end

@implementation ARPagePositionView
@synthesize host = _host;
- (NSView*)hitTest:(NSPoint)point { return nil; }
- (void)setFrameSize:(NSSize)size {
  [super setFrameSize:size];
  [self.host positionPage];
}
- (void)setFrameOrigin:(NSPoint)origin {
  [super setFrameOrigin:origin];
  [self.host positionPage];
}
- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  [self.host positionPage];
}
@end

@interface ARDevToolsClipView : NSView
@property(nonatomic) NSRect pageRect;
@end

@implementation ARDevToolsClipView
- (NSView*)hitTest:(NSPoint)point {
  if (NSPointInRect([self convertPoint:point fromView:self.superview], self.pageRect)) return nil;
  return [super hitTest:point];
}
@end

void StripObserver::OnTabStripModelChanged(TabStripModel*,
                                            const TabStripModelChange& change,
                                            const TabStripSelectionChange&) {
  [host_ stripChanged:change];
}

void StripObserver::OnTabCloseCancelled(const tabs::TabInterface* tab) {
  [host_ closeCancelled:tab];
}

__attribute__((visibility("default"))) id<ARWindowHostAPI>
AraratWindowHostCreate(NSView* contentView, NSString* windowId) {
  return [[ARWindowHost alloc] initWithContentView:contentView windowId:windowId];
}

@implementation ARWindowHost {
  std::unique_ptr<AraratWindowHostCore> core_;
  std::map<BrowserWindowInterface*, std::unique_ptr<StripObserver>> strip_observers_;
  std::map<std::string, std::unique_ptr<HostedProfile>> profile_keep_alives_;
  std::set<std::string> shown_profiles_;
  BrowserWindowInterface* browser_;
  BOOL workspace_page_hidden_;
  NSMutableDictionary<NSValue*, ARTab*>* tabs_;
  NSMutableDictionary<NSValue*, NSString*>* pending_closes_;
  NSMutableArray<NSDictionary*>* pending_opens_;
  NSString* window_id_;
  NSString* command_id_;
  NSString* opening_item_;
  BOOL draining_opens_;
  BOOL loading_profile_;
  BOOL emitted_change_;
  BOOL empty_reported_;
  BOOL closing_all_;
  BOOL closing_window_;
  BOOL switching_for_close_;
  NSUInteger check_close_cancelled_;
  BOOL cookie_started_;
  BOOL cookie_set_;
  BOOL cookie_done_;
  BOOL cookie_isolated_;
  NSMutableArray<NSNumber*>* check_closing_events_;
  base::CallbackListSubscription closing_all_subscription_;
  ARPagePositionView* page_position_view_;
  NSView* devtools_view_;
  ARDevToolsClipView* devtools_clip_;
  NSUInteger devtools_hook_count_;
  id became_key_observer_;
  id resigned_key_observer_;
  std::unique_ptr<ExtensionPopupCheck> extension_popup_check_;
  NSString* extension_popup_storage_;
  base::OnceClosure check_chooser_close_;
  __weak NSWindow* check_anchor_bubble_;
}

- (BOOL)dispatchWorkspaceCommand:(NSInteger)command {
  if (core_->popup()) return command == IDC_FOCUS_LOCATION || command == IDC_FOCUS_SEARCH;
  if (core_->closing() || core_->closed() || closing_all_ || closing_window_) return NO;
  NSString* name = nil;
  if (command == IDC_NEW_TAB) name = @"new_tab";
  else if (command == IDC_FOCUS_LOCATION) name = @"edit_url";
  else if (command == IDC_FOCUS_SEARCH) name = @"search";
  else if (command == IDC_CLOSE_TAB) name = @"close_tab";
  else if (command == IDC_OPTIONS) name = @"settings";
  if (!name) return NO;
  [self.delegate windowHost:self performWorkspaceCommand:name];
  return YES;
}

- (NSArray<NSDictionary<NSString*, id>*>*)extensionActions {
  auto* window = core_->window();
  auto* container = window ? window->extensions() : nullptr;
  if (!container) return @[];
  NSMutableArray* result = [NSMutableArray array];
  for (const auto& [id, action] : container->actions()) {
    auto image = action->GetIcon(container->GetActiveWebContents(), gfx::Size(20, 20))
                     .Rasterize(core_->widget()->GetColorProvider());
    NSImage* icon = gfx::Image(image).ToNSImage();
    const auto action_name = action->GetActionName();
    NSString* name = [[NSString alloc] initWithCharacters:
        reinterpret_cast<const unichar*>(action_name.data()) length:action_name.size()];
    [result addObject:@{ @"id": [NSString stringWithUTF8String:id.c_str()],
                         @"name": name, @"icon": icon ?: [NSImage new] }];
  }
  return result;
}

- (void)setExtensionAnchor:(NSRect)rect {
  NSView* root = self.window.contentView;
  if (!root.isFlipped) rect.origin.y = NSHeight(root.bounds) - NSMaxY(rect);
  core_->SetExtensionAnchor(gfx::Rect(NSMinX(rect), NSMinY(rect), NSWidth(rect), NSHeight(rect)));
}

- (void)runExtensionAction:(NSString*)identifier {
  auto* window = core_->window();
  auto* container = window ? window->extensions() : nullptr;
  auto* action = container ? container->GetActionForId(identifier.UTF8String) : nullptr;
  if (action) action->ExecuteUserAction(ToolbarActionViewModel::InvocationSource::kMenuEntry);
}

- (BOOL)checkIsExtensionAppPopup {
  auto* args = base::CommandLine::ForCurrentProcess();
  return (args->GetSwitchValueASCII("ararat-check") == "ext-windows-popup" ||
      (args->GetSwitchValueASCII("ararat-screen") == "extensions" && args->HasSwitch("ararat-page-only-menu-check"))) &&
      browser_ && browser_->GetType() == BrowserWindowInterface::TYPE_APP_POPUP;
}

- (void)checkExtensionAction:(NSInteger)command {
  auto* flags = base::CommandLine::ForCurrentProcess();
  if (flags->GetSwitchValueASCII("ararat-check") != "ext-popup" && flags->GetSwitchValueASCII("ararat-check") != "keyboard" && flags->GetSwitchValueASCII("ararat-screen") != "extensions" && flags->GetSwitchValueASCII("ararat-screen") != "keyboard") return;
  auto* window = core_->window();
  auto* container = window ? window->extensions() : nullptr;
  if (!container || !browser_) return;
  const std::string id = "kmgaadhbnkendcanjninlfmfgehagggl";
  auto* action = container->GetActionForId(id);
  if (!action) return;
  if (command == 0 || command == 5) {
    extension_popup_check_ = std::make_unique<ExtensionPopupCheck>(browser_->GetProfile());
    if (command == 0) action->ExecuteUserAction(ToolbarActionViewModel::InvocationSource::kMenuEntry);
  } else if (command == 1) {
    container->HideActivePopup();
  } else if (command == 2) {
    action->ExecuteUserAction(ToolbarActionViewModel::InvocationSource::kMenuEntry);
  } else if (command == 3 && extension_popup_check_ && extension_popup_check_->current) {
    extension_popup_check_->current->host_contents()->GetPrimaryMainFrame()->ExecuteJavaScriptForTests(
        u"window.close()", base::NullCallback(), content::ISOLATED_WORLD_ID_GLOBAL);
  } else if (command == 4 && extension_popup_check_) {
    __weak ARWindowHost* host = self;
    container->ShowToolbarActionPopupForAPICall(id, base::BindOnce(^(extensions::ExtensionHost* popup) {
      ARWindowHost* strong = host;
      if (strong && strong->extension_popup_check_) strong->extension_popup_check_->api_callback = popup != nullptr;
    }));
  }
}

- (NSDictionary<NSString*, id>*)checkExtensionActionState {
  auto* flags = base::CommandLine::ForCurrentProcess();
  if (flags->GetSwitchValueASCII("ararat-check") != "ext-popup" && flags->GetSwitchValueASCII("ararat-check") != "keyboard" && flags->GetSwitchValueASCII("ararat-screen") != "extensions" && flags->GetSwitchValueASCII("ararat-screen") != "keyboard") return @{};
  auto* check = extension_popup_check_.get();
  if (!check) return @{};
  auto* popup = ExtensionPopup::last_popup_for_testing();
  auto* contents = check->current ? check->current->host_contents() : nullptr;
  if (contents && !extension_popup_storage_) {
    __weak ARWindowHost* host = self;
    contents->GetPrimaryMainFrame()->ExecuteJavaScriptForTests(
        u"document.body.dataset.stored || ''", base::BindOnce(^(base::Value result) {
          ARWindowHost* strong = host;
          if (strong && result.is_string() && !result.GetString().empty())
            strong->extension_popup_storage_ = [NSString stringWithUTF8String:result.GetString().c_str()];
        }), content::ISOLATED_WORLD_ID_GLOBAL);
  }
  NSWindow* popup_window = popup && popup->GetWidget() ? popup->GetWidget()->GetNativeWindow().GetNativeNSWindow() : nil;
  return @{ @"loaded": @(check->loaded), @"destroyed": @(check->destroyed),
            @"title": contents ? (base::SysUTF16ToNSString(contents->GetTitle()) ?: @"") : @"",
            @"storage": extension_popup_storage_ ?: @"",
            @"anchor": @(popup && popup->anchor_widget() == core_->widget()),
            @"api_callback": @(check->api_callback), @"window": popup_window ?: (id)NSNull.null };
}

- (AraratWindowHostCore*)hostCore { return core_.get(); }

@synthesize delegate = _delegate;

- (instancetype)initWithContentView:(NSView*)content_view windowId:(NSString*)windowId {
  DCHECK([NSThread isMainThread]);
  self = [super init];
  if (self) {
    core_ =
        std::make_unique<AraratWindowHostCore>(gfx::NativeView(content_view),
                                               (__bridge void*)self);
    tabs_ = [NSMutableDictionary dictionary];
    pending_closes_ = [NSMutableDictionary dictionary];
    pending_opens_ = [NSMutableArray array];
    auto* command_line = base::CommandLine::ForCurrentProcess();
    std::string check = command_line->GetSwitchValueASCII("ararat-check");
    if (check == "quit" || check == "quit-cancel" || check == "close" || check == "devtools" ||
        command_line->HasSwitch("ararat-screen"))
      check_closing_events_ = [NSMutableArray array];
    window_id_ = [windowId copy];
    __weak ARWindowHost* host = self;
    became_key_observer_ = [NSNotificationCenter.defaultCenter
        addObserverForName:NSWindowDidBecomeKeyNotification object:self.window queue:nil
        usingBlock:^(NSNotification*) { [host updateActive:YES]; }];
    resigned_key_observer_ = [NSNotificationCenter.defaultCenter
        addObserverForName:NSWindowDidResignKeyNotification object:self.window queue:nil
        usingBlock:^(NSNotification*) { [host updateActive:NO]; }];
    closing_all_subscription_ = chrome::AddClosingAllBrowsersCallback(
        base::BindRepeating(^(bool closing) {
          ARWindowHost* strong_host = host;
          if (!strong_host) return;
          [strong_host->check_closing_events_ addObject:@(closing)];
          BOOL was_closing = strong_host->closing_all_;
          strong_host->closing_all_ = closing;
          if (closing && !was_closing && strong_host.delegate)
            [strong_host.delegate windowHostWillBeginClosing:strong_host];
          if (!closing) {
            if (strong_host->closing_window_)
              strong_host->core_->OnCloseCancelled();
            else if (was_closing) {
              if (strong_host.delegate) [strong_host.delegate windowHostClosingAllCancelled:strong_host];
              [strong_host emitCause:@"Chrome"];
            }
          }
        }));
  }
  return self;
}

- (void)dealloc {
  if (became_key_observer_) [NSNotificationCenter.defaultCenter removeObserver:became_key_observer_];
  if (resigned_key_observer_) [NSNotificationCenter.defaultCenter removeObserver:resigned_key_observer_];
}

- (void)updateActive:(BOOL)active {
  core_->SetShortcutActivation(active);
  if (IsProfileCheck()) std::fprintf(stderr, "ararat-trace: profile-activation name=%s active=%d browser=%d\n", core_->profile_name().c_str(), active, browser_ != nullptr);
  // Why not reject all closing hosts: beforeunload may switch profiles and cancel.
  if (!browser_ || browser_->IsDeleteScheduled() || browser_->GetType() != BrowserWindowInterface::TYPE_NORMAL) return;
  auto* manager = BrowserActiveStateManager::From(browser_);
  if (!manager) return;
  if (active) manager->DidBecomeActive();
  else manager->DidBecomeInactive();
}

- (void)activateBrowser {
  if (auto* window = core_->window()) window->Activate();
}

- (void)showBrowserProfile:(BrowserWindowInterface*)browser {
  const auto name = browser->GetProfile()->GetPath().BaseName().value();
  if (closing_all_) {
    if (name != core_->profile_name())
      [self.delegate windowHost:self showProfile:[NSString stringWithUTF8String:name.c_str()]];
    [self setClosePresentationProfile:[NSString stringWithUTF8String:name.c_str()]];
    return;
  }
  if (name != core_->profile_name())
    [self.delegate windowHost:self showProfile:[NSString stringWithUTF8String:name.c_str()]];
}

- (void)showBrowserProfileForClose:(BrowserWindowInterface*)browser {
  [self showBrowserProfile:browser];
  const auto name = browser->GetProfile()->GetPath().BaseName().value();
  [self setClosePresentationProfile:[NSString stringWithUTF8String:name.c_str()]];
}

- (void)setDelegate:(id<ARWindowHostDelegate>)delegate {
  DCHECK([NSThread isMainThread]);
  _delegate = delegate;
  if (delegate && !g_epoch) {
    base::Time started = base::Process::Current().CreationTime();
    if (started.is_null()) started = base::Time::Now();
    g_epoch = started.InMillisecondsSinceUnixEpoch();
    g_revision = 0;
    [delegate windowHost:self didReceiveTransaction:@{
      @"epoch": @(g_epoch), @"rev": @0, @"cause": @"Engine", @"strips": @[]
    }];
  }
}

- (NSWindow*)window {
  DCHECK([NSThread isMainThread]);
  return core_->GetNativeWindow().GetNativeNSWindow();
}

- (void)close {
  DCHECK([NSThread isMainThread]);
  // Why not release here: a cancelled close must keep the keep-alive.
  if (core_->windows().empty()) {
    [self discardPendingOpens];
    profile_keep_alives_.clear();
  }
  core_->Close();
}

- (void)beginClosing {
  closing_window_ = YES;
  if (self.delegate) [self.delegate windowHostWillBeginClosing:self];
}

- (void)installCheckDialogFactory {
  auto* args = base::CommandLine::ForCurrentProcess();
  const auto check = args->GetSwitchValueASCII("ararat-check");
  if (args->HasSwitch("ararat-screen") ||
      (check != "profiles" && check != "keyboard" && check != "quit-cancel" && check != "close")) return;
  g_check_dialog_count = 0;
  g_check_cancel_dialog = 1;
  g_check_dialog_limit = 0;
  g_check_admitted_count = 0;
  g_check_dialog_seen.clear();
  ++g_check_attempt_generation;
  g_check_dialog_pages = [NSMutableArray array];
  g_check_dialog_host = self;
  g_check_dialog_installed = true;
  std::fprintf(stderr, "ararat-check-dialog: install pid=%d check=%s\n", getpid(), check.c_str());
  javascript_dialogs::AppModalDialogManager::GetInstance()->SetNativeDialogFactory(
      base::BindRepeating([](std::unique_ptr<javascript_dialogs::AppModalDialogController> controller)
          -> javascript_dialogs::AppModalDialogView* {
        auto* contents = controller->web_contents();
        ARWindowHost* host = g_check_dialog_host;
        NSDictionary* page = host && contents ? [host checkDialogPage:contents] : nil;
        NSString* live = page[@"live"];
        std::string live_id = live.length ? base::SysNSStringToUTF8(live) : std::string();
        auto registered = g_check_beforeunload_lives.find(live_id);
        bool owned = contents && contents->GetPrimaryMainFrame() && [page[@"item"] length] && registered != g_check_beforeunload_lives.end() &&
                     registered->second.contents.get() == contents &&
                     registered->second.document.AsRenderFrameHostIfValid() == contents->GetPrimaryMainFrame();
        auto request = std::find_if(g_check_requests.begin(), g_check_requests.end(), [&](const auto& entry) {
          return !entry.second.claimed && entry.second.live == live_id && CheckRequestCurrent(entry.second);
        });
        bool expected = controller->is_before_unload_dialog() && owned && request != g_check_requests.end();
        if (!expected) g_check_dialog_failed = true;
        uint64_t token = expected ? request->first : 0;
        bool cancel = !expected || request->second.cancel;
        if (expected) request->second.claimed = true;
        if (g_check_dialog_count < 32) std::fprintf(stderr, "ararat-check-dialog: request pid=%d beforeunload=%d owned=%d count=%lu limit=%lu expected=%d\n", getpid(), controller->is_before_unload_dialog(), owned, (unsigned long)g_check_dialog_count, (unsigned long)g_check_dialog_limit, expected);
        if (expected && contents->GetDelegate()) contents->GetDelegate()->ActivateContents(contents);
        if (expected && host && contents) [g_check_dialog_pages addObject:[host checkDialogPage:contents]];
        return new CheckDialog(std::move(controller), expected, token, cancel);
      }));
}

- (void)expectCheckDialogs:(NSUInteger)limit {
  if (!g_check_dialog_installed) { g_check_dialog_failed = true; return; }
  g_check_dialog_seen.clear();
  g_check_admitted_count = g_check_dialog_count;
  ++g_check_attempt_generation;
  g_check_dialog_limit = limit;
}

- (BOOL)checkDialogIntegrity { return !g_check_dialog_failed && g_check_requests.empty(); }

- (NSDictionary*)checkDialogPage:(content::WebContents*)contents {
  ARTab* tab = tabs_[[NSValue valueWithPointer:contents]];
  NSDictionary* presentation = [self checkPagePresentation:tab.liveId ?: @""];
  return @{ @"profile": self.profileDirectory ?: @"", @"live": tab.liveId ?: @"", @"item": tab.itemId ?: @"",
            @"active": @([tab.liveId isEqualToString:[self findLiveId]]),
            @"presented": presentation[@"presented"] ?: @NO, @"attachment": presentation };
}

- (NSDictionary<NSString*, id>*)checkPagePresentation:(NSString*)liveId {
  auto* active = browser_ ? browser_->GetTabStripModel()->GetActiveWebContents() : nullptr;
  ARTab* tab = active ? tabs_[[NSValue valueWithPointer:active]] : nil;
  NSView* view = active ? active->GetNativeView().GetNativeNSView() : nil;
  NSView* card = page_position_view_.superview;
  NSWindow* window = core_->GetNativeWindow().GetNativeNSWindow();
  auto* pageHost = core_->page_host();
  BOOL shared = AraratUsesSharedCompositor() && !core_->devtools();
  BOOL target = view && tab && [tab.liveId isEqualToString:liveId] &&
      (!shared || (pageHost && pageHost->native_view() == active->GetNativeView()));
  BOOL host = shared ? (pageHost && pageHost->GetWidget() == core_->widget() && pageHost->GetVisible())
                     : (view && card && [view isDescendantOf:card]);
  BOOL windowMatch = view && card && window && view.window == window && card.window == window;
  BOOL visible = view && !view.isHiddenOrHasHiddenAncestor;
  NSRect pageRect = view.window ? [view convertRect:view.bounds toView:nil] : NSZeroRect;
  NSView* root = window.contentView;
  gfx::Rect expected = core_->page_rect();
  NSRect expectedRoot = NSMakeRect(expected.x(), expected.y(), expected.width(), expected.height());
  if (root && !root.isFlipped) expectedRoot.origin.y = NSHeight(root.bounds) - NSMaxY(expectedRoot);
  NSRect expectedWindow = root ? [root convertRect:expectedRoot toView:nil] : NSZeroRect;
  BOOL actualBounds = !NSIsEmptyRect(pageRect) && !NSIsEmptyRect(expectedWindow) &&
      std::abs(NSMinX(pageRect) - NSMinX(expectedWindow)) <= 2 && std::abs(NSMinY(pageRect) - NSMinY(expectedWindow)) <= 2 &&
      std::abs(NSWidth(pageRect) - NSWidth(expectedWindow)) <= 2 && std::abs(NSHeight(pageRect) - NSHeight(expectedWindow)) <= 2;
  BOOL bounds = shared ? (pageHost && !expected.IsEmpty() && pageHost->bounds() == expected && actualBounds)
                       : (view && card && !NSIsEmptyRect(view.bounds));
  NSPoint point = NSMakePoint(NSMidX(pageRect), NSMidY(pageRect));
  NSView* hit = root.superview ? [root hitTest:[root.superview convertPoint:point fromView:nil]] : nil;
  BOOL pageHit = view && hit && [hit isDescendantOf:view];
  return @{ @"compositor": shared ? @"c2" : @"c1", @"live": tab.liveId ?: @"", @"target": @(target), @"host": @(host),
            @"window": @(windowMatch), @"visible": @(visible), @"bounds": @(bounds),
            @"page_hit": @(pageHit), @"page_frame": NSStringFromRect(pageRect), @"expected_frame": NSStringFromRect(expectedWindow),
            @"presented": @(target && host && visible && (!shared || (windowMatch && bounds))) };
}

- (NSUInteger)checkDialogCount { return g_check_dialog_count; }
- (BOOL)checkDialogHostForContents:(content::WebContents*)contents {
  auto* manager = web_modal::WebContentsModalDialogManager::FromWebContents(contents);
  return manager && manager->delegate() &&
      manager->delegate()->GetWebContentsModalDialogHost(contents) == core_->modal_dialog_host();
}
- (void)configureProfileCloseCheck:(NSUInteger)cancelDialog {
  const auto check = base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check");
  if (check != "profiles" && check != "quit-cancel") return;
  [self installCheckDialogFactory];
  g_check_cancel_dialog = cancelDialog;
  g_check_dialog_limit = cancelDialog ? cancelDialog : self.tabs.count;
  g_check_beforeunload_profiles = [NSMutableArray array];
}
- (NSDictionary<NSString*, id>*)checkProfileCloseState {
  return @{ @"dialogs": @(g_check_dialog_count), @"close_cancelled": @(check_close_cancelled_),
            @"closing": @(core_->closing()), @"closed": @(core_->closed()),
            @"browsers": @(core_->windows().size()), @"beforeunload_profiles": g_check_beforeunload_profiles ?: @[],
            @"dialog_pages": [g_check_dialog_pages copy] ?: @[] };
}
- (NSArray<NSNumber*>*)checkClosingEvents { return [check_closing_events_ copy] ?: @[]; }
- (BOOL)checkTryingToQuit { return browser_shutdown::IsTryingToQuit(); }
- (NSUInteger)checkStockBrowsers { return AraratStockBrowserCount(); }

- (NSDictionary<NSString*, id>*)checkFullscreenState {
  auto* command = base::CommandLine::ForCurrentProcess();
  if (!core_->window() || (command->GetSwitchValueASCII("ararat-check") != "fullscreen" &&
                          command->GetSwitchValueASCII("ararat-screen") != "fullscreen" &&
                          command->GetSwitchValueASCII("ararat-check") != "keyboard" &&
                          command->GetSwitchValueASCII("ararat-screen") != "keyboard")) return @{};
  auto* manager = ExclusiveAccessManager::From(core_->window()->browser());
  if (!manager) return @{};
  auto* controller = manager->fullscreen_controller();
  auto* contents = core_->window()->browser()->GetTabStripModel()->GetActiveWebContents();
  auto* view = contents ? contents->GetRenderWidgetHostView() : nullptr;
  return @{ @"window": @(core_->IsFullscreen()), @"tab": @(controller->IsTabFullscreen()),
            @"transitioning": @(core_->IsFullscreenTransitioning()),
            @"pending": @(controller->IsWindowFullscreenForTabOrPending()),
            @"browser": @(controller->IsFullscreenForBrowser()),
            @"bubble_created": @(core_->window()->HasExclusiveAccessBubbleForCheck()),
            @"bubble_visible": @(core_->window()->IsExclusiveAccessBubbleVisibleForCheck()),
            @"completion_without_browser": @(g_fullscreen_completion_without_browser),
            @"view_focused": @(view && view->HasFocus()) };
}

- (void)checkFullscreenAction:(NSInteger)action {
  auto* command = base::CommandLine::ForCurrentProcess();
  if (!core_->window() || (command->GetSwitchValueASCII("ararat-check") != "fullscreen" &&
                          command->GetSwitchValueASCII("ararat-screen") != "fullscreen" &&
                          command->GetSwitchValueASCII("ararat-check") != "keyboard" &&
                          command->GetSwitchValueASCII("ararat-screen") != "keyboard")) return;
  auto* manager = ExclusiveAccessManager::From(core_->window()->browser());
  if (!manager) return;
  if (action == 0) {
    input::NativeWebKeyboardEvent event(blink::WebInputEvent::Type::kRawKeyDown, 0, base::TimeTicks::Now());
    event.windows_key_code = ui::VKEY_ESCAPE;
    manager->HandleUserKeyEvent(event);
    input::NativeWebKeyboardEvent up(blink::WebInputEvent::Type::kKeyUp, 0, base::TimeTicks::Now());
    up.windows_key_code = ui::VKEY_ESCAPE;
    if (core_->window() && ExclusiveAccessManager::From(core_->window()->browser()) == manager)
      manager->HandleUserKeyEvent(up);
  } else if (action == 1) {
    manager->fullscreen_controller()->ToggleBrowserFullscreenMode(true);
  } else if (action == 2 && command->GetSwitchValueASCII("ararat-check") == "fullscreen") {
    core_->SetFullscreen(false, display::kInvalidDisplayId);
  } else if (action == 3 && command->GetSwitchValueASCII("ararat-check") == "fullscreen") {
    auto* strip = core_->window()->browser()->GetTabStripModel();
    if (strip->count() >= 2) strip->ActivateTabAt(strip->active_index() == 0 ? 1 : 0);
  } else if (action == 4 && command->GetSwitchValueASCII("ararat-check") == "fullscreen") {
    auto* strip = core_->window()->browser()->GetTabStripModel();
    if (strip->count() >= 2) strip->CloseWebContentsAt(strip->active_index(), TabCloseTypes::CLOSE_CREATE_HISTORICAL_TAB);
  } else if (action == 5 && command->GetSwitchValueASCII("ararat-check") == "fullscreen") {
    auto* controller = manager->fullscreen_controller();
    controller->ToggleBrowserFullscreenMode(true);
    g_fullscreen_completion_called = false;
    controller->RunOrDeferUntilTransitionIsComplete(base::BindOnce([] { g_fullscreen_completion_called = true; }));
    const bool deferred = !g_fullscreen_completion_called;
    [self setProfileDirectory:@"Fullscreen Check"];
    const bool missing = core_->window() == nullptr;
    core_->FullscreenStateChanged();
    g_fullscreen_completion_without_browser = deferred && missing && g_fullscreen_completion_called;
  }
}
- (void)checkOpenDevTools {
  if ((!IsDevToolsCheck() && base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check") != "popup") || !browser_) return;
  auto* active = browser_->GetTabStripModel()->GetActiveWebContents();
  if (active) DevToolsWindow::OpenDevToolsWindow(active, DevToolsToggleAction::Show(), DevToolsOpenedByAction::kUnknown);
}
- (void)checkCloseDevTools {
  const auto check = base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check");
  if ((check != "devtools" && check != "popup") || !browser_) return;
  auto* active = browser_->GetTabStripModel()->GetActiveWebContents();
  auto* window = active ? DevToolsWindow::GetInstanceForInspectedWebContents(active) : nullptr;
  if (!window) return;
  if (window->IsDocked()) DevToolsWindow::ToggleDevToolsWindow(browser_, DevToolsToggleAction::Toggle());
  else if (auto* contents = window->GetDevToolsWebContents().get()) contents->Close();
}
- (NSDictionary<NSString*, id>*)checkDevToolsState {
  if (!IsDevToolsCheck()) return @{};
  auto* active = browser_ ? browser_->GetTabStripModel()->GetActiveWebContents() : nullptr;
  auto* window = active ? DevToolsWindow::GetInstanceForInspectedWebContents(active) : nullptr;
  NSView* card = page_position_view_.superview;
  NSView* page = active ? active->GetNativeView().GetNativeNSView() : nil;
  NSRect cardRect = card ? [card convertRect:card.bounds toView:nil] : NSZeroRect;
  NSRect pageRect = page && page.window ? [page convertRect:page.bounds toView:nil] : NSZeroRect;
  NSRect devtoolsRect = devtools_view_.window ? [devtools_view_ convertRect:devtools_view_.bounds toView:nil] : NSZeroRect;
  DevToolsContentsResizingStrategy strategy;
  if (active) DevToolsWindow::GetInTabWebContents(active, &strategy);
  gfx::Rect devtoolsBounds, pageBounds;
  if (card) ApplyDevToolsContentsResizingStrategy(strategy, gfx::Rect(static_cast<int>(NSWidth(card.bounds)), static_cast<int>(NSHeight(card.bounds))), &devtoolsBounds, &pageBounds);
  NSRect expected = card ? NSMakeRect(pageBounds.x(), card.isFlipped ? pageBounds.y() : NSHeight(card.bounds) - pageBounds.bottom(), pageBounds.width(), pageBounds.height()) : NSZeroRect;
  NSRect expectedWindow = card ? [card convertRect:expected toView:nil] : NSZeroRect;
  NSView* pageBranch = page;
  NSView* devtoolsBranch = devtools_view_;
  while (pageBranch && ![devtoolsBranch isDescendantOf:pageBranch.superview]) pageBranch = pageBranch.superview;
  while (devtoolsBranch && devtoolsBranch.superview != pageBranch.superview) devtoolsBranch = devtoolsBranch.superview;
  NSArray<NSView*>* siblings = pageBranch.superview.subviews;
  NSUInteger pageIndex = [siblings indexOfObjectIdenticalTo:pageBranch];
  NSUInteger devtoolsIndex = [siblings indexOfObjectIdenticalTo:devtoolsBranch];
  BOOL above = pageIndex != NSNotFound && devtoolsIndex != NSNotFound && pageIndex > devtoolsIndex;
  NSView* root = core_->GetNativeWindow().GetNativeNSWindow().contentView;
  NSPoint pagePoint = NSMakePoint(NSMidX(pageRect), NSMidY(pageRect));
  NSPoint toolsPoint = NSMakePoint((NSMaxX(pageRect) + NSMaxX(cardRect)) / 2, NSMidY(cardRect));
  NSView* pageHit = [root hitTest:[root.superview convertPoint:pagePoint fromView:nil]];
  NSView* toolsHit = [root hitTest:[root.superview convertPoint:toolsPoint fromView:nil]];
  NSMutableDictionary<NSString*, id>* result = [@{ @"docked": @(window && window->IsDocked()), @"hook_count": @(devtools_hook_count_),
            @"card_frame": NSStringFromRect(cardRect), @"page_frame": NSStringFromRect(pageRect),
            @"devtools_frame": NSStringFromRect(devtoolsRect), @"strategy_page_frame": NSStringFromRect(expectedWindow),
            @"devtools_attached": @(devtools_view_ && card && [devtools_view_ isDescendantOf:card]), @"page_above": @(above),
            @"page_hit": @(page && [pageHit isDescendantOf:page]),
            @"devtools_hit": @(devtools_view_ && [toolsHit isDescendantOf:devtools_view_]) } mutableCopy];
  if (base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-screen") == "devtools") {
    NSMutableArray<NSString*>* chain = [NSMutableArray array];
    for (NSView* view = toolsHit; view; view = view.superview) [chain addObject:NSStringFromClass(view.class)];
    NSView* clipHit = devtools_clip_ ? [devtools_clip_ hitTest:[devtools_clip_.superview convertPoint:toolsPoint fromView:nil]] : nil;
    NSView* directHit = devtools_view_ ? [devtools_view_ hitTest:[devtools_view_.superview convertPoint:toolsPoint fromView:nil]] : nil;
    result[@"tools_point"] = NSStringFromPoint(toolsPoint);
    result[@"tools_hit_chain"] = chain;
    result[@"clip_hit_class"] = clipHit ? NSStringFromClass(clipHit.class) : @"";
    result[@"direct_hit_class"] = directHit ? NSStringFromClass(directHit.class) : @"";
    result[@"clip_frame"] = NSStringFromRect(devtools_clip_.frame);
    result[@"clip_bounds"] = NSStringFromRect(devtools_clip_.bounds);
    result[@"clip_page_rect"] = NSStringFromRect(devtools_clip_.pageRect);
    result[@"clip_hidden"] = @(devtools_clip_.isHiddenOrHasHiddenAncestor);
    result[@"tools_hidden"] = @(devtools_view_.isHiddenOrHasHiddenAncestor);
    result[@"tools_bounds"] = NSStringFromRect(devtools_view_.bounds);
    result[@"tools_superview"] = devtools_view_.superview ? NSStringFromClass(devtools_view_.superview.class) : @"";
  }
  return result;
}
- (NSDictionary<NSString*, id>*)checkDevToolsTabState:(NSString*)liveId {
  if (base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check") != "devtools") return @{};
  for (ARTab* tab in tabs_.allValues) {
    if (![tab.liveId isEqualToString:liveId]) continue;
    auto* devtools = DevToolsWindow::GetInTabWebContents(tab.contents, nullptr);
    NSView* view = devtools ? devtools->GetNativeView().GetNativeNSView() : nil;
    return @{ @"exists": @(devtools != nullptr), @"hidden": @(devtools && devtools->GetVisibility() == content::Visibility::HIDDEN),
              @"in_card": @(view && page_position_view_.superview && [view isDescendantOf:page_position_view_.superview]) };
  }
  return @{};
}
- (BOOL)checkSetDevToolsDocked:(BOOL)docked {
  if (!IsDevToolsCheck() || !browser_) return NO;
  auto* active = browser_->GetTabStripModel()->GetActiveWebContents();
  auto* window = active ? DevToolsWindow::GetInstanceForInspectedWebContents(active) : nullptr;
  auto* bindings = window ? DevToolsUIBindings::ForWebContents(window->GetDevToolsWebContents()) : nullptr;
  if (!bindings) return NO;
  static_cast<DevToolsEmbedderMessageDispatcher::Delegate*>(bindings)->SetIsDocked(
      base::BindOnce([](const base::Value*) {}), docked);
  return YES;
}
- (NSUInteger)checkDevToolsHostCount {
  if (!IsDevToolsCheck() && base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check") != "popup") return 0;
  NSUInteger count = 0;
  for (auto* host : AraratHosts()) if (host->devtools() && !host->closed()) ++count;
  return count;
}
- (BOOL)checkFocusDevTools {
  if (!IsDevToolsCheck() || !browser_) return NO;
  auto* active = browser_->GetTabStripModel()->GetActiveWebContents();
  auto* tools = active ? DevToolsWindow::GetInTabWebContents(active, nullptr) : nullptr;
  if (!tools) return NO;
  tools->Focus();
  NSView* view = tools->GetNativeView().GetNativeNSView();
  NSResponder* responder = view.window.firstResponder;
  return [responder isKindOfClass:NSView.class] && [(NSView*)responder isDescendantOf:view];
}
- (void)checkDevToolsFrontend:(void (^)(NSString*))completion {
  if (!IsDevToolsCheck() || !browser_) { completion(@""); return; }
  auto* active = browser_->GetTabStripModel()->GetActiveWebContents();
  auto* tools = active ? DevToolsWindow::GetInTabWebContents(active, nullptr) : nullptr;
  if (!tools) { completion(@""); return; }
  tools->GetPrimaryMainFrame()->ExecuteJavaScript(
      uR"JS((() => { const all = root => Array.from(root.querySelectorAll('*')).flatMap(e => [e, ...(e.shadowRoot ? all(e.shadowRoot) : [])]); const nodes = all(document); const visible = e => !!(e && e.getClientRects().length && getComputedStyle(e).visibility !== 'hidden'); return JSON.stringify({drawer: nodes.some(e => e.classList.contains('drawer-tabbed-pane') && visible(e)), search: nodes.some(e => e.id === 'search-input-field' && visible(e))}); })())JS",
      base::BindOnce(^(base::Value result) {
        completion(result.is_string() ? [NSString stringWithUTF8String:result.GetString().c_str()] : @"");
      }));
}
- (BOOL)checkInspectElement {
  if (base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check") != "devtools" || !browser_) return NO;
  auto* active = browser_->GetTabStripModel()->GetActiveWebContents();
  if (!active || !active->GetPrimaryMainFrame()) return NO;
  content::ContextMenuParams params;
  params.page_url = active->GetLastCommittedURL();
  params.frame_url = params.page_url;
  // The Mac menu displays UI; this check only exercises its command path.
  class CheckContextMenu : public RenderViewContextMenu {
   public:
    using RenderViewContextMenu::RenderViewContextMenu;
    void Show() override {}
  };
  CheckContextMenu menu(*active->GetPrimaryMainFrame(), params, false, false);
  if (!menu.IsCommandIdEnabled(IDC_CONTENT_CONTEXT_INSPECTELEMENT)) return NO;
  menu.ExecuteCommand(IDC_CONTENT_CONTEXT_INSPECTELEMENT, 0);
  return YES;
}
- (void)checkNavigate:(NSString*)url disposition:(NSString*)disposition {
  auto* command = base::CommandLine::ForCurrentProcess();
  if (!browser_ || (!command->HasSwitch("ararat-check") && command->GetSwitchValueASCII("ararat-screen") != "prompts" && command->GetSwitchValueASCII("ararat-screen") != "fullscreen" && command->GetSwitchValueASCII("ararat-screen") != "keyboard" && !((command->GetSwitchValueASCII("ararat-screen") == "profiles" || command->GetSwitchValueASCII("ararat-screen") == "links" || command->GetSwitchValueASCII("ararat-screen") == "extensions") && command->HasSwitch("ararat-page-only-menu-check")))) return;
  NavigateParams params(browser_, GURL(url.UTF8String), ui::PAGE_TRANSITION_LINK);
  params.source_contents = browser_->GetTabStripModel()->GetActiveWebContents();
  if ([disposition isEqualToString:@"current"]) params.disposition = WindowOpenDisposition::CURRENT_TAB;
  else if ([disposition isEqualToString:@"foreground"]) params.disposition = WindowOpenDisposition::NEW_FOREGROUND_TAB;
  else if ([disposition isEqualToString:@"background"]) params.disposition = WindowOpenDisposition::NEW_BACKGROUND_TAB;
  else if ([disposition isEqualToString:@"split"]) params.disposition = WindowOpenDisposition::NEW_SPLIT_VIEW;
  else if ([disposition isEqualToString:@"window"]) params.disposition = WindowOpenDisposition::NEW_WINDOW;
  else if ([disposition isEqualToString:@"popup"]) params.disposition = WindowOpenDisposition::NEW_POPUP;
  else return;
  if (base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check") == "menu")
    std::fprintf(stderr, "ararat-trace: menu navigate begin\n");
  Navigate(&params);
  if (base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check") == "menu")
    std::fprintf(stderr, "ararat-trace: menu navigate end\n");
}
- (void)checkCreateDeferredBrowsers {
  if (!browser_ || base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check") != "deferred") return;
  Profile* profile = browser_->GetProfile();
  auto* devtools = CreateBrowserWindow(BrowserWindowCreateParams::CreateForDevTools(profile));
  if (devtools) devtools->GetWindow()->Close();
  CreateBrowserWindow(BrowserWindowCreateParams::CreateForAppPopup(
      "ararat-check", false, gfx::Rect(0, 0, 400, 300), profile, true));
}
- (void)checkCreateRestoreBrowser {
  if (!browser_ || base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check") != "profiles") return;
  auto* browser = CreateBrowserWindow(BrowserWindowCreateParams::CreateForDevTools(browser_->GetProfile()));
  if (browser) browser->GetWindow()->Close();
}
- (void)checkMenuCommand:(BOOL)newWindow {
  const auto check = base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check");
  if (check != "menu" && check != "empty" && check != "keyboard" && base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-screen") != "keyboard") return;
  NSMenuItem* item = [[NSMenuItem alloc] init];
  item.tag = newWindow ? IDC_NEW_WINDOW : IDC_NEW_TAB;
  const bool tracing = check == "empty";
  if (tracing) std::fprintf(stderr, "ararat-trace: empty-new-tab dispatch browser=%p tabs_before=%d\n",
                            static_cast<void*>(browser_), browser_ ? browser_->GetTabStripModel()->count() : -1);
  if (check == "menu") std::fprintf(stderr, "ararat-trace: menu-command dispatch tag=%ld target=window\n", static_cast<long>(item.tag));
  [(NSWindow<CommandDispatchingWindow>*)self.window commandDispatch:item];
  if (check == "menu") std::fprintf(stderr, "ararat-trace: menu-command returned tag=%ld target=window\n", static_cast<long>(item.tag));
  if (tracing) std::fprintf(stderr, "ararat-trace: empty-new-tab returned browser=%p tabs_after=%d\n",
                            static_cast<void*>(browser_), browser_ ? browser_->GetTabStripModel()->count() : -1);
}

- (void)checkKeyboardCommand:(NSString*)command {
  auto* args = base::CommandLine::ForCurrentProcess();
  if (args->GetSwitchValueASCII("ararat-check") != "keyboard" && args->GetSwitchValueASCII("ararat-screen") != "keyboard" && args->GetSwitchValueASCII("ararat-check") != "empty" && args->GetSwitchValueASCII("ararat-check") != "incognito" && args->GetSwitchValueASCII("ararat-check") != "popup" && args->GetSwitchValueASCII("ararat-check") != "ext-windows-popup") return;
  NSDictionary<NSString*, NSNumber*>* commands = @{
    @"new": @(IDC_NEW_TAB), @"location": @(IDC_FOCUS_LOCATION), @"search": @(IDC_FOCUS_SEARCH),
    @"find": @(IDC_FIND), @"next": @(IDC_FIND_NEXT), @"previous": @(IDC_FIND_PREVIOUS),
    @"reload": @(IDC_RELOAD), @"back": @(IDC_BACK), @"devtools": @(IDC_DEV_TOOLS),
    @"duplicate": @(IDC_DUPLICATE_TAB), @"close": @(IDC_CLOSE_TAB),
    @"window": @(IDC_NEW_WINDOW), @"incognito": @(IDC_NEW_INCOGNITO_WINDOW)
  };
  NSNumber* tag = commands[command];
  if (!tag) return;
  NSMenuItem* item = [[NSMenuItem alloc] init];
  item.tag = tag.integerValue;
  [(NSWindow<CommandDispatchingWindow>*)self.window commandDispatch:item];
}

- (void)checkSetFindPasteboard:(NSString*)text {
  auto* args = base::CommandLine::ForCurrentProcess();
  if (args->GetSwitchValueASCII("ararat-check") != "keyboard" && args->GetSwitchValueASCII("ararat-screen") != "keyboard") return;
  [[FindPasteboard sharedInstance] setFindText:text];
}

- (BOOL)checkCloseFindEnabled {
  auto* args = base::CommandLine::ForCurrentProcess();
  if (args->GetSwitchValueASCII("ararat-check") != "keyboard" && args->GetSwitchValueASCII("ararat-screen") != "keyboard") return NO;
  return browser_ && chrome::IsCommandEnabled(browser_, IDC_CLOSE_FIND_OR_STOP);
}

- (NSUInteger)checkPageOnlySaveCount { return g_check_page_only_save_count; }

- (BOOL)checkReplaceActiveForKeyboard {
  auto* args = base::CommandLine::ForCurrentProcess();
  if ((args->GetSwitchValueASCII("ararat-check") != "keyboard" && args->GetSwitchValueASCII("ararat-screen") != "keyboard") || !browser_) return NO;
  auto* strip = browser_->GetTabStripModel();
  auto* contents = strip->GetActiveWebContents();
  if (!contents) return NO;
  auto replacement = contents->Clone();
  if (!replacement) return NO;
  auto old = strip->DiscardWebContents(contents, std::move(replacement));
  return old != nullptr;
}

- (BOOL)checkKeyboardAccelerator:(BOOL)action {
  auto* args = base::CommandLine::ForCurrentProcess();
  if (args->GetSwitchValueASCII("ararat-check") != "keyboard" && args->GetSwitchValueASCII("ararat-screen") != "keyboard") return NO;
  auto* manager = core_->widget()->GetFocusManager();
  if (!manager) return NO;
  return manager->ProcessAccelerator(ui::Accelerator(action ? ui::VKEY_I : ui::VKEY_U, ui::EF_ALT_DOWN | ui::EF_SHIFT_DOWN));
}

- (BOOL)checkKeyboardDevTools {
  auto* args = base::CommandLine::ForCurrentProcess();
  if (args->GetSwitchValueASCII("ararat-check") != "keyboard" && args->GetSwitchValueASCII("ararat-screen") != "keyboard") return NO;
  auto* contents = browser_ ? browser_->GetTabStripModel()->GetActiveWebContents() : nullptr;
  return contents && DevToolsWindow::GetInTabWebContents(contents, nullptr);
}

- (BOOL)checkReassignInactiveAction {
  auto* args = base::CommandLine::ForCurrentProcess();
  if (args->GetSwitchValueASCII("ararat-check") != "keyboard" && args->GetSwitchValueASCII("ararat-screen") != "keyboard") return NO;
  auto* window = core_->windowForProfile("Profile 1");
  if (!window || window == core_->window()) return NO;
  auto* service = extensions::CommandService::Get(window->browser()->GetProfile());
  if (!service) return NO;
  service->UpdateKeybindingPrefs("kmgaadhbnkendcanjninlfmfgehagggl", "_execute_action", "Alt+Shift+O");
  return YES;
}

- (BOOL)checkReassignProbeCommand:(BOOL)collision {
  auto* args = base::CommandLine::ForCurrentProcess();
  if (args->GetSwitchValueASCII("ararat-screen") != "keyboard" || !browser_) return NO;
  auto* service = extensions::CommandService::Get(browser_->GetProfile());
  if (!service) return NO;
  service->UpdateKeybindingPrefs("kmgaadhbnkendcanjninlfmfgehagggl", "probe-command",
                                 collision ? "Command+L" : "Alt+Shift+U");
  return YES;
}

- (BOOL)checkReassignedAction {
  auto* args = base::CommandLine::ForCurrentProcess();
  if (args->GetSwitchValueASCII("ararat-check") != "keyboard" && args->GetSwitchValueASCII("ararat-screen") != "keyboard") return NO;
  auto* manager = core_->widget()->GetFocusManager();
  return manager && manager->ProcessAccelerator(ui::Accelerator(ui::VKEY_O, ui::EF_ALT_DOWN | ui::EF_SHIFT_DOWN));
}

- (BOOL)checkShortcutActivation {
  auto* args = base::CommandLine::ForCurrentProcess();
  if (args->GetSwitchValueASCII("ararat-check") != "keyboard" && args->GetSwitchValueASCII("ararat-screen") != "keyboard") return NO;
  return core_->ShortcutActivationMatches(self.window.isKeyWindow);
}

- (BOOL)checkViewlessBubbleAnchor {
  const auto check = base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check");
  if ((check != "permissions" && check != "keyboard") || !browser_) return NO;
  return bubble_anchor_util::GetPageInfoAnchorConfiguration(browser_).anchor.IsNull();
}

- (NSDictionary<NSString*, id>*)checkViewlessBubbleAnchorGeometry {
  const auto check = base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check");
  if ((check != "permissions" && check != "keyboard") || !browser_ || !browser_->GetWindow()) return @{};
  const bool rtl = base::i18n::IsRTL();
  auto* browser = browser_;
  auto verify = [browser, rtl]() {
    const gfx::Rect bounds = browser->GetWindow()->GetBounds();
    const gfx::Rect anchor = bubble_anchor_util::GetPageInfoAnchorRect(browser);
    const int expected_x = rtl ? bounds.right() - bubble_anchor_util::kNoToolbarLeftOffset
                               : bounds.x() + bubble_anchor_util::kNoToolbarLeftOffset;
    return !bounds.IsEmpty() && anchor.origin() == gfx::Point(expected_x, bounds.y());
  };
  const BOOL initial = verify();
  const NSRect original = self.window.frame;
  NSRect moved = original;
  moved.origin.x = -9000;
  moved.origin.y = -1000;
  [self.window setFrame:moved display:NO];
  const gfx::Rect shifted = browser_->GetWindow()->GetBounds();
  const BOOL negative = shifted.x() < 0 && verify();
  [self.window setFrame:original display:NO];
  const BOOL missing = bubble_anchor_util::GetPageInfoAnchorRect(nullptr).IsEmpty() &&
      bubble_anchor_util::GetPageInfoAnchorConfiguration(nullptr).anchor.IsNull();
  return @{ @"initial": @(initial), @"negative_origin": @(negative), @"missing_host": @(missing), @"rtl": @(rtl) };
}

- (void)checkShowViewlessBubble:(NSInteger)kind {
  if (base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-screen") != "keyboard" || !browser_) return;
  auto* contents = browser_->GetTabStripModel()->GetActiveWebContents();
  if (!contents || !contents->GetPrimaryMainFrame()) return;
  check_anchor_bubble_ = nil;
  if (kind == 0) {
    NSSet<NSWindow*>* before = [NSSet setWithArray:NSApp.windows];
    check_chooser_close_ = chrome::ShowDeviceChooserDialog(contents->GetPrimaryMainFrame(), std::make_unique<CheckChooserController>());
    for (NSWindow* window in NSApp.windows) {
      if (![before containsObject:window]) { check_anchor_bubble_ = window; break; }
    }
  } else if (kind == 1) {
    using Manager = FileSystemAccessPermissionRequestManager;
    std::vector<Manager::FileRequestData> files;
    files.emplace_back(content::PathInfo(base::FilePath("/tmp/ararat-anchor-fixture")),
                       content::FileSystemAccessPermissionContext::HandleType::kFile, Manager::Access::kRead);
    Manager::RequestData request(Manager::RequestType::kRestorePermissions, url::Origin::Create(contents->GetLastCommittedURL()), files);
    auto* bubble = FileSystemAccessRestorePermissionBubbleView::CreateAndShow(
        request, base::BindOnce([](permissions::PermissionAction) {}), contents);
    if (bubble && bubble->GetWidget()) check_anchor_bubble_ = bubble->GetWidget()->GetNativeWindow().GetNativeNSWindow();
  }
}

- (NSDictionary<NSString*, id>*)checkViewlessBubbleState {
  if (base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-screen") != "keyboard" || !browser_) return @{};
  const gfx::Rect anchor = bubble_anchor_util::GetPageInfoAnchorRect(browser_);
  NSWindow* bubble = check_anchor_bubble_;
  return @{ @"visible": @(bubble && bubble.isVisible), @"frame": NSStringFromRect(bubble ? bubble.frame : NSZeroRect),
            @"host_frame": NSStringFromRect(self.window.frame), @"anchor_x": @(anchor.x()), @"anchor_y": @(anchor.y()),
            @"rtl": @(base::i18n::IsRTL()) };
}

- (void)checkCloseViewlessBubble {
  if (base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-screen") != "keyboard") return;
  if (check_chooser_close_) std::move(check_chooser_close_).Run();
  else [check_anchor_bubble_ performClose:nil];
  check_anchor_bubble_ = nil;
}
- (BOOL)checkFocusSearch {
  if (base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check") != "menu" || !browser_) return NO;
  const int before = browser_->GetTabStripModel()->count();
  NSMenuItem* item = [[NSMenuItem alloc] init];
  item.tag = IDC_FOCUS_SEARCH;
  std::fprintf(stderr, "ararat-trace: menu-command dispatch tag=%ld target=window tabs_before=%d\n", static_cast<long>(item.tag), before);
  [(NSWindow<CommandDispatchingWindow>*)self.window commandDispatch:item];
  const int after = browser_->GetTabStripModel()->count();
  std::fprintf(stderr, "ararat-trace: menu-command returned tag=%ld target=window tabs_after=%d\n", static_cast<long>(item.tag), after);
  return before == after;
}

- (void)checkCloseAllTabs {
  const auto check = base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check");
  if (browser_ && (check == "menu" || check == "empty"))
    browser_->GetTabStripModel()->CloseAllTabs();
}
- (void)checkEnsureEmptyBrowser {
  if (base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check") == "empty")
    [self ensureProfileBrowser:self.profileDirectory];
}
- (NSDictionary<NSString*, id>*)checkEmptySessionRestore {
  if (base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check") != "empty" ||
      !core_->windows().empty()) return @{};
  auto it = profile_keep_alives_.find(core_->profile_name());
  if (it == profile_keep_alives_.end() || !it->second->profile) return @{};
  Profile* profile = it->second->profile;
  SessionService* service = SessionServiceFactory::GetForProfile(profile);
  if (!service) return @{ @"service_available": @NO };
  const bool eligible = service->ShouldRestore(nullptr);
  const NSUInteger browsers_before = AraratBrowserCount();
  const NSUInteger stock_before = AraratStockBrowserCount();
  auto pref = SessionStartupPref::GetStartupPref(profile);
  pref.urls = {GURL("https://ararat-check.test/first"), GURL("https://ararat-check.test/second")};
  SessionStartupPref::SetStartupPref(profile, pref);
  profile->GetPrefs()->SetInteger(prefs::kRestoreOnStartup, SessionStartupPref::kPrefValueLast);
  const auto after = SessionStartupPref::GetStartupPref(profile);
  const bool is_default = after.type == SessionStartupPref::DEFAULT;
  const bool urls_preserved = after.urls == pref.urls;
  const bool restored = service->RestoreIfNecessary(StartupTabs(), false);
  std::fprintf(stderr, "ararat-trace: empty-restore eligible=%d default=%d restored=%d\n", eligible, is_default, restored);
  return @{ @"service_available": @YES, @"restore_eligible": @(eligible), @"startup_default": @(is_default),
            @"startup_urls_preserved": @(urls_preserved),
            @"restore_requested": @(restored), @"browsers_before": @(browsers_before),
            @"browsers_after": @(AraratBrowserCount()), @"stock_before": @(stock_before),
            @"stock_after": @(AraratStockBrowserCount()) };
}
- (NSDictionary<NSString*, id>*)checkEmptyMenuValidation {
  if (base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check") != "empty" ||
      !browser_ || browser_->GetTabStripModel()->count() != 0 || !NSApp.mainMenu) return @{};
  NSMutableArray<NSMenu*>* menus = [NSMutableArray arrayWithObject:NSApp.mainMenu];
  NSMutableArray<NSNumber*>* enabled = [NSMutableArray array];
  NSUInteger count = 0;
  while (menus.count) {
    NSMenu* menu = menus.lastObject;
    [menus removeLastObject];
    for (NSMenuItem* item in menu.itemArray) {
      if (item.submenu) [menus addObject:item.submenu];
      if (item.action == @selector(commandDispatch:) || item.action == @selector(commandDispatchUsingKeyModifiers:)) {
        if ([self.window validateUserInterfaceItem:item]) [enabled addObject:@(item.tag)];
        ++count;
      }
    }
  }
  std::fprintf(stderr, "ararat-trace: empty-menu-validated count=%lu\n", static_cast<unsigned long>(count));
  return @{ @"validated": @(count), @"enabled_command_ids": enabled };
}
- (void)checkOpenURLs {
  if (base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check") != "menu") return;
  [NSApp.delegate application:NSApp openURLs:@[
      [NSURL URLWithString:@"https://example.test/ararat-one"],
      [NSURL URLWithString:@"https://example.test/ararat-two"]]];
}
- (NSString*)checkOpenLinkNewWindowTitle {
  if (base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-screen") != "links") return @"";
  return l10n_util::GetNSStringWithFixup(IDS_CONTENT_CONTEXT_OPENLINKNEWWINDOW);
}
- (void)disableCheckConfirmQuit {
  g_browser_process->local_state()->SetBoolean(prefs::kConfirmToQuitEnabled, false);
}

- (NSDictionary<NSString*, id>*)checkProfileState {
  const auto check = base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check");
  if (!IsProfileCheck() && check != "popup" && check != "ext-windows-popup") return @{};
  NSMutableArray* browsers = [NSMutableArray array];
  for (const auto& [name, window] : core_->windows()) {
    NSMutableArray* tabs = [NSMutableArray array];
    auto* strip = window->browser()->GetTabStripModel();
    for (int i = 0; i < strip->count(); ++i) {
      auto* contents = strip->GetWebContentsAt(i);
      ARTab* tab = tabs_[[NSValue valueWithPointer:contents]];
      if (tab) [tabs addObject:@{ @"id": tab.liveId, @"title": tab.title, @"url": tab.url }];
    }
    [browsers addObject:@{ @"profile": [NSString stringWithUTF8String:name.c_str()],
      @"browser_pointer": [NSString stringWithFormat:@"%p", static_cast<void*>(window->browser())],
      @"profile_pointer": [NSString stringWithFormat:@"%p", window->browser()->GetProfile()],
      @"off_the_record": @(window->browser()->GetProfile()->IsOffTheRecord()),
      @"visible": @(window->IsVisible()), @"active": @(window->IsActive()),
      @"minimized": @(window->IsMinimized()), @"tabs": tabs }];
  }
  Profile* last = ProfileManager::GetLastUsedProfileIfLoaded();
  Profile* app_last = [(id)NSApp.delegate lastProfileIfLoaded];
  NSMutableArray* loaded = [NSMutableArray array];
  for (Profile* profile : g_browser_process->profile_manager()->GetLoadedProfiles()) {
    const auto name = profile->GetPath().BaseName().value();
    [loaded addObject:[NSString stringWithUTF8String:name.c_str()]];
  }
  NSString* last_name = last ? [NSString stringWithUTF8String:last->GetPath().BaseName().value().c_str()] : @"";
  NSString* app_name = app_last ? [NSString stringWithUTF8String:app_last->GetPath().BaseName().value().c_str()] : @"";
  return @{ @"shown": self.profileDirectory, @"browsers": browsers,
            @"loaded": @(loaded.count), @"loaded_profiles": loaded,
            @"chrome_last": last_name, @"app_last": app_name,
            @"restore_omitted": @(g_restore_omitted && g_restore_checked > 0 && g_restore_devtools_checked),
            @"restore_checked": @(g_restore_checked), @"restore_devtools_checked": @(g_restore_devtools_checked),
            @"devtools_destroyed": @(AraratCheckDevToolsDestroyed()),
            @"stock_browsers": @(AraratStockBrowserCount()) };
}

- (void)checkCookieIsolation {
  if (!IsProfileCheck() || cookie_started_) return;
  auto* manager = g_browser_process->profile_manager();
  Profile* first = manager->GetProfileByPath(manager->user_data_dir().AppendASCII("Default"));
  Profile* second = manager->GetProfileByPath(manager->user_data_dir().AppendASCII("Profile 1"));
  if (!first || !second) return;
  const GURL url("https://ararat-check.test/");
  auto cookie = net::CanonicalCookie::CreateForTesting(url, "isolation=default; Secure", base::Time::Now(), net::CookieSourceType::kHTTP);
  if (!cookie) return;
  cookie_started_ = YES;
  __weak ARWindowHost* host = self;
  first->GetDefaultStoragePartition()->GetCookieManagerForBrowserProcess()->SetCanonicalCookie(
      *cookie, url, net::CookieOptions::MakeAllInclusive(),
      base::BindOnce(^(net::CookieAccessResult result) {
        ARWindowHost* strong = host;
        if (!strong) return;
        strong->cookie_set_ = result.status.IsInclude();
        auto* manager = g_browser_process->profile_manager();
        Profile* named = manager->GetProfileByPath(manager->user_data_dir().AppendASCII("Profile 1"));
        if (!named) { strong->cookie_done_ = YES; return; }
        named->GetDefaultStoragePartition()->GetCookieManagerForBrowserProcess()->GetCookieList(
            GURL("https://ararat-check.test/"), net::CookieOptions::MakeAllInclusive(),
            net::CookiePartitionKeyCollection(),
            base::BindOnce(^(const net::CookieAccessResultList& cookies, const net::CookieAccessResultList&) {
              ARWindowHost* current = host;
              if (!current) return;
              current->cookie_isolated_ = cookies.empty();
              current->cookie_done_ = YES;
            }));
      }));
}

- (NSDictionary<NSString*, id>*)checkCookieState {
  return @{ @"started": @(cookie_started_), @"set": @(cookie_set_),
            @"done": @(cookie_done_), @"isolated": @(cookie_isolated_) };
}

- (void)checkCloseTabsForProfile:(NSString*)profile {
  auto* args = base::CommandLine::ForCurrentProcess();
  if (!IsProfileCheck() && args->GetSwitchValueASCII("ararat-check") != "keyboard" && args->GetSwitchValueASCII("ararat-screen") != "keyboard") return;
  auto* window = core_->windowForProfile(profile.UTF8String);
  if (window) window->browser()->GetTabStripModel()->CloseAllTabs();
}

- (void)checkActivateShownProfile {
  if (!IsProfileCheck() || !base::CommandLine::ForCurrentProcess()->HasSwitch("ararat-check")) return;
  for (const auto& [name, window] : core_->windows()) {
    if (window != core_->window() && !window->browser()->IsDeleteScheduled()) {
      if (auto* manager = BrowserActiveStateManager::From(window->browser())) manager->DidBecomeInactive();
    }
  }
  [self updateActive:YES];
  [(id)NSApp.delegate windowDidBecomeMain:[NSNotification notificationWithName:NSWindowDidBecomeMainNotification object:self.window]];
}

- (void)checkCreateIncognito {
  if (IsProfileCheck() && browser_) chrome::NewIncognitoWindow(browser_->GetProfile());
}

- (void)checkNavigateOffTheRecord {
  if (!IsProfileCheck() || !browser_) return;
  NavigateParams params(browser_, GURL("data:text/html,<title>ararat-otr-navigation</title>"), ui::PAGE_TRANSITION_LINK);
  params.disposition = WindowOpenDisposition::OFF_THE_RECORD;
  Navigate(&params);
}

- (void)closeCancelled {
  if (IsProfileCheck()) ++check_close_cancelled_;
  closing_window_ = NO;
  if (!closing_all_) {
    if (self.delegate) [self.delegate windowHostClosingAllCancelled:self];
    [self emitCause:@"Chrome"];
  }
}

- (void)makePending {
  DCHECK([NSThread isMainThread]);
  core_->SetPending(core_->profile_name());
}

- (void)pinProfile:(Profile*)profile {
  if (!profile || profile->IsOffTheRecord()) return;
  const auto name = profile->GetPath().BaseName().value();
  if (!profile_keep_alives_.contains(name)) {
    // Reloading the profile in openURL: instead would build a new Profile
    // object and re-run its final init; kBrowserWindow has the same scope the
    // Browser's own keep-alive has, but outlives it: the host is the window.
    auto keep_alive = ScopedProfileKeepAlive::TryAcquire(
        profile, ProfileKeepAliveOrigin::kBrowserWindow);
    if (keep_alive) profile_keep_alives_[name] = std::make_unique<HostedProfile>(profile, std::move(keep_alive));
    else {
      PinStartupPref(profile);
      if (IsProfileCheck()) std::fprintf(stderr, "ararat-trace: profile-keepalive-failed name=%s\n", name.c_str());
    }
  }
}

- (void)browserCreated:(BrowserWindowInterface*)browser {
  if (strip_observers_.contains(browser) || core_->closing() || core_->closed()) return;
  [self pinProfile:browser->GetProfile()];
  strip_observers_[browser] = std::make_unique<StripObserver>(browser->GetTabStripModel(), self);
  if (core_->window() && core_->window()->browser() == browser) {
    browser_ = browser;
    core_->SetShortcutWindow(core_->window(), self.window.isKeyWindow);
    if (self.window.isKeyWindow) [self updateActive:YES];
    if (self.window.isMainWindow)
      [(id)NSApp.delegate windowDidBecomeMain:[NSNotification notificationWithName:NSWindowDidBecomeMainNotification object:self.window]];
  }
  [self syncTabs];
  // Why not rely on the insert: a Chrome-routed Browser was populated before
  // this posted call attached the observer.
  if (!command_id_) [self emitCause:@"Chrome"];
}

- (void)browserDestroyed:(BrowserWindowInterface*)browser {
  if (strip_observers_.erase(browser)) {
    if (browser_ == browser) browser_ = nullptr;
    [self syncTabs];
    if (core_->closing() || core_->closed()) {
      if (core_->windows().empty()) profile_keep_alives_.clear();
      if (pending_opens_.count) {
        if (!closing_all_) closing_window_ = NO;
        [self discardPendingOpens];
        if (!closing_all_) closing_window_ = YES;
      }
    }
    if (closing_window_ && !closing_all_) {
      closing_window_ = NO;
      [self transactionWithCause:@"Engine" setEmptyReported:YES retainHost:YES];
      closing_window_ = YES;
    } else if (!empty_reported_) {
      [self emitCause:@"Chrome"];
    }
    empty_reported_ = NO;
  }
  if (pending_opens_.count) {
    __weak ARWindowHost* host = self;
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(^{ [host drainPendingOpens]; }));
  }
}

- (NSArray<ARTab*>*)tabs {
  DCHECK([NSThread isMainThread]);
  NSMutableArray<ARTab*>* result = [NSMutableArray array];
  for (const auto& [name, window] : core_->windows()) {
    TabStripModel* strip = window->browser()->GetTabStripModel();
    for (int i = 0; i < strip->count(); ++i) {
      ARTab* tab = tabs_[[NSValue valueWithPointer:strip->GetWebContentsAt(i)]];
      if (tab) [result addObject:tab];
    }
  }
  return result;
}

- (NSDictionary<NSString*, id>*)navigationTarget {
  if (!g_epoch || core_->popup() || workspace_page_hidden_ || core_->closing() || core_->closed() || closing_all_ || closing_window_ || !browser_ || browser_->IsDeleteScheduled()) return nil;
  auto* contents = browser_->GetTabStripModel()->GetActiveWebContents();
  ARTab* tab = contents ? tabs_[[NSValue valueWithPointer:contents]] : nil;
  NSString* item = tab.itemId;
  if (!tab || !item) return nil;
  return @{ @"epoch": @(g_epoch), @"live": tab.liveId, @"item": item,
            @"profile": self.profileDirectory, @"url": tab.url };
}

- (BOOL)hasActiveTab {
  if (!core_->popup() && workspace_page_hidden_) return NO;
  auto* window = core_->window();
  auto* browser = window ? window->browser() : nullptr;
  return browser && !browser->IsDeleteScheduled() && browser->GetTabStripModel()->GetActiveWebContents();
}

- (void)setWorkspacePageHidden:(BOOL)hidden {
  if (workspace_page_hidden_ == hidden) return;
  workspace_page_hidden_ = hidden;
  [self syncTabs];
}

- (NSString*)findLiveId {
  auto* contents = browser_ ? browser_->GetTabStripModel()->GetActiveWebContents() : nullptr;
  return contents ? tabs_[[NSValue valueWithPointer:contents]].liveId : nil;
}

- (void)findAction:(NSString*)action text:(NSString*)text selection:(NSRange)selection liveId:(NSString*)liveId profile:(NSString*)profile {
  if (core_->closing() || core_->closed() || closing_all_ || !browser_ || browser_->IsDeleteScheduled()) return;
  if (!liveId.length || ![[self findLiveId] isEqualToString:liveId] || ![self.profileDirectory isEqualToString:profile]) return;
  auto* controller = FindBarController::From(browser_);
  auto* contents = browser_->GetTabStripModel()->GetActiveWebContents();
  if (!controller || !contents) return;
  auto* helper = find_in_page::FindTabHelper::FromWebContents(contents);
  if (!helper) return;
  if ([action isEqualToString:@"close"]) {
    controller->EndFindSession(find_in_page::SelectionAction::kKeep, find_in_page::ResultAction::kKeep);
    return;
  }
  auto value = base::SysNSStringToUTF16(text ?: @"");
  if ([action isEqualToString:@"change"]) {
    controller->OnUserChangedFindText(value);
    size_t start = std::min(static_cast<size_t>(selection.location), value.size());
    size_t length = std::min(static_cast<size_t>(selection.length), value.size() - start);
    controller->find_bar()->SetFindTextAndSelectedRange(value, gfx::Range(start, start + length));
    helper->StartFinding(value, true, false, true);
  } else if ([action isEqualToString:@"next"] || [action isEqualToString:@"previous"]) {
    helper->StartFinding(value, [action isEqualToString:@"next"], false, true);
  }
}

- (BOOL)navigateURL:(NSString*)url target:(NSDictionary<NSString*, id>*)target {
  if (!url || !g_epoch || core_->popup() || core_->closing() || core_->closed() || closing_all_ || closing_window_ ||
      ![target[@"epoch"] isKindOfClass:NSNumber.class] || [target[@"epoch"] unsignedLongLongValue] != g_epoch ||
      ![target[@"live"] isKindOfClass:NSString.class] || ![target[@"item"] isKindOfClass:NSString.class] ||
      ![target[@"profile"] isKindOfClass:NSString.class] || ![self.profileDirectory isEqualToString:target[@"profile"]]) return NO;
  GURL parsed_url(url.UTF8String);
  if (!parsed_url.is_valid()) return NO;
  auto* window = core_->windowForProfile([target[@"profile"] UTF8String]);
  if (!window || !window->browser() || window->browser()->IsDeleteScheduled()) return NO;
  auto* strip = window->browser()->GetTabStripModel();
  for (int i = 0; i < strip->count(); ++i) {
    auto* contents = strip->GetWebContentsAt(i);
    ARTab* tab = tabs_[[NSValue valueWithPointer:contents]];
    if ([tab.liveId isEqualToString:target[@"live"]] && [tab.itemId isEqualToString:target[@"item"]]) {
      content::NavigationController::LoadURLParams params(parsed_url);
      params.transition_type = ui::PAGE_TRANSITION_TYPED;
      return contents->GetController().LoadURLWithParamsForResult(params).has_value();
    }
  }
  return NO;
}

- (BOOL)openURL:(NSString*)url commandId:(NSString*)commandId itemId:(NSString*)itemId {
  return [self openURL:url commandId:commandId itemId:itemId external:NO untrusted:NO profile:self.profileDirectory];
}

- (BOOL)openExternalURL:(NSString*)url commandId:(NSString*)commandId itemId:(NSString*)itemId untrusted:(BOOL)untrusted {
  return [self openURL:url commandId:commandId itemId:itemId external:YES untrusted:untrusted profile:self.profileDirectory];
}

- (BOOL)openURL:(NSString*)url commandId:(NSString*)commandId itemId:(NSString*)itemId profile:(NSString*)profile external:(BOOL)external untrusted:(BOOL)untrusted {
  base::FilePath name(profile.UTF8String);
  if (name.empty() || name.IsAbsolute() || name.ReferencesParent() || name.BaseName() != name || name.value() == ".") return NO;
  return [self openURL:url commandId:commandId itemId:itemId external:external untrusted:untrusted profile:profile];
}

- (BOOL)openURL:(NSString*)url commandId:(NSString*)commandId itemId:(NSString*)itemId external:(BOOL)external untrusted:(BOOL)untrusted profile:(NSString*)profileDirectory {
  DCHECK([NSThread isMainThread]);
  if (core_->closing() || core_->closed() || closing_all_ || !g_epoch ||
      !url || !commandId || !itemId) return NO;
  GURL parsed_url(url.UTF8String);
  if (!parsed_url.is_valid()) return NO;
  const std::string profile_name_value(profileDirectory.UTF8String);
  auto* existing_window = core_->windowForProfile(profile_name_value);
  BrowserWindowInterface* closing_browser = existing_window ? existing_window->browser() : nullptr;
  if ((!draining_opens_ && pending_opens_.count) ||
      (closing_browser && closing_browser->IsDeleteScheduled())) {
    [pending_opens_ addObject:@{ @"url": [url copy], @"command": [commandId copy], @"item": [itemId copy], @"external": @(external), @"untrusted": @(untrusted), @"profile": profileDirectory }];
    return YES;
  }
  BOOL new_browser = !existing_window;
  base::FilePath profile_name(profile_name_value);
  ProfileManager* manager = g_browser_process->profile_manager();
  Profile* profile = new_browser ? manager->GetProfileByPath(manager->user_data_dir().Append(profile_name)) : nullptr;
  if (new_browser && !profile) {
    [pending_opens_ addObject:@{ @"url": [url copy], @"command": [commandId copy], @"item": [itemId copy], @"external": @(external), @"untrusted": @(untrusted), @"profile": profileDirectory }];
    if (!loading_profile_) {
      loading_profile_ = YES;
      __weak ARWindowHost* host = self;
      if (IsProfileCheck()) std::fprintf(stderr, "ararat-trace: profile-load name=%s\n", profile_name.value().c_str());
      if (IsCloseCheck()) std::fprintf(stderr, "ararat-trace: profile-load\n");
      manager->CreateProfileAsync(manager->user_data_dir().Append(profile_name),
          base::BindOnce(^(Profile* loaded) { [host profileLoaded:loaded != nullptr]; }));
    }
    return YES;
  }
  command_id_ = commandId;
  opening_item_ = itemId;
  emitted_change_ = NO;
  if (new_browser) {
    if (GetBrowserWindowCreationStatusForProfile(*profile) != BrowserWindowInterface::CreationStatus::kOk) {
      if (IsCloseCheck()) std::fprintf(stderr, "ararat-trace: browser-create-denied\n");
      command_id_ = nil; opening_item_ = nil;
      [self emitOpenFailure:commandId];
      return YES;
    }
    core_->SetPending(profile_name_value);
    BrowserWindowInterface* browser = CreateBrowserWindow(BrowserWindowCreateParams(profile, true));
    if (!browser || !core_->windowForProfile(profile_name_value)) {
      if (IsCloseCheck()) std::fprintf(stderr, "ararat-trace: browser-create-failed\n");
      core_->ClearPending();
      command_id_ = nil; opening_item_ = nil;
      [self emitOpenFailure:commandId];
      return YES;
    }
    [self browserCreated:browser];
  } else if (!strip_observers_.contains(closing_browser)) {
    NSString* item = opening_item_;
    opening_item_ = nil;
    [self browserCreated:closing_browser];
    opening_item_ = item;
  }
  auto* target_window = core_->windowForProfile(profile_name_value);
  BrowserWindowInterface* target = target_window ? target_window->browser() : nullptr;
  if (!target || target->IsDeleteScheduled()) {
    command_id_ = nil; opening_item_ = nil;
    [self emitOpenFailure:commandId];
    return YES;
  }
  content::WebContents* contents = nullptr;
  if (external) {
    NavigateParams params(target, parsed_url, ui::PAGE_TRANSITION_AUTO_TOPLEVEL);
    params.disposition = WindowOpenDisposition::NEW_FOREGROUND_TAB;
    if (untrusted) params.initiator_origin = url::Origin();
    params.web_app_navigation_data.emplace();
    params.web_app_navigation_data->SetNavigationCapturingForceOff(true);
    Navigate(&params);
    contents = params.navigated_or_inserted_contents;
  } else {
    contents = chrome::AddAndReturnTabAt(target, parsed_url, -1, true);
  }
  [self syncTabs];
  ARTab* tab = tabs_[[NSValue valueWithPointer:contents]];
  if (!emitted_change_) {
    if (tab) [self emitCause:@{ @"Command": commandId }];
    else [self emitOpenFailure:commandId];
  }
  command_id_ = nil;
  opening_item_ = nil;
  return YES;
}

- (void)drainPendingOpens {
  if (core_->closed()) { [self discardPendingOpens]; return; }
  draining_opens_ = YES;
  while (pending_opens_.count && !core_->closed()) {
    NSDictionary* open = pending_opens_.firstObject;
    auto* pending_window = core_->windowForProfile([open[@"profile"] UTF8String]);
    if (loading_profile_ || (pending_window && pending_window->browser()->IsDeleteScheduled())) break;
    [pending_opens_ removeObjectAtIndex:0];
    [self openURL:open[@"url"] commandId:open[@"command"] itemId:open[@"item"] external:[open[@"external"] boolValue] untrusted:[open[@"untrusted"] boolValue] profile:open[@"profile"]];
  }
  draining_opens_ = NO;
  if (core_->closed()) [self discardPendingOpens];
}

- (void)profileLoaded:(BOOL)loaded {
  loading_profile_ = NO;
  if (IsCloseCheck()) std::fprintf(stderr, "ararat-trace: profile-loaded=%d\n", loaded);
  if (IsProfileCheck()) std::fprintf(stderr, "ararat-trace: profile-loaded success=%d pending=%lu\n", loaded, (unsigned long)pending_opens_.count);
  if (loaded && !core_->closed()) [self drainPendingOpens];
  else [self discardPendingOpens];
}

- (void)discardPendingOpens {
  for (NSDictionary* open in pending_opens_) {
    [self emitOpenFailure:open[@"command"]];
  }
  [pending_opens_ removeAllObjects];
}

- (void)activateTab:(ARTab*)tab commandId:(NSString*)commandId {
  if (!g_epoch || !tab.contents || !commandId) return;
  TabStripModel* strip = [self stripForTab:tab];
  if (!strip) return;
  int index = strip->GetIndexOfWebContents(tab.contents);
  if (index == TabStripModel::kNoTab) return;
  command_id_ = commandId;
  emitted_change_ = NO;
  strip->ActivateTabAt(index);
  if (!emitted_change_) [self emitCause:@{ @"Command": commandId }];
  command_id_ = nil;
}

- (void)closeTab:(ARTab*)tab commandId:(NSString*)commandId {
  if (!g_epoch || !tab.contents || !commandId) return;
  TabStripModel* strip = [self stripForTab:tab];
  if (!strip) return;
  if (strip->GetIndexOfWebContents(tab.contents) == TabStripModel::kNoTab) return;
  command_id_ = commandId;
  pending_closes_[[NSValue valueWithPointer:tab.contents]] = commandId;
  strip->CloseWebContents(tab.contents, TabCloseTypes::CLOSE_CREATE_HISTORICAL_TAB);
  command_id_ = nil;
}

- (TabStripModel*)stripForTab:(ARTab*)tab {
  for (const auto& [name, window] : core_->windows()) {
    auto* strip = window->browser()->GetTabStripModel();
    if (strip->GetIndexOfWebContents(tab.contents) != TabStripModel::kNoTab) return strip;
  }
  return nullptr;
}

- (void)setItemId:(NSString*)itemId forTab:(ARTab*)tab {
  if (!g_epoch || !tab.contents) return;
  auto* identity = static_cast<TabIdentity*>(tab.contents->GetUserData(kTabIdentityKey));
  if (identity) identity->item_id = [itemId copy];
}

- (NSString*)itemIdForTab:(ARTab*)tab {
  if (!tab.contents) return nil;
  auto* identity = static_cast<TabIdentity*>(tab.contents->GetUserData(kTabIdentityKey));
  return identity ? identity->item_id : nil;
}

- (BOOL)isActiveTab:(ARTab*)tab {
  return browser_ && browser_->GetTabStripModel()->GetActiveWebContents() == tab.contents;
}

- (void)closeCancelled:(const tabs::TabInterface*)tab {
  [pending_closes_ removeObjectForKey:[NSValue valueWithPointer:tab->GetContents()]];
}

- (void)stripChanged:(const TabStripModelChange&)change {
  NSString* cause_command = command_id_;
  if (change.type() == TabStripModelChange::kReplaced) {
    const auto* replaced = change.GetReplace();
    content::WebContents* old_contents = replaced->old_contents;
    content::WebContents* new_contents = replaced->new_contents;
    NSValue* old_key = [NSValue valueWithPointer:old_contents];
    ARTab* tab = tabs_[old_key];
    auto data = old_contents->TakeUserData(kTabIdentityKey);
    if (data) new_contents->SetUserData(kTabIdentityKey, std::move(data));
    if (tab) {
      [tabs_ removeObjectForKey:old_key];
      [tab replaceContents:new_contents];
      tabs_[[NSValue valueWithPointer:new_contents]] = tab;
    }
  }
  if (change.type() == TabStripModelChange::kRemoved) {
    const auto* removed = change.GetRemove();
    for (const auto& entry : removed->contents) {
      NSValue* key = [NSValue valueWithPointer:entry.contents.get()];
      NSString* pending = pending_closes_[key];
      if (pending) cause_command = pending;
      [pending_closes_ removeObjectForKey:key];
    }
  }
  [self syncTabs];
  emitted_change_ = YES;
  [self emitCause:cause_command ? @{ @"Command": cause_command } : @"Chrome"];
}

- (void)tabMetadataChanged {
  __weak ARWindowHost* host = self;
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(^{ [host emitCause:@"Engine"]; }));
}

- (void)devToolsChanged:(content::WebContents*)inspected {
  ++devtools_hook_count_;
  [self syncTabs];
}

- (void)syncTabs {
  content::WebContents* active = browser_ ? browser_->GetTabStripModel()->GetActiveWebContents() : nullptr;
  if (!core_->popup() && workspace_page_hidden_) active = nullptr;
  NSView* card = [self.delegate pageCardForWindowHost:self];
  content::WebContents* active_devtools = active ? DevToolsWindow::GetInTabWebContents(active, nullptr) : nullptr;
  NSView* desired_devtools = active_devtools && card ? active_devtools->GetNativeView().GetNativeNSView() : nil;
  if (devtools_view_ != desired_devtools) {
    [devtools_view_ removeFromSuperview];
    devtools_view_ = desired_devtools;
  }
  {
    if (page_position_view_.superview != card) {
      [page_position_view_ removeFromSuperview];
      page_position_view_ = nil;
      if (card) {
        page_position_view_ = [[ARPagePositionView alloc] initWithFrame:card.bounds];
        page_position_view_.host = self;
        page_position_view_.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [card addSubview:page_position_view_];
      }
    }
    if (AraratUsesSharedCompositor() && !core_->devtools()) core_->AttachPage(active && card ? active->GetNativeView() : gfx::NativeView());
  }
  if (AraratUsesSharedCompositor() && !core_->devtools()) {
    if (!devtools_view_ || !card) {
      [devtools_clip_ removeFromSuperview];
      devtools_clip_ = nil;
    } else {
      if (!devtools_clip_) {
        devtools_clip_ = [[ARDevToolsClipView alloc] initWithFrame:card.bounds];
        devtools_clip_.wantsLayer = YES;
        devtools_clip_.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
      }
      if (devtools_clip_.superview != card)
        [card addSubview:devtools_clip_ positioned:NSWindowBelow relativeTo:nil];
      if (devtools_view_.superview != devtools_clip_) [devtools_clip_ addSubview:devtools_view_];
    }
  } else if (devtools_view_ && devtools_view_.superview != card) {
    [card addSubview:devtools_view_ positioned:NSWindowBelow relativeTo:nil];
  }
  NSMutableSet<NSValue*>* present = [NSMutableSet set];
  for (const auto& [name, window] : core_->windows()) {
   TabStripModel* strip = window->browser()->GetTabStripModel();
   for (int i = 0; i < strip->count(); ++i) {
    content::WebContents* contents = strip->GetWebContentsAt(i);
    NSValue* key = [NSValue valueWithPointer:contents];
    [present addObject:key];
    auto* identity = static_cast<TabIdentity*>(contents->GetUserData(kTabIdentityKey));
    if (!identity) {
      NSString* live = opening_item_ && command_id_ ? command_id_ : [@"chrome-" stringByAppendingString:NSUUID.UUID.UUIDString];
      auto data = std::make_unique<TabIdentity>(live, opening_item_);
      identity = data.get();
      contents->SetUserData(kTabIdentityKey, std::move(data));
      opening_item_ = nil;
    }
    if (!tabs_[key]) tabs_[key] = [[ARTab alloc] initWithContents:contents liveId:identity->live_id host:self];
    NSView* view = contents->GetNativeView().GetNativeNSView();
    content::WebContents* devtools = DevToolsWindow::GetInTabWebContents(contents, nullptr);
    if (devtools) {
      if (contents == active && card) devtools->WasShown();
      else devtools->WasHidden();
    }
    if (AraratUsesSharedCompositor() && !core_->devtools()) {
      if (contents == active && card) contents->WasShown();
      else contents->WasHidden();
    } else if (contents == active && card) {
      for (NSView* child in [card.subviews copy]) if (child != view && child != page_position_view_ && child != devtools_view_) [child removeFromSuperview];
      if (view.superview != card) [card addSubview:view];
      contents->WasShown();
    } else {
      [view removeFromSuperview];
      contents->WasHidden();
    }
   }
  }
  for (NSValue* key in [tabs_.allKeys copy]) {
    if (![present containsObject:key]) {
      [tabs_[key] invalidate];
      [tabs_ removeObjectForKey:key];
    }
  }
  if (!active && (!AraratUsesSharedCompositor() || core_->devtools())) for (NSView* child in [card.subviews copy]) if (child != page_position_view_) [child removeFromSuperview];
  [self positionPage];
}

- (void)positionPage {
  NSView* card = page_position_view_.superview;
  NSView* root = core_->GetNativeWindow().GetNativeNSWindow().contentView;
  if (!card || !root || card.window != root.window) return;
  content::WebContents* active = browser_ ? browser_->GetTabStripModel()->GetActiveWebContents() : nullptr;
  DevToolsContentsResizingStrategy strategy;
  content::WebContents* devtools = active ? DevToolsWindow::GetInTabWebContents(active, &strategy) : nullptr;
  gfx::Rect devtools_bounds, page_bounds;
  ApplyDevToolsContentsResizingStrategy(strategy, gfx::Rect(static_cast<int>(NSWidth(card.bounds)), static_cast<int>(NSHeight(card.bounds))), &devtools_bounds, &page_bounds);
  NSRect page = NSMakeRect(page_bounds.x(), NSHeight(card.bounds) - page_bounds.bottom(), page_bounds.width(), page_bounds.height());
  if (card.isFlipped) page.origin.y = page_bounds.y();
  [self.delegate windowHost:self findPageRectChanged:page];
  if (devtools && devtools_view_) {
    if (devtools_clip_) devtools_clip_.frame = card.bounds;
    devtools_view_.frame = devtools_clip_ ? devtools_clip_.bounds : card.bounds;
    if (devtools_clip_) {
      NSRect hole = NSIntersectionRect(devtools_clip_.bounds, [devtools_clip_ convertRect:page fromView:card]);
      devtools_clip_.pageRect = hole;
      CGMutablePathRef path = CGPathCreateMutable();
      CGPathAddRect(path, nullptr, NSRectToCGRect(devtools_clip_.bounds));
      if (!NSIsEmptyRect(hole)) CGPathAddRect(path, nullptr, NSRectToCGRect(hole));
      CAShapeLayer* mask = [CAShapeLayer layer];
      mask.frame = devtools_clip_.bounds;
      mask.fillRule = kCAFillRuleEvenOdd;
      mask.path = path;
      CGPathRelease(path);
      [CATransaction begin];
      [CATransaction setDisableActions:YES];
      devtools_clip_.layer.mask = mask;
      [CATransaction commit];
    }
  }
  if (active && (!AraratUsesSharedCompositor() || core_->devtools())) active->GetNativeView().GetNativeNSView().frame = page;
  NSRect rect = [card convertRect:page toView:root];
  if (!root.isFlipped) rect.origin.y = NSHeight(root.bounds) - NSMaxY(rect);
  core_->PositionPage(gfx::Rect(static_cast<int>(NSMinX(rect)),
                                static_cast<int>(NSMinY(rect)),
                                static_cast<int>(NSWidth(rect)),
                                static_cast<int>(NSHeight(rect))));
}

- (NSDictionary*)stripSnapshot:(BOOL)consumeNavigation {
  NSMutableArray* entries = [NSMutableArray array];
  NSString* active_id = nil;
  content::WebContents* active = browser_ ? browser_->GetTabStripModel()->GetActiveWebContents() : nullptr;
  if (!core_->popup() && workspace_page_hidden_) active = nullptr;
  for (ARTab* tab in [self tabs]) {
    auto* identity = static_cast<TabIdentity*>(tab.contents->GetUserData(kTabIdentityKey));
    TabStripModel* strip = nullptr;
    NSString* profile = nil;
    for (const auto& [name, window] : core_->windows()) {
      auto* candidate = window->browser()->GetTabStripModel();
      if (candidate->GetIndexOfWebContents(tab.contents) != TabStripModel::kNoTab) {
        strip = candidate;
        profile = [NSString stringWithUTF8String:name.c_str()];
        break;
      }
    }
    if (!strip) continue;
    auto* opener = strip->GetOpenerOfTabAt(strip->GetIndexOfWebContents(tab.contents));
    auto* opener_identity = opener ? static_cast<TabIdentity*>(opener->GetContents()->GetUserData(kTabIdentityKey)) : nullptr;
    const GURL& committed = tab.contents->GetLastCommittedURL();
    NSString* url = committed.is_valid() ? [NSString stringWithUTF8String:committed.spec().c_str()] : nil;
    [entries addObject:@{ @"profile": profile, @"live_id": tab.liveId, @"item": identity->item_id ? (id)identity->item_id : (id)NSNull.null,
                          @"opener": opener_identity ? (id)opener_identity->live_id : (id)NSNull.null,
                          @"navigated": @(consumeNavigation && [tab takePendingNavigation]),
                          @"url": url ?: (id)NSNull.null,
                          @"title": committed.is_valid() ? (id)tab.title : (id)NSNull.null }];
    if (tab.contents == active) active_id = tab.liveId;
  }
  return @{ @"window": window_id_, @"tabs": entries, @"active": active_id ? (id)active_id : (id)NSNull.null };
}

- (void)emitCause:(id)cause {
  [self transactionWithCause:cause setEmptyReported:YES retainHost:NO];
}

// Why not set empty_reported_: a discard must not suppress the empty strip of
// a Browser destroyed with tabs.
- (void)emitOpenFailure:(NSString*)commandId {
  [self transactionWithCause:@{ @"Command": commandId } setEmptyReported:NO retainHost:NO];
}

- (void)transactionWithCause:(id)cause setEmptyReported:(BOOL)setEmptyReported retainHost:(BOOL)retainHost {
  if (!g_epoch || closing_all_ || closing_window_) return;
  NSArray* strips = @[ [self stripSnapshot:[cause isKindOfClass:NSString.class]] ];
  if (setEmptyReported)
    empty_reported_ = [self tabs].count == 0;
  __weak ARWindowHost* host = self;
  ARWindowHost* retained_host = retainHost ? self : nil;
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(^{
        ARWindowHost* strong_host = retained_host ?: host;
        if (retainHost && IsCloseCheck()) std::fprintf(stderr, "ararat-trace: empty-strip-delivered=%d\n", strong_host.delegate != nil);
        id<ARWindowHostDelegate> delegate = strong_host.delegate;
        if (!strong_host || !delegate) return;
        NSDictionary* transaction = @{ @"epoch": @(g_epoch), @"rev": @(++g_revision), @"cause": cause, @"strips": strips };
        [delegate windowHost:strong_host didReceiveTransaction:transaction];
      }));
}

- (BOOL)hasBrowser {
  return core_->window() != nullptr;
}

- (NSString*)activeItemId {
  if (!browser_) return nil;
  auto* contents = browser_->GetTabStripModel()->GetActiveWebContents();
  if (!contents) return nil;
  auto* identity = static_cast<TabIdentity*>(contents->GetUserData(kTabIdentityKey));
  return identity ? identity->item_id : nil;
}

- (BOOL)isClosing {
  return core_->closing() || core_->closed();
}

- (BOOL)setProfileDirectory:(NSString*)directory {
  if (!directory || (core_->closing() && !switching_for_close_) || core_->closed()) return NO;
  base::FilePath name(directory.UTF8String);
  if (name.empty() || name.IsAbsolute() || name.ReferencesParent() || name.BaseName() != name || name.value() == ".") return NO;
  if (core_->profile_name() == name.value()) {
    if (self.delegate && shown_profiles_.insert(name.value()).second) [self ensureProfileBrowser:directory];
    return YES;
  }
  if (IsProfileCheck()) std::fprintf(stderr, "ararat-trace: show-profile old=%s new=%s exists=%d\n", core_->profile_name().c_str(), name.value().c_str(), core_->windowForProfile(name.value()) != nullptr);
  if (core_->window()) {
    auto* old_browser = core_->window()->browser();
    auto* manager = ExclusiveAccessManager::From(old_browser);
    auto* contents = old_browser->GetTabStripModel()->GetActiveWebContents();
    if (manager && contents) manager->OnTabDeactivated(contents);
  }
  if (self.window.isKeyWindow) [self updateActive:NO];
  core_->SetProfileName(name.value());
  browser_ = core_->window() ? core_->window()->browser() : nullptr;
  core_->SetShortcutWindow(core_->window(), self.window.isKeyWindow);
  auto* find = browser_ ? FindBarController::From(browser_) : nullptr;
  if (find && find->HasFindBar()) find->find_bar()->UpdateFindBarForChangedWebContents();
  else [self.delegate windowHost:self updateFindBar:@{ @"visible": @NO }];
  if (self.window.isKeyWindow) [self updateActive:YES];
  [self syncTabs];
  if (self.window.isMainWindow)
    [(id)NSApp.delegate windowDidBecomeMain:[NSNotification notificationWithName:NSWindowDidBecomeMainNotification object:self.window]];
  [self emitCause:@"Engine"];
  if (self.delegate) {
    shown_profiles_.insert(name.value());
    [self ensureProfileBrowser:directory];
  }
  return YES;
}

- (BOOL)setClosePresentationProfile:(NSString*)directory {
  if (!closing_all_ && !closing_window_ && !core_->closing()) return NO;
  switching_for_close_ = YES;
  [self setWorkspacePageHidden:NO];
  BOOL result = [self setProfileDirectory:directory];
  switching_for_close_ = NO;
  return result;
}

- (void)ensureProfileBrowser:(NSString*)directory {
  if (!self.delegate || core_->closing() || core_->closed() || core_->windowForProfile(directory.UTF8String)) return;
  NSString* requested = [directory copy];
  __weak ARWindowHost* host = self;
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(FROM_HERE, base::BindOnce(^{
    ARWindowHost* strong = host;
    if (!strong || strong->core_->closed() || strong->core_->closing() || strong->core_->windowForProfile(requested.UTF8String)) return;
    ProfileManager* manager = g_browser_process->profile_manager();
    base::FilePath path = manager->user_data_dir().Append(base::FilePath(requested.UTF8String));
    if (IsProfileCheck()) std::fprintf(stderr, "ararat-trace: ensure-profile name=%s\n", requested.UTF8String);
    manager->CreateProfileAsync(path, base::BindOnce(^(Profile* profile) {
      ARWindowHost* current = host;
      if (IsProfileCheck()) std::fprintf(stderr, "ararat-trace: ensure-profile-loaded success=%d host=%d\n", profile != nullptr, current != nil);
      if (!current || !profile || current->core_->closed() || current->core_->closing()) return;
      [current pinProfile:profile];
      const auto name = profile->GetPath().BaseName().value();
      if (current->core_->windowForProfile(name) ||
          GetBrowserWindowCreationStatusForProfile(*profile) != BrowserWindowInterface::CreationStatus::kOk) return;
      current->core_->SetPending(name);
      BrowserWindowInterface* browser = CreateBrowserWindow(BrowserWindowCreateParams(profile, true));
      if (IsProfileCheck()) std::fprintf(stderr, "ararat-trace: ensure-browser-created name=%s success=%d\n", name.c_str(), browser != nullptr);
      if (!browser || !current->core_->windowForProfile(name)) {
        current->core_->ClearPending();
        return;
      }
      [current browserCreated:browser];
    }));
  }));
}

- (NSString*)profileDirectory { return [NSString stringWithUTF8String:core_->profile_name().c_str()]; }
- (BOOL)hasProfileDirectory:(NSString*)directory {
  const std::string name(directory.UTF8String);
  return core_->profile_name() == name || core_->windowForProfile(name) || profile_keep_alives_.contains(name);
}
- (BOOL)hasBrowserForProfile:(NSString*)directory {
  return core_->windowForProfile(directory.UTF8String) != nullptr;
}
- (BOOL)isClosingAll { return closing_all_; }

@end
