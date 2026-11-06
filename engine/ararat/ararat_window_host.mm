
#include "ararat/core/ararat_window_host.h"

#import <AppKit/AppKit.h>

#include <utility>
#include <set>

#include "ararat/core/ararat_browser_window.h"
#include "ararat/core/ararat_hooks.h"
#include "ararat/core/ararat_tab.h"
#include "base/check.h"
#include "base/functional/bind.h"
#include "base/no_destructor.h"
#include "base/process/process.h"
#include "base/supports_user_data.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
#include "chrome/browser/profiles/keep_alive/profile_keep_alive_types.h"
#include "chrome/browser/profiles/keep_alive/scoped_profile_keep_alive.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/ui/browser_tabstrip.h"
#include "chrome/browser/ui/browser_window.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/create_browser_window.h"
#include "chrome/browser/ui/tabs/tab_enums.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/tabs/tab_strip_model_observer.h"
#include "content/public/browser/web_contents.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/views/controls/native/native_view_host.h"
#include "ui/views/layout/fill_layout.h"
#include "ui/views/view.h"
#include "ui/views/widget/widget.h"
#include "ui/views/widget/widget_delegate.h"
#include "url/gurl.h"

namespace {

BrowserWindow* AraratCreateBrowserWindowForPendingHost(
    BrowserWindowInterface* browser);

AraratWindowHostCore* g_pending_window_host = nullptr;
std::set<BrowserWindowInterface*>& AraratWindows() {
  static base::NoDestructor<std::set<BrowserWindowInterface*>> windows;
  return *windows;
}

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
  AraratWindows().insert(browser);
  g_ararat_is_window = [](BrowserWindowInterface* candidate) {
    return AraratWindows().contains(candidate);
  };
  core->SetWindow(window);
  return window;
}

}  // namespace

AraratWindowHostCore::AraratWindowHostCore(gfx::NativeView app_content_view,
                                           void* owner)
    : owner_(owner) {
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
    closing_ = true;
    close_cancelled_ = window_->browser()->RegisterBrowserCloseCancelled(
        base::BindRepeating(
            [](AraratWindowHostCore* host, BrowserWindowInterface*,
               BrowserWindowInterface::ClosingStatus) { host->closing_ = false; },
            base::Unretained(this)));
    window_->RequestClose();
  } else {
    closed_ = true;
    widget_->Close();
  }
}

void AraratWindowHostCore::SetPending() {
  AraratSetPendingWindowHost(this);
}

void AraratWindowHostCore::ClearPending() {
  if (g_pending_window_host == this) AraratSetPendingWindowHost(nullptr);
}

void AraratWindowHostCore::SetWindow(AraratBrowserWindow* window) {
  window_ = window;
  __weak ARWindowHost* owner = (__bridge ARWindowHost*)owner_;
  BrowserWindowInterface* browser = window->browser();
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(^{ [owner browserCreated:browser]; }));
}

void AraratWindowHostCore::OnWindowDestroyed(BrowserWindowInterface* browser) {
  [(__bridge ARWindowHost*)owner_ browserDestroyed:browser];
  AraratWindows().erase(browser);
  window_ = nullptr;
  close_cancelled_ = {};
  if (closing_) {
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
- (void)stripChanged:(const TabStripModelChange&)change;
- (NSDictionary*)stripSnapshot;
- (void)emitCause:(id)cause;
- (void)emitOpenFailure:(NSString*)commandId;
- (void)transactionWithCause:(id)cause setEmptyReported:(BOOL)setEmptyReported;
- (void)syncTabs;
- (void)closeCancelled:(const tabs::TabInterface*)tab;
- (void)drainPendingOpens;
- (void)discardPendingOpens;
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
  std::unique_ptr<StripObserver> strip_observer_;
  std::unique_ptr<ScopedProfileKeepAlive> profile_keep_alive_;
  BrowserWindowInterface* browser_;
  NSMutableDictionary<NSValue*, ARTab*>* tabs_;
  NSMutableDictionary<NSValue*, NSString*>* pending_closes_;
  NSMutableArray<NSDictionary*>* pending_opens_;
  NSString* window_id_;
  NSString* command_id_;
  NSString* opening_item_;
  BOOL draining_opens_;
  BOOL emitted_change_;
  BOOL empty_reported_;
}

@synthesize delegate = _delegate;

- (instancetype)initWithContentView:(NSView*)content_view windowId:(NSString*)windowId {
  DCHECK([NSThread isMainThread]);
  self = [super init];
  if (self) {
    core_ =
        std::make_unique<AraratWindowHostCore>(gfx::NativeView(content_view),
                                               (__bridge void*)self);
    tabs_ = [NSMutableDictionary dictionary];
    pending_closes_ = [NSMutableDictionary dictionary];
    pending_opens_ = [NSMutableArray array];
    window_id_ = [windowId copy];
  }
  return self;
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
  if (!core_->window()) profile_keep_alive_.reset();
  core_->Close();
}

- (void)makePending {
  DCHECK([NSThread isMainThread]);
  core_->SetPending();
}

- (void)browserCreated:(BrowserWindowInterface*)browser {
  if (!core_->window() || core_->window()->browser() != browser || browser_) return;
  browser_ = browser;
  if (!profile_keep_alive_ && !core_->closing() && !core_->closed() &&
      !browser_->GetProfile()->IsOffTheRecord()) {
    // Reloading the profile in openURL: instead would build a new Profile
    // object and re-run its final init; kBrowserWindow has the same scope the
    // Browser's own keep-alive has, but outlives it: the host is the window.
    profile_keep_alive_ = ScopedProfileKeepAlive::TryAcquire(
        browser_->GetProfile(), ProfileKeepAliveOrigin::kBrowserWindow);
  }
  strip_observer_ = std::make_unique<StripObserver>(browser_->GetTabStripModel(), self);
  [self syncTabs];
  // Why not rely on the insert: a Chrome-routed Browser was populated before
  // this posted call attached the observer.
  if (!command_id_) [self emitCause:@"Chrome"];
}

- (void)browserDestroyed:(BrowserWindowInterface*)browser {
  if (browser_ && browser_ != browser) return;
  if (browser_) {
    strip_observer_.reset();
    browser_ = nullptr;
    [tabs_ removeAllObjects];
    if (core_->closing() || core_->closed()) {
      profile_keep_alive_.reset();
      if (pending_opens_.count) [self discardPendingOpens];
    }
    if (!empty_reported_) [self emitCause:@"Chrome"];
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
  if (!browser_) return @[];
  NSMutableArray<ARTab*>* result = [NSMutableArray array];
  TabStripModel* strip = browser_->GetTabStripModel();
  for (int i = 0; i < strip->count(); ++i) {
    ARTab* tab = tabs_[[NSValue valueWithPointer:strip->GetWebContentsAt(i)]];
    if (tab) [result addObject:tab];
  }
  return result;
}

- (BOOL)openURL:(NSString*)url commandId:(NSString*)commandId itemId:(NSString*)itemId {
  DCHECK([NSThread isMainThread]);
  if (core_->closed() || !g_epoch || !url || !commandId || !itemId) return NO;
  GURL parsed_url(url.UTF8String);
  if (!parsed_url.is_valid()) return NO;
  BrowserWindowInterface* closing_browser = core_->window() ? core_->window()->browser() : nullptr;
  if ((!draining_opens_ && pending_opens_.count) ||
      (closing_browser && closing_browser->IsDeleteScheduled())) {
    [pending_opens_ addObject:@{ @"url": [url copy], @"command": [commandId copy], @"item": [itemId copy] }];
    return YES;
  }
  BOOL new_browser = !core_->window();
  command_id_ = commandId;
  opening_item_ = itemId;
  emitted_change_ = NO;
  if (new_browser) {
    Profile* profile = ProfileManager::GetLastUsedProfileIfLoaded();
    if (!profile || GetBrowserWindowCreationStatusForProfile(*profile) != BrowserWindowInterface::CreationStatus::kOk) {
      command_id_ = nil; opening_item_ = nil;
      [self emitOpenFailure:commandId];
      return YES;
    }
    core_->SetPending();
    BrowserWindowInterface* browser = CreateBrowserWindow(BrowserWindowCreateParams(profile, true));
    if (!browser || !core_->window()) {
      core_->ClearPending();
      command_id_ = nil; opening_item_ = nil;
      [self emitOpenFailure:commandId];
      return YES;
    }
    [self browserCreated:browser];
  } else if (!browser_) {
    NSString* item = opening_item_;
    opening_item_ = nil;
    [self browserCreated:core_->window()->browser()];
    opening_item_ = item;
  }
  if (!browser_ || browser_->IsDeleteScheduled()) {
    command_id_ = nil; opening_item_ = nil;
    [self emitOpenFailure:commandId];
    return YES;
  }
  content::WebContents* contents = chrome::AddAndReturnTabAt(
      browser_, parsed_url, -1, true);
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
    if (browser_ && browser_->IsDeleteScheduled()) break;
    NSDictionary* open = pending_opens_.firstObject;
    [pending_opens_ removeObjectAtIndex:0];
    [self openURL:open[@"url"] commandId:open[@"command"] itemId:open[@"item"]];
  }
  draining_opens_ = NO;
  if (core_->closed()) [self discardPendingOpens];
}

- (void)discardPendingOpens {
  for (NSDictionary* open in pending_opens_) {
    [self emitOpenFailure:open[@"command"]];
  }
  [pending_opens_ removeAllObjects];
}

- (void)activateTab:(ARTab*)tab commandId:(NSString*)commandId {
  if (!g_epoch || !browser_ || !tab.contents || !commandId) return;
  TabStripModel* strip = browser_->GetTabStripModel();
  int index = strip->GetIndexOfWebContents(tab.contents);
  if (index == TabStripModel::kNoTab) return;
  command_id_ = commandId;
  emitted_change_ = NO;
  strip->ActivateTabAt(index);
  if (!emitted_change_) [self emitCause:@{ @"Command": commandId }];
  command_id_ = nil;
}

- (void)closeTab:(ARTab*)tab commandId:(NSString*)commandId {
  if (!g_epoch || !browser_ || !tab.contents || !commandId) return;
  TabStripModel* strip = browser_->GetTabStripModel();
  if (strip->GetIndexOfWebContents(tab.contents) == TabStripModel::kNoTab) return;
  command_id_ = commandId;
  pending_closes_[[NSValue valueWithPointer:tab.contents]] = commandId;
  strip->CloseWebContents(tab.contents, TabCloseTypes::CLOSE_CREATE_HISTORICAL_TAB);
  command_id_ = nil;
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

- (void)syncTabs {
  if (!browser_) return;
  TabStripModel* strip = browser_->GetTabStripModel();
  content::WebContents* active = strip->GetActiveWebContents();
  NSView* card = [self.delegate pageCardForWindowHost:self];
  NSMutableSet<NSValue*>* present = [NSMutableSet set];
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
    if (contents == active && card) {
      for (NSView* child in [card.subviews copy]) if (child != view) [child removeFromSuperview];
      if (view.superview != card) [card addSubview:view];
      view.frame = card.bounds;
      view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
      contents->WasShown();
    } else {
      [view removeFromSuperview];
      contents->WasHidden();
    }
  }
  for (NSValue* key in [tabs_.allKeys copy]) {
    if (![present containsObject:key]) {
      [tabs_[key] invalidate];
      [tabs_ removeObjectForKey:key];
    }
  }
  if (!active) for (NSView* child in [card.subviews copy]) [child removeFromSuperview];
}

- (NSDictionary*)stripSnapshot {
  NSMutableArray* entries = [NSMutableArray array];
  NSString* active_id = nil;
  content::WebContents* active = browser_ ? browser_->GetTabStripModel()->GetActiveWebContents() : nullptr;
  for (ARTab* tab in [self tabs]) {
    auto* identity = static_cast<TabIdentity*>(tab.contents->GetUserData(kTabIdentityKey));
    [entries addObject:@{ @"live_id": tab.liveId, @"item": identity->item_id ? (id)identity->item_id : (id)NSNull.null }];
    if (tab.contents == active) active_id = tab.liveId;
  }
  return @{ @"window": window_id_, @"tabs": entries, @"active": active_id ? (id)active_id : (id)NSNull.null };
}

- (void)emitCause:(id)cause {
  [self transactionWithCause:cause setEmptyReported:YES];
}

// Why not set empty_reported_: a discard must not suppress the empty strip of
// a Browser destroyed with tabs.
- (void)emitOpenFailure:(NSString*)commandId {
  [self transactionWithCause:@{ @"Command": commandId } setEmptyReported:NO];
}

- (void)transactionWithCause:(id)cause setEmptyReported:(BOOL)setEmptyReported {
  if (!g_epoch) return;
  NSArray* strips = @[ [self stripSnapshot] ];
  if (setEmptyReported)
    empty_reported_ = !browser_ || browser_->GetTabStripModel()->empty();
  __weak ARWindowHost* host = self;
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(^{
        ARWindowHost* strong_host = host;
        id<ARWindowHostDelegate> delegate = strong_host.delegate;
        if (!strong_host || !delegate) return;
        NSDictionary* transaction = @{ @"epoch": @(g_epoch), @"rev": @(++g_revision), @"cause": cause, @"strips": strips };
        [delegate windowHost:strong_host didReceiveTransaction:transaction];
      }));
}

- (BOOL)hasBrowser {
  return core_->window() != nullptr;
}

@end
