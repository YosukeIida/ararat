#include "ararat/core/ararat_tab.h"

#include <memory>
#include <cstdio>

#include "ararat/core/public/ARWindowHost.h"
#include "ararat/core/ararat_permission_prompt.h"
#include "ararat/core/ararat_autofill_bubble_handler.h"
#include "ararat/core/ararat_window_host.h"
#include "base/check.h"
#include "base/command_line.h"
#include "base/functional/callback.h"
#include "base/functional/bind.h"
#include "base/json/json_writer.h"
#include "base/values.h"
#include "base/strings/sys_string_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "chrome/common/chrome_isolated_world_ids.h"
#include "chrome/browser/external_protocol/external_protocol_handler.h"
#include "chrome/browser/autofill/personal_data_manager_factory.h"
#include "chrome/browser/ui/autofill/payments/save_card_bubble_controller_impl.h"
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
#include "components/permissions/permission_request_manager.h"
#include "components/find_in_page/find_tab_helper.h"
#include "components/find_in_page/find_notification_details.h"
#include "content/public/browser/javascript_dialog_manager.h"
#include "content/public/browser/web_contents_delegate.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/weak_document_ptr.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/common/isolated_world_ids.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/navigation_handle.h"
#include "url/gurl.h"
#include "url/origin.h"
#include "ui/views/controls/button/md_text_button.h"
#include "ui/views/widget/widget.h"
#include "ui/views/window/dialog_delegate.h"

@interface NSObject (AraratCheckInputObservation)
- (int)textInputType;
- (BOOL)isHandlingKeyDown;
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
  return base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-screen") == "prompts";
}
class TabContentsObserver : public content::WebContentsObserver {
 public:
  TabContentsObserver(content::WebContents* contents, ARTab* tab)
      : tab_(tab) { Observe(contents); }
  void Stop() { Observe(nullptr); }
  void DidFinishNavigation(content::NavigationHandle* navigation) override {
    if (navigation->HasCommitted() && navigation->IsInPrimaryMainFrame()) {
      if (!navigation->IsSameDocument() && tab_ && web_contents())
        AraratCheckRevokeChangedDocument(base::SysNSStringToUTF8([tab_ liveId]), web_contents());
      [tab_ navigationFinished];
    }
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
- (BOOL)isLoading { DCHECK([NSThread isMainThread]); return loading_; }
- (NSUInteger)navigationCount { DCHECK([NSThread isMainThread]); return navigation_count_; }
- (content::WebContents*)contents { return contents_; }

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
  auto* delegate = widget ? widget->widget_delegate()->AsDialogDelegate() : nullptr;
  auto* button = delegate ? delegate->GetCancelButton() : nullptr;
  NSWindow* window = widget ? widget->GetNativeWindow().GetNativeNSWindow() : nil;
  if (!button || !window) return @{};
  const auto bounds = button->GetBoundsInScreen();
  if (bounds.IsEmpty()) return @{};
  const CGFloat top = NSMaxY(NSScreen.screens.firstObject.frame);
  NSRect screen = NSMakeRect(bounds.x(), top - bounds.y() - bounds.height(), bounds.width(), bounds.height());
  return @{ @"window": window, @"frame": [NSValue valueWithRect:[window convertRectFromScreen:screen]] };
}

- (BOOL)checkPermissionPending {
  if (!contents_ || base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check") != "permissions") return NO;
  auto* manager = permissions::PermissionRequestManager::FromWebContents(contents_);
  return manager && (manager->IsRequestInProgress() || manager->has_pending_requests());
}

- (void)checkRequestPermission:(NSInteger)request {
  if (!contents_ || (base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check") != "permissions" && !IsPromptScreen())) return;
  const char16_t* scripts[] = {u"window.requestNotifications()", u"window.requestLocation()", u"window.requestMidi()"};
  if (request < 0 || request >= 3) return;
  contents_->GetPrimaryMainFrame()->ExecuteJavaScriptWithUserGestureForTests(
      scripts[request], base::NullCallback(), content::ISOLATED_WORLD_ID_GLOBAL);
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
  if (!contents_ || (check != "dialogs" && check != "protocol" && check != "autofill" && !IsPromptScreen())) return NO;
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
  if (!AraratCheckRegisterBeforeUnload(base::SysNSStringToUTF8(live_id_), contents_)) return;
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
  AraratCheckUnregisterBeforeUnload(base::SysNSStringToUTF8(live_id_), contents_);
  [self willChangeValueForKey:@"view"];
  contents_ = nullptr;
  observer_->Stop();
  [self didChangeValueForKey:@"view"];
}

- (void)replaceContents:(content::WebContents*)contents {
  AraratCheckUnregisterBeforeUnload(base::SysNSStringToUTF8(live_id_), contents_);
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
