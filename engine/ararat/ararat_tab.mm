#include "ararat/core/ararat_tab.h"

#include <memory>

#include "ararat/core/public/ARWindowHost.h"
#include "base/check.h"
#include "base/functional/callback.h"
#include "base/strings/sys_string_conversions.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/common/isolated_world_ids.h"
#include "content/public/browser/web_contents_observer.h"
#include "url/gurl.h"

namespace {
class TabContentsObserver : public content::WebContentsObserver {
 public:
  TabContentsObserver(content::WebContents* contents, ARTab* tab)
      : tab_(tab) { Observe(contents); }
  void Stop() { Observe(nullptr); }
  void DidFinishNavigation(content::NavigationHandle*) override { [tab_ navigationFinished]; }
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

- (void)navigationFinished {
  ++navigation_count_;
  [self refresh];
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
