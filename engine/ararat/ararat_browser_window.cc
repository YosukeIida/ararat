#include "ararat/core/ararat_browser_window.h"

#include <utility>
#include <cstdio>

#include "ararat/core/ararat_window_host.h"
#include "ararat/core/ararat_autofill_bubble_handler.h"
#include "ararat/core/ararat_extensions_container.h"
#include "base/functional/bind.h"
#include "base/command_line.h"
#include "base/functional/callback.h"
#include "base/task/cancelable_task_tracker.h"
#include "base/task/single_thread_task_runner.h"
#include "chrome/app/chrome_command_ids.h"
#include "chrome/browser/devtools/devtools_ui_controller.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/global_keyboard_shortcuts_mac.h"
#include "chrome/browser/themes/theme_service.h"
#include "chrome/browser/ui/browser_active_state_manager/browser_active_state_manager.h"
#include "chrome/browser/ui/browser_window/public/browser_window_features.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/find_bar/find_bar.h"
#include "chrome/browser/ui/find_bar/find_bar_controller.h"
#include "chrome/browser/ui/location_bar/location_bar.h"
#include "chrome/browser/ui/views/bubble_anchor_util_views.h"
#include "chrome/browser/ui/views/download/download_in_progress_dialog_view.h"
#include "chrome/browser/ui/exclusive_access/exclusive_access_context.h"
#include "chrome/browser/ui/exclusive_access/exclusive_access_manager.h"
#include "chrome/browser/ui/exclusive_access/fullscreen_controller.h"
#include "chrome/browser/ui/views/exclusive_access/exclusive_access_bubble_views.h"
#include "chrome/browser/ui/views/exclusive_access/exclusive_access_bubble_views_context.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/window_metadata/window_metadata_controller.h"
#include "components/input/native_web_keyboard_event.h"
#include "components/find_in_page/find_notification_details.h"
#include "components/find_in_page/find_tab_helper.h"
#include "components/web_modal/web_contents_modal_dialog_host.h"
#include "content/public/browser/eye_dropper.h"
#include "content/public/browser/keyboard_event_processing_result.h"
#include "content/public/browser/web_contents.h"
#include "ui/base/mojom/window_show_state.mojom.h"
#include "ui/base/accelerators/accelerator.h"
#include "ui/display/types/display_constants.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/geometry/size.h"
#include "ui/gfx/range/range.h"
#include "ui/gfx/animation/slide_animation.h"
#include "ui/views/widget/widget.h"
#include "ui/views/widget/widget_delegate.h"
#include "ui/views/view.h"

// Adapted from Ardia's GPL-3.0 ac_location_bar.mm and ac_browser_window.h.
class AraratLocationBar : public LocationBar {
 public:
  AraratLocationBar(BrowserWindowInterface* browser, AraratWindowHostCore* host)
      : LocationBar(nullptr), browser_(browser), host_(host) {}
  ~AraratLocationBar() override = default;
  void FocusLocation(bool user, bool) override { if (user && host_->window() && host_->window()->browser() == browser_) host_->ShowCommandBar(false); }
  void FocusSearch() override { if (host_->window() && host_->window()->browser() == browser_) host_->ShowCommandBar(true); }
  void UpdateFocusBehavior(bool) override {}
  void UpdateContentSettingsIcons() override {}
  void SaveStateToContents(content::WebContents*) override {}
  void Revert() override {}
  OmniboxView* GetOmniboxView() override { return nullptr; }
  OmniboxPopupView* GetOmniboxPopupView() override { return nullptr; }
  OmniboxController* GetOmniboxController() override { return nullptr; }
  bool ShouldCloseOmniboxPopup(ui::MouseEvent*) override { return false; }
  content::WebContents* GetWebContents() override { return browser_->GetTabStripModel()->GetActiveWebContents(); }
  LocationBarModel* GetLocationBarModel() override { return nullptr; }
  std::optional<bubble_anchor_util::AnchorConfiguration> GetChipAnchor() override { return std::nullopt; }
  ChipController* GetChipController() override { return nullptr; }
  void AnnounceAlert(const std::u16string&) override {}
  void OnChanged() override {}
  void UpdateWithoutTabRestore() override {}
  ui::TrackedElement* GetAnchorOrNull() override { return nullptr; }
  BrowserWindowInterface* GetBrowser() override { return browser_; }
  Profile* GetProfile() override { return browser_->GetProfile(); }
  bool IsInitialized() const override { return true; }
  bool IsVisible() const override { return false; }
  bool IsDrawn() const override { return false; }
  bool IsFullscreen() const override { return host_->IsFullscreen(); }
  bool IsEditingOrEmpty() const override { return false; }
  bool IsMouseHovered() const override { return false; }
  bool IsFocusWithin() const override { return false; }
  void InvalidateLayout() override {}
  gfx::Rect Bounds() const override { return {}; }
  gfx::Rect BoundsInScreen() const override { return {}; }
  gfx::Size MinimumSize() const override { return {}; }
  gfx::Size PreferredSize() const override { return {}; }
  void Update(content::WebContents*) override {}
  void ResetTabState(content::WebContents*) override {}
  bool HasSecurityStateChanged() override { return false; }
  LocationBarTesting* GetLocationBarForTesting() override { return nullptr; }
 private:
  raw_ptr<BrowserWindowInterface> browser_;
  raw_ptr<AraratWindowHostCore> host_;
};
namespace {
unsigned long g_exclusive_input_count = 0;
class AraratFindBar : public FindBar {
 public:
  AraratFindBar(BrowserWindowInterface* browser, AraratWindowHostCore* host)
      : browser_(browser), host_(host) {}
  ~AraratFindBar() override { visible_ = false; Publish(false); }
  FindBarController* GetFindBarController() const override { return controller_; }
  void SetFindBarController(FindBarController* controller) override { controller_ = controller; }
  void Show(bool, bool focus) override { bool changed = !visible_; visible_ = true; SetFocused(focus); Publish(focus); if (changed && controller_) controller_->OnFindBarVisibilityChanged(); }
  void Hide(bool) override { bool changed = visible_; visible_ = false; SetFocused(false); Publish(false); if (changed && controller_) controller_->OnFindBarVisibilityChanged(); }
  void SetFocusAndSelection() override { SetFocused(true); Publish(true); }
  void ClearResults(const find_in_page::FindNotificationDetails&) override { matches_ = 0; ordinal_ = 0; request_id_ = 0; final_update_ = false; Publish(false); }
  void StopAnimation() override {}
  void MoveWindowIfNecessary() override { Publish(false); }
  void SetFindTextAndSelectedRange(const std::u16string& text, const gfx::Range& range) override {
    text_ = text; range_ = range; Publish(false);
  }
  std::u16string_view GetFindText() const override { return text_; }
  gfx::Range GetSelectedRange() const override { return range_; }
  void UpdateUIForFindResult(const find_in_page::FindNotificationDetails& result, const std::u16string& text) override {
    if (!text.empty()) text_ = text;
    matches_ = result.number_of_matches(); ordinal_ = result.active_match_ordinal();
    request_id_ = result.request_id(); final_update_ = result.final_update(); Publish(false);
  }
  void AudibleAlert() override {}
  bool IsFindBarVisible() const override { return visible_; }
  void RestoreSavedFocus() override { if (auto* contents = browser_->GetTabStripModel()->GetActiveWebContents()) contents->Focus(); }
  bool HasGlobalFindPasteboard() const override { return true; }
  void UpdateFindBarForChangedWebContents() override { Publish(false); }
  bool CanPopulateFromSelectedText() override { return true; }
  const FindBarTesting* GetFindBarTesting() const override { return nullptr; }
  bool HasFocus() const override { return visible_ && host_->FindBarHasFocus(browser_); }
  void CloseOverlappingBubbles() override {}
  views::Widget* GetHostWidget() override { return host_->widget(); }
 private:
  void SetFocused(bool focused) {
    if (auto* contents = browser_->GetTabStripModel()->GetActiveWebContents())
      if (auto* helper = find_in_page::FindTabHelper::FromWebContents(contents)) helper->set_find_ui_focused(focused);
  }
  void Publish(bool focus) { host_->UpdateFindBar(browser_, text_, range_.start(), range_.end(), matches_, ordinal_, request_id_, final_update_, visible_, focus); }
  raw_ptr<BrowserWindowInterface> browser_;
  raw_ptr<AraratWindowHostCore> host_;
  raw_ptr<FindBarController> controller_ = nullptr;
  std::u16string text_;
  gfx::Range range_;
  int matches_ = 0;
  int ordinal_ = 0;
  int request_id_ = 0;
  bool final_update_ = false;
  bool visible_ = false;
};
// Bubble lifecycle follows WebUIBrowserExclusiveAccessContext in Chromium.
class AraratExclusiveAccessContext : public ExclusiveAccessContext,
                                     public ExclusiveAccessBubbleViewsContext,
                                     public ui::AcceleratorProvider {
 public:
  AraratExclusiveAccessContext(BrowserWindowInterface* browser,
                               AraratWindowHostCore* host)
      : browser_(browser), host_(host) {}
  Profile* GetProfile() override { return browser_->GetProfile(); }
  bool IsFullscreen() const override { return host_->IsFullscreen(); }
  void UpdateUIForTabFullscreen() override {
    auto* manager = ExclusiveAccessManager::From(browser_);
    if (manager && host_->window() && host_->window()->browser() == browser_) {
      auto weak = weak_factory_.GetWeakPtr();
      host_->SetPageFullscreen(manager->fullscreen_controller()->IsWindowFullscreenForTabOrPending());
      if (weak && base::CommandLine::ForCurrentProcess()->HasSwitch("ararat-check")) {
        base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
            FROM_HERE, base::BindOnce(&AraratExclusiveAccessContext::SynchronizeForCheck,
                                      weak));
      }
    }
  }
  void EnterFullscreen(const url::Origin&, ExclusiveAccessBubbleType,
                       FullscreenTabParams params) override {
    if (!IsFullscreen() || params.display_id != display::kInvalidDisplayId)
      host_->SetFullscreen(true, params.display_id);
  }
  void ExitFullscreen() override {
    if (IsFullscreen()) host_->SetFullscreen(false, display::kInvalidDisplayId);
  }
  void UpdateExclusiveAccessBubble(
      const ExclusiveAccessBubbleParams& params,
      ExclusiveAccessBubbleHideCallback callback) override {
    auto weak = weak_factory_.GetWeakPtr();
    if (!params.has_download && params.type == EXCLUSIVE_ACCESS_BUBBLE_TYPE_NONE) {
      if (callback) std::move(callback).Run(ExclusiveAccessBubbleHideReason::kNotShown);
      if (!bubble_ || destruction_task_) return;
      bubble_->HideImmediately();
      destruction_task_ = tasks_.PostTask(
          base::SingleThreadTaskRunner::GetCurrentDefault().get(), FROM_HERE,
          base::BindOnce(&AraratExclusiveAccessContext::DestroyAnyExclusiveAccessBubble,
                         weak_factory_.GetWeakPtr()));
      return;
    }
    if (bubble_) {
      if (destruction_task_) {
        tasks_.TryCancel(*destruction_task_);
        destruction_task_.reset();
      }
      bubble_->Update(params, std::move(callback));
    } else {
      bubble_ = std::make_unique<ExclusiveAccessBubbleViews>(this, params, std::move(callback));
    }
    // Why not animate in hidden checks: the popup must not be ordered on screen.
    if (weak && bubble_ && base::CommandLine::ForCurrentProcess()->HasSwitch("ararat-check")) {
      bubble_->animation_for_test()->Reset();
      bubble_->GetView()->GetWidget()->Hide();
    }
  }
  bool IsExclusiveAccessBubbleDisplayed() const override {
    return bubble_ && (bubble_->IsShowing() || bubble_->IsVisible());
  }
  bool HasBubble() const { return bubble_ != nullptr; }
  bool BubbleVisibleOnScreen() const {
    return bubble_ && bubble_->GetView() && bubble_->GetView()->GetWidget() &&
           bubble_->GetView()->GetWidget()->IsVisibleOnScreen();
  }
  void OnExclusiveAccessUserInput() override {
    ++g_exclusive_input_count;
    if (bubble_) bubble_->OnUserInput();
  }
  content::WebContents* GetWebContentsForExclusiveAccess() override {
    return browser_->GetTabStripModel()->GetActiveWebContents();
  }
  bool CanUserEnterFullscreen() const override { return true; }
  bool CanUserExitFullscreen() const override { return true; }
  ExclusiveAccessManager* GetExclusiveAccessManager() override {
    return ExclusiveAccessManager::From(browser_);
  }
  ui::AcceleratorProvider* GetAcceleratorProvider() override { return this; }
  bool GetAcceleratorForCommandId(int command, ui::Accelerator* accelerator) const override {
    if (command != IDC_FULLSCREEN) return false;
    *accelerator = ui::Accelerator(ui::VKEY_F, ui::EF_CONTROL_DOWN | ui::EF_COMMAND_DOWN);
    return true;
  }
  gfx::NativeView GetBubbleParentView() const override { return host_->widget()->GetNativeView(); }
  gfx::Rect GetClientAreaBoundsInScreen() const override { return host_->widget()->GetClientAreaBoundsInScreen(); }
  bool IsImmersiveModeEnabled() const override { return false; }
  gfx::Rect GetTopContainerBoundsInScreen() override { return {}; }
  void DestroyAnyExclusiveAccessBubble() override {
    bubble_.reset();
    destruction_task_.reset();
  }

 private:
  void SynchronizeForCheck() { host_->SynchronizeFullscreenForCheck(); }
  raw_ptr<BrowserWindowInterface> browser_;
  raw_ptr<AraratWindowHostCore> host_;
  std::unique_ptr<ExclusiveAccessBubbleViews> bubble_;
  base::CancelableTaskTracker tasks_;
  std::optional<base::CancelableTaskTracker::TaskId> destruction_task_;
  base::WeakPtrFactory<AraratExclusiveAccessContext> weak_factory_{this};
};
}  // namespace

extern "C" __attribute__((visibility("default")))
unsigned long AraratExclusiveInputCount() {
  return g_exclusive_input_count;
}

AraratBrowserWindow::AraratBrowserWindow(BrowserWindowInterface* browser,
                                         AraratWindowHostCore* host)
    : browser_(browser), host_(host),
      devtools_controller_(std::make_unique<DevtoolsUIController>(browser, std::vector<raw_ptr<ContentsContainerView, DanglingUntriaged>>{})),
      location_bar_(std::make_unique<AraratLocationBar>(browser, host)),
      exclusive_access_(std::make_unique<AraratExclusiveAccessContext>(browser, host)),
      autofill_handler_(std::make_unique<AraratAutofillBubbleHandler>()),
      autofill_registration_(std::make_unique<ui::ScopedUnownedUserData<autofill::AutofillBubbleHandler>>(
          browser->GetUnownedUserDataHost(), *autofill_handler_)) {
  if (browser->GetType() == BrowserWindowInterface::TYPE_NORMAL && !browser->GetProfile()->IsOffTheRecord()) {
    extensions_ = std::make_unique<ararat::AraratExtensionsContainer>(
        browser, nullptr, base::BindRepeating([](AraratWindowHostCore* host) {
          return views::BubbleAnchor(host->extension_anchor());
        }, base::Unretained(host)));
    extensions_registration_ = std::make_unique<ui::ScopedUnownedUserData<ExtensionsContainer>>(
        browser->GetUnownedUserDataHost(), *extensions_);
  }
}
AraratBrowserWindow::~AraratBrowserWindow() {
  // Why here and not left implicit: BrowserWidget (~BrowserWidget) and
  // WebUIBrowserWindow both call this hook before their widget and features go
  // away, and BrowserWindowFeatures may read window state while it tears its
  // members down. Ararat's window is Browser::window_ itself and its widget
  // belongs to the host, so this is the same lifecycle point as theirs.
  browser_->GetFeatures().TearDownPreBrowserWindowDestruction();
  if (host_->window() == this) host_->SetShortcutWindow(nullptr, false);
  extensions_registration_.reset();
  extensions_.reset();
  devtools_controller_.reset();
  autofill_registration_.reset();
  host_->OnWindowDestroyed(browser_);
}
bool AraratBrowserWindow::HasExclusiveAccessBubbleForCheck() const {
  return static_cast<AraratExclusiveAccessContext*>(exclusive_access_.get())->HasBubble();
}
bool AraratBrowserWindow::IsExclusiveAccessBubbleVisibleForCheck() const {
  return static_cast<AraratExclusiveAccessContext*>(exclusive_access_.get())->BubbleVisibleOnScreen();
}
void AraratBrowserWindow::RequestClose() {
  UnloadController::From(browser_)->OnWindowClosing();
}

gfx::NativeWindow AraratBrowserWindow::GetNativeWindow() const {
  return host_->widget()->GetNativeWindow();
}

bool AraratBrowserWindow::IsOnCurrentWorkspace() const {
  return true;
}

bool AraratBrowserWindow::IsVisibleOnScreen() const {
  return host_->window() == this && host_->widget()->IsVisibleOnScreen();
}

void AraratBrowserWindow::SetTopControlsShownRatio(
    content::WebContents* web_contents,
    float ratio) {}

bool AraratBrowserWindow::DoBrowserControlsShrinkRendererSize(
    const content::WebContents* contents) const {
  return false;
}

ui::NativeTheme* AraratBrowserWindow::GetNativeTheme() {
  return host_->widget()->GetNativeTheme();
}

const ui::ThemeProvider* AraratBrowserWindow::GetThemeProvider() const {
  return &ThemeService::GetThemeProviderForProfile(browser_->GetProfile());
}

int AraratBrowserWindow::GetTopControlsHeight() const {
  return 0;
}

void AraratBrowserWindow::SetTopControlsGestureScrollInProgress(
    bool in_progress) {}

std::vector<StatusBubble*> AraratBrowserWindow::GetStatusBubbles() {
  return {};
}

void AraratBrowserWindow::UpdateTitleBar() {
  if (browser_->GetType() == BrowserWindowInterface::TYPE_DEVTOOLS) {
    auto* contents = browser_->GetTabStripModel()->GetActiveWebContents();
    host_->SetTitle(contents ? contents->GetTitle() : std::u16string());
    return;
  }
  host_->SetTitle(
      WindowMetadataController::From(browser_)->GetWindowTitleForCurrentTab(
          true));
}

void AraratBrowserWindow::UpdateLoadingAnimations(bool is_visible) {}

void AraratBrowserWindow::OnActiveTabChanged(content::WebContents* old_contents,
                                             content::WebContents* new_contents,
                                             int index,
                                             int reason) {
  if (extensions_) extensions_->SetWebContents(new_contents);
}

void AraratBrowserWindow::OnTabDetached(content::WebContents* contents,
                                        bool was_active) {}

gfx::Size AraratBrowserWindow::GetContentsSize() const {
  return host_->widget()->GetClientAreaBoundsInScreen().size();
}

void AraratBrowserWindow::SetContentsSize(const gfx::Size& size) {
  host_->widget()->SetSize(size);
}

autofill::AutofillBubbleHandler*
AraratBrowserWindow::GetAutofillBubbleHandler() {
  return autofill_handler_.get();
}

LocationBar* AraratBrowserWindow::GetLocationBar() const {
  return location_bar_.get();
}

ui::AcceleratorProvider* AraratBrowserWindow::GetAcceleratorProvider() {
  return this;
}

bool AraratBrowserWindow::GetAcceleratorForCommandId(int command, ui::Accelerator* accelerator) const {
  if (command == IDC_TASK_MANAGER || command == IDC_TASK_MANAGER_APP_MENU ||
      command == IDC_TASK_MANAGER_CONTEXT_MENU || command == IDC_TASK_MANAGER_MAIN_MENU)
    command = IDC_TASK_MANAGER_SHORTCUT;
  return GetDefaultMacAcceleratorForCommandId(command, accelerator);
}

PinnedToolbarActions* AraratBrowserWindow::GetPinnedToolbarActions() {
  // Why not now: send-tab CHECKs null actions; the toolbar is pending.
  return nullptr;
}

void AraratBrowserWindow::SetFocusToLocationBar(bool is_user_initiated) {
  if (is_user_initiated && host_->window() == this) host_->ShowCommandBar(false);
}

void AraratBrowserWindow::UpdateReloadStopState(bool is_loading, bool force) {}

void AraratBrowserWindow::UpdateToolbar(content::WebContents* contents) {}

bool AraratBrowserWindow::UpdateToolbarSecurityState() {
  return false;
}

void AraratBrowserWindow::UpdateCustomTabBarVisibility(bool visible,
                                                       bool animate) {}

void AraratBrowserWindow::ResetToolbarTabState(content::WebContents* contents) {
}

void AraratBrowserWindow::FocusToolbar() {}

void AraratBrowserWindow::ToolbarSizeChanged(bool is_animating) {}

void AraratBrowserWindow::TabDraggingStatusChanged(bool is_dragging) {}

void AraratBrowserWindow::LinkOpeningFromGesture(
    WindowOpenDisposition disposition) {}

void AraratBrowserWindow::FocusAppMenu() {}

bool AraratBrowserWindow::IsTabStripEditable() const {
  return tab_strip_editable_;
}

void AraratBrowserWindow::DisableTabStripEditingForTesting() {
  tab_strip_editable_ = false;
}

bool AraratBrowserWindow::IsToolbarVisible() const {
  return extensions_ != nullptr;
}

bool AraratBrowserWindow::IsToolbarShowing() const {
  return false;
}

bool AraratBrowserWindow::IsLocationBarVisible() const {
  return false;
}

void AraratBrowserWindow::ShowUpdateChromeDialog() {}

void AraratBrowserWindow::ShowIntentPickerBubble(
    std::vector<apps::IntentPickerAppInfo> app_info,
    bool show_stay_in_chrome,
    bool show_remember_selection,
    apps::IntentPickerBubbleType bubble_type,
    const std::optional<url::Origin>& initiating_origin,
    IntentPickerResponse callback) {
  std::move(callback).Run("", apps::PickerEntryType::kUnknown,
                          apps::IntentPickerCloseReason::ERROR_BEFORE_PICKER,
                          false);
}

void AraratBrowserWindow::ShowBookmarkBubble(const GURL& url,
                                             bool already_bookmarked) {}

ShowTranslateBubbleResult AraratBrowserWindow::ShowTranslateBubble(
    content::WebContents* contents,
    translate::TranslateStep step,
    const std::string& source_language,
    const std::string& target_language,
    translate::TranslateErrors error_type,
    bool is_user_gesture) {
  return ShowTranslateBubbleResult::kBrowserWindowNotValid;
}

DownloadBubbleUIController*
AraratBrowserWindow::GetDownloadBubbleUIController() {
  // Why not now: download scanning crashes on null; download UI is pending.
  return nullptr;
}

void AraratBrowserWindow::ConfirmBrowserCloseWithPendingDownloads(
    int download_count,
    UnloadController::DownloadCloseType dialog_type,
    base::OnceCallback<void(bool)> callback) {
  if (base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check") == "download-close") {
    std::fprintf(stderr, "ararat-trace: download-close showing confirmation count=%d type=%d\n", download_count, static_cast<int>(dialog_type));
    callback = base::BindOnce([](base::OnceCallback<void(bool)> next, bool cancel) {
      std::fprintf(stderr, "ararat-trace: download-close dialog callback cancel=%d\n", cancel);
      std::move(next).Run(cancel);
    }, std::move(callback));
  }
  DownloadInProgressDialogView::Show(GetNativeWindow(), download_count,
                                     dialog_type, std::move(callback));
}

void AraratBrowserWindow::ShowAppMenu() {}

void AraratBrowserWindow::PreHandleDragUpdate(
    const content::DropData& drop_data,
    const gfx::PointF& point) {}

void AraratBrowserWindow::PreHandleDragExit() {}

void AraratBrowserWindow::HandleDragEnded() {}

content::KeyboardEventProcessingResult
AraratBrowserWindow::PreHandleKeyboardEvent(
    const input::NativeWebKeyboardEvent& event) {
  return AraratIsKeyboardShortcut(event) ? content::KeyboardEventProcessingResult::NOT_HANDLED_IS_SHORTCUT : content::KeyboardEventProcessingResult::NOT_HANDLED;
}

bool AraratBrowserWindow::HandleKeyboardEvent(
    const input::NativeWebKeyboardEvent& event) {
  return AraratRedispatchKeyboardEvent(host_, event);
}

std::unique_ptr<FindBar> AraratBrowserWindow::CreateFindBar() {
  return std::make_unique<AraratFindBar>(browser_, host_);
}

web_modal::WebContentsModalDialogHost*
AraratBrowserWindow::GetWebContentsModalDialogHost() {
  return host_->modal_dialog_host();
}

web_modal::WebContentsModalDialogHost*
AraratBrowserWindow::GetWebContentsModalDialogHostFor(
    content::WebContents* web_contents) {
  return host_->modal_dialog_host_for(web_contents);
}

void AraratBrowserWindow::ShowAvatarBubbleFromAvatarButton(
    bool is_source_accelerator) {}

void AraratBrowserWindow::ShowHatsDialog(
    const std::string& site_id,
    const std::optional<std::string>& hats_histogram_name,
    const std::optional<uint64_t> hats_survey_ukm_id,
    base::OnceClosure success_callback,
    base::OnceClosure failure_callback,
    const SurveyBitsData& product_specific_bits_data,
    const SurveyStringData& product_specific_string_data) {
  if (failure_callback)
    std::move(failure_callback).Run();
}

ExclusiveAccessContext* AraratBrowserWindow::GetExclusiveAccessContext() {
  return exclusive_access_.get();
}

std::string AraratBrowserWindow::GetWorkspace() const {
  return {};
}

bool AraratBrowserWindow::IsVisibleOnAllWorkspaces() const {
  return false;
}

void AraratBrowserWindow::ShowEmojiPanel() {}

std::unique_ptr<content::EyeDropper> AraratBrowserWindow::OpenEyeDropper(
    content::RenderFrameHost* frame,
    content::EyeDropperListener* listener) {
  return {};
}

void AraratBrowserWindow::ShowCaretBrowsingDialog() {}

void AraratBrowserWindow::CreateTabSearchBubble() {}

void AraratBrowserWindow::CloseTabSearchBubble() {}

void AraratBrowserWindow::ShowIncognitoClearBrowsingDataDialog() {}

void AraratBrowserWindow::ShowIncognitoHistoryDisclaimerDialog() {}

bool AraratBrowserWindow::IsUnframedModeEnabled() const {
  return false;
}

bool AraratBrowserWindow::GetCanResize() {
  return host_->widget()->widget_delegate()->CanResize();
}

ui::mojom::WindowShowState AraratBrowserWindow::GetWindowShowState() const {
  if (IsFullscreen())
    return ui::mojom::WindowShowState::kFullscreen;
  if (IsMaximized())
    return ui::mojom::WindowShowState::kMaximized;
  if (IsMinimized())
    return ui::mojom::WindowShowState::kMinimized;
  return ui::mojom::WindowShowState::kNormal;
}

void AraratBrowserWindow::ShowChromeLabs() {}

BrowserView* AraratBrowserWindow::AsBrowserView() {
  return nullptr;
}

void AraratBrowserWindow::Show() {
  if (host_->closed() || host_->closing()) return;
  host_->ShowBrowserProfile(browser_);
  if (base::CommandLine::ForCurrentProcess()->HasSwitch("ararat-check")) return;
  if (host_->window() == this) host_->widget()->Show();
}

void AraratBrowserWindow::ShowInactive() {
  if (base::CommandLine::ForCurrentProcess()->HasSwitch("ararat-check")) return;
  if (host_->window() == this) host_->widget()->ShowInactive();
}

void AraratBrowserWindow::Hide() {
  if (host_->window() == this) host_->widget()->Hide();
}

bool AraratBrowserWindow::IsVisible() const {
  return host_->window() == this && host_->widget()->IsVisible();
}

void AraratBrowserWindow::SetBounds(const gfx::Rect& bounds) {
  host_->widget()->SetBounds(bounds);
}

void AraratBrowserWindow::Close() {
  RequestClose();
}

void AraratBrowserWindow::Activate() {
  if (host_->closed() || host_->closing() || browser_->IsDeleteScheduled()) return;
  host_->ShowBrowserProfile(browser_);
  if (host_->closed() || host_->closing() || browser_->IsDeleteScheduled()) return;
  if (host_->window() == this) {
    if (auto* manager = BrowserActiveStateManager::From(browser_))
      manager->DidBecomeActive();
  }
  if (base::CommandLine::ForCurrentProcess()->HasSwitch("ararat-check")) return;
  host_->widget()->Activate();
}

void AraratBrowserWindow::Deactivate() {
  if (host_->window() == this) host_->widget()->Deactivate();
}

bool AraratBrowserWindow::IsActive() const {
  return host_->window() == this && host_->widget()->IsActive();
}

gfx::Rect AraratBrowserWindow::GetBounds() const {
  return host_->widget()->GetWindowBoundsInScreen();
}

bool AraratBrowserWindow::IsMaximized() const {
  return host_->widget()->IsMaximized();
}

bool AraratBrowserWindow::IsMinimized() const {
  return host_->window() == this && host_->widget()->IsMinimized();
}

bool AraratBrowserWindow::IsFullscreen() const {
  return host_->IsFullscreen();
}

gfx::Rect AraratBrowserWindow::GetRestoredBounds() const {
  return host_->widget()->GetRestoredBounds();
}

ui::mojom::WindowShowState AraratBrowserWindow::GetRestoredState() const {
  return ui::mojom::WindowShowState::kNormal;
}

void AraratBrowserWindow::Maximize() {
  host_->widget()->Maximize();
}

void AraratBrowserWindow::Minimize() {
  host_->widget()->Minimize();
}

void AraratBrowserWindow::Restore() {
  host_->widget()->Restore();
}

void AraratBrowserWindow::FlashFrame(bool flash) {
  host_->widget()->FlashFrame(flash);
}

ui::ZOrderLevel AraratBrowserWindow::GetZOrderLevel() const {
  return host_->widget()->GetZOrderLevel();
}

void AraratBrowserWindow::SetZOrderLevel(ui::ZOrderLevel order) {
  host_->widget()->SetZOrderLevel(order);
}

const ui::ColorProvider* AraratBrowserWindow::GetColorProvider() const {
  return host_->widget()->GetColorProvider();
}

void AraratBrowserWindow::DeleteBrowserWindow() {
  delete this;
}
