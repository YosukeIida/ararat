#include "ararat/core/ararat_tab.h"

#include <algorithm>
#include <memory>
#include <cstdio>

#include "ararat/core/public/ARWindowHost.h"
#include "ararat/core/ararat_permission_prompt.h"
#include "ararat/core/ararat_autofill_bubble_handler.h"
#include "ararat/core/ararat_password_prompt.h"
#include "ararat/core/ararat_window_host.h"
#if defined(ARARAT_TOUCH_ID_CHECK)
#include "ararat/core/ararat_touch_id_check.h"
#include "chrome/browser/ui/autofill/autofill_suggestion_controller.h"
#include "chrome/browser/ui/autofill/chrome_autofill_client.h"
#include "components/autofill/core/browser/suggestions/suggestion_type.h"
#endif
#include "base/check.h"
#include "base/command_line.h"
#include "base/functional/callback.h"
#include "base/functional/callback_helpers.h"
#include "base/functional/bind.h"
#include "base/json/json_writer.h"
#include "base/memory/raw_ptr.h"
#include "base/scoped_observation.h"
#include "base/values.h"
#include "base/strings/sys_string_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
#include "ui/base/page_transition_types.h"
#include "chrome/common/chrome_isolated_world_ids.h"
#include "chrome/browser/external_protocol/external_protocol_handler.h"
#include "chrome/browser/autofill/personal_data_manager_factory.h"
#include "chrome/browser/ui/autofill/payments/save_card_bubble_controller_impl.h"
#include "chrome/browser/ui/passwords/manage_passwords_ui_controller.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/common/pref_names.h"
#include "components/prefs/pref_service.h"
#include "components/autofill/content/browser/content_autofill_driver_factory.h"
#include "components/autofill/core/browser/data_manager/personal_data_manager.h"
#include "components/autofill/core/browser/data_manager/addresses/address_data_manager.h"
#include "components/autofill/core/browser/data_manager/payments/payments_data_manager.h"
#include "components/autofill/core/browser/data_model/addresses/autofill_profile.h"
#include "components/autofill/core/browser/foundations/autofill_driver.h"
#include "components/autofill/core/browser/foundations/autofill_client.h"
#include "components/autofill/core/browser/foundations/autofill_manager.h"
#include "components/autofill/core/browser/suggestions/suggestion.h"
#include "base/no_destructor.h"
#include "components/web_modal/web_contents_modal_dialog_manager.h"
#include "components/web_modal/web_contents_modal_dialog_manager_delegate.h"
#include "components/viz/common/frame_sinks/copy_output_result.h"
#include "components/permissions/permission_request_manager.h"
#include "components/permissions/permission_request.h"
#include "components/permissions/permission_request_data.h"
#include "components/permissions/request_type.h"
#include "components/find_in_page/find_tab_helper.h"
#include "components/find_in_page/find_notification_details.h"
#include "content/public/browser/javascript_dialog_manager.h"
#include "content/public/browser/web_contents_delegate.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/page_user_data.h"
#include "components/favicon/content/content_favicon_driver.h"
#include "components/favicon/core/favicon_driver_observer.h"
#include "content/public/browser/favicon_status.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_process_host.h"
#include "content/public/browser/render_widget_host.h"
#include "content/public/browser/weak_document_ptr.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/common/isolated_world_ids.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/navigation_handle.h"
#include "net/base/net_errors.h"
#include "url/gurl.h"
#include "url/origin.h"
#include "ui/views/controls/button/md_text_button.h"
#include "ui/views/widget/widget.h"
#include "ui/views/focus/focus_manager.h"
#include "ui/views/window/dialog_delegate.h"
#include "ui/gfx/image/image.h"

@interface NSObject (AraratCheckInputObservation)
- (int)textInputType;
- (BOOL)isHandlingKeyDown;
@end

@interface ARTab (SwitcherThumbnail)
- (void)setSwitcherThumbnailNavigating:(BOOL)navigating;
@end

namespace {
NSDictionary* KeyboardIMEObservation(content::WebContents* contents, NSString* stage) {
  auto* render_view = contents->GetRenderWidgetHostView();
  auto* frame = contents->GetFocusedFrame();
  NSView* view = contents->GetContentNativeView().GetNativeNSView();
  NSWindow* window = view.window;
  id<NSTextInputClient> input = (id<NSTextInputClient>)view;
  BOOL text_type_available = [view respondsToSelector:@selector(textInputType)];
  BOOL key_down_available = [view respondsToSelector:@selector(isHandlingKeyDown)];
  BOOL marked_available = [view respondsToSelector:@selector(hasMarkedText)];
  return @{ @"stage": stage, @"view_class": view ? NSStringFromClass(view.class) : @"",
            @"view_present": @(view != nil), @"window_present": @(window != nil),
            @"window_visible": @(window.isVisible), @"window_key": @(window.isKeyWindow),
            @"first_responder": @(view && window.firstResponder == view), @"app_active": @(NSApp.isActive),
            @"render_view_present": @(render_view != nullptr), @"render_focus": @(render_view && render_view->HasFocus()),
            @"render_showing": @(render_view && render_view->IsShowing()), @"focused_frame_present": @(frame != nullptr),
            @"focused_widget_is_root": @(frame && render_view && frame->GetRenderWidgetHost() == render_view->GetRenderWidgetHost()),
            @"text_input_type": text_type_available ? @([(NSObject*)view textInputType]) : (id)[NSNull null],
            @"handling_key_down": key_down_available ? @([(NSObject*)view isHandlingKeyDown]) : (id)[NSNull null],
            @"has_marked_text": marked_available ? @([input hasMarkedText]) : (id)[NSNull null] };
}
base::WeakPtr<content::WebContents> g_held_find_contents;
int g_held_find_request = -1;
bool IsPromptScreen() {
  const auto screen = base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-screen");
  return screen == "prompts" || screen == "dialogs" || screen == "site-controls" ||
         base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check") == "site-controls";
}

bool IsBlankSwitcherURL(const GURL& url) {
  return url.IsAboutBlank() || url.IsAboutSrcdoc();
}

bool HasBlankSwitcherURL(content::WebContents* contents) {
  const auto* frame = contents ? contents->GetPrimaryMainFrame() : nullptr;
  return frame && IsBlankSwitcherURL(frame->GetLastCommittedURL());
}

enum class TabFaviconKind { kNone, kDefault, kStale, kPage };

TabFaviconKind ClassifyTabFavicon(content::NavigationEntry* visible,
                                 const content::NavigationEntry* committed) {
  if (!visible || visible->GetFavicon().image.IsEmpty()) return TabFaviconKind::kNone;
  if (!visible->GetFavicon().valid) return TabFaviconKind::kDefault;
  return visible == committed ? TabFaviconKind::kPage : TabFaviconKind::kStale;
}

void TraceSwitcherThumbnail(ARWindowHost* host, NSString* live, const char* source,
                            const char* status, const char* reason, int viz_error, double ms,
                            bool retry = false) {
  const auto* command = base::CommandLine::ForCurrentProcess();
  if (!command->HasSwitch("ararat-check") && !command->HasSwitch("ararat-screen")) return;
  std::fprintf(stderr, "ararat-trace: switcher-thumbnail %s live=%s source=%s%s reason=%s viz_error=%d elapsed_ms=%.1f\n",
               status, live.UTF8String, source, retry ? " retry=1" : "", reason, viz_error, ms);
  id<ARWindowHostDelegate> delegate = host.delegate;
  if ([delegate respondsToSelector:@selector(windowHost:switcherThumbnailTrace:)])
    [delegate windowHost:host switcherThumbnailTrace:@{@"status": @(status), @"live": live,
        @"source": @(source), @"retry": @(retry ? 1 : 0), @"reason": @(reason),
        @"viz_error": @(viz_error), @"elapsed_ms": @(ms)}];
}

class SwitcherReserveStamp : public content::PageUserData<SwitcherReserveStamp> {
 public:
  base::TimeTicks last_request;
  bool retry_scheduled = false;

  double DelayUntilNextRequest() const {
    return last_request.is_null() ? 0
        : std::max(0.0, (last_request + base::Seconds(2) - base::TimeTicks::Now()).InSecondsF());
  }

 private:
  explicit SwitcherReserveStamp(content::Page& page) : PageUserData(page) {}
  friend PageUserData;
  PAGE_USER_DATA_KEY_DECL();
};
PAGE_USER_DATA_KEY_IMPL(SwitcherReserveStamp);

class TabContentsObserver : public content::WebContentsObserver,
                            public favicon::FaviconDriverObserver {
 public:
  TabContentsObserver(content::WebContents* contents, ARTab* tab)
      : content::WebContentsObserver(contents), tab_(tab) {
    if (auto* driver = favicon::ContentFaviconDriver::FromWebContents(contents))
      favicon_observation_.Observe(driver);
    __weak ARTab* weak_tab = tab;
    AraratObservePasswordOffer(contents, base::BindRepeating(^{
      [[weak_tab ownerHost] queuePasswordOfferChanged];
    }));
  }
  void Stop() {
    favicon_observation_.Reset();
    Observe(nullptr);
  }
  void OnFaviconUpdated(favicon::FaviconDriver*, NotificationIconType type,
                        const GURL&, bool, const gfx::Image&) override {
    if (type == NON_TOUCH_16_DIP)
      [[tab_ ownerHost] tabMetadataChanged:@"favicon" tab:tab_];
  }
  void DidFinishNavigation(content::NavigationHandle* navigation) override {
    if (navigation == thumbnail_navigation_) {
      thumbnail_navigation_ = nullptr;
      [tab_ setSwitcherThumbnailNavigating:NO];
      if (!navigation->HasCommitted() && !web_contents()->IsLoading())
        [tab_ reserveSwitcherThumbnail];
    }
    if (navigation->HasCommitted() && navigation->IsInPrimaryMainFrame()) {
      if (HasBlankSwitcherURL(web_contents()))
        [tab_ invalidateSwitcherThumbnail];
      const auto error = navigation->GetNetErrorCode();
      [tab_ setNetworkError:(navigation->IsErrorPage() && (error == net::ERR_NAME_NOT_RESOLVED || error == net::ERR_NAME_RESOLUTION_FAILED || error == net::ERR_INTERNET_DISCONNECTED)) ? error : 0];
      if (!navigation->IsSameDocument() && tab_ && web_contents())
        AraratCheckRevokeChangedDocument(base::SysNSStringToUTF8([tab_ liveId]), web_contents());
      [tab_ navigationFinished];
    }
  }
  void DidStartNavigation(content::NavigationHandle* navigation) override {
    if (navigation->IsInPrimaryMainFrame() && !navigation->IsSameDocument()) {
      thumbnail_navigation_ = navigation;
      [tab_ setSwitcherThumbnailNavigating:YES];
      [tab_ invalidateSwitcherThumbnail];
      [[tab_ ownerHost] traceTabEvent:@"navigation-start" tab:tab_];
      [tab_ refresh];
    }
  }
  void DidStartLoading() override { [tab_ refresh]; }
  void DidFirstVisuallyNonEmptyPaint() override { [tab_ reserveSwitcherThumbnail]; }
  void DidStopLoading() override {
    [tab_ refresh];
    [tab_ reserveSwitcherThumbnail];
  }
  void NavigationEntriesDeleted() override { [[tab_ ownerHost] tabMetadataChanged:@"navigation-entries" tab:tab_]; }
  void OnAudioStateChanged(bool audible) override { [tab_ audioStateChanged:@"audible"]; }
  void DidUpdateAudioMutingState(bool muted) override { [tab_ audioStateChanged:@"muted"]; }
  void BeforeUnloadDialogCancelled() override {
    [[tab_ ownerHost] tabCloseCancelled:web_contents()];
    [tab_ refresh];
  }
  void PrimaryMainFrameRenderProcessGone(base::TerminationStatus) override {
    [tab_ rendererCrashed];
  }
  void TitleWasSet(content::NavigationEntry*) override { [tab_ refresh]; }
  void OnWebContentsFocused(content::RenderWidgetHost*) override { [tab_ pageFocused]; }
  void WebContentsDestroyed() override { [tab_ invalidate]; }

 private:
  __weak ARTab* tab_;
  raw_ptr<content::NavigationHandle> thumbnail_navigation_ = nullptr;
  base::ScopedObservation<favicon::FaviconDriver, favicon::FaviconDriverObserver>
      favicon_observation_{this};
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
  BOOL loading_ui_;
  NSInteger network_error_;
  NSUInteger navigation_count_;
  NSUInteger thumbnail_document_generation_;
  BOOL thumbnail_navigating_;
  BOOL check_opener_alive_;
  NSMutableArray<NSDictionary*>* check_ime_observations_;
  std::string screen_address_guid_;
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
- (NSImage*)favicon {
  if (!contents_) return nil;
  auto& controller = contents_->GetController();
  auto* entry = controller.GetVisibleEntry();
  return ClassifyTabFavicon(entry, controller.GetLastCommittedEntry()) == TabFaviconKind::kPage
      ? entry->GetFavicon().image.ToNSImage() : nil;
}
- (NSDictionary<NSString*, id>*)checkFaviconState {
  if (!contents_ || base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-screen") != "tab-switcher")
    return @{};
  auto& controller = contents_->GetController();
  auto* visible = controller.GetVisibleEntry();
  const auto* committed = controller.GetLastCommittedEntry();
  const auto kind = ClassifyTabFavicon(visible, committed);
  const auto* status = visible ? &visible->GetFavicon() : nullptr;
  NSString* name = @"none";
  switch (kind) {
    case TabFaviconKind::kNone: break;
    case TabFaviconKind::kDefault: name = @"default"; break;
    case TabFaviconKind::kStale: name = @"stale"; break;
    case TabFaviconKind::kPage: name = @"page"; break;
  }
  return @{ @"kind": name,
            @"width_pt": @(status ? status->image.Width() : 0),
            @"height_pt": @(status ? status->image.Height() : 0),
            @"source_url": status && !status->url.is_empty() ? base::SysUTF8ToNSString(status->url.spec()) : (id)NSNull.null,
            @"entry_url": visible ? base::SysUTF8ToNSString(visible->GetURL().spec()) : (id)NSNull.null,
            @"committed_url": committed ? base::SysUTF8ToNSString(committed->GetURL().spec()) : (id)NSNull.null };
}
- (BOOL)isLoading { DCHECK([NSThread isMainThread]); return loading_; }
- (NSUInteger)navigationCount { DCHECK([NSThread isMainThread]); return navigation_count_; }
- (NSUInteger)entryCount { DCHECK([NSThread isMainThread]); return contents_ ? contents_->GetController().GetEntryCount() : 0; }
- (BOOL)canGoBack { DCHECK([NSThread isMainThread]); return contents_ && contents_->GetController().CanGoBack(); }
- (BOOL)crashed { DCHECK([NSThread isMainThread]); return contents_ && contents_->IsCrashed(); }
- (NSInteger)networkError { DCHECK([NSThread isMainThread]); return network_error_; }
- (void)setNetworkError:(NSInteger)error { network_error_ = error; }
- (void)reload {
  DCHECK([NSThread isMainThread]);
  if (contents_) contents_->GetController().Reload(content::ReloadType::NORMAL, true);
}
- (void)focus {
  DCHECK([NSThread isMainThread]);
  if (contents_) contents_->Focus();
}
- (void)checkFlushHistory:(void (^)(BOOL))completion {
  if (!host_) { completion(NO); return; }
  [host_ checkFlushHistoryForTab:self completion:completion];
}
- (BOOL)checkCrashRenderer {
  auto* args = base::CommandLine::ForCurrentProcess();
  if (!contents_ || (args->GetSwitchValueASCII("ararat-check") != "sadtab" &&
                     args->GetSwitchValueASCII("ararat-check") != "errorpages" &&
                     args->GetSwitchValueASCII("ararat-check") != "sidebar-rows" &&
                     args->GetSwitchValueASCII("ararat-screen") != "errorpages" &&
                     args->GetSwitchValueASCII("ararat-screen") != "sidebar-rows")) return NO;
  auto* frame = contents_->GetPrimaryMainFrame();
  return frame && frame->GetProcess()->Shutdown(1);
}
- (content::WebContents*)contents { return contents_; }
- (ARWindowHost*)ownerHost { return host_; }

- (NSDictionary<NSString*, id>*)checkNavigationState {
  auto* args = base::CommandLine::ForCurrentProcess();
  if (!contents_ || (args->GetSwitchValueASCII("ararat-check") != "keyboard" &&
                     args->GetSwitchValueASCII("ararat-screen") != "keyboard" &&
                     args->GetSwitchValueASCII("ararat-check") != "atc-routing")) return @{};
  auto* pending = contents_->GetController().GetPendingEntry();
  auto* entry = pending ? pending : contents_->GetController().GetLastCommittedEntry();
  return @{ @"committed_url": base::SysUTF8ToNSString(contents_->GetLastCommittedURL().spec()),
            @"visible_url": base::SysUTF8ToNSString(contents_->GetVisibleURL().spec()),
            @"pending_url": pending ? base::SysUTF8ToNSString(pending->GetVirtualURL().spec()) : (id)[NSNull null],
            @"loading": @(contents_->IsLoading()),
            @"auto_toplevel": @(entry && ui::PageTransitionCoreTypeIs(entry->GetTransitionType(), ui::PAGE_TRANSITION_AUTO_TOPLEVEL)) };
}

- (void)checkKeyboardScript:(NSInteger)script completion:(void (^)(NSString*))completion {
  auto* args = base::CommandLine::ForCurrentProcess();
  if (!contents_ || (args->GetSwitchValueASCII("ararat-check") != "keyboard" && args->GetSwitchValueASCII("ararat-screen") != "keyboard")) { completion(@""); return; }
  const char16_t* scripts[] = {
    u"JSON.stringify({value:document.querySelector('#edit')?.value, start:document.querySelector('#edit')?.selectionStart, end:document.querySelector('#edit')?.selectionEnd, focused:document.activeElement === document.querySelector('#edit'), events:window.araratInputEvents})",
    u"window.araratInputEvents = []; if (!window.araratInputProbe) { window.araratInputProbe = true; ['compositionstart','compositionupdate','compositionend','beforeinput','input'].forEach(type => document.querySelector('#edit').addEventListener(type, e => window.araratInputEvents.push(e.type))); } document.querySelector('#edit').focus(); document.querySelector('#edit').setSelectionRange(2,6); 'ready'",
    u"try { window.registerFixtureProtocol(); 'requested' } catch(e) { e.name }",
    u"document.documentElement.dataset.extensionCommand || ''",
    u"delete document.documentElement.dataset.extensionCommand; 'cleared'",
    u"window.onbeforeunload = e => { e.preventDefault(); e.returnValue = ''; }; 'armed'",
    u"window.onbeforeunload = null; 'disarmed'"
  };
  if (script < 0 || script >= 7) { completion(@""); return; }
  if (script == 5 && !AraratCheckRegisterBeforeUnload(base::SysNSStringToUTF8(live_id_), contents_)) { completion(@""); return; }
  if (script == 6) AraratCheckUnregisterBeforeUnload(base::SysNSStringToUTF8(live_id_), contents_);
  auto weak_contents = contents_->GetWeakPtr();
  auto document = contents_->GetPrimaryMainFrame()->GetWeakDocumentPtr();
  bool verify_document = (script == 5 || script == 6) && !args->HasSwitch("ararat-screen");
  uint64_t generation = verify_document ? AraratCheckDocumentRevision() : 0;
  contents_->GetPrimaryMainFrame()->ExecuteJavaScriptWithUserGestureForTests(scripts[script], base::BindOnce(^(base::Value value) {
    if (verify_document && (!weak_contents || !weak_contents->GetPrimaryMainFrame() || document.AsRenderFrameHostIfValid() != weak_contents->GetPrimaryMainFrame() || AraratCheckDocumentRevision() != generation)) { completion(@""); return; }
    completion(value.is_string() ? base::SysUTF8ToNSString(value.GetString()) : @"");
  }), content::ISOLATED_WORLD_ID_GLOBAL);
}

- (BOOL)checkKeyboardIME {
  auto* args = base::CommandLine::ForCurrentProcess();
  if (!contents_ || (args->GetSwitchValueASCII("ararat-check") != "keyboard" && args->GetSwitchValueASCII("ararat-screen") != "keyboard")) return NO;
  auto contents = contents_->GetWeakPtr();
  check_ime_observations_ = [NSMutableArray array];
  [check_ime_observations_ addObject:KeyboardIMEObservation(contents.get(), @"before_focus_override")];
  if (args->GetSwitchValueASCII("ararat-check") == "keyboard") {
    auto* render_view = contents->GetRenderWidgetHostView();
    if (!render_view) return NO;
    render_view->SetHasFocusForTesting(true);
    render_view->GetRenderWidgetHost()->Focus();
  }
  if (!contents || contents_ != contents.get()) return NO;
  NSView* view = contents->GetContentNativeView().GetNativeNSView();
  if (![view respondsToSelector:@selector(setMarkedText:selectedRange:replacementRange:)] ||
      ![view respondsToSelector:@selector(insertText:replacementRange:)]) return NO;
  if (args->GetSwitchValueASCII("ararat-screen") == "keyboard" &&
      (!view.window || view.window.firstResponder != view)) return NO;
  id<NSTextInputClient> input = (id<NSTextInputClient>)view;
  [check_ime_observations_ addObject:KeyboardIMEObservation(contents.get(), @"before_marked")];
  [input setMarkedText:@"か" selectedRange:NSMakeRange(1, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
  if (!contents || contents_ != contents.get() || contents->GetContentNativeView().GetNativeNSView() != view) return NO;
  [check_ime_observations_ addObject:KeyboardIMEObservation(contents.get(), @"after_marked")];
  [input insertText:@"漢" replacementRange:NSMakeRange(NSNotFound, 0)];
  if (contents && contents_ == contents.get() && contents->GetContentNativeView().GetNativeNSView() == view)
    [check_ime_observations_ addObject:KeyboardIMEObservation(contents.get(), @"after_insert")];
  return YES;
}

- (NSArray<NSDictionary<NSString*, id>*>*)checkKeyboardIMEState {
  auto* args = base::CommandLine::ForCurrentProcess();
  if (args->GetSwitchValueASCII("ararat-check") != "keyboard" && args->GetSwitchValueASCII("ararat-screen") != "keyboard") return @[];
  return [check_ime_observations_ copy] ?: @[];
}

- (void)checkStartBackgroundFind:(NSString*)text {
  auto* args = base::CommandLine::ForCurrentProcess();
  if (!contents_ || (args->GetSwitchValueASCII("ararat-check") != "keyboard" && args->GetSwitchValueASCII("ararat-screen") != "keyboard")) return;
  if (auto* helper = find_in_page::FindTabHelper::FromWebContents(contents_))
    helper->StartFinding(base::SysNSStringToUTF16(text), true, false, true);
}

- (NSDictionary<NSString*, id>*)checkBackgroundFindState {
  auto* args = base::CommandLine::ForCurrentProcess();
  if (!contents_ || (args->GetSwitchValueASCII("ararat-check") != "keyboard" && args->GetSwitchValueASCII("ararat-screen") != "keyboard")) return @{};
  auto* helper = find_in_page::FindTabHelper::FromWebContents(contents_);
  if (!helper) return @{};
  const auto& result = helper->find_result();
  return @{ @"request_id": @(result.request_id()), @"final": @(result.final_update()), @"matches": @(result.number_of_matches()),
            @"text": base::SysUTF16ToNSString(helper->find_text()) };
}

- (BOOL)checkHoldFindReply:(NSString*)text {
  auto* args = base::CommandLine::ForCurrentProcess();
  if (!contents_ || (args->GetSwitchValueASCII("ararat-check") != "keyboard" && args->GetSwitchValueASCII("ararat-screen") != "keyboard")) return NO;
  auto* helper = find_in_page::FindTabHelper::FromWebContents(contents_);
  if (!helper) return NO;
  helper->StartFinding(base::SysNSStringToUTF16(text), true, false, true);
  g_held_find_request = helper->current_find_request_id();
  g_held_find_contents = contents_->GetWeakPtr();
  return g_held_find_request > 0;
}

- (NSDictionary<NSString*, id>*)checkDeliverHeldFindReply {
  auto* args = base::CommandLine::ForCurrentProcess();
  if (args->GetSwitchValueASCII("ararat-check") != "keyboard" && args->GetSwitchValueASCII("ararat-screen") != "keyboard") return @{};
  bool alive = !!g_held_find_contents;
  auto* helper = alive ? find_in_page::FindTabHelper::FromWebContents(g_held_find_contents.get()) : nullptr;
  if (helper) static_cast<content::WebContentsObserver*>(helper)->DidReceiveFindReply(g_held_find_request, 19, gfx::Rect(), 1, true);
  g_held_find_contents.reset();
  g_held_find_request = -1;
  return @{ @"alive": @(alive), @"delivered": @(helper != nullptr) };
}

- (BOOL)checkHeldFindTargetAlive { return !!g_held_find_contents; }

- (void)checkFullscreenRequest:(BOOL)enter {
  auto* command = base::CommandLine::ForCurrentProcess();
  if (!contents_ || (command->GetSwitchValueASCII("ararat-check") != "fullscreen" &&
                     command->GetSwitchValueASCII("ararat-screen") != "fullscreen" &&
                     command->GetSwitchValueASCII("ararat-check") != "keyboard" &&
                     command->GetSwitchValueASCII("ararat-screen") != "keyboard")) return;
  if (command->GetSwitchValueASCII("ararat-check") == "fullscreen" || command->GetSwitchValueASCII("ararat-check") == "keyboard") {
    if (auto* view = contents_->GetRenderWidgetHostView()) view->SetHasFocusForTesting(true);
  }
  contents_->GetPrimaryMainFrame()->ExecuteJavaScriptWithUserGestureForTests(
      enter ? u"document.documentElement.requestFullscreen()" : u"document.exitFullscreen()",
      base::NullCallback(), content::ISOLATED_WORLD_ID_GLOBAL);
}

- (void)checkFullscreenElement:(void (^)(BOOL))completion {
  auto* command = base::CommandLine::ForCurrentProcess();
  if (!contents_ || (command->GetSwitchValueASCII("ararat-check") != "fullscreen" &&
                     command->GetSwitchValueASCII("ararat-screen") != "fullscreen" &&
                     command->GetSwitchValueASCII("ararat-check") != "keyboard" &&
                     command->GetSwitchValueASCII("ararat-screen") != "keyboard")) {
    completion(NO);
    return;
  }
  contents_->GetPrimaryMainFrame()->ExecuteJavaScriptForTests(
      u"!!document.fullscreenElement", base::BindOnce(^(base::Value value) {
        completion(value.is_bool() && value.GetBool());
      }), content::ISOLATED_WORLD_ID_GLOBAL);
}

- (NSUInteger)checkPermissionShownCount { return AraratCheckPermissionShownCount(); }
- (BOOL)checkAutofillBubble:(BOOL)card decline:(BOOL)decline {
  return contents_ && AraratCheckAutofillBubble(contents_, card, decline);
}

static bool IsPasswordLoginFixture(content::WebContents* contents) {
  if (!contents || base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII(
                       "ararat-screen") != "password-prompt") return false;
  const auto& url = contents->GetLastCommittedURL();
  return url.SchemeIs("http") && url.host() == "127.0.0.1" &&
         url.path() == "/password-login";
}

#if defined(ARARAT_TOUCH_ID_CHECK)
static bool IsTouchIDLoginFixture(content::WebContents* contents,
                                  NSString* expected_url) {
  if (!contents ||
      !AraratTouchIDCheckHasProfile(
          Profile::FromBrowserContext(contents->GetBrowserContext())))
    return false;
  const auto& url = contents->GetLastCommittedURL();
  return url.SchemeIs("http") && url.host() == "127.0.0.1" &&
         url.path() == "/password-login" &&
         url.spec() == base::SysNSStringToUTF8(expected_url);
}

- (BOOL)checkTouchIDFixture:(NSString*)url
                      focus:(BOOL)focus
                 completion:(void (^)(NSString*))completion {
  if (!IsTouchIDLoginFixture(contents_, url))
    return NO;
  const char16_t* script = focus
      ? u"(() => { document.getElementById('username')?.focus(); "
        u"return document.activeElement?.id === 'username' ? "
        u"JSON.stringify([document.getElementById('username')?.value, "
        u"document.getElementById('password')?.value]) : ''; })()"
      : u"JSON.stringify([document.getElementById('username')?.value, "
        u"document.getElementById('password')?.value])";
  contents_->GetPrimaryMainFrame()->ExecuteJavaScriptInIsolatedWorld(
      script, base::BindOnce(^(base::Value value) {
        completion(value.is_string() ? base::SysUTF8ToNSString(value.GetString())
                                     : @"");
      }), ISOLATED_WORLD_ID_CHROME_INTERNAL);
  return YES;
}

- (BOOL)checkTouchIDPasswordSuggestion:(NSString*)url accept:(BOOL)accept {
  if (!IsTouchIDLoginFixture(contents_, url))
    return NO;
  auto* client =
      autofill::ChromeAutofillClient::FromWebContentsForTesting(contents_);
  auto popup = client ? client->suggestion_controller_for_testing() : nullptr;
  if (!popup)
    return NO;
  const auto suggestions = popup->GetSuggestions();
  if (suggestions.empty() ||
      suggestions.front().type != autofill::SuggestionType::kPasswordEntry)
    return NO;
  if (accept) {
    popup->AcceptSuggestion(
        0, autofill::AutofillMetrics::SuggestionAcceptedMethod::kKeyboard,
        /*was_obscured=*/false);
  }
  return YES;
}
#endif

- (BOOL)checkFillPasswordFixture:(void (^)(NSString*))completion {
  if (!IsPasswordLoginFixture(contents_)) return NO;
  contents_->GetPrimaryMainFrame()->ExecuteJavaScriptWithUserGestureForTests(
      u"typeof fillAraratPasswordFixture === 'function' ? "
      u"fillAraratPasswordFixture() : 'missing_script'",
      base::BindOnce(^(base::Value value) {
        completion(value.is_string() ? base::SysUTF8ToNSString(value.GetString())
                                     : @"no_renderer_result");
      }), content::ISOLATED_WORLD_ID_GLOBAL);
  return YES;
}

- (BOOL)checkSubmitPasswordFixture {
  if (!IsPasswordLoginFixture(contents_)) return NO;
  contents_->GetPrimaryMainFrame()->ExecuteJavaScriptWithUserGestureForTests(
      u"document.querySelector('form')?.requestSubmit()", base::NullCallback(),
      content::ISOLATED_WORLD_ID_GLOBAL);
  return YES;
}

- (BOOL)checkStartPasswordConfirmation:(void (^)(NSString*))completion {
  if (!IsPasswordLoginFixture(contents_)) return NO;
  contents_->GetPrimaryMainFrame()->ExecuteJavaScriptWithUserGestureForTests(
      u"startAraratPasswordConfirmation()",
      base::BindOnce(^(base::Value value) {
        completion(value.is_string() ? base::SysUTF8ToNSString(value.GetString())
                                     : @"no_renderer_result");
      }), content::ISOLATED_WORLD_ID_GLOBAL);
  return YES;
}

- (NSInteger)checkPasswordPromptState {
  if (!contents_ || base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII(
                        "ararat-screen") != "password-prompt") return -1;
  auto* controller = ManagePasswordsUIController::FromWebContents(contents_);
  return controller ? static_cast<NSInteger>(controller->GetState()) : -1;
}

- (ARPasswordOfferState)passwordOffer {
  if (!contents_ || ![host_ isActiveTab:self]) return {};
  auto offer = AraratGetPasswordOffer(contents_);
  return {offer.generation, offer.is_update ? YES : NO};
}

- (BOOL)reopenPasswordOffer:(NSUInteger)generation {
  return contents_ && [host_ isActiveTab:self] &&
         AraratReopenPasswordOffer(contents_, generation);
}

- (NSWindow*)checkPasswordPromptWindow {
  auto* widget = contents_ ? AraratCheckPasswordPromptWidget(contents_) : nullptr;
  return widget && widget->IsVisible() ? widget->GetNativeWindow().GetNativeNSWindow() : nil;
}

- (BOOL)checkPasswordPromptAction:(NSString*)action {
  auto* widget = contents_ ? AraratCheckPasswordPromptWidget(contents_) : nullptr;
  if (!widget || !widget->IsVisible()) return NO;
  if ([action isEqualToString:@"never"]) return AraratCheckPressNeverButton(widget);
  if ([action isEqualToString:@"close"]) {
    widget->Close();
    return YES;
  }
  if ([action isEqualToString:@"clearPassword"] || [action isEqualToString:@"editPassword"])
    return AraratCheckEditPassword(widget, [action isEqualToString:@"clearPassword"]);
  if ([action isEqualToString:@"cancel"]) {
    widget->widget_delegate()->AsDialogDelegate()->CancelDialog();
    return YES;
  }
  if ([action isEqualToString:@"escape"] || [action isEqualToString:@"accept"]) {
    const auto key = [action isEqualToString:@"escape"] ? ui::VKEY_ESCAPE : ui::VKEY_RETURN;
    return widget->GetFocusManager()->ProcessAccelerator(ui::Accelerator(key, ui::EF_NONE));
  }
  return NO;
}

- (NSInteger)checkPasswordPromptNotNowCount {
  return AraratCheckPasswordPromptNotNowCount();
}

- (BOOL)checkHasPasswordPrompt {
  return contents_ && AraratCheckPasswordPromptWidget(contents_);
}

- (NSDictionary<NSString*, id>*)checkAutofillState {
  if (!contents_ || (base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check") != "autofill" && !IsPromptScreen())) return @{};
  if (!IsPromptScreen()) {
    static base::NoDestructor<base::AutoReset<bool>> ignore_activation(
        autofill::SaveCardBubbleControllerImpl::IgnoreWindowActivationForTesting());
  }
  auto* data = autofill::PersonalDataManagerFactory::GetForBrowserContext(contents_->GetBrowserContext());
  if (!data) return @{};
  auto& addresses = data->address_data_manager();
  auto& payments = data->payments_data_manager();
  int forms = 0;
  size_t suggestions = 0;
  if (auto* factory = autofill::ContentAutofillDriverFactory::FromWebContents(contents_)) {
    for (auto* driver : factory->GetExistingDrivers()) {
      driver->GetAutofillManager().ForEachCachedForm([&forms](const autofill::FormStructure&) { ++forms; });
      suggestions = driver->GetAutofillManager().client().GetAutofillSuggestions().size();
    }
  }
  return @{ @"loaded": @(data->IsDataLoaded()), @"address_enabled": @(addresses.IsAutofillProfileEnabled()),
    @"card_enabled": @(payments.IsAutofillPaymentMethodsEnabled()), @"forms": @(forms),
    @"addresses": @(addresses.GetProfiles().size()), @"cards": @(payments.GetCreditCards().size()),
    @"address_pending": @(addresses.IsAwaitingPendingAddressChanges()), @"card_pending": @(payments.HasPendingPaymentQueries()),
    @"suggestions": @(suggestions) };
}

- (void)checkAutofillAction:(NSInteger)action {
  if (!contents_ || base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check") != "autofill") return;
  const char16_t* scripts[] = {u"window.fillAddress()", u"document.getElementById('address-submit').click()",
      u"window.fillCard()", u"document.getElementById('card-submit').click()"};
  if (action < 0 || action >= 4) return;
  contents_->GetPrimaryMainFrame()->ExecuteJavaScriptWithUserGestureForTests(
      scripts[action], base::NullCallback(), content::ISOLATED_WORLD_ID_GLOBAL);
}

- (void)checkRefreshAutofillData {
  if (!contents_ || base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check") != "autofill") return;
  if (auto* data = autofill::PersonalDataManagerFactory::GetForBrowserContext(contents_->GetBrowserContext())) data->Refresh();
}
- (BOOL)checkPermissionDecision:(NSInteger)decision {
  return contents_ && decision >= 0 && decision <= 3 && AraratCheckPermissionDecision(contents_, static_cast<int>(decision));
}

- (NSDictionary<NSString*, id>*)checkPermissionBlockButton {
  auto* widget = contents_ ? AraratCheckPermissionWidget(contents_) : nullptr;
  auto* button = contents_ ? AraratCheckPermissionBlockButton(contents_) : nullptr;
  NSWindow* window = widget ? widget->GetNativeWindow().GetNativeNSWindow() : nil;
  if (!button || !window) return @{};
  const auto bounds = button->GetBoundsInScreen();
  if (bounds.IsEmpty()) return @{};
  const CGFloat top = NSMaxY(NSScreen.screens.firstObject.frame);
  NSRect screen = NSMakeRect(bounds.x(), top - bounds.y() - bounds.height(), bounds.width(), bounds.height());
  return @{ @"window": window, @"frame": [NSValue valueWithRect:[window convertRectFromScreen:screen]],
            @"origin_wrapped": @(AraratCheckPermissionOriginWrapped(contents_)) };
}

- (BOOL)checkPermissionWidgetVisible {
  auto* widget = contents_ ? AraratCheckPermissionWidget(contents_) : nullptr;
  return widget && widget->IsVisible();
}

- (NSDictionary<NSString*, id>*)checkPermissionWidgetState {
  auto* widget = contents_ ? AraratCheckPermissionWidget(contents_) : nullptr;
  auto* dialog = widget && widget->widget_delegate() ? widget->widget_delegate()->AsDialogDelegate() : nullptr;
  if (!dialog) return @{};
  auto* manager = web_modal::WebContentsModalDialogManager::FromWebContents(contents_);
  auto* delegate = manager ? manager->delegate() : nullptr;
  NSWindow* window = widget->GetNativeWindow().GetNativeNSWindow();
  std::fprintf(stderr, "ararat-trace: permission-widget name=%s view=%s fixed=%d bounds=%s visible=%d\n",
               widget->GetName().c_str(), std::string(dialog->GetContentsView()->GetClassName()).c_str(), dialog->fixed_width(),
               widget->GetWindowBoundsInScreen().ToString().c_str(), widget->IsVisible());
  return @{ @"visible": @(widget->IsVisible()),
            @"window_number": @(window.windowNumber),
            @"parent_window_number": @(window.parentWindow ? window.parentWindow.windowNumber : -1),
            @"delegate_visible": @(delegate && delegate->IsWebContentsVisible(contents_)),
            @"no_default": @(dialog->GetDefaultDialogButton() == static_cast<int>(ui::mojom::DialogButton::kNone)),
            @"escape_closes": @(!dialog->EscShouldCancelDialog()),
            @"width": @(widget->GetWindowBoundsInScreen().width()) };
}

- (BOOL)checkPermissionPending {
  const auto* args = base::CommandLine::ForCurrentProcess();
  if (!contents_ || (args->GetSwitchValueASCII("ararat-check") != "permissions" && args->GetSwitchValueASCII("ararat-check") != "keyboard" && args->GetSwitchValueASCII("ararat-screen") != "keyboard" && !IsPromptScreen())) return NO;
  auto* manager = permissions::PermissionRequestManager::FromWebContents(contents_);
  return manager && (manager->IsRequestInProgress() || manager->has_pending_requests());
}

- (void)checkRequestPermission:(NSInteger)request {
  if (!contents_ || (base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check") != "permissions" && !IsPromptScreen())) return;
  if (request == 3 && base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-screen") == "dialogs") {
    auto* manager = permissions::PermissionRequestManager::FromWebContents(contents_);
    if (!manager) return;
    const auto origin = contents_->GetLastCommittedURL().DeprecatedGetOriginAsURL();
    auto data = std::make_unique<permissions::PermissionRequestData>(
        permissions::RequestType::kNotifications, true, origin, origin);
    manager->AddRequest(contents_->GetPrimaryMainFrame(),
        std::make_unique<permissions::PermissionRequest>(std::move(data), base::DoNothing()));
    return;
  }
  const char16_t* scripts[] = {u"window.requestNotifications()", u"window.requestLocation()", u"window.requestMidi()"};
  if (request < 0 || request >= 3) return;
  contents_->GetPrimaryMainFrame()->ExecuteJavaScriptWithUserGestureForTests(
      scripts[request], base::NullCallback(), content::ISOLATED_WORLD_ID_GLOBAL);
}

- (void)checkActivateSplitPane {
  if (base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-screen") == "dialogs")
    [host_ focusSplitTab:self];
}

- (void)checkPermissionResults:(void (^)(NSString*))completion {
  if (!contents_ || (base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check") != "permissions" && !IsPromptScreen())) {
    completion(@"");
    return;
  }
  contents_->GetPrimaryMainFrame()->ExecuteJavaScriptInIsolatedWorld(
      u"JSON.stringify(document.documentElement.dataset)",
      base::BindOnce(^(base::Value value) {
        const std::string* result = value.GetIfString();
        completion(result ? base::SysUTF8ToNSString(*result) : @"");
      }), ISOLATED_WORLD_ID_CHROME_INTERNAL);
}

- (BOOL)checkIsDialogActive {
  const auto check = base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check");
  const auto screen = base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-screen");
  if (!contents_ || (check != "permissions" && check != "dialogs" && check != "protocol" && check != "autofill" && check != "keyboard" && screen != "keyboard" && screen != "password-prompt" && !IsPromptScreen())) return NO;
  auto* manager = web_modal::WebContentsModalDialogManager::FromWebContents(contents_);
  return manager && manager->IsDialogActive();
}

- (BOOL)checkDialogHostIsOurs {
  return [self checkIsDialogActive] && [host_ checkDialogHostForContents:contents_];
}

- (BOOL)checkCloseModalDialogs {
  if (![self checkIsDialogActive]) return NO;
  auto* manager = web_modal::WebContentsModalDialogManager::FromWebContents(contents_);
  manager->CloseAllDialogs();
  return YES;
}

// Why not CloseAllDialogs: closing a widget only tears the dialog down. A
// WebAuthn request settles on the dialog's cancel path, so a closed widget
// leaves its promise pending and the page never sees NotAllowedError.
- (BOOL)checkCancelScreenDialog:(NSWindow*)window {
  if (!IsPromptScreen() || ![self checkDialogHostIsOurs] || !window ||
      window.parentWindow != [host_ window]) return NO;
  auto* widget = views::Widget::GetWidgetForNativeWindow(gfx::NativeWindow(window));
  auto* delegate = widget && widget->widget_delegate() ? widget->widget_delegate()->AsDialogDelegate() : nullptr;
  auto* button = delegate ? delegate->GetCancelButton() : nullptr;
  if (!button || !button->GetVisible() || !button->GetEnabled()) return NO;
  delegate->CancelDialog();
  return YES;
}

- (NSDictionary<NSString*, id>*)checkProtocol:(NSString*)scheme launch:(BOOL)launch {
  if (!contents_ || base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check") != "protocol") return @{};
  const std::string name = base::SysNSStringToUTF8(scheme);
  if (name.size() < 2 || name.find_first_not_of("abcdefghijklmnopqrstuvwxyz0123456789+.-") != std::string::npos ||
      name == "mailto" || name == "http" || name == "https" || name == "file" || name == "ftp") return @{};
  Profile* profile = Profile::FromBrowserContext(contents_->GetBrowserContext());
  auto* prefs = profile->GetPrefs();
  auto* allowlist = prefs->FindPreference("policy.url_allowlist");
  auto* blocklist = prefs->FindPreference("policy.url_blocklist");
  if (!allowlist || !blocklist || !allowlist->GetValue()->is_list() || !blocklist->GetValue()->is_list()) return @{};
  const auto* user = prefs->GetUserPrefValue(prefs::kProtocolHandlerPerOriginAllowedProtocols);
  std::string snapshot = "null";
  if (user && !base::JSONWriter::Write(*user, &snapshot)) return @{};
  const auto origin = url::Origin::Create(contents_->GetLastCommittedURL());
  const GURL target(name + "://ararat.invalid/");
  bool eligible = !origin.opaque() && target.is_valid() &&
      allowlist->GetValue()->GetList().empty() && blocklist->GetValue()->GetList().empty() &&
      ExternalProtocolHandler::GetBlockState(name, &origin, profile) == ExternalProtocolHandler::UNKNOWN;
  if (launch && eligible) {
    std::u16string script = base::UTF8ToUTF16("window.location.href='" + target.spec() + "'");
    contents_->GetPrimaryMainFrame()->ExecuteJavaScriptWithUserGestureForTests(
        script, base::NullCallback(), content::ISOLATED_WORLD_ID_GLOBAL);
  }
  return @{ @"eligible": @(eligible), @"pref": base::SysUTF8ToNSString(snapshot), @"launched_request": @(launch && eligible) };
}

- (BOOL)checkAcceptJavaScriptDialog:(NSString*)text {
  if ((base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check") != "dialogs" && !IsPromptScreen()) ||
      ![self checkIsDialogActive] || !contents_->GetDelegate()) return NO;
  auto* manager = contents_->GetDelegate()->GetJavaScriptDialogManager(contents_);
  const auto prompt = base::SysNSStringToUTF16(text);
  return manager && manager->HandleJavaScriptDialog(contents_, true, &prompt);
}

- (BOOL)checkCancelJavaScriptDialog {
  if ((base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check") != "dialogs" && !IsPromptScreen()) ||
      ![self checkIsDialogActive] || !contents_->GetDelegate()) return NO;
  auto* manager = contents_->GetDelegate()->GetJavaScriptDialogManager(contents_);
  return manager && manager->HandleJavaScriptDialog(contents_, false, nullptr);
}

- (void)checkRunJavaScriptDialog:(NSInteger)dialog {
  if (!contents_ || (base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check") != "dialogs" && !IsPromptScreen())) return;
  const char16_t* scripts[] = {u"window.runAlert()", u"window.runConfirm('confirmOk')",
      u"window.runConfirm('confirmCancel')", u"window.runPrompt('promptText')", u"window.runPrompt('promptCancel')"};
  if (dialog < 0 || dialog >= 5) return;
  contents_->GetPrimaryMainFrame()->ExecuteJavaScriptWithUserGestureForTests(
      scripts[dialog], base::NullCallback(), content::ISOLATED_WORLD_ID_GLOBAL);
}

- (void)checkDialogResults:(void (^)(NSString*))completion {
  if (!contents_ || (base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check") != "dialogs" && !IsPromptScreen())) {
    completion(@"");
    return;
  }
  contents_->GetPrimaryMainFrame()->ExecuteJavaScriptInIsolatedWorld(
      u"JSON.stringify(document.documentElement.dataset)",
      base::BindOnce(^(base::Value value) {
        const std::string* result = value.GetIfString();
        completion(result ? base::SysUTF8ToNSString(*result) : @"");
      }), ISOLATED_WORLD_ID_CHROME_INTERNAL);
}

- (void)checkScreenWebAuthn:(BOOL)create {
  if (!contents_ || !IsPromptScreen()) return;
  contents_->GetPrimaryMainFrame()->ExecuteJavaScriptWithUserGestureForTests(
      create ? u"window.runCreate()" : u"window.runGet()", base::NullCallback(),
      content::ISOLATED_WORLD_ID_GLOBAL);
}

- (BOOL)checkScreenAddress:(BOOL)seed {
  if (!contents_ || !IsPromptScreen()) return NO;
  auto* data = autofill::PersonalDataManagerFactory::GetForBrowserContext(contents_->GetBrowserContext());
  if (!data || !data->IsDataLoaded()) return NO;
  auto& addresses = data->address_data_manager();
  if (seed) {
    if (!screen_address_guid_.empty() || !addresses.GetProfiles().empty()) return NO;
    autofill::AutofillProfile profile(autofill::AddressCountryCode("US"));
    profile.SetRawInfo(autofill::NAME_FULL, u"John Smith");
    profile.SetRawInfo(autofill::ADDRESS_HOME_LINE1, u"123 Testing St");
    profile.SetRawInfo(autofill::ADDRESS_HOME_CITY, u"Mountain View");
    profile.SetRawInfo(autofill::ADDRESS_HOME_STATE, u"CA");
    profile.SetRawInfo(autofill::ADDRESS_HOME_ZIP, u"94043");
    screen_address_guid_ = profile.guid();
    addresses.AddProfile(profile);
  } else {
    if (screen_address_guid_.empty()) return NO;
    addresses.RemoveProfile(screen_address_guid_);
    screen_address_guid_.clear();
  }
  return YES;
}

- (void)checkScreenFocusAddress {
  if (!contents_ || !IsPromptScreen()) return;
  contents_->GetPrimaryMainFrame()->ExecuteJavaScriptWithUserGestureForTests(
      u"(()=>{let e=document.querySelector('#address input[autocomplete=name]'); e.focus(); let r=e.getBoundingClientRect(); document.documentElement.dataset.field=JSON.stringify({x:r.x,y:r.y,width:r.width,height:r.height});})()",
      base::NullCallback(), content::ISOLATED_WORLD_ID_GLOBAL);
}

- (NSView*)view {
  DCHECK([NSThread isMainThread]);
  if (!contents_ || (![host_ isActiveTab:self] && ![host_ isVisibleSplitTab:self])) return nil;
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
  if (!AraratCheckRegisterBeforeUnload(base::SysNSStringToUTF8(live_id_), contents_)) return;
  contents_->GetPrimaryMainFrame()->ExecuteJavaScriptWithUserGestureForTests(
      u"window.addEventListener('beforeunload', e => { e.preventDefault(); e.returnValue = ''; });",
      base::NullCallback(), content::ISOLATED_WORLD_ID_GLOBAL);
}

- (BOOL)checkHasBeforeUnload {
  return contents_ && contents_->NeedToFireBeforeUnloadOrUnloadEvents();
}

- (void)focusCheckPage {
  [self focus];
}

- (void)openCheckPopup {
  auto* command_line = base::CommandLine::ForCurrentProcess();
  if (!contents_ || (command_line->GetSwitchValueASCII("ararat-check") != "popup" &&
                     command_line->GetSwitchValueASCII("ararat-screen") != "links")) return;
  contents_->GetPrimaryMainFrame()->ExecuteJavaScriptWithUserGestureForTests(
      u"{ const popup = window.open('', '', 'popup,width=400,height=300'); if (popup) popup.document.title = 'Popup'; }",
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

- (void)checkExtensionPopupWindow:(BOOL)remove {
  auto* args = base::CommandLine::ForCurrentProcess();
  if (!contents_ || (args->GetSwitchValueASCII("ararat-check") != "ext-windows-popup" &&
      !(args->GetSwitchValueASCII("ararat-screen") == "extensions" && args->HasSwitch("ararat-page-only-menu-check")))) return;
  contents_->GetPrimaryMainFrame()->ExecuteJavaScriptWithUserGestureForTests(
      remove ? u"location.hash = 'remove-popup'" : u"location.hash = 'popup'",
      base::NullCallback(), content::ISOLATED_WORLD_ID_GLOBAL);
}

- (void)checkOpenActionPopup {
  if (!contents_ || base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-screen") != "extensions") return;
  contents_->GetPrimaryMainFrame()->ExecuteJavaScriptWithUserGestureForTests(
      u"location.hash = 'action-popup'", base::NullCallback(), content::ISOLATED_WORLD_ID_GLOBAL);
}

- (void)navigationFinished {
  ++navigation_count_;
  [host_ noteNavigationForTab:self];
  [self refresh];
  [host_ tabMetadataChanged:@"navigation-finished" tab:self];
}

- (void)audioStateChanged:(NSString*)field {
  [host_ tabMetadataChanged:field tab:self];
}

- (void)rendererCrashed {
  [self invalidateSwitcherThumbnail];
  [host_ tabMetadataChanged:@"crashed" tab:self];
}

- (void)pageFocused {
  [host_ focusSplitTab:self];
}

static void CopyTabSurface(content::WebContents* contents,
                           content::RenderWidgetHostView* view,
                           NSString* live_id, const gfx::Rect& crop,
                           const gfx::Size& size, bool secure, bool trace,
                           void (^completion)(NSImage*, const char*, int)) {
  if (trace) std::fprintf(stderr, "ararat-trace: transfer snapshot request view=%d surface=%d\n", view != nullptr, view && view->IsSurfaceAvailableForCopy());
  if (!view || !view->IsSurfaceAvailableForCopy()) { completion(nil, "error", -1); return; }
  auto runner = base::SingleThreadTaskRunner::GetCurrentDefault();
  auto weak_contents = contents->GetWeakPtr();
  std::string live = base::SysNSStringToUTF8(live_id);
  auto copied = base::BindOnce(^(const content::CopyFromSurfaceResult& result) {
        SkBitmap bitmap = result.has_value() ? result->bitmap : SkBitmap();
        bool copyOK = result.has_value();
        const int viz_error = copyOK ? -1 : static_cast<int>(result.error());
        const char* reason = "empty";
        if (!copyOK && result.error() == content::CopyFromSurfaceError::kTimeout) reason = "timeout";
        else if (!copyOK && result.error() != content::CopyFromSurfaceError::kVizSentEmptyBitmap) reason = "error";
        runner->PostTask(FROM_HERE, base::BindOnce(^{
          const bool same_live = weak_contents && AraratLiveIdForContents(weak_contents.get()) == live;
          if (trace) std::fprintf(stderr, "ararat-trace: transfer snapshot copy ok=%d contents=%d live_match=%d bitmap=%d\n",
                                  copyOK, !!weak_contents, same_live, !bitmap.empty());
          completion(same_live && !bitmap.empty() ? gfx::Image::CreateFrom1xBitmap(bitmap).ToNSImage() : nil,
                     same_live ? reason : "error", viz_error);
        }));
  });
  if (secure)
    view->CopyFromSurfaceSecure(crop, size, base::Milliseconds(250), std::move(copied));
  else
    view->CopyFromSurface(crop, size, base::Milliseconds(250), std::move(copied));
}

- (void)captureSnapshot:(void (^)(NSImage*))completion {
  auto* view = contents_ ? contents_->GetRenderWidgetHostView() : nullptr;
  const auto check = base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check");
  CopyTabSurface(contents_, view, live_id_, gfx::Rect(), gfx::Size(320, 200),
                 false, check == "transfer" || check == "transfer-ext",
                 ^(NSImage* image, const char*, int) { completion(image); });
}

- (void)reserveSwitcherThumbnail {
  if (!contents_ || contents_->GetVisibility() != content::Visibility::VISIBLE ||
      thumbnail_navigating_) return;
  if (HasBlankSwitcherURL(contents_)) {
    TraceSwitcherThumbnail(host_, live_id_, "reserve", "skipped", "blank-url", -1, 0);
    return;
  }
  if (!contents_->CompletedFirstVisuallyNonEmptyPaint()) return;
  ARWindowHost* host = host_;
  id<ARWindowHostDelegate> delegate = host.delegate;
  if (![delegate respondsToSelector:@selector(windowHost:reserveSwitcherThumbnailForTab:afterDelay:)]) return;
  const auto* stamp = SwitcherReserveStamp::GetForPage(contents_->GetPrimaryPage());
  [delegate windowHost:host reserveSwitcherThumbnailForTab:self afterDelay:stamp ? stamp->DelayUntilNextRequest() : 0];
}

- (void)checkStopSwitcherNavigation {
  if (contents_ && base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-screen") == "tab-switcher")
    contents_->Stop();
}

- (void)captureSwitcherThumbnailForReserve:(BOOL)reserve
                                    retry:(BOOL)retry
                               completion:(BOOL (^)(NSImage*, NSNumber*))completion {
  const base::TimeTicks start = base::TimeTicks::Now();
  NSString* live = live_id_;
  NSString* item = self.itemId;
  __weak ARWindowHost* weak_host = host_;
  const char* source = reserve ? "reserve" : "prehide";
  void (^event)(const char*, const char*, int) = ^(const char* status, const char* reason, int viz_error) {
    TraceSwitcherThumbnail(weak_host, live, source, status, reason, viz_error,
                           (base::TimeTicks::Now() - start).InMillisecondsF(), retry);
  };
  auto* view = contents_ ? contents_->GetRenderWidgetHostView() : nullptr;
  const gfx::Size viewport = view ? view->GetVisibleViewportSize() : gfx::Size();
  const int units = std::min(viewport.width() / 3, viewport.height() / 2);
  const char* skip = nullptr;
  if (thumbnail_navigating_) skip = "navigation-pending";
  else if (HasBlankSwitcherURL(contents_)) skip = "blank-url";
  else if (!view) skip = "no-view";
  else if (self.crashed) skip = "crashed";
  else if (contents_->GetVisibility() != content::Visibility::VISIBLE ||
           (reserve && !view->IsShowing())) skip = "not-visible";
  else if (!contents_->CompletedFirstVisuallyNonEmptyPaint()) skip = "no-paint";
  else if (!units) skip = "empty-viewport";
  else if (!view->IsSurfaceAvailableForCopy()) skip = "no-surface";
  if (!skip && reserve) {
    auto* stamp = SwitcherReserveStamp::GetOrCreateForPage(contents_->GetPrimaryPage());
    if (!stamp) skip = "error";
    else if (retry && !stamp->retry_scheduled) skip = "stale-document";
    else if (!stamp->last_request.is_null() && start - stamp->last_request < base::Seconds(2))
      skip = "rate-limited";
    else
      stamp->last_request = start;
  }
  if (skip) {
    event("skipped", skip, -1);
    completion(nil, nil);
    return;
  }
  const gfx::Rect crop((viewport.width() - units * 3) / 2, 0, units * 3, units * 2);
  __weak ARTab* weak_tab = self;
  const NSUInteger document = thumbnail_document_generation_;
  event("requested", "none", -1);
  CopyTabSurface(contents_, view, live_id_, crop, gfx::Size(312, 208),
                 true, false, ^(NSImage* image, const char* failure, int viz_error) {
    ARTab* tab = weak_tab;
    const bool stale = !tab || document != tab->thumbnail_document_generation_;
    if (stale) image = nil;
    event(image ? "completed" : "failed", image ? "none" : (stale ? "stale-document" : failure), viz_error);
    image.size = NSMakeSize(156, 104);
    base::WeakPtr<content::Page> retry_page;
    NSNumber* retry_delay = nil;
    if (!image && reserve && !retry && !stale && tab->contents_ && weak_host &&
        tab->host_ == weak_host && [tab.itemId isEqualToString:item] &&
        tab->contents_->GetVisibility() == content::Visibility::VISIBLE) {
      auto* showing_view = tab->contents_->GetRenderWidgetHostView();
      if (showing_view && showing_view->IsShowing()) {
        auto& page = tab->contents_->GetPrimaryPage();
        const auto* stamp = SwitcherReserveStamp::GetForPage(page);
        if (stamp && !stamp->retry_scheduled) {
          retry_page = page.GetWeakPtr();
          retry_delay = @(stamp->DelayUntilNextRequest());
        }
      }
    }
    if (completion(image, retry_delay) && retry_page) {
      if (auto* stamp = SwitcherReserveStamp::GetForPage(*retry_page))
        stamp->retry_scheduled = true;
    }
  });
}

- (void)setSwitcherThumbnailNavigating:(BOOL)navigating { thumbnail_navigating_ = navigating; }

- (void)invalidateSwitcherThumbnail {
  ++thumbnail_document_generation_;
  id<ARWindowHostDelegate> delegate = host_.delegate;
  if ([delegate respondsToSelector:@selector(windowHost:invalidateSwitcherThumbnailForTab:)])
    [delegate windowHost:host_ invalidateSwitcherThumbnailForTab:self];
}

- (BOOL)takePendingNavigation {
  return [host_ takePendingNavigationForTab:self];
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
    [host_ tabMetadataChanged:@"title" tab:self];
  }
  if (![url_ isEqualToString:url]) {
    [self willChangeValueForKey:@"url"];
    url_ = url;
    [self didChangeValueForKey:@"url"];
  }
  if (loading_ != loading) {
    [self willChangeValueForKey:@"isLoading"];
    loading_ = loading;
    [host_ traceTabEvent:@"isLoading" tab:self];
    [self didChangeValueForKey:@"isLoading"];
  }
  BOOL loadingUI = contents_->ShouldShowLoadingUI();
  if (loading_ui_ != loadingUI) {
    loading_ui_ = loadingUI;
    [host_ tabMetadataChanged:@"loading-ui" tab:self];
  }
}

- (void)invalidate {
  if (!contents_) return;
  [self invalidateSwitcherThumbnail];
  AraratCheckUnregisterBeforeUnload(base::SysNSStringToUTF8(live_id_), contents_);
  [self willChangeValueForKey:@"view"];
  contents_ = nullptr;
  observer_->Stop();
  [self didChangeValueForKey:@"view"];
}

- (void)replaceContents:(content::WebContents*)contents {
  [self invalidateSwitcherThumbnail];
  thumbnail_navigating_ = NO;
  AraratCheckUnregisterBeforeUnload(base::SysNSStringToUTF8(live_id_), contents_);
  [self willChangeValueForKey:@"view"];
  network_error_ = 0;
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
