from pathlib import Path
import sys

source = Path('engine/ararat/ararat_window_host.mm').read_text()
method = source.index('- (void)transactionWithCause:(id)cause setEmptyReported:(BOOL)setEmptyReported retainHost:(BOOL)retainHost {')
start = source.index('  NSArray* strips =', method)
capture = source[start:source.index('  if (setEmptyReported)', start)]
method = source.index('- (NSDictionary*)stripSnapshot:(BOOL)consumeNavigation {')
start = source.index('  NSMutableArray* entries =', method)
mask = source[start:source.index('  for (ARTab* tab', start)]
scope = next(line for line in source.splitlines() if '> foreground_open(' in line)
foreground_field = next(line for line in source.splitlines() if line.strip().endswith((' foreground_open_;', ' foreground_open_item_;')))
sync = source.index('      contents->SetUserData(kTabIdentityKey, std::move(data));')
consume_open_item = source[source.index('      opening_item_ = nil;', sync):source.index('    }', sync)]
pre = r'''#import <Foundation/Foundation.h>
#include <cassert>
#include <cstdio>
#include <string>
namespace base {
template<class T> struct AutoReset {
  T* value; T old;
  AutoReset(T* value, T next) : value(value), old(*value) { *value = next; }
  ~AutoReset() { *value = old; }
};
struct CommandLine {
  static CommandLine* ForCurrentProcess() { static CommandLine flags; return &flags; }
  std::string GetSwitchValueASCII(const char* name) const { return name == organizeSwitch ? "organize" : ""; }
  std::string organizeSwitch;
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
''' + foreground_field + r'''
  NSString* window_id_;
  NSString* opening_item_;
  NSString* command_id_;
  uint64_t opening_stamp_;
}
- (NSDictionary*)barrierSnapshot:(BOOL)consume preserveActive:(BOOL)preserve;
- (NSArray*)capture:(id)cause;
- (NSArray*)open:(BOOL)background cause:(id)cause syncTabsFirst:(BOOL)syncTabsFirst;
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
- (NSArray*)open:(BOOL)background cause:(id)cause syncTabsFirst:(BOOL)syncTabsFirst {
  NSString* itemId = opening_item_;
''' + scope + r'''
  if (syncTabsFirst) {
''' + consume_open_item + r'''
  }
  return [self capture:cause];
}
@end
static id active(Probe* host, id cause) { return [host capture:cause].firstObject[@"active"]; }
static id open(Probe* host, BOOL background, id cause, BOOL syncTabsFirst = NO) {
  return [host open:background cause:cause syncTabsFirst:syncTabsFirst].firstObject[@"active"];
}
int main(int argc, char** argv) {
  if (argc > 1) base::CommandLine::ForCurrentProcess()->organizeSwitch = argv[1];
  @autoreleasepool {
    content::WebContents tab{{@"cmd-open", @"row"}};
    Browser browser{{&tab}};
    Core core;
    Probe* host = [Probe new];
    host->browser_ = &browser; host->core_ = &core;
    host->window_id_ = @"probe";
    host->workspace_page_hidden_ = YES;
    host->opening_item_ = @"row"; host->command_id_ = @"cmd-open";
    NSDictionary* completion = @{ @"Command": @"cmd-open" };
    assert([open(host, NO, completion, YES) isEqual:@"cmd-open"]);
    assert(host->opening_item_ == nil);
    host->opening_item_ = @"row";
    assert([open(host, NO, completion) isEqual:@"cmd-open"]);
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
    std::puts("12 extracted Open completion capture checks passed");
  }
}
'''
Path(sys.argv[1]).write_text(pre + mask + mid + capture + post)
