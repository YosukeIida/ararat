#ifndef ARARAT_ARARAT_WINDOW_HOST_H_
#define ARARAT_ARARAT_WINDOW_HOST_H_

#include <memory>
#include <string>

#include "base/memory/raw_ptr.h"
#include "ui/gfx/native_ui_types.h"

class AraratBrowserWindow;

namespace views {
class Widget;
class WidgetDelegate;
}  // namespace views

class AraratWindowHostCore {
 public:
  explicit AraratWindowHostCore(gfx::NativeView app_content_view);
  ~AraratWindowHostCore();

  AraratWindowHostCore(const AraratWindowHostCore&) = delete;
  AraratWindowHostCore& operator=(const AraratWindowHostCore&) = delete;

  gfx::NativeWindow GetNativeWindow() const;
  AraratBrowserWindow* window() const { return window_; }
  views::Widget* widget() const { return widget_.get(); }
  void SetTitle(const std::u16string& title);

  void Close();

  void SetPending();

  void SetWindow(AraratBrowserWindow* window);
  void OnWindowDestroyed();

 private:
  std::unique_ptr<views::WidgetDelegate> delegate_;
  std::unique_ptr<views::Widget> widget_;
  raw_ptr<AraratBrowserWindow> window_;
};

#ifdef __OBJC__
#import "ararat/core/public/ARWindowHost.h"
@interface ARWindowHost ()
- (BOOL)hasBrowser;
@end
#endif  // __OBJC__

#endif  // ARARAT_ARARAT_WINDOW_HOST_H_
