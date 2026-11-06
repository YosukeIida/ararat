#ifndef ARARAT_PUBLIC_AR_TAB_H_
#define ARARAT_PUBLIC_AR_TAB_H_

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

__attribute__((visibility("default")))
@interface ARTab : NSObject
@property(nonatomic, readonly, copy) NSString* liveId;
@property(nonatomic, readonly, copy) NSString* title;
@property(nonatomic, readonly, copy) NSString* url;
@property(nonatomic, readonly) BOOL isLoading;
@property(nonatomic, readonly, nullable) NSView* view;
- (void)activateWithCommandId:(NSString*)commandId;
- (void)closeWithCommandId:(NSString*)commandId;
- (void)setItemId:(nullable NSString*)itemId;
@end

NS_ASSUME_NONNULL_END

#endif  // ARARAT_PUBLIC_AR_TAB_H_
