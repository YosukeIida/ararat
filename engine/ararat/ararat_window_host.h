#ifndef ARARAT_ARARAT_WINDOW_HOST_H_
#define ARARAT_ARARAT_WINDOW_HOST_H_

#include <memory>
#include <cstdint>
#include <map>
#include <set>
#include <string>
#include <utility>

#include "base/callback_list.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "ui/gfx/native_ui_types.h"
#include "ui/gfx/geometry/rect.h"

class AraratBrowserWindow;
class AraratModalDialogHost;
class BrowserWindowInterface;
class FullscreenController;
class Profile;
namespace content { class WebContents; }

namespace web_modal {
class WebContentsModalDialogHost;
}

namespace views {
class NativeViewHost;
class View;
class Widget;
class WidgetDelegate;
}  // namespace views

class AraratWindowHostCore {
 public:
  AraratWindowHostCore(gfx::NativeView app_content_view, void* owner);
  ~AraratWindowHostCore();

  AraratWindowHostCore(const AraratWindowHostCore&) = delete;
  AraratWindowHostCore& operator=(const AraratWindowHostCore&) = delete;

  gfx::NativeWindow GetNativeWindow() const;
  AraratBrowserWindow* window() const;
  AraratBrowserWindow* windowForProfile(const std::string& name) const;
  bool HasProfile(const std::string& name) const;
  const std::map<std::string, raw_ptr<AraratBrowserWindow>>& windows() const { return windows_; }
  views::Widget* widget() const { return widget_.get(); }
  views::View* extension_anchor() const { return extension_anchor_; }
  void SetExtensionAnchor(const gfx::Rect& bounds);
  bool closing() const { return closing_; }
  bool closed() const { return closed_; }
  bool popup() const { return popup_; }
  bool devtools() const { return devtools_; }
  const std::string& profile_name() const { return profile_name_; }
  void SetProfileName(std::string name) { profile_name_ = std::move(name); }
  void SetTitle(const std::u16string& title);
  void SetPageFullscreen(bool fullscreen);
  void SetWindowFullscreen(bool fullscreen);
  bool IsFullscreen() const;
  bool IsFullscreenTransitioning() const { return fullscreen_transitioning_; }
  void SetFullscreen(bool fullscreen, int64_t display_id);
  void FullscreenStateChanged();
  void FullscreenStateChanging();
  void FullscreenTransitionStarting();
  void SynchronizeFullscreenForCheck();
  void AttachPage(gfx::NativeView view);
  void PositionPage(const gfx::Rect& rect);
  web_modal::WebContentsModalDialogHost* modal_dialog_host() const;
  const gfx::Rect& page_rect() const { return page_rect_; }
  void ShowBrowserProfile(BrowserWindowInterface* browser);
  void DevToolsChanged(content::WebContents* inspected);

  void Close();

  void SetPending(const std::string& profile);
  void ClearPending();

  void SetWindow(AraratBrowserWindow* window);
  void OnWindowDestroyed(BrowserWindowInterface* browser);
  void OnCloseCancelled();
  void ConfirmClose();
  void CloseConfirmed(bool proceed);

 private:
  std::unique_ptr<views::WidgetDelegate> delegate_;
  std::unique_ptr<views::Widget> widget_;
  raw_ptr<views::NativeViewHost> page_host_ = nullptr;
  raw_ptr<views::View> extension_anchor_ = nullptr;
  gfx::Rect page_rect_;
  std::unique_ptr<AraratModalDialogHost> modal_dialog_host_;
  std::map<std::string, raw_ptr<AraratBrowserWindow>> windows_;
  std::set<std::string> close_warnings_confirmed_;
  bool closing_ = false;
  bool closed_ = false;
  bool popup_ = false;
  bool devtools_ = false;
  bool check_fullscreen_ = false;
  bool fullscreen_transitioning_ = false;
  uint64_t fullscreen_transition_generation_ = 0;
  base::WeakPtr<FullscreenController> fullscreen_transition_controller_;
  std::string profile_name_ = "Default";
  void* owner_;
  base::WeakPtrFactory<AraratWindowHostCore> weak_factory_{this};
};

bool AraratUsesSharedCompositor();
bool AraratHandleMenuKey(gfx::NativeEvent event);
bool AraratKeyEventFromDevTools(gfx::NativeEvent event);
unsigned long AraratStockBrowserCount();
bool AraratCheckDevToolsDestroyed();
void AraratInstallWindowFactory();
bool AraratHasHostCallback();
void* AraratRequestHost(bool popup, const std::string& profile, const gfx::Rect& bounds);

#ifdef __OBJC__
#import "ararat/core/public/ARWindowHost.h"
void AraratOpenOffTheRecordURLs(Profile* profile, NSArray* urls);
@interface ARWindowHost ()
- (BOOL)hasBrowser;
- (AraratWindowHostCore*)hostCore;
- (void)browserCreated:(BrowserWindowInterface*)browser;
- (void)browserDestroyed:(BrowserWindowInterface*)browser;
- (void)closeCancelled;
- (void)beginClosing;
- (void)showBrowserProfile:(BrowserWindowInterface*)browser;
- (void)showBrowserProfileForClose:(BrowserWindowInterface*)browser;
- (void)pinProfile:(Profile*)profile;
- (void)devToolsChanged:(content::WebContents*)inspected;
@end
#endif  // __OBJC__

#endif  // ARARAT_ARARAT_WINDOW_HOST_H_
