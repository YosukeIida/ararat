#ifndef ARARAT_PUBLIC_AR_WINDOW_HOST_H_
#define ARARAT_PUBLIC_AR_WINDOW_HOST_H_

#import <AppKit/AppKit.h>

__attribute__((visibility("default")))
@interface ARWindowHost : NSObject
- (instancetype)initWithContentView:(NSView*)content_view;
- (NSWindow*)window;
- (void)close;
- (void)makePending;
@end

#endif  // ARARAT_PUBLIC_AR_WINDOW_HOST_H_
