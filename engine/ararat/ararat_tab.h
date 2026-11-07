#ifndef ARARAT_ARARAT_TAB_H_
#define ARARAT_ARARAT_TAB_H_

#import "ararat/core/public/ARTab.h"
#import "ararat/core/public/ARWindowHost.h"

namespace content {
class WebContents;
}
@class ARWindowHost;

@interface ARTab ()
- (instancetype)initWithContents:(content::WebContents*)contents
                          liveId:(NSString*)liveId
                            host:(ARWindowHost*)host;
- (content::WebContents*)contents;
- (void)refresh;
- (void)navigationFinished;
- (BOOL)takePendingNavigation;
- (void)invalidate;
- (void)replaceContents:(content::WebContents*)contents;
@end

@interface ARWindowHost (ARTabCommands)
- (void)activateTab:(ARTab*)tab commandId:(NSString*)commandId;
- (void)closeTab:(ARTab*)tab commandId:(NSString*)commandId;
- (void)setItemId:(NSString*)itemId forTab:(ARTab*)tab;
- (NSString*)itemIdForTab:(ARTab*)tab;
- (BOOL)isActiveTab:(ARTab*)tab;
- (void)tabMetadataChanged;
- (BOOL)checkDialogHostForContents:(content::WebContents*)contents;
@end

#endif  // ARARAT_ARARAT_TAB_H_
