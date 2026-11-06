#ifndef ARARAT_ARARAT_WINDOW_HOST_H_
#define ARARAT_ARARAT_WINDOW_HOST_H_

#include <memory>
#include <string>

#include "base/callback_list.h"
#include "base/memory/raw_ptr.h"
#include "ui/gfx/native_ui_types.h"
#include "ui/gfx/geometry/rect.h"

class AraratBrowserWindow;
class BrowserWindowInterface;

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
  AraratBrowserWindow* window() const { return window_; }
  views::Widget* widget() const { return widget_.get(); }
  bool closing() const { return closing_; }
  bool closed() const { return closed_; }
  void SetTitle(const std::u16string& title);
  void AttachPage(gfx::NativeView view);
  void PositionPage(const gfx::Rect& rect);

  void Close();

  void SetPending();
  void ClearPending();

  void SetWindow(AraratBrowserWindow* window);
  void OnWindowDestroyed(BrowserWindowInterface* browser);

 private:
  std::unique_ptr<views::WidgetDelegate> delegate_;
  std::unique_ptr<views::Widget> widget_;
  raw_ptr<views::NativeViewHost> page_host_ = nullptr;
  raw_ptr<AraratBrowserWindow> window_;
  bool closing_ = false;
  bool closed_ = false;
  base::CallbackListSubscription close_cancelled_;
  void* owner_;
};

bool AraratUsesSharedCompositor();

#ifdef __OBJC__
#import "ararat/core/public/ARWindowHost.h"
@interface ARWindowHost ()
- (BOOL)hasBrowser;
- (void)browserCreated:(BrowserWindowInterface*)browser;
- (void)browserDestroyed:(BrowserWindowInterface*)browser;
@end
#endif  // __OBJC__

#endif  // ARARAT_ARARAT_WINDOW_HOST_H_
