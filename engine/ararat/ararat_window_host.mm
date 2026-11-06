
#include "ararat/core/ararat_window_host.h"

#import <AppKit/AppKit.h>

#include <utility>

#include "ararat/core/ararat_browser_window.h"
#include "ararat/core/ararat_hooks.h"
#include "base/check.h"
#include "chrome/browser/ui/browser_window.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/views/controls/native/native_view_host.h"
#include "ui/views/layout/fill_layout.h"
#include "ui/views/view.h"
#include "ui/views/widget/widget.h"
#include "ui/views/widget/widget_delegate.h"

namespace {

BrowserWindow* AraratCreateBrowserWindowForPendingHost(
    BrowserWindowInterface* browser);

AraratWindowHostCore* g_pending_window_host = nullptr;

void AraratSetPendingWindowHost(AraratWindowHostCore* host) {
  g_pending_window_host = host;
  g_ararat_create_browser_window =
      host ? &AraratCreateBrowserWindowForPendingHost : nullptr;
}

AraratWindowHostCore* AraratTakePendingWindowHost() {
  AraratWindowHostCore* host = g_pending_window_host;
  g_pending_window_host = nullptr;
  g_ararat_create_browser_window = nullptr;
  return host;
}

BrowserWindow* AraratCreateBrowserWindowForPendingHost(
    BrowserWindowInterface* browser) {
  AraratWindowHostCore* core = AraratTakePendingWindowHost();
  if (!core) {
    return nullptr;
  }
  auto* window = new AraratBrowserWindow(browser, core);
  core->SetWindow(window);
  return window;
}

}  // namespace

AraratWindowHostCore::AraratWindowHostCore(gfx::NativeView app_content_view) {
  delegate_ = std::make_unique<views::WidgetDelegate>();
  delegate_->SetCanResize(true);
  delegate_->SetCanMaximize(true);
  auto contents = std::make_unique<views::View>();
  contents->SetLayoutManager(std::make_unique<views::FillLayout>());
  auto* native_host =
      contents->AddChildView(std::make_unique<views::NativeViewHost>());
  delegate_->SetContentsView(std::move(contents));
  widget_ = std::make_unique<views::Widget>();
  views::Widget::InitParams params(
      views::Widget::InitParams::CLIENT_OWNS_WIDGET);
  params.delegate = delegate_.get();
  params.name = "AraratWindowHost";
  params.bounds = gfx::Rect(0, 0, 800, 600);
  params.remove_standard_frame = true;
  widget_->Init(std::move(params));
  native_host->Attach(app_content_view);
  widget_->LayoutRootViewIfNecessary();
}

AraratWindowHostCore::~AraratWindowHostCore() {
  CHECK(!window_);
  if (g_pending_window_host == this) {
    g_pending_window_host = nullptr;
    g_ararat_create_browser_window = nullptr;
  }
}

gfx::NativeWindow AraratWindowHostCore::GetNativeWindow() const {
  return widget_->GetNativeWindow();
}

void AraratWindowHostCore::SetTitle(const std::u16string& title) {
  delegate_->SetTitle(title);
}

void AraratWindowHostCore::Close() {
  if (window_) {
    window_->RequestClose();
  } else {
    widget_->Close();
  }
}

void AraratWindowHostCore::SetPending() {
  AraratSetPendingWindowHost(this);
}

void AraratWindowHostCore::SetWindow(AraratBrowserWindow* window) {
  window_ = window;
}

void AraratWindowHostCore::OnWindowDestroyed() {
  window_ = nullptr;
}

@implementation ARWindowHost {
  std::unique_ptr<AraratWindowHostCore> core_;
}

- (instancetype)initWithContentView:(NSView*)content_view {
  self = [super init];
  if (self) {
    core_ =
        std::make_unique<AraratWindowHostCore>(gfx::NativeView(content_view));
  }
  return self;
}

- (NSWindow*)window {
  return core_->GetNativeWindow().GetNativeNSWindow();
}

- (void)close {
  core_->Close();
}

- (void)makePending {
  core_->SetPending();
}

- (BOOL)hasBrowser {
  return core_->window() != nullptr;
}

@end
