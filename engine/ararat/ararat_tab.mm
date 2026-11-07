#include "ararat/core/ararat_tab.h"

#include <memory>
#include <cstdio>

#include "ararat/core/public/ARWindowHost.h"
#include "base/check.h"
#include "base/command_line.h"
#include "base/functional/callback.h"
#include "base/functional/bind.h"
#include "base/values.h"
#include "base/strings/sys_string_conversions.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/common/isolated_world_ids.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/navigation_handle.h"
#include "url/gurl.h"

namespace {
class TabContentsObserver : public content::WebContentsObserver {
 public:
  TabContentsObserver(content::WebContents* contents, ARTab* tab)
      : tab_(tab) { Observe(contents); }
  void Stop() { Observe(nullptr); }
  void DidFinishNavigation(content::NavigationHandle* navigation) override {
    if (navigation->HasCommitted() && navigation->IsInPrimaryMainFrame()) [tab_ navigationFinished];
  }
  void DidStartLoading() override { [tab_ refresh]; }
  void DidStopLoading() override { [tab_ refresh]; }
  void TitleWasSet(content::NavigationEntry*) override { [tab_ refresh]; }
  void WebContentsDestroyed() override { [tab_ invalidate]; }

 private:
  __weak ARTab* tab_;
};
}  // namespace

@implementation ARTab {
  __weak ARWindowHost* host_;
  content::WebContents* contents_;
  std::unique_ptr<TabContentsObserver> observer_;
  NSString* live_id_;
  NSString* title_;
  NSString* url_;
  BOOL loading_;
  NSUInteger navigation_count_;
  BOOL navigation_pending_;
  BOOL check_opener_alive_;
}

- (instancetype)initWithContents:(content::WebContents*)contents
                          liveId:(NSString*)liveId
                            host:(ARWindowHost*)host {
  self = [super init];
  if (self) {
    host_ = host;
    contents_ = contents;
    live_id_ = [liveId copy];
    title_ = @"";
    url_ = @"";
    observer_ = std::make_unique<TabContentsObserver>(contents, self);
    [self refresh];
  }
  return self;
}

- (NSString*)liveId { DCHECK([NSThread isMainThread]); return live_id_; }
- (NSString*)itemId { DCHECK([NSThread isMainThread]); return [host_ itemIdForTab:self]; }
- (NSString*)title { DCHECK([NSThread isMainThread]); return title_; }
- (NSString*)url { DCHECK([NSThread isMainThread]); return url_; }
- (BOOL)isLoading { DCHECK([NSThread isMainThread]); return loading_; }
- (NSUInteger)navigationCount { DCHECK([NSThread isMainThread]); return navigation_count_; }
- (content::WebContents*)contents { return contents_; }

- (NSView*)view {
  DCHECK([NSThread isMainThread]);
  if (!contents_ || ![host_ isActiveTab:self]) return nil;
  NSView* view = contents_->GetNativeView().GetNativeNSView();
  return view.superview ? view : nil;
}

- (BOOL)sendCheckMouseMoved:(NSEvent*)event {
  DCHECK([NSThread isMainThread]);
  NSView* view = self.view;
  if (!view) return NO;
  [view mouseMoved:event];
  return YES;
}

- (void)prepareCheckBeforeUnload {
  if (!contents_) return;
  contents_->GetPrimaryMainFrame()->ExecuteJavaScriptWithUserGestureForTests(
      u"window.addEventListener('beforeunload', e => { e.preventDefault(); e.returnValue = ''; });",
      base::NullCallback(), content::ISOLATED_WORLD_ID_GLOBAL);
}

- (BOOL)checkHasBeforeUnload {
  return contents_ && contents_->NeedToFireBeforeUnloadOrUnloadEvents();
}

- (void)focusCheckPage {
  if (contents_) contents_->Focus();
}

- (void)openCheckPopup {
  auto* command_line = base::CommandLine::ForCurrentProcess();
  if (!contents_ || (command_line->GetSwitchValueASCII("ararat-check") != "popup" &&
                     command_line->GetSwitchValueASCII("ararat-screen") != "links")) return;
  contents_->GetPrimaryMainFrame()->ExecuteJavaScriptWithUserGestureForTests(
      u"const popup = window.open('', '', 'popup,width=400,height=300'); if (popup) popup.document.title = 'Popup';",
      base::NullCallback(), content::ISOLATED_WORLD_ID_GLOBAL);
}

- (void)probeCheckOpener {
  if (!contents_ || base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check") != "popup") return;
  __weak ARTab* tab = self;
  contents_->GetPrimaryMainFrame()->ExecuteJavaScriptForTests(
      u"!!window.opener && !window.opener.closed",
      base::BindOnce(^(base::Value result) {
        ARTab* strong_tab = tab;
        if (strong_tab) strong_tab->check_opener_alive_ = result.is_bool() && result.GetBool();
      }), content::ISOLATED_WORLD_ID_GLOBAL);
}

- (BOOL)checkOpenerAlive { return check_opener_alive_; }

- (void)closeCheckPopup {
  if (!contents_ || base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check") != "popup") return;
  contents_->GetPrimaryMainFrame()->ExecuteJavaScriptForTests(
      u"window.close()", base::NullCallback(), content::ISOLATED_WORLD_ID_GLOBAL);
}

- (void)checkFocusExtensionWindow {
  auto* command = base::CommandLine::ForCurrentProcess();
  if (!contents_ || (command->GetSwitchValueASCII("ararat-check") != "ext-windows" &&
                     command->GetSwitchValueASCII("ararat-screen") != "profiles")) return;
  contents_->GetPrimaryMainFrame()->ExecuteJavaScriptWithUserGestureForTests(
      u"location.hash = 'focus'", base::NullCallback(), content::ISOLATED_WORLD_ID_GLOBAL);
}

- (void)checkPrepareExtensionFocus {
  auto* command = base::CommandLine::ForCurrentProcess();
  if (!contents_ || (command->GetSwitchValueASCII("ararat-check") != "ext-windows" &&
                     command->GetSwitchValueASCII("ararat-screen") != "profiles")) return;
  contents_->GetPrimaryMainFrame()->ExecuteJavaScriptForTests(
      u"location.hash = 'prepare-focus'", base::NullCallback(), content::ISOLATED_WORLD_ID_GLOBAL);
}

- (void)checkPrepareExtensionWindows {
  if (!contents_ || base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check") != "ext-windows") return;
  contents_->GetPrimaryMainFrame()->ExecuteJavaScriptForTests(
      u"location.hash = 'prepare-hidden'", base::NullCallback(), content::ISOLATED_WORLD_ID_GLOBAL);
}

- (void)checkReportExtensionWindow {
  auto* command = base::CommandLine::ForCurrentProcess();
  if (!contents_ || (command->GetSwitchValueASCII("ararat-check") != "ext-windows" &&
                     command->GetSwitchValueASCII("ararat-screen") != "profiles")) return;
  contents_->GetPrimaryMainFrame()->ExecuteJavaScriptForTests(
      u"location.hash = location.hash === '#report' ? 'report2' : 'report'", base::NullCallback(), content::ISOLATED_WORLD_ID_GLOBAL);
}

- (void)checkReloadExtensionWindow {
  auto* command = base::CommandLine::ForCurrentProcess();
  if (!contents_ || (command->GetSwitchValueASCII("ararat-check") != "ext-windows" &&
                     command->GetSwitchValueASCII("ararat-screen") != "profiles")) return;
  std::fprintf(stderr, "ararat-trace: extension-probe reload\n");
  contents_->GetController().Reload(content::ReloadType::NORMAL, false);
}

- (void)navigationFinished {
  ++navigation_count_;
  navigation_pending_ = YES;
  [self refresh];
  [host_ tabMetadataChanged];
}

- (BOOL)takePendingNavigation {
  BOOL pending = navigation_pending_;
  navigation_pending_ = NO;
  return pending;
}

- (void)refresh {
  if (!contents_) return;
  NSString* title = base::SysUTF16ToNSString(contents_->GetTitle()) ?: @"";
  NSString* url = base::SysUTF8ToNSString(contents_->GetVisibleURL().spec()) ?: @"";
  BOOL loading = contents_->IsLoading();
  if (![title_ isEqualToString:title]) {
    [self willChangeValueForKey:@"title"];
    title_ = title;
    [self didChangeValueForKey:@"title"];
    [host_ tabMetadataChanged];
  }
  if (![url_ isEqualToString:url]) {
    [self willChangeValueForKey:@"url"];
    url_ = url;
    [self didChangeValueForKey:@"url"];
  }
  if (loading_ != loading) {
    [self willChangeValueForKey:@"isLoading"];
    loading_ = loading;
    [self didChangeValueForKey:@"isLoading"];
  }
}

- (void)invalidate {
  if (!contents_) return;
  [self willChangeValueForKey:@"view"];
  contents_ = nullptr;
  observer_->Stop();
  [self didChangeValueForKey:@"view"];
}

- (void)replaceContents:(content::WebContents*)contents {
  [self willChangeValueForKey:@"view"];
  observer_.reset();
  contents_ = contents;
  observer_ = std::make_unique<TabContentsObserver>(contents, self);
  [self refresh];
  [self didChangeValueForKey:@"view"];
}

- (void)activateWithCommandId:(NSString*)commandId {
  DCHECK([NSThread isMainThread]);
  if (contents_) [host_ activateTab:self commandId:commandId];
}

- (void)closeWithCommandId:(NSString*)commandId {
  DCHECK([NSThread isMainThread]);
  if (contents_) [host_ closeTab:self commandId:commandId];
}

- (void)setItemId:(NSString*)itemId {
  DCHECK([NSThread isMainThread]);
  if (contents_) [host_ setItemId:itemId forTab:self];
}
@end
