#ifndef ARARAT_PUBLIC_AR_WINDOW_HOST_H_
#define ARARAT_PUBLIC_AR_WINDOW_HOST_H_

#import <AppKit/AppKit.h>
#import "AraratHostAPI.h"

NS_ASSUME_NONNULL_BEGIN

@class ARTab;
@class ARWindowHost;

__attribute__((visibility("default")))
@interface ARWindowHost : NSObject <ARWindowHostAPI>
@property(nonatomic, weak, nullable) id<ARWindowHostDelegate> delegate;
- (instancetype)initWithContentView:(NSView*)content_view windowId:(NSString*)windowId;
- (NSWindow*)window;
- (BOOL)openURL:(NSString*)url
      commandId:(NSString*)commandId
         itemId:(NSString*)itemId;
- (NSArray<ARTab*>*)tabs;
- (void)close;
- (void)makePending;
@end

NS_ASSUME_NONNULL_END

#endif  // ARARAT_PUBLIC_AR_WINDOW_HOST_H_
