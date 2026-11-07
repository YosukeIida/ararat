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
@end

@protocol ARWindowHostAPI;
@protocol ARWindowHostDelegate <NSObject>
- (NSView*)pageCardForWindowHost:(id<ARWindowHostAPI>)host;
- (void)windowHost:(id<ARWindowHostAPI>)host
    didReceiveTransaction:(NSDictionary<NSString*, id>*)transaction;
@end

@protocol ARWindowHostAPI <NSObject>
@property(nonatomic, weak, nullable) id<ARWindowHostDelegate> delegate;
- (NSWindow*)window;
- (BOOL)hasBrowser;
- (BOOL)isClosing;
- (BOOL)setProfileDirectory:(NSString*)directory;
- (NSString*)profileDirectory;
- (BOOL)isClosingAll;
- (BOOL)openURL:(NSString*)url commandId:(NSString*)commandId itemId:(NSString*)itemId;
- (BOOL)openExternalURL:(NSString*)url commandId:(NSString*)commandId itemId:(NSString*)itemId untrusted:(BOOL)untrusted;
- (NSArray*)tabs;
- (void)close;
- (void)installCheckDialogFactory;
- (NSUInteger)checkDialogCount;
- (NSArray<NSNumber*>*)checkClosingEvents;
- (BOOL)checkTryingToQuit;
- (NSUInteger)checkStockBrowsers;
- (void)disableCheckConfirmQuit;
- (void)checkNavigate:(NSString*)url disposition:(NSString*)disposition;
- (void)checkCreateDeferredBrowsers;
- (void)checkMenuCommand:(BOOL)newWindow;
- (void)checkCloseAllTabs;
- (void)checkOpenURLs;
- (NSString*)checkOpenLinkNewWindowTitle;
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
