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
- (BOOL)isLittleWindowForWindowHost:(id<ARWindowHostAPI>)host;
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
- (NSDictionary<NSString*, id>*)checkExtensionActionPopup;
- (void)checkDismissExtensionActionPopup;
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
// U27h: a page-only Little Window in this host's profile Browser, at an AppKit screen frame.
// NO when the profile's Browser is not in this host; the caller keeps the current window.
- (BOOL)openLittleWindow:(NSString*)url profile:(NSString*)profile frame:(NSRect)frame;
- (void)prepareTransferProfile:(NSString*)profile;
- (BOOL)checkMoveTab:(id<ARTabAPI>)tab toHost:(id<ARWindowHostAPI>)destination;
- (nullable NSDictionary<NSString*, id>*)navigationTarget;
- (BOOL)navigateURL:(NSString*)url target:(NSDictionary<NSString*, id>*)target;
- (BOOL)navigateLittleWindow:(NSString*)url;
- (void)findAction:(NSString*)action text:(NSString*)text selection:(NSRange)selection liveId:(NSString*)liveId profile:(NSString*)profile;
- (nullable NSString*)activeItemId;
- (BOOL)runCommand:(NSString*)command;
- (nullable NSString*)currentSiteDomain;
- (double)checkZoomLevel;
- (NSDictionary<NSString*, id>*)checkSiteClearResults;
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
- (void)checkNewTab;
- (void)checkNewWindow;
- (void)checkNewIncognitoWindow;
- (void)checkSavePage;
- (void)checkNavigateOffTheRecord;
- (NSDictionary<NSString*, id>*)checkFullscreenState;
- (void)checkFullscreenAction:(NSInteger)action;
- (void)forceReload;
- (BOOL)isPrivateWindow;
- (BOOL)checkRefuseOpenWithoutBrowser;
- (BOOL)checkRoutingDomain;
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
// U27w: Settings › Websites. The app's synced core record is the source of the seven
// per-permission defaults; applying it writes every regular profile's HostContentSettingsMap
// default now and for a profile added later. A private profile inherits through Chromium. The
// core record refuses a value its kind cannot take as a default (camera and microphone take no
// Allow; pop-ups and sound take no Ask), so this call receives only accepted defaults.
__attribute__((visibility("default")))
void AraratApplySiteDefaults(NSDictionary<NSString*, NSString*>* defaults);
// One entry per stored user exception of the seven kinds: profile directory, origin, kind and
// the permission-setting dictionary the site snapshot uses. Policy, extension, one-time and
// default (wildcard) entries are not listed.
__attribute__((visibility("default")))
NSArray<NSDictionary<NSString*, id>*>* AraratSiteExceptions(void);
// Writes one origin's exception of one kind in one profile; a nil setting resets that kind.
__attribute__((visibility("default")))
BOOL AraratSetSiteException(NSString* profile, NSString* origin, NSString* kind,
                            NSDictionary<NSString*, id>* _Nullable setting);
// Clears the site's cookies, storage and cache for its registrable domain in one profile (W3):
// one BrowsingDataRemover task with a domain filter. The reply is the failed data types bitmask,
// not a count, and is always called.
__attribute__((visibility("default")))
void AraratClearSiteData(NSString* profile, NSString* origin, void (^completion)(uint64_t failedDataTypes));
// U27x: Settings › Extensions. One profile's extensions, as Chromium's own extensions page lists
// them: id, name, icon (NSImage or NSNull), enabled, needsReview (disabled for a permissions
// increase), disableReasons (raw values), siteAccess ("all", "specific", "click" or "none" when the
// extension requests no site access), pinned and canPin (the toolbar action and its pin prefs),
// canDisable (Chromium's rule for offering the switch), removable. The list is empty when the
// profile does not exist or is not regular; while a profile that exists but is not loaded yet is
// being loaded it is one entry {"loading": true}, so the pane keeps its rows instead of drawing
// the empty state.
__attribute__((visibility("default")))
NSArray<NSDictionary<NSString*, id>*>* AraratExtensions(NSString* profile);
// Enables or disables one extension: "done", "unchanged", "unknown", "policy", or "review" when
// Chromium disabled it for a permissions increase (only the re-enable prompt may enable it).
__attribute__((visibility("default")))
NSString* AraratSetExtensionEnabled(NSString* profile, NSString* identifier, BOOL enabled);
// Writes the profile's user site access for one extension: "all" or "click" (a site-by-site
// choice stays Chromium's page). The reply is "done", "unsupported" or "unknown".
__attribute__((visibility("default")))
NSString* AraratSetExtensionSiteAccess(NSString* profile, NSString* identifier, NSString* access);
// Pins or unpins one extension's action in the profile's toolbar, as the action menu does:
// "done", "unchanged", "forced", "unknown" or "incognito".
__attribute__((visibility("default")))
NSString* AraratSetExtensionPinned(NSString* profile, NSString* identifier, BOOL pinned);
// Opens Chromium's re-enable prompt for an extension disabled for a permissions increase; an
// accepted prompt grants the permissions and enables it. The completion reports whether it was
// accepted, and is always called.
__attribute__((visibility("default")))
void AraratReviewExtension(NSString* profile, NSString* identifier, NSWindow* _Nullable window,
                           void (^completion)(BOOL allowed));
// U27x: the pane's Remove… asks in its own AppKit sheet (the app layer) and this entry performs the
// uninstall through the registrar, which re-applies the management policy. "" on success;
// "unknown" when the profile or extension is gone, "forced" when the policy forbids it, otherwise
// the registrar's error text. Chromium's own uninstall dialog is not used by the pane because it
// cannot host a Views modal under the settings window; the context-menu Remove… keeps it.
__attribute__((visibility("default")))
NSString* AraratRemoveExtension(NSString* profile, NSString* identifier);
// X5: called on the main thread when any regular profile's extension registry changes (install,
// removal, enable, disable). Pass nil to stop.
__attribute__((visibility("default")))
void AraratSetExtensionsChangedHandler(void (^ _Nullable handler)(void));
// Check-only: installs an unpacked fixture into one profile ("loaded" or an error). Refused
// outside a check run. Unpacked updates are trusted locations, so Chrome never disables them for
// a permissions increase; the next call produces that state for the settings check.
__attribute__((visibility("default")))
void AraratCheckLoadUnpackedExtension(NSString* profile, NSString* path,
                                      void (^completion)(NSString* result));
// Check-only: marks an installed extension as disabled for a permissions increase.
__attribute__((visibility("default")))
void AraratCheckDisableExtensionForReview(NSString* profile, NSString* identifier);
// Check-only: accepts ("accept") the re-enable prompt the Review… action opened, and returns the
// dialog's contents class ("ExtensionInstallDialogView") or an empty string when it is not up. The
// seam is accept-download-close's (views::Widget::GetWidgetForNativeWindow, then the dialog
// delegate), because the VM's in-process accessibility tree is empty. The pane's Remove… is an
// AppKit sheet and needs no seam.
__attribute__((visibility("default")))
NSString* AraratCheckExtensionDialog(NSWindow* _Nullable parent, NSString* action);
// U27p: Settings › Privacy. The app's synced core record is the source of the third-party cookie
// mode, the Global Privacy Control signal and the browsing-history retention. Applying it writes
// every regular profile's cookie-controls pref and GPC pref now and for a profile added later,
// and sets the history expiry's retention (days; 0 is Forever, -1 keeps Chromium's 90 days).
// Chromium 157's GPC needs kUniversalOptOut and kUniversalOptOutSettings enabled plus the
// universal_optout.enabled pref, which AraratMain adds to the process's feature list.
__attribute__((visibility("default")))
void AraratApplyPrivacySettings(NSDictionary<NSString*, id>* settings);
// P4: clears the chosen types (1 history, 2 cookies and other site data, 4 cached images and
// files) for the range in one profile, through one BrowsingDataRemover task. The times are
// seconds since 1970; a 0 begin is the beginning of time. The reply is the failed data types
// bitmask, not a count, and is always called.
__attribute__((visibility("default")))
void AraratClearBrowsingData(NSString* profile, double beginSeconds, double endSeconds,
                             uint64_t types, void (^completion)(uint64_t failedDataTypes));
// Check-only: adds one history visit for a URL at the given age, and answers whether the service
// accepted it. Refused outside a check run by the launch guard's screen list.
__attribute__((visibility("default")))
void AraratCheckSeedHistoryVisit(NSString* profile, NSString* url, double daysAgo,
                                 void (^completion)(BOOL done));
// Check-only: the URL's visit times, seconds since 1970, for the retention and clear conditions.
__attribute__((visibility("default")))
void AraratCheckHistoryVisitTimes(NSString* profile, NSString* url,
                                  void (^completion)(NSArray<NSNumber*>* times));
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
