#include "ararat/core/ararat_browser_window.h"

#include <utility>

#include "ararat/core/ararat_window_host.h"
#include "ararat/core/ararat_autofill_bubble_handler.h"
#include "ararat/core/ararat_extensions_container.h"
#include "base/functional/bind.h"
#include "base/command_line.h"
#include "base/functional/callback.h"
#include "chrome/browser/devtools/devtools_ui_controller.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/themes/theme_service.h"
#include "chrome/browser/ui/browser_active_state_manager/browser_active_state_manager.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/find_bar/find_bar.h"
#include "chrome/browser/ui/exclusive_access/exclusive_access_context.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/window_metadata/window_metadata_controller.h"
#include "components/input/native_web_keyboard_event.h"
#include "components/web_modal/web_contents_modal_dialog_host.h"
#include "content/public/browser/eye_dropper.h"
#include "content/public/browser/keyboard_event_processing_result.h"
#include "content/public/browser/web_contents.h"
#include "ui/base/mojom/window_show_state.mojom.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/geometry/size.h"
#include "ui/views/widget/widget.h"
#include "ui/views/widget/widget_delegate.h"

namespace {
unsigned long g_exclusive_input_count = 0;
class AraratExclusiveAccessContext : public ExclusiveAccessContext {
 public:
  AraratExclusiveAccessContext(BrowserWindowInterface* browser,
                               AraratWindowHostCore* host)
      : browser_(browser), host_(host) {}
  Profile* GetProfile() override { return browser_->GetProfile(); }
  bool IsFullscreen() const override { return host_->widget()->IsFullscreen(); }
  void EnterFullscreen(const url::Origin&, ExclusiveAccessBubbleType,
                       FullscreenTabParams) override {
    host_->widget()->SetFullscreen(true);
  }
  void ExitFullscreen() override { host_->widget()->SetFullscreen(false); }
  void UpdateExclusiveAccessBubble(
      const ExclusiveAccessBubbleParams&,
      ExclusiveAccessBubbleHideCallback callback) override {
    if (callback)
      std::move(callback).Run(ExclusiveAccessBubbleHideReason::kNotShown);
  }
  bool IsExclusiveAccessBubbleDisplayed() const override { return false; }
  void OnExclusiveAccessUserInput() override { ++g_exclusive_input_count; }
  content::WebContents* GetWebContentsForExclusiveAccess() override {
    return browser_->GetTabStripModel()->GetActiveWebContents();
  }
  bool CanUserEnterFullscreen() const override { return true; }
  bool CanUserExitFullscreen() const override { return true; }

 private:
  raw_ptr<BrowserWindowInterface> browser_;
  raw_ptr<AraratWindowHostCore> host_;
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
  extensions_registration_.reset();
  extensions_.reset();
  devtools_controller_.reset();
  autofill_registration_.reset();
  host_->OnWindowDestroyed(browser_);
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
  // Why not now: null crashes bubble anchors; U16 owns the location bar.
  return nullptr;
}

ui::AcceleratorProvider* AraratBrowserWindow::GetAcceleratorProvider() {
  // Why not implement it yet: new-tab shortcuts crash on null; U16 owns it.
  return nullptr;
}

PinnedToolbarActions* AraratBrowserWindow::GetPinnedToolbarActions() {
  // Why not now: send-tab CHECKs null actions; the toolbar is pending.
  return nullptr;
}

void AraratBrowserWindow::SetFocusToLocationBar(bool is_user_initiated) {}

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
  std::move(callback).Run(false);
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
  if (event.windows_key_code == 'F' &&
      (event.GetModifiers() & blink::WebInputEvent::kMetaKey) &&
      !AraratKeyEventFromDevTools(event.os_event))
    return content::KeyboardEventProcessingResult::HANDLED;
  return content::KeyboardEventProcessingResult::NOT_HANDLED;
}

bool AraratBrowserWindow::HandleKeyboardEvent(
    const input::NativeWebKeyboardEvent& event) {
  return AraratHandleMenuKey(event.os_event);
}

std::unique_ptr<FindBar> AraratBrowserWindow::CreateFindBar() {
  // Why not implement it yet: FindBarController crashes on null; U16 owns it.
  return {};
}

web_modal::WebContentsModalDialogHost*
AraratBrowserWindow::GetWebContentsModalDialogHost() {
  return host_->modal_dialog_host();
}

web_modal::WebContentsModalDialogHost*
AraratBrowserWindow::GetWebContentsModalDialogHostFor(
    content::WebContents* web_contents) {
  return host_->modal_dialog_host();
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
  return host_->widget()->IsFullscreen();
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
