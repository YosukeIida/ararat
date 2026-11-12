#ifndef ARARAT_PUBLIC_ARARAT_HOST_API_H_
#define ARARAT_PUBLIC_ARARAT_HOST_API_H_

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol ARTabAPI <NSObject>
@property(nonatomic, readonly, copy) NSString* liveId;
@property(nonatomic, copy, nullable) NSString* itemId;
@property(nonatomic, readonly, copy) NSString* title;
@property(nonatomic, readonly, copy) NSString* url;
@property(nonatomic, readonly, nullable) NSImage* favicon;
@property(nonatomic, readonly) BOOL isLoading;
@property(nonatomic, readonly) NSUInteger navigationCount;
@property(nonatomic, readonly) NSUInteger entryCount;
@property(nonatomic, readonly) BOOL canGoBack;
@property(nonatomic, readonly) BOOL crashed;
@property(nonatomic, readonly) NSInteger networkError;
- (void)reload;
- (void)focus;
- (void)checkFlushHistory:(void (^)(BOOL written))completion;
- (void)captureSnapshot:(void (^)(NSImage* _Nullable image))completion;
@property(nonatomic, readonly, nullable) NSView* view;
- (void)activateWithCommandId:(NSString*)commandId;
- (void)closeWithCommandId:(NSString*)commandId;
- (BOOL)sendCheckMouseMoved:(NSEvent*)event;
- (BOOL)checkCrashRenderer;
- (void)prepareCheckBeforeUnload;
- (BOOL)checkHasBeforeUnload;
- (void)focusCheckPage;
- (void)openCheckPopup;
- (void)probeCheckOpener;
- (BOOL)checkOpenerAlive;
- (void)closeCheckPopup;
- (void)checkFocusExtensionWindow;
- (void)checkPrepareExtensionFocus;
- (void)checkPrepareExtensionWindows;
- (void)checkReportExtensionWindow;
- (void)checkReloadExtensionWindow;
- (void)checkExtensionPopupWindow:(BOOL)remove;
- (void)checkOpenActionPopup;
- (BOOL)checkIsDialogActive;
- (BOOL)checkDialogHostIsOurs;
- (BOOL)checkAcceptJavaScriptDialog:(NSString*)text;
- (BOOL)checkCancelJavaScriptDialog;
- (void)checkRunJavaScriptDialog:(NSInteger)dialog;
- (void)checkDialogResults:(void (^)(NSString*))completion;
- (void)checkScreenWebAuthn:(BOOL)create;
- (BOOL)checkScreenAddress:(BOOL)seed;
- (void)checkScreenFocusAddress;
- (NSDictionary<NSString*, id>*)checkProtocol:(NSString*)scheme launch:(BOOL)launch;
- (BOOL)checkCloseModalDialogs;
- (BOOL)checkCancelScreenDialog:(NSWindow*)window;
- (NSUInteger)checkPermissionShownCount;
- (BOOL)checkPermissionDecision:(NSInteger)decision;
- (NSDictionary<NSString*, id>*)checkPermissionBlockButton;
- (BOOL)checkPermissionWidgetVisible;
- (NSDictionary<NSString*, id>*)checkPermissionWidgetState;
- (BOOL)checkPermissionPending;
- (void)checkRequestPermission:(NSInteger)request;
- (void)checkActivateSplitPane;
- (void)checkPermissionResults:(void (^)(NSString*))completion;
- (BOOL)checkAutofillBubble:(BOOL)card decline:(BOOL)decline;
- (NSDictionary<NSString*, id>*)checkAutofillState;
- (void)checkRefreshAutofillData;
- (void)checkAutofillAction:(NSInteger)action;
- (void)checkFullscreenRequest:(BOOL)enter;
- (void)checkFullscreenElement:(void (^)(BOOL))completion;
- (void)checkKeyboardScript:(NSInteger)script completion:(void (^)(NSString*))completion;
- (BOOL)checkKeyboardIME;
- (NSArray<NSDictionary<NSString*, id>*>*)checkKeyboardIMEState;
- (NSDictionary<NSString*, id>*)checkNavigationState;
- (void)checkStartBackgroundFind:(NSString*)text;
- (NSDictionary<NSString*, id>*)checkBackgroundFindState;
- (BOOL)checkHoldFindReply:(NSString*)text;
- (BOOL)checkHeldFindTargetAlive;
- (NSDictionary<NSString*, id>*)checkDeliverHeldFindReply;
@end

@protocol ARWindowHostAPI;
@protocol ARWindowHostDelegate <NSObject>
- (NSView*)pageCardForWindowHost:(id<ARWindowHostAPI>)host;
- (void)windowHost:(id<ARWindowHostAPI>)host
    didReceiveTransaction:(NSDictionary<NSString*, id>*)transaction;
- (void)windowHost:(id<ARWindowHostAPI>)host showProfile:(NSString*)profile;
- (void)windowHostClosingAllCancelled:(id<ARWindowHostAPI>)host;
- (void)windowHostWillBeginClosing:(id<ARWindowHostAPI>)host;
- (void)windowHost:(id<ARWindowHostAPI>)host pageFullscreenChanged:(BOOL)fullscreen;
- (void)windowHost:(id<ARWindowHostAPI>)host windowFullscreenChanged:(BOOL)fullscreen;
- (void)windowHost:(id<ARWindowHostAPI>)host performWorkspaceCommand:(NSString*)command;
- (void)windowHost:(id<ARWindowHostAPI>)host updateFindBar:(NSDictionary<NSString*, id>*)state;
- (BOOL)findBarHasFocusForWindowHost:(id<ARWindowHostAPI>)host;
- (void)windowHost:(id<ARWindowHostAPI>)host findPageRectChanged:(NSRect)rect;
@optional
- (void)siteStateChangedForWindowHost:(id<ARWindowHostAPI>)host;
- (void)extensionActionsChangedForWindowHost:(id<ARWindowHostAPI>)host;
- (void)windowHost:(id<ARWindowHostAPI>)host downloadsChanged:(NSArray<NSDictionary<NSString*, id>*>*)items newDownload:(nullable NSString*)identifier flight:(BOOL)flight;
- (void)windowHost:(id<ARWindowHostAPI>)host permissionDim:(NSString*)identifier
        container:(NSView*)container frame:(NSRect)frame visible:(BOOL)visible;
- (BOOL)windowHost:(id<ARWindowHostAPI>)host shouldOpenCommand:(NSString*)commandId itemId:(NSString*)itemId;
- (void)windowHost:(id<ARWindowHostAPI>)host prepareCloseHandoff:(void (^)(BOOL ready))completion;
- (BOOL)windowHost:(id<ARWindowHostAPI>)host installSplitMeasurement:(NSUInteger)count;
- (BOOL)windowHost:(id<ARWindowHostAPI>)host dragSplitMeasurement:(CGFloat)delta finished:(BOOL)finished;
@end

@protocol ARWindowHostAPI <NSObject>
// A missing site setting is NSNull; allowed includes valid mixed geolocation values.
// The blocked flag includes cookie and policy blocks, but excludes automatic downloads and storage access.
// An embargo alone does not count as a site-specific block until content is refused.
// Security and certificates use the visible entry and can differ from the committed origin while navigating; error includes Safe Browsing.
// Closing after a change drops the reload hint; focus and navigation recreate PageInfo and record its open metrics.
// Swift wrappers and focused bridge tests are left to the UI integration.
- (NSDictionary<NSString*, id>*)siteState;
- (BOOL)changeSitePermission:(NSDictionary<NSString*, id>*)request;
- (void)closeSiteControls;
// Capture completions are asynchronous; devtoolsBusy includes an existing capture.
- (void)captureFullPageForDocument:(NSString*)document completion:(void (^)(NSData* _Nullable png, NSString* _Nullable error))completion;
// The rectangle uses the focused page's contents->GetNativeView() points, with the origin at its top left.
- (void)captureRegion:(NSRect)rect document:(NSString*)document completion:(void (^)(NSData* _Nullable png, NSString* _Nullable error))completion;
- (NSArray<NSDictionary<NSString*, id>*>*)downloads;
- (BOOL)performDownloadAction:(NSString*)action identifier:(NSString*)identifier;
- (NSArray<NSDictionary<NSString*, id>*>*)extensionActions;
- (NSArray<NSDictionary<NSString*, id>*>*)extensionActionsWithIconSize:(NSUInteger)size;
- (NSString*)setExtensionPinned:(NSString*)identifier pinned:(BOOL)pinned;
// Open the returned URL through the shown space's existing new-tab command path.
- (nullable NSString*)extensionManagementURL:(NSString*)identifier;
// Completion is asynchronous. Chrome's browser-modal fallback requires VM verification.
// Report-abuse and setUninstallURL tabs require VM verification in the hosted window.
- (void)removeExtension:(NSString*)identifier completion:(void (^)(NSString* result, NSString* detail))completion;
- (void)setExtensionAnchor:(NSRect)rect;
- (void)runExtensionAction:(NSString*)identifier;
- (BOOL)checkIsExtensionAppPopup;
- (void)checkExtensionAction:(NSInteger)command;
- (NSDictionary<NSString*, id>*)checkExtensionActionState;
- (void)checkOpenDevTools;
- (void)checkCloseDevTools;
- (NSDictionary<NSString*, id>*)checkDevToolsState;
- (NSDictionary<NSString*, id>*)checkPagePresentation:(NSString*)liveId;
- (NSDictionary<NSString*, id>*)checkDevToolsTabState:(NSString*)liveId;
- (BOOL)checkSetDevToolsDocked:(BOOL)docked;
- (NSUInteger)checkDevToolsHostCount;
- (BOOL)checkInspectElement;
- (BOOL)checkFocusDevTools;
- (void)checkDevToolsFrontend:(void (^)(NSString*))completion;
@property(nonatomic, weak, nullable) id<ARWindowHostDelegate> delegate;
- (NSWindow*)window;
- (BOOL)hasBrowser;
- (void)activateBrowser;
- (BOOL)isClosing;
- (BOOL)setProfileDirectory:(NSString*)directory;
- (BOOL)setClosePresentationProfile:(NSString*)directory;
- (NSString*)profileDirectory;
- (BOOL)hasProfileDirectory:(NSString*)directory;
- (BOOL)hasBrowserForProfile:(NSString*)directory;
- (BOOL)isClosingAll;
- (void)checkCreateRestoreBrowser;
- (BOOL)openURL:(NSString*)url commandId:(NSString*)commandId itemId:(NSString*)itemId;
- (BOOL)openExternalURL:(NSString*)url commandId:(NSString*)commandId itemId:(NSString*)itemId untrusted:(BOOL)untrusted;
- (BOOL)openURL:(NSString*)url commandId:(NSString*)commandId itemId:(NSString*)itemId profile:(NSString*)profile external:(BOOL)external untrusted:(BOOL)untrusted historyStamp:(uint64_t)stamp;
- (BOOL)openBackgroundURL:(NSString*)url commandId:(NSString*)commandId itemId:(NSString*)itemId profile:(NSString*)profile historyStamp:(uint64_t)stamp;
- (BOOL)cancelPendingOpen:(NSString*)commandId;
- (NSArray*)tabs;
- (void)setTabMuted:(BOOL)muted itemId:(NSString*)itemId;
- (BOOL)hasActiveTab;
- (void)setWorkspacePageHidden:(BOOL)hidden;
- (void)setWorkspaceRemote:(BOOL)remote;
- (BOOL)setSplitFrames:(NSDictionary<NSString*, NSValue*>*)frames frozen:(BOOL)frozen;
- (BOOL)transferTab:(id<ARTabAPI>)tab commandId:(NSString*)commandId;
- (BOOL)handoffTab:(id<ARTabAPI>)tab activate:(BOOL)activate;
- (void)prepareTransferProfile:(NSString*)profile;
- (BOOL)checkMoveTab:(id<ARTabAPI>)tab toHost:(id<ARWindowHostAPI>)destination;
- (nullable NSDictionary<NSString*, id>*)navigationTarget;
- (BOOL)navigateURL:(NSString*)url target:(NSDictionary<NSString*, id>*)target;
- (void)findAction:(NSString*)action text:(NSString*)text selection:(NSRange)selection liveId:(NSString*)liveId profile:(NSString*)profile;
- (nullable NSString*)activeItemId;
- (void)close;
- (void)installCheckDialogFactory;
- (void)expectCheckDialogs:(NSUInteger)limit;
- (BOOL)checkDialogIntegrity;
- (NSUInteger)checkDialogCount;
- (void)configureProfileCloseCheck:(NSUInteger)cancelDialog;
- (NSDictionary<NSString*, id>*)checkProfileCloseState;
- (NSArray<NSNumber*>*)checkClosingEvents;
- (BOOL)checkTryingToQuit;
- (NSUInteger)checkStockBrowsers;
- (NSUInteger)checkBrowserViews;
- (void)disableCheckConfirmQuit;
- (void)checkNavigate:(NSString*)url disposition:(NSString*)disposition;
- (void)checkCreateDeferredBrowsers;
- (void)checkMenuCommand:(BOOL)newWindow;
- (BOOL)checkFocusSearch;
- (NSDictionary<NSString*, id>*)checkEmptyMenuValidation;
- (NSDictionary<NSString*, id>*)checkEmptySessionRestore;
- (void)checkEnsureEmptyBrowser;
- (void)checkCloseAllTabs;
- (void)checkOpenURLs;
- (NSString*)checkOpenLinkNewWindowTitle;
- (NSDictionary<NSString*, id>*)checkProfileState;
- (void)checkCookieIsolation;
- (NSDictionary<NSString*, id>*)checkCookieState;
- (void)checkCloseTabsForProfile:(NSString*)profile;
- (void)checkActivateShownProfile;
- (void)checkCreateIncognito;
- (void)checkNavigateOffTheRecord;
- (NSDictionary<NSString*, id>*)checkFullscreenState;
- (void)checkFullscreenAction:(NSInteger)action;
- (void)forceReload;
- (BOOL)isPrivateWindow;
- (int)checkInProgressDownloadCount;
- (BOOL)prepareCheckDownload;
- (NSString*)prepareDownloadsCheckDirectory:(NSString*)name;
- (NSDictionary<NSString*, id>*)downloadsCheckSettings;
- (void)queryHistory:(NSString*)text completion:(void (^)(NSArray<NSDictionary<NSString*, id>*>*))completion;
- (void)checkKeyboardCommand:(NSString*)command;
- (void)checkSetFindPasteboard:(NSString*)text;
- (BOOL)checkCloseFindEnabled;
- (NSUInteger)checkPageOnlySaveCount;
- (BOOL)checkReplaceActiveForKeyboard;
- (BOOL)checkKeyboardAccelerator:(BOOL)action;
- (BOOL)checkKeyboardDevTools;
- (BOOL)checkReassignInactiveAction;
- (BOOL)checkReassignProbeCommand:(BOOL)collision;
- (BOOL)checkReassignedAction;
- (BOOL)checkShortcutActivation;
- (BOOL)checkViewlessBubbleAnchor;
- (NSDictionary<NSString*, id>*)checkViewlessBubbleAnchorGeometry;
- (void)checkShowViewlessBubble:(NSInteger)kind;
- (NSDictionary<NSString*, id>*)checkViewlessBubbleState;
- (void)checkCloseViewlessBubble;
@end

#ifdef __cplusplus
extern "C" {
#endif
__attribute__((visibility("default")))
id<ARWindowHostAPI> AraratWindowHostCreate(NSView* contentView, NSString* windowId);
__attribute__((visibility("default")))
void AraratStartMeasure(id<ARWindowHostAPI> host, NSString* scenario);
__attribute__((visibility("default")))
NSString* _Nullable AraratUserDataDirectory(void);
__attribute__((visibility("default")))
void AraratPurgeTabHistory(NSString* profile, NSString* itemId, uint64_t changedAt, void (^completion)(BOOL ok));
__attribute__((visibility("default")))
void AraratFinishCrashRecovery(void);
__attribute__((visibility("default")))
NSDictionary* AraratCheckCrashState(NSString* profile);
__attribute__((visibility("default")))
void AraratCheckCommitProfilePrefs(NSString* profile, void (^completion)(BOOL done));
__attribute__((visibility("default")))
void AraratCheckTabHistoryFile(NSString* profile, NSString* itemId, void (^completion)(NSDictionary* state));
__attribute__((visibility("default")))
void AraratCheckDeleteHistory(NSString* profile, NSInteger mode, void (^completion)(BOOL done));
__attribute__((visibility("default")))
NSUInteger AraratBrowserCount(void);
__attribute__((visibility("default")))
NSUInteger AraratExclusiveInputCount(void);
__attribute__((visibility("default")))
void AraratFinishSliceCheck(BOOL passed);
#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
#endif
