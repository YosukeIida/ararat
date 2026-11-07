#ifndef ARARAT_PUBLIC_ARARAT_HOST_API_H_
#define ARARAT_PUBLIC_ARARAT_HOST_API_H_

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol ARTabAPI <NSObject>
@property(nonatomic, readonly, copy) NSString* liveId;
@property(nonatomic, copy, nullable) NSString* itemId;
@property(nonatomic, readonly, copy) NSString* title;
@property(nonatomic, readonly, copy) NSString* url;
@property(nonatomic, readonly) BOOL isLoading;
@property(nonatomic, readonly) NSUInteger navigationCount;
@property(nonatomic, readonly, nullable) NSView* view;
- (void)activateWithCommandId:(NSString*)commandId;
- (void)closeWithCommandId:(NSString*)commandId;
- (BOOL)sendCheckMouseMoved:(NSEvent*)event;
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
- (NSUInteger)checkPermissionShownCount;
- (BOOL)checkPermissionDecision:(NSInteger)decision;
- (NSDictionary<NSString*, id>*)checkPermissionBlockButton;
- (BOOL)checkPermissionPending;
- (void)checkRequestPermission:(NSInteger)request;
- (void)checkPermissionResults:(void (^)(NSString*))completion;
- (BOOL)checkAutofillBubble:(BOOL)card decline:(BOOL)decline;
- (NSDictionary<NSString*, id>*)checkAutofillState;
- (void)checkRefreshAutofillData;
- (void)checkAutofillAction:(NSInteger)action;
@end

@protocol ARWindowHostAPI;
@protocol ARWindowHostDelegate <NSObject>
- (NSView*)pageCardForWindowHost:(id<ARWindowHostAPI>)host;
- (void)windowHost:(id<ARWindowHostAPI>)host
    didReceiveTransaction:(NSDictionary<NSString*, id>*)transaction;
- (void)windowHost:(id<ARWindowHostAPI>)host showProfile:(NSString*)profile;
- (void)windowHostClosingAllCancelled:(id<ARWindowHostAPI>)host;
@end

@protocol ARWindowHostAPI <NSObject>
- (NSArray<NSDictionary<NSString*, id>*>*)extensionActions;
- (void)setExtensionAnchor:(NSRect)rect;
- (void)runExtensionAction:(NSString*)identifier;
- (BOOL)checkIsExtensionAppPopup;
- (void)checkExtensionAction:(NSInteger)command;
- (NSDictionary<NSString*, id>*)checkExtensionActionState;
- (void)checkOpenDevTools;
- (void)checkCloseDevTools;
- (NSDictionary<NSString*, id>*)checkDevToolsState;
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
- (NSString*)profileDirectory;
- (BOOL)hasProfileDirectory:(NSString*)directory;
- (BOOL)hasBrowserForProfile:(NSString*)directory;
- (BOOL)isClosingAll;
- (void)checkCreateRestoreBrowser;
- (BOOL)openURL:(NSString*)url commandId:(NSString*)commandId itemId:(NSString*)itemId;
- (BOOL)openExternalURL:(NSString*)url commandId:(NSString*)commandId itemId:(NSString*)itemId untrusted:(BOOL)untrusted;
- (BOOL)openURL:(NSString*)url commandId:(NSString*)commandId itemId:(NSString*)itemId profile:(NSString*)profile external:(BOOL)external untrusted:(BOOL)untrusted;
- (NSArray*)tabs;
- (nullable NSString*)activeItemId;
- (void)close;
- (void)installCheckDialogFactory;
- (NSUInteger)checkDialogCount;
- (void)configureProfileCloseCheck:(NSUInteger)cancelDialog;
- (NSDictionary<NSString*, id>*)checkProfileCloseState;
- (NSArray<NSNumber*>*)checkClosingEvents;
- (BOOL)checkTryingToQuit;
- (NSUInteger)checkStockBrowsers;
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
