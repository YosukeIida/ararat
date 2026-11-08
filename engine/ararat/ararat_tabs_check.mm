#include "ararat/core/ararat_window_check.h"
#include "ararat/core/ararat_window_host.h"
#include "ararat/core/ararat_tab.h"

#import <AppKit/AppKit.h>

#include <iostream>

#include "ararat/core/public/AraratEngine.h"
#include "base/functional/bind.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "content/public/browser/web_contents.h"

@interface ARTabsCheck : NSObject <ARWindowHostDelegate>
@property(nonatomic, strong) ARWindowHost* host;
@property(nonatomic, strong) NSView* card;
@property(nonatomic, strong) NSMutableArray<NSDictionary*>* transactions;
@property(nonatomic, strong) NSArray<NSString*>* titles;
@property(nonatomic, copy) NSString* activeId;
@property(nonatomic) BOOL reopenAccepted;
@property(nonatomic) BOOL activeInCard;
@property(nonatomic) BOOL inactiveHidden;
@property(nonatomic) BOOL hostAliveEmpty;
@property(nonatomic) BOOL reopenSameEpoch;
@property(nonatomic) NSInteger phase;
@property(nonatomic) NSInteger attempts;
- (void)tick;
- (void)finish:(BOOL)timedOut;
@end

namespace {
ARTabsCheck* g_tabs_check;
bool g_tabs_check_passed = false;
void Tick() { [g_tabs_check tick]; }
void ScheduleTick() {
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(
      FROM_HERE, base::BindOnce(&Tick), base::Milliseconds(100));
}
}  // namespace

@implementation ARTabsCheck
- (void)windowHostClosingAllCancelled:(id<ARWindowHostAPI>)host {}
- (void)windowHost:(id<ARWindowHostAPI>)host pageFullscreenChanged:(BOOL)fullscreen {}
- (void)windowHost:(id<ARWindowHostAPI>)host windowFullscreenChanged:(BOOL)fullscreen {}
@synthesize host = _host;
@synthesize card = _card;
@synthesize transactions = _transactions;
@synthesize titles = _titles;
@synthesize activeId = _activeId;
@synthesize reopenAccepted = _reopenAccepted;
@synthesize activeInCard = _activeInCard;
@synthesize inactiveHidden = _inactiveHidden;
@synthesize hostAliveEmpty = _hostAliveEmpty;
@synthesize reopenSameEpoch = _reopenSameEpoch;
@synthesize phase = _phase;
@synthesize attempts = _attempts;

- (NSView*)pageCardForWindowHost:(id<ARWindowHostAPI>)host { return self.card; }
- (void)windowHost:(id<ARWindowHostAPI>)host showProfile:(NSString*)profile {}
- (void)windowHost:(id<ARWindowHostAPI>)host didReceiveTransaction:(NSDictionary*)transaction {
  NSMutableArray<NSString*>* strips = [NSMutableArray array];
  for (NSDictionary* strip in transaction[@"strips"]) {
    NSMutableArray<NSString*>* liveIds = [NSMutableArray array];
    for (NSDictionary* tab in strip[@"tabs"]) [liveIds addObject:tab[@"live_id"]];
    if (strip[@"active"] && strip[@"active"] != NSNull.null)
      [liveIds addObject:[NSString stringWithFormat:@"%@*", strip[@"active"]]];
    [strips addObject:[NSString stringWithFormat:@"%@: %@",
                       strip[@"window"],
                       liveIds.count ? [liveIds componentsJoinedByString:@","] : @"-"]];
  }
  id cause = transaction[@"cause"];
  NSString* causeText = [cause isKindOfClass:NSDictionary.class]
      ? (NSString*)cause[@"Command"] : (NSString*)cause;
  std::cerr << "tabs-check: epoch " << [transaction[@"epoch"] unsignedLongLongValue]
            << " rev " << [transaction[@"rev"] unsignedLongLongValue]
            << " cause " << causeText.UTF8String << " strips ["
            << (strips.count ? [strips componentsJoinedByString:@" | "].UTF8String : "-")
            << "]\n";
  [self.transactions addObject:transaction];
}
- (void)tick {
  if (++self.attempts > 300) {
    std::cerr << "engine: tabs check timed out\n";
    [self finish:YES];
    return;
  }
  if (self.phase == 0) {
    NSArray<ARTab*>* tabs = self.host.tabs;
    if (tabs.count != 3 || ![tabs[0].title isEqualToString:@"Ararat A"] ||
        ![tabs[1].title isEqualToString:@"Ararat B"] ||
        ![tabs[2].title isEqualToString:@"Ararat C"]) {
      ScheduleTick();
      return;
    }
    [tabs[1] activateWithCommandId:@"cmd-4"];
    self.titles = @[ tabs[0].title, tabs[1].title, tabs[2].title ];
    NSUInteger tabViewsInCard = 0;
    for (ARTab* tab in tabs) {
      if (tab.view && tab.view.superview == self.card) {
        ++tabViewsInCard;
        self.activeId = tab.liveId;
      }
    }
    BOOL positionViewPassesHits = YES;
    for (NSView* view in self.card.subviews) {
      if ([view isKindOfClass:NSClassFromString(@"ARPagePositionView")] &&
          [view hitTest:NSMakePoint(NSMidX(view.frame), NSMidY(view.frame))])
        positionViewPassesHits = NO;
    }
    self.activeInCard = tabViewsInCard == 1 && tabs[1].view.superview == self.card && positionViewPassesHits;
    self.inactiveHidden = YES;
    for (ARTab* tab in @[ tabs[0], tabs[2] ]) {
      content::WebContents* contents = tab.contents;
      NSView* view = contents->GetNativeView().GetNativeNSView();
      if (view.superview || contents->GetVisibility() != content::Visibility::HIDDEN)
        self.inactiveHidden = NO;
    }
    [tabs[0] closeWithCommandId:@"cmd-5"];
    [tabs[1] closeWithCommandId:@"cmd-6"];
    [tabs[2] closeWithCommandId:@"cmd-7"];
    self.phase = 1;
    ScheduleTick();
    return;
  }
  if (self.phase == 1) {
    if ([self.host hasBrowser] || GlobalBrowserCollection::GetInstance()->GetSize() != 0) {
      ScheduleTick();
      return;
    }
    self.hostAliveEmpty = self.host.window != nil && self.host.tabs.count == 0;
    self.reopenAccepted = [self.host openURL:@"data:text/html,<title>Ararat D</title>" commandId:@"cmd-8" itemId:@"item-4"];
    self.phase = 2;
    ScheduleTick();
    return;
  }
  if (self.phase == 2) {
    NSDictionary* reopen = nil;
    for (NSDictionary* transaction in self.transactions) {
      if ([transaction[@"cause"] isEqual:@{ @"Command": @"cmd-8" }]) reopen = transaction;
    }
    if (!reopen) {
      ScheduleTick();
      return;
    }
    ARTab* reopened = nil;
    for (ARTab* tab in self.host.tabs)
      if ([tab.liveId isEqualToString:@"cmd-8"]) reopened = tab;
    NSDictionary* first = self.transactions.firstObject;
    NSArray* strips = reopen[@"strips"];
    self.reopenSameEpoch = self.reopenAccepted && reopened &&
        [reopen[@"epoch"] unsignedLongLongValue] != 0 &&
        [reopen[@"epoch"] isEqual:first[@"epoch"]] && [reopen[@"rev"] unsignedLongLongValue] > 0 &&
        [reopen[@"cause"] isEqual:@{ @"Command": @"cmd-8" }] &&
        strips.count == 1 && [strips.firstObject[@"window"] isEqual:@"window-1"];
    [reopened closeWithCommandId:@"cmd-9"];
    self.phase = 3;
    ScheduleTick();
    return;
  }
  if ([self.host hasBrowser] || GlobalBrowserCollection::GetInstance()->GetSize() != 0) {
    ScheduleTick();
    return;
  }
  [self finish:NO];
}

- (void)finish:(BOOL)timedOut {
  NSArray<NSDictionary*>* transactions = self.transactions;
  NSDictionary* first = transactions.firstObject;
  BOOL firstIsEmptySnapshot = first && [first[@"epoch"] unsignedLongLongValue] != 0 &&
      [first[@"rev"] unsignedLongLongValue] == 0 && [first[@"cause"] isEqual:@"Engine"] &&
      [first[@"strips"] isEqual:@[]];
  BOOL gapless = YES;
  NSMutableArray<NSString*>* commandCauses = [NSMutableArray array];
  for (NSUInteger i = 0; i < transactions.count; ++i) {
    NSDictionary* transaction = transactions[i];
    if ([transaction[@"rev"] unsignedLongLongValue] != i ||
        ![transaction[@"epoch"] isEqual:first[@"epoch"]]) gapless = NO;
    id cause = transaction[@"cause"];
    if ([cause isKindOfClass:NSDictionary.class] && cause[@"Command"])
      [commandCauses addObject:cause[@"Command"]];
  }
  BOOL causesMatch = [commandCauses isEqual:@[ @"cmd-1", @"cmd-2", @"cmd-3", @"cmd-4", @"cmd-5", @"cmd-6", @"cmd-7", @"cmd-8", @"cmd-9" ]];
  unsigned long long lastRev = transactions.count ? [transactions.lastObject[@"rev"] unsignedLongLongValue] : 0;
  gapless = gapless && transactions.count == lastRev + 1;
  BOOL ok = !timedOut && self.activeInCard && self.inactiveHidden && firstIsEmptySnapshot && self.hostAliveEmpty && self.reopenSameEpoch &&
      gapless && causesMatch && [self.titles isEqual:@[ @"Ararat A", @"Ararat B", @"Ararat C" ]] &&
      [self.activeId isEqualToString:@"cmd-2"];
  g_tabs_check_passed = ok;
  NSArray<NSString*>* titlesSoFar = self.titles;
  if (!titlesSoFar) {
    NSMutableArray<NSString*>* gathered = [NSMutableArray array];
    for (ARTab* tab in self.host.tabs) [gathered addObject:tab.title];
    titlesSoFar = gathered;
  }
  NSData* data = [NSJSONSerialization dataWithJSONObject:titlesSoFar options:0 error:nullptr];
  NSString* titles = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  std::cout << "{\"check\":\"tabs\",\"ok\":" << (ok ? "true" : "false")
            << ",\"titles\":" << titles.UTF8String << ",\"active\":\"" << (self.activeId ?: @"").UTF8String << "\",\"active_in_card\":"
            << (self.activeInCard ? "true" : "false") << ",\"inactive_hidden\":"
            << (self.inactiveHidden ? "true" : "false") << ",\"first_is_empty_snapshot\":"
            << (firstIsEmptySnapshot ? "true" : "false") << ",\"transactions\":{\"count\":"
            << transactions.count << ",\"last_rev\":" << lastRev << ",\"gapless\":"
            << (gapless ? "true" : "false") << ",\"causes_match\":" << (causesMatch ? "true" : "false")
            << "},\"host_alive_empty\":" << (self.hostAliveEmpty ? "true" : "false")
            << ",\"reopen_same_epoch\":" << (self.reopenSameEpoch ? "true" : "false") << "}\n" << std::flush;
  [self.host close];
  AraratQuit();
}
@end

bool AraratTabsCheckPassed() { return g_tabs_check_passed; }
void AraratCheckTabs() {
  g_tabs_check = [[ARTabsCheck alloc] init];
  g_tabs_check.transactions = [NSMutableArray array];
  g_tabs_check.card = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
  g_tabs_check.host = [[ARWindowHost alloc] initWithContentView:g_tabs_check.card windowId:@"window-1"];
  g_tabs_check.host.delegate = g_tabs_check;
  [g_tabs_check.host openURL:@"data:text/html,<title>Ararat A</title>" commandId:@"cmd-1" itemId:@"item-1"];
  [g_tabs_check.host openURL:@"data:text/html,<title>Ararat B</title>" commandId:@"cmd-2" itemId:@"item-2"];
  [g_tabs_check.host openURL:@"data:text/html,<title>Ararat C</title>" commandId:@"cmd-3" itemId:@"item-3"];
  ScheduleTick();
}
