#ifndef ARARAT_CORE_ARARAT_SITE_STATE_H_
#define ARARAT_CORE_ARARAT_SITE_STATE_H_

#import <Foundation/Foundation.h>

namespace content { class WebContents; }

@interface ARSiteState : NSObject
- (instancetype)initWithChanged:(void (^)(void))changed;
- (void)setContents:(content::WebContents*)contents;
- (NSDictionary*)snapshot;
- (BOOL)change:(NSDictionary*)request;
- (void)close;
@end

#endif
