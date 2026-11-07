#ifndef ARARAT_ARARAT_WINDOW_HOST_H_
#define ARARAT_ARARAT_WINDOW_HOST_H_

#include <memory>
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
class BrowserWindowInterface;
class Profile;

namespace views {
class NativeViewHost;
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
  bool closing() const { return closing_; }
  bool closed() const { return closed_; }
  bool popup() const { return popup_; }
  const std::string& profile_name() const { return profile_name_; }
  void SetProfileName(std::string name) { profile_name_ = std::move(name); }
  void SetTitle(const std::u16string& title);
  void AttachPage(gfx::NativeView view);
  void PositionPage(const gfx::Rect& rect);
  void ShowBrowserProfile(BrowserWindowInterface* browser);

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
  std::map<std::string, raw_ptr<AraratBrowserWindow>> windows_;
  std::set<std::string> close_warnings_confirmed_;
  bool closing_ = false;
  bool closed_ = false;
  bool popup_ = false;
  std::string profile_name_ = "Default";
  void* owner_;
  base::WeakPtrFactory<AraratWindowHostCore> weak_factory_{this};
};

bool AraratUsesSharedCompositor();
bool AraratHandleMenuKey(gfx::NativeEvent event);
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
@end
#endif  // __OBJC__

#endif  // ARARAT_ARARAT_WINDOW_HOST_H_
