from pathlib import Path
import sys

source = Path('engine/ararat/ararat_window_host.mm').read_text()
method = source.index('- (void)transactionWithCause:(id)cause setEmptyReported:(BOOL)setEmptyReported retainHost:(BOOL)retainHost {')
start = source.index('  NSArray* strips =', method)
capture = source[start:source.index('  if (setEmptyReported)', start)]
method = source.index('- (NSDictionary*)stripSnapshot:(BOOL)consumeNavigation {')
start = source.index('  NSMutableArray* entries =', method)
mask = source[start:source.index('  for (ARTab* tab', start)]
scope = next(line for line in source.splitlines() if 'base::AutoReset<bool> foreground_open(' in line)
pre = r'''#import <Foundation/Foundation.h>
#include <cassert>
#include <cstdio>
namespace base {
template<class T> struct AutoReset {
  T* value; T old;
  AutoReset(T* value, T next) : value(value), old(*value) { *value = next; }
  ~AutoReset() { *value = old; }
};
}
struct TabIdentity { NSString* live_id; NSString* item_id; };
static int kTabIdentityKey;
namespace content {
struct WebContents {
  TabIdentity identity;
  void* GetUserData(int) { return &identity; }
};
}
struct Strip {
  content::WebContents* active;
  content::WebContents* GetActiveWebContents() { return active; }
};
struct Browser {
  Strip strip;
  Strip* GetTabStripModel() { return &strip; }
};
struct Core { bool popup() { return false; } };
@interface Probe : NSObject {
@public
  Browser* browser_;
  Core* core_;
  BOOL workspace_page_hidden_;
  BOOL workspace_remote_;
  bool foreground_open_;
  NSString* opening_item_;
  NSString* command_id_;
}
- (NSDictionary*)barrierSnapshot:(BOOL)consume preserveActive:(BOOL)preserve;
- (NSArray*)capture:(id)cause;
- (NSArray*)open:(BOOL)background cause:(id)cause;
@end
@implementation Probe
- (NSDictionary*)barrierSnapshot:(BOOL)consume preserveActive:(BOOL)preserve {
'''
mid = r'''
  return @{ @"active": active ? (id)active->identity.live_id : (id)NSNull.null };
}
- (NSArray*)capture:(id)cause {
'''
post = r'''
  return strips;
}
- (NSArray*)open:(BOOL)background cause:(id)cause {
''' + scope + r'''
  return [self capture:cause];
}
@end
static id active(Probe* host, id cause) { return [host capture:cause].firstObject[@"active"]; }
static id open(Probe* host, BOOL background, id cause) { return [host open:background cause:cause].firstObject[@"active"]; }
int main() {
  @autoreleasepool {
    content::WebContents tab{{@"cmd-open", @"row"}};
    Browser browser{{&tab}};
    Core core;
    Probe* host = [Probe new];
    host->browser_ = &browser; host->core_ = &core;
    host->workspace_page_hidden_ = YES;
    host->opening_item_ = @"row"; host->command_id_ = @"cmd-open";
    NSDictionary* completion = @{ @"Command": @"cmd-open" };
    assert([open(host, NO, completion) isEqual:@"cmd-open"]);
    assert(!host->foreground_open_);
    assert(active(host, @"Engine") == NSNull.null);
    assert(active(host, completion) == NSNull.null);
    assert(open(host, YES, completion) == NSNull.null);
    assert(open(host, NO, @"Chrome") == NSNull.null);
    assert(open(host, NO, @{ @"Command": @"other" }) == NSNull.null);
    host->workspace_remote_ = YES;
    assert(open(host, NO, completion) == NSNull.null);
    host->workspace_remote_ = NO;
    tab.identity.live_id = @"different-live";
    assert(open(host, NO, completion) == NSNull.null);
    tab.identity.live_id = @"cmd-open";
    tab.identity.item_id = @"different-row";
    assert(open(host, NO, completion) == NSNull.null);
    host->workspace_page_hidden_ = NO;
    assert([active(host, @"Chrome") isEqual:@"cmd-open"]);
    std::puts("11 extracted Open completion capture checks passed");
  }
}
'''
Path(sys.argv[1]).write_text(pre + mask + mid + capture + post)
