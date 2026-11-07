
#include "ararat/core/ararat_window_host.h"

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

#include <algorithm>
#include <utility>
#include <cstdio>
#include <set>
#include <string>
#include <vector>

#include "ararat/core/ararat_browser_window.h"
#include "ararat/core/ararat_extensions_container.h"
#include "ararat/core/ararat_hooks.h"
#include "ararat/core/ararat_tab.h"
#include "base/check.h"
#include "base/command_line.h"
#include "base/functional/bind.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/observer_list.h"
#include "base/process/process.h"
#include "base/scoped_observation.h"
#include "base/strings/sys_string_conversions.h"
#include "base/supports_user_data.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
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
#include "chrome/browser/renderer_context_menu/render_view_context_menu.h"
#include "chrome/browser/chrome_browser_application_mac.h"
#include "chrome/browser/ui/browser_tabstrip.h"
#include "chrome/browser/ui/browser_commands.h"
#include "chrome/browser/ui/browser_window.h"
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
#include "chrome/browser/ui/toolbar/toolbar_action_view_model.h"
#include "chrome/browser/ui/views/extensions/extension_popup.h"
#include "chrome/browser/web_applications/web_app_helpers.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/render_frame_host.h"
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
#include "chrome/common/pref_names.h"
#include "chrome/common/chrome_constants.h"
#include "chrome/grit/generated_resources.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/image/image.h"
#include "ui/base/l10n/l10n_util_mac.h"
#import "ui/base/cocoa/command_dispatcher.h"
#import "ui/base/cocoa/user_interface_item_command_handler.h"
#include "ui/views/controls/native/native_view_host.h"
#include "ui/views/layout/fill_layout.h"
#include "ui/views/view.h"
#include "ui/views/view_class_properties.h"
#include "ui/views/widget/widget.h"
#include "ui/views/widget/native_widget_mac.h"
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

bool AraratHandleMenuKey(gfx::NativeEvent event) {
  NSEvent* native_event = event.Get();
  return native_event && native_event.type == NSEventTypeKeyDown &&
         (native_event.modifierFlags & NSEventModifierFlagCommand) &&
         [[NSApp mainMenu] performKeyEquivalent:native_event];
}

namespace {

bool IsDevToolsCheck() {
  auto* command = base::CommandLine::ForCurrentProcess();
  return command->GetSwitchValueASCII("ararat-check") == "devtools" ||
         command->GetSwitchValueASCII("ararat-screen") == "devtools";
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

class HostNativeWidgetMac : public views::NativeWidgetMac {
 public:
  explicit HostNativeWidgetMac(views::Widget* widget) : NativeWidgetMac(widget) {}

 protected:
  void PopulateCreateWindowParams(
      const views::Widget::InitParams& widget_params,
      remote_cocoa::mojom::CreateWindowParams* params) override {
    params->style_mask = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                         NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable |
                         NSWindowStyleMaskFullSizeContentView;
    params->titlebar_appears_transparent = true;
    params->window_title_hidden = true;
  }
};

NSUInteger g_check_dialog_count = 0;
NSUInteger g_check_cancel_dialog = 1;
NSMutableArray<NSString*>* g_check_beforeunload_profiles;

class CheckDialog : public javascript_dialogs::AppModalDialogView {
 public:
  explicit CheckDialog(std::unique_ptr<javascript_dialogs::AppModalDialogController> controller)
      : controller_(std::move(controller)) {}
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
    auto weak = weak_factory_.GetWeakPtr();
    controller_->OnAccept(u"", false);
    if (weak) delete this;
  }
  void CancelAppModalDialog() override {
    auto weak = weak_factory_.GetWeakPtr();
    chrome_browser_application_mac::CancelTerminate();
    controller_->OnCancel(false);
    if (weak) delete this;
  }
  bool IsShowing() const override { return true; }
 private:
  void Respond() {
    if (g_check_dialog_count == g_check_cancel_dialog) CancelAppModalDialog();
    else AcceptAppModalDialog();
  }
  std::unique_ptr<javascript_dialogs::AppModalDialogController> controller_;
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

bool AraratKeyEventFromDevTools(gfx::NativeEvent event) {
  NSEvent* native_event = event.Get();
  NSResponder* responder = native_event.window.firstResponder;
  if (![responder isKindOfClass:NSView.class]) return false;
  for (auto* host : AraratHosts()) {
    auto* window = host->window();
    if (!window) continue;
    auto* active = window->browser()->GetTabStripModel()->GetActiveWebContents();
    auto* devtools = active && DevToolsWindow::IsDevToolsWindow(active)
                         ? active
                         : active ? DevToolsWindow::GetInTabWebContents(active, nullptr) : nullptr;
    NSView* view = devtools ? devtools->GetNativeView().GetNativeNSView() : nil;
    if (view && [(NSView*)responder isDescendantOf:view]) return true;
  }
  return false;
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
  params.native_widget = new HostNativeWidgetMac(widget_.get());
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
  for (const auto& [name, window] : windows_) {
    auto* controller = UnloadController::From(window->browser());
    if (controller->GetBrowserClosingStatus() == BrowserWindowInterface::ClosingStatus::kDeniedByPolicy) {
      CloseConfirmed(false);
      return;
    }
    if (close_warnings_confirmed_.contains(name)) continue;
    auto weak = weak_factory_.GetWeakPtr();
    std::string profile_name = name;
    auto result = controller->MaybeWarnBeforeClosing(base::BindOnce(^(UnloadController::WarnBeforeClosingResult answer) {
      if (!weak || !weak->closing()) return;
      if (answer == UnloadController::WarnBeforeClosingResult::kDoNotClose) {
        weak->CloseConfirmed(false);
        return;
      }
      weak->close_warnings_confirmed_.insert(profile_name);
      weak->ConfirmClose();
    }));
    if (result == UnloadController::WarnBeforeClosingResult::kDoNotClose) return;
    close_warnings_confirmed_.insert(name);
  }
  for (const auto& [name, window] : windows_) {
    auto* controller = UnloadController::From(window->browser());
    if (controller->TabsNeedBeforeUnloadFired()) {
      [(__bridge ARWindowHost*)owner_ showBrowserProfileForClose:window->browser()];
      if (IsProfileCheck()) {
        NSString* shown = [(__bridge ARWindowHost*)owner_ profileDirectory];
        [g_check_beforeunload_profiles addObject:shown];
        std::fprintf(stderr, "ararat-trace: beforeunload profile=%s shown=%s\n", name.c_str(), shown.UTF8String);
      }
    }
    if (controller->RunBeforeUnloadForShutdown(
            false, base::BindRepeating(&AraratWindowHostCore::CloseConfirmed,
                                       weak_factory_.GetWeakPtr()))) return;
  }
  std::vector<AraratBrowserWindow*> windows;
  for (const auto& [name, window] : windows_) windows.push_back(window);
  for (auto* window : windows) window->RequestClose();
}

void AraratWindowHostCore::CloseConfirmed(bool proceed) {
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
- (BOOL)dispatchEmptyNewTab:(id)sender;
@end

@interface ARWindowCommandHandler : NSObject <UserInterfaceItemCommandHandler>
@property(nonatomic, weak) ARWindowHost* host;
@end

@implementation ARWindowCommandHandler
@synthesize host = _host;
- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item window:(NSWindow*)window {
  return [(id)NSApp.delegate validateUserInterfaceItem:item];
}
- (void)commandDispatch:(id)sender window:(NSWindow*)window {
  // U16 replaces this handler; the location bar is currently null.
  if ([sender tag] == IDC_FOCUS_SEARCH) return;
  if ([sender tag] == IDC_NEW_TAB && [self.host dispatchEmptyNewTab:sender]) return;
  [(id)NSApp.delegate commandDispatch:sender];
}
- (void)commandDispatchUsingKeyModifiers:(id)sender window:(NSWindow*)window {
  // U16 replaces this handler; the location bar is currently null.
  if ([sender tag] == IDC_FOCUS_SEARCH) return;
  if ([sender tag] == IDC_NEW_TAB && [self.host dispatchEmptyNewTab:sender]) return;
  [(id)NSApp.delegate commandDispatchUsingKeyModifiers:sender];
}
@end

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
  return base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check") == "ext-windows-popup" &&
      browser_ && browser_->GetType() == BrowserWindowInterface::TYPE_APP_POPUP;
}

- (void)checkExtensionAction:(NSInteger)command {
  auto* flags = base::CommandLine::ForCurrentProcess();
  if (flags->GetSwitchValueASCII("ararat-check") != "ext-popup" && flags->GetSwitchValueASCII("ararat-screen") != "extensions") return;
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
  if (flags->GetSwitchValueASCII("ararat-check") != "ext-popup" && flags->GetSwitchValueASCII("ararat-screen") != "extensions") return @{};
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
    ARWindowCommandHandler* command_handler = [[ARWindowCommandHandler alloc] init];
    command_handler.host = self;
    [(NSWindow<CommandDispatchingWindow>*)self.window setCommandHandler:command_handler];
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
          if (!closing) {
            if (was_closing && strong_host.delegate)
              [strong_host.delegate windowHostClosingAllCancelled:strong_host];
            if (strong_host->closing_window_)
              strong_host->core_->OnCloseCancelled();
            else if (was_closing)
              [strong_host emitCause:@"Chrome"];
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
  if (name != core_->profile_name())
    [self.delegate windowHost:self showProfile:[NSString stringWithUTF8String:name.c_str()]];
}

- (void)showBrowserProfileForClose:(BrowserWindowInterface*)browser {
  switching_for_close_ = YES;
  [self showBrowserProfile:browser];
  const auto name = browser->GetProfile()->GetPath().BaseName().value();
  if (name != core_->profile_name())
    [self setProfileDirectory:[NSString stringWithUTF8String:name.c_str()]];
  switching_for_close_ = NO;
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
}

- (void)installCheckDialogFactory {
  g_check_dialog_count = 0;
  g_check_cancel_dialog = 1;
  javascript_dialogs::AppModalDialogManager::GetInstance()->SetNativeDialogFactory(
      base::BindRepeating([](std::unique_ptr<javascript_dialogs::AppModalDialogController> controller)
          -> javascript_dialogs::AppModalDialogView* {
        auto* contents = controller->web_contents();
        if (contents && contents->GetDelegate()) contents->GetDelegate()->ActivateContents(contents);
        return new CheckDialog(std::move(controller));
      }));
}

- (NSUInteger)checkDialogCount { return g_check_dialog_count; }
- (BOOL)checkDialogHostForContents:(content::WebContents*)contents {
  auto* manager = web_modal::WebContentsModalDialogManager::FromWebContents(contents);
  return manager && manager->delegate() &&
      manager->delegate()->GetWebContentsModalDialogHost(contents) == core_->modal_dialog_host();
}
- (void)configureProfileCloseCheck:(NSUInteger)cancelDialog {
  if (base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check") != "profiles") return;
  [self installCheckDialogFactory];
  g_check_cancel_dialog = cancelDialog;
  g_check_beforeunload_profiles = [NSMutableArray array];
}
- (NSDictionary<NSString*, id>*)checkProfileCloseState {
  return @{ @"dialogs": @(g_check_dialog_count), @"close_cancelled": @(check_close_cancelled_),
            @"closing": @(core_->closing()), @"closed": @(core_->closed()),
            @"browsers": @(core_->windows().size()), @"beforeunload_profiles": g_check_beforeunload_profiles ?: @[] };
}
- (NSArray<NSNumber*>*)checkClosingEvents { return [check_closing_events_ copy] ?: @[]; }
- (BOOL)checkTryingToQuit { return browser_shutdown::IsTryingToQuit(); }
- (NSUInteger)checkStockBrowsers { return AraratStockBrowserCount(); }
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
  if (!browser_ || (!command->HasSwitch("ararat-check") && command->GetSwitchValueASCII("ararat-screen") != "prompts")) return;
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
  if (check != "menu" && check != "empty") return;
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

- (BOOL)dispatchEmptyNewTab:(id)sender {
  if ([sender tag] != IDC_NEW_TAB || !browser_ || core_->closing() || core_->closed() ||
      browser_->GetTabStripModel()->count() != 0) return NO;
  if (base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check") == "empty")
    std::fprintf(stderr, "ararat-trace: empty-new-tab handled browser=%p\n", static_cast<void*>(browser_));
  chrome::NewTab(browser_, NewTabTypes::kNewTabCommand);
  return YES;
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
  if (!IsProfileCheck()) return @{};
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
  if (!IsProfileCheck()) return;
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
  if (!closing_all_) [self emitCause:@"Chrome"];
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
  if (self.window.isKeyWindow) [self updateActive:NO];
  core_->SetProfileName(name.value());
  browser_ = core_->window() ? core_->window()->browser() : nullptr;
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
