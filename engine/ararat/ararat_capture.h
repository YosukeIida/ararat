#ifndef ARARAT_CORE_ARARAT_CAPTURE_H_
#define ARARAT_CORE_ARARAT_CAPTURE_H_

#import <AppKit/AppKit.h>

namespace content { class WebContents; }

@interface ARCapture : NSObject
- (void)selectContents:(content::WebContents*)contents;
- (void)fullPage:(content::WebContents*)contents completion:(void (^)(NSData*, NSString*))completion;
- (void)region:(NSRect)rect contents:(content::WebContents*)contents completion:(void (^)(NSData*, NSString*))completion;
@end

#endif
