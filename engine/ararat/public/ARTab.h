#ifndef ARARAT_PUBLIC_AR_TAB_H_
#define ARARAT_PUBLIC_AR_TAB_H_

#import <AppKit/AppKit.h>
#import "AraratHostAPI.h"

NS_ASSUME_NONNULL_BEGIN

__attribute__((visibility("default")))
@interface ARTab : NSObject <ARTabAPI>
@property(nonatomic, readonly, copy) NSString* liveId;
@property(nonatomic, copy, nullable) NSString* itemId;
@property(nonatomic, readonly, copy) NSString* title;
@property(nonatomic, readonly, copy) NSString* url;
@property(nonatomic, readonly) BOOL isLoading;
@property(nonatomic, readonly) NSUInteger navigationCount;
@property(nonatomic, readonly) NSUInteger entryCount;
@property(nonatomic, readonly) BOOL canGoBack;
@property(nonatomic, readonly) BOOL crashed;
- (void)checkFlushHistory:(void (^)(BOOL written))completion;
@property(nonatomic, readonly, nullable) NSView* view;
- (void)activateWithCommandId:(NSString*)commandId;
- (void)closeWithCommandId:(NSString*)commandId;
- (BOOL)sendCheckMouseMoved:(NSEvent*)event;
- (BOOL)checkCrashRenderer;
@end

NS_ASSUME_NONNULL_END

#endif  // ARARAT_PUBLIC_AR_TAB_H_
