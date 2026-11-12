#include "ararat/core/ararat_window_check.h"
#include "ararat/core/ararat_window_host.h"
#include "ararat/core/ararat_tab.h"
#include "ararat/core/ararat_tab_history.h"

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

#include <iostream>

#include "ararat/core/public/AraratEngine.h"
#include "base/functional/bind.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_process_host.h"

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
- (void)windowHostWillBeginClosing:(id<ARWindowHostAPI>)host {}
- (void)windowHost:(id<ARWindowHostAPI>)host pageFullscreenChanged:(BOOL)fullscreen {}
- (void)windowHost:(id<ARWindowHostAPI>)host windowFullscreenChanged:(BOOL)fullscreen {}
- (void)windowHost:(id<ARWindowHostAPI>)host performWorkspaceCommand:(NSString*)command {}
- (void)windowHost:(id<ARWindowHostAPI>)host updateFindBar:(NSDictionary<NSString*, id>*)state {}
- (BOOL)findBarHasFocusForWindowHost:(id<ARWindowHostAPI>)host { return NO; }
- (void)windowHost:(id<ARWindowHostAPI>)host findPageRectChanged:(NSRect)rect {}
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

@interface ARSplitCheck : ARTabsCheck
@property(nonatomic) BOOL layoutsShown;
@property(nonatomic) BOOL activationWorked;
@property(nonatomic) BOOL dragWorked;
@property(nonatomic) BOOL twoShown;
@property(nonatomic) BOOL threeShown;
@property(nonatomic) BOOL nestedShown;
@property(nonatomic) BOOL heldSizes;
@property(nonatomic) BOOL clippedPanes;
@property(nonatomic) BOOL finalSizes;
@property(nonatomic) BOOL resizeCountsValid;
@end

namespace {
ARSplitCheck* g_split_check;
bool g_split_check_passed = false;
void SplitTick() { [g_split_check tick]; }
void ScheduleSplitTick() {
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(
      FROM_HERE, base::BindOnce(&SplitTick), base::Milliseconds(100));
}
}

@implementation ARSplitCheck
- (void)tick {
  if (++self.attempts > 300) { [self finish:YES]; return; }
  NSArray<ARTab*>* tabs = self.host.tabs;
  if (self.phase == 1) {
    if (tabs.count != 2) { ScheduleSplitTick(); return; }
    BOOL remainingShown = YES;
    for (ARTab* tab in tabs) {
      if (![tab.itemId isEqualToString:@"split-a"] && ![tab.itemId isEqualToString:@"split-b"]) remainingShown = NO;
      if (!tab.contents || tab.view.superview != self.card || tab.view.isHidden || tab.contents->GetVisibility() == content::Visibility::HIDDEN) remainingShown = NO;
    }
    g_split_check_passed = self.layoutsShown && self.activationWorked && self.dragWorked && remainingShown && AraratStockBrowserCount() == 0;
    std::cout << "{\"check\":\"split\",\"ok\":" << (g_split_check_passed ? "true" : "false")
              << ",\"two_three_nested\":" << (self.layoutsShown ? "true" : "false")
              << ",\"two\":" << (self.twoShown ? "true" : "false")
              << ",\"three\":" << (self.threeShown ? "true" : "false")
              << ",\"nested\":" << (self.nestedShown ? "true" : "false")
              << ",\"activation\":" << (self.activationWorked ? "true" : "false")
              << ",\"frozen_drag\":" << (self.dragWorked ? "true" : "false")
              << ",\"held_sizes\":" << (self.heldSizes ? "true" : "false")
              << ",\"clipped_panes\":" << (self.clippedPanes ? "true" : "false")
              << ",\"final_sizes\":" << (self.finalSizes ? "true" : "false")
              << ",\"resize_counts_valid\":" << (self.resizeCountsValid ? "true" : "false")
              << ",\"remaining_after_close\":" << (remainingShown ? "true" : "false")
              << ",\"stock_browsers\":" << AraratStockBrowserCount() << "}\n" << std::flush;
    [self.host close]; AraratQuit(); return;
  }
  if (tabs.count != 3) { ScheduleSplitTick(); return; }
  for (ARTab* tab in tabs) if (tab.isLoading || !tab.contents) { ScheduleSplitTick(); return; }
  NSDictionary* two = @{
    @"split-a": [NSValue valueWithRect:NSMakeRect(0, 0, 398, 600)],
    @"split-b": [NSValue valueWithRect:NSMakeRect(402, 0, 398, 600)] };
  if (![self.host setSplitFrames:two frozen:NO]) {
    std::cout << "{\"check\":\"split\",\"ok\":false,\"unsupported\":true}\n" << std::flush;
    [self.host close]; AraratQuit(); return;
  }
  auto visible = ^BOOL(NSString* item) {
    for (ARTab* tab in tabs) if ([tab.itemId isEqualToString:item])
      return tab.view.superview == self.card && !tab.view.isHidden && tab.contents->GetVisibility() != content::Visibility::HIDDEN;
    return NO;
  };
  BOOL twoShown = visible(@"split-a") && visible(@"split-b");
  NSDictionary* three = @{
    @"split-a": [NSValue valueWithRect:NSMakeRect(0, 0, 264, 600)],
    @"split-b": [NSValue valueWithRect:NSMakeRect(268, 0, 264, 600)],
    @"split-c": [NSValue valueWithRect:NSMakeRect(536, 0, 264, 600)] };
  [self.host setSplitFrames:three frozen:NO];
  BOOL threeShown = visible(@"split-a") && visible(@"split-b") && visible(@"split-c");
  NSDictionary* dragged = @{
    @"split-a": [NSValue valueWithRect:NSMakeRect(0, 0, 284, 600)],
    @"split-b": [NSValue valueWithRect:NSMakeRect(288, 0, 244, 600)],
    @"split-c": three[@"split-c"] };
  NSMutableDictionary<NSString*, NSNumber*>* resizeCounts = [NSMutableDictionary dictionary];
  NSMutableDictionary<NSString*, NSValue*>* lastSizes = [NSMutableDictionary dictionary];
  NSMutableArray* observers = [NSMutableArray array];
  for (ARTab* tab in tabs) {
    NSString* item = tab.itemId;
    NSView* view = tab.view;
    resizeCounts[item] = @0;
    lastSizes[item] = [NSValue valueWithSize:view.frame.size];
    view.postsFrameChangedNotifications = YES;
    [observers addObject:[NSNotificationCenter.defaultCenter addObserverForName:NSViewFrameDidChangeNotification object:view queue:nil usingBlock:^(NSNotification*) {
      NSSize size = view.frame.size;
      if (!NSEqualSizes(size, lastSizes[item].sizeValue)) {
        resizeCounts[item] = @([resizeCounts[item] integerValue] + 1);
        lastSizes[item] = [NSValue valueWithSize:size];
      }
    }]];
  }
  [self.host setSplitFrames:dragged frozen:YES];
  BOOL heldSizes = YES;
  BOOL clippedPanes = YES;
  for (ARTab* tab in tabs) {
    NSValue* original = three[tab.itemId];
    if (!original || !NSEqualSizes(tab.view.frame.size, original.rectValue.size)) heldSizes = NO;
    NSValue* target = dragged[tab.itemId];
    NSView* clip = tab.view.superview;
    if (!target || !clip || clip.superview != self.card || !clip.layer.masksToBounds ||
        !NSEqualRects(clip.frame, target.rectValue)) clippedPanes = NO;
  }
  BOOL noDragResizes = [resizeCounts[@"split-a"] integerValue] == 0 && [resizeCounts[@"split-b"] integerValue] == 0 && [resizeCounts[@"split-c"] integerValue] == 0;
  [self.host setSplitFrames:dragged frozen:NO];
  BOOL finalSizes = YES;
  for (ARTab* tab in tabs) {
    NSValue* frame = dragged[tab.itemId];
    if (!frame || !NSEqualRects(tab.view.frame, frame.rectValue)) finalSizes = NO;
  }
  BOOL releaseResizes = [resizeCounts[@"split-a"] integerValue] == 1 && [resizeCounts[@"split-b"] integerValue] == 1 && [resizeCounts[@"split-c"] integerValue] == 0;
  for (id observer in observers) [NSNotificationCenter.defaultCenter removeObserver:observer];
  self.heldSizes = heldSizes;
  self.clippedPanes = clippedPanes;
  self.finalSizes = finalSizes;
  self.resizeCountsValid = noDragResizes && releaseResizes;
  self.dragWorked = heldSizes && clippedPanes && finalSizes && noDragResizes && releaseResizes;
  NSDictionary* nested = @{
    @"split-a": [NSValue valueWithRect:NSMakeRect(0, 0, 398, 298)],
    @"split-b": [NSValue valueWithRect:NSMakeRect(0, 302, 398, 298)],
    @"split-c": [NSValue valueWithRect:NSMakeRect(402, 0, 398, 600)] };
  [self.host setSplitFrames:nested frozen:NO];
  BOOL nestedShown = visible(@"split-a") && visible(@"split-b") && visible(@"split-c");
  BOOL nestedFrames = YES;
  for (ARTab* tab in tabs) {
    NSValue* value = nested[tab.itemId];
    if (!value || !NSEqualRects(tab.view.frame, value.rectValue)) nestedFrames = NO;
  }
  self.layoutsShown = twoShown && threeShown && nestedShown && nestedFrames;
  self.twoShown = twoShown;
  self.threeShown = threeShown;
  self.nestedShown = nestedShown && nestedFrames;
  ARTab* focused = nil; ARTab* closing = nil;
  for (ARTab* tab in tabs) {
    if ([tab.itemId isEqualToString:@"split-b"]) focused = tab;
    if ([tab.itemId isEqualToString:@"split-c"]) closing = tab;
  }
  [focused activateWithCommandId:@"split-focus-b"];
  self.activationWorked = [self.host.activeItemId isEqualToString:@"split-b"];
  self.phase = 1;
  [closing closeWithCommandId:@"split-close-c"];
  ScheduleSplitTick();
}

- (void)finish:(BOOL)timedOut {
  g_split_check_passed = false;
  std::cout << "{\"check\":\"split\",\"ok\":false,\"timeout\":" << (timedOut ? "true" : "false") << "}\n" << std::flush;
  [self.host close]; AraratQuit();
}
@end

bool AraratSplitCheckPassed() { return g_split_check_passed; }
void AraratCheckSplit() {
  g_split_check = [[ARSplitCheck alloc] init];
  g_split_check.transactions = [NSMutableArray array];
  g_split_check.card = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
  g_split_check.host = [[ARWindowHost alloc] initWithContentView:g_split_check.card windowId:@"split-check"];
  g_split_check.host.delegate = g_split_check;
  [g_split_check.host openURL:@"about:blank" commandId:@"split-open-a" itemId:@"split-a"];
  [g_split_check.host openBackgroundURL:@"about:blank" commandId:@"split-open-b" itemId:@"split-b" profile:@"Default" historyStamp:0];
  [g_split_check.host openBackgroundURL:@"about:blank" commandId:@"split-open-c" itemId:@"split-c" profile:@"Default" historyStamp:0];
  ScheduleSplitTick();
}

@interface ARTransferCheck : ARTabsCheck
@property(nonatomic, strong) ARWindowHost* destination;
@property(nonatomic, strong) NSView* destinationCard;
@property(nonatomic) BOOL extensionPath;
@property(nonatomic) BOOL captureDone;
@property(nonatomic) BOOL snapshotPresent;
@property(nonatomic) BOOL pairedForward;
@property(nonatomic) BOOL pairedBack;
@property(nonatomic) BOOL identityPreserved;
@property(nonatomic) uintptr_t contentsAddress;
@property(nonatomic) int rendererPid;
@property(nonatomic) NSUInteger entries;
@property(nonatomic) uintptr_t writerAddress;
@property(nonatomic) BOOL writerPreserved;
@property(nonatomic) uint64_t writerStamp;
@property(nonatomic) BOOL flushDone;
@property(nonatomic) BOOL flushOK;
@property(nonatomic) BOOL recoveryBarrier;
@end

namespace {
ARTransferCheck* g_transfer_check;
bool g_transfer_check_passed = false;
void TransferTick() { [g_transfer_check tick]; }
void ScheduleTransferTick() {
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(
      FROM_HERE, base::BindOnce(&TransferTick), base::Milliseconds(100));
}
int RendererPid(ARTab* tab) {
  auto* frame = tab.contents ? tab.contents->GetPrimaryMainFrame() : nullptr;
  if (!frame) return 0;
  const auto& process = frame->GetProcess()->GetProcess();
  return process.IsValid() ? process.Pid() : 0;
}
}

@implementation ARTransferCheck
- (NSView*)pageCardForWindowHost:(id<ARWindowHostAPI>)host {
  return host == self.destination ? self.destinationCard : self.card;
}

- (BOOL)hasPairFrom:(NSString*)source to:(NSString*)target cause:(id)cause {
  for (NSDictionary* transaction in self.transactions) {
    if (cause && ![transaction[@"cause"] isEqual:cause]) continue;
    NSDictionary* from = nil; NSDictionary* to = nil;
    for (NSDictionary* strip in transaction[@"strips"]) {
      if ([strip[@"window"] isEqual:source]) from = strip;
      if ([strip[@"window"] isEqual:target]) to = strip;
    }
    if (!from || !to) continue;
    BOOL inSource = NO, inTarget = NO;
    for (NSDictionary* tab in from[@"tabs"]) if ([tab[@"live_id"] isEqual:@"transfer-open"]) inSource = YES;
    for (NSDictionary* tab in to[@"tabs"]) if ([tab[@"live_id"] isEqual:@"transfer-open"]) inTarget = YES;
    if (!inSource && inTarget) return YES;
  }
  return NO;
}

- (BOOL)sourceRemovalWasPaired {
  NSString* owner = nil;
  for (NSDictionary* transaction in self.transactions) {
    NSDictionary* source = nil; NSDictionary* destination = nil;
    for (NSDictionary* strip in transaction[@"strips"]) {
      if ([strip[@"window"] isEqual:@"transfer-source"]) source = strip;
      if ([strip[@"window"] isEqual:@"transfer-destination"]) destination = strip;
    }
    BOOL inSource = NO, inDestination = NO;
    for (NSDictionary* entry in source[@"tabs"]) if ([entry[@"live_id"] isEqual:@"transfer-open"]) inSource = YES;
    for (NSDictionary* entry in destination[@"tabs"]) if ([entry[@"live_id"] isEqual:@"transfer-open"]) inDestination = YES;
    if ([owner isEqual:@"transfer-source"] && source && !inSource && !(destination && inDestination)) return NO;
    if ([owner isEqual:@"transfer-destination"] && destination && !inDestination && !(source && inSource)) return NO;
    if (source && inSource) owner = @"transfer-source";
    if (destination && inDestination) owner = @"transfer-destination";
  }
  return YES;
}

- (void)tick {
  if (++self.attempts > 300) { [self finish:YES]; return; }
  if (self.phase == 0) {
    [self.destination prepareTransferProfile:@"Default"];
    NSArray<ARTab*>* tabs = self.host.tabs;
    if (tabs.count != 1 || tabs[0].isLoading || !tabs[0].contents || ![self.destination hasBrowserForProfile:@"Default"]) { ScheduleTransferTick(); return; }
    ARTab* tab = tabs[0];
    self.contentsAddress = reinterpret_cast<uintptr_t>(tab.contents);
    self.rendererPid = RendererPid(tab);
    self.entries = tab.entryCount;
    auto* writer = ararat::tab_history::TabHistory::Get().FindWriter("Default", "transfer-item");
    self.writerAddress = reinterpret_cast<uintptr_t>(writer);
    self.writerStamp = writer ? writer->admitted_at() : 0;
    self.writerPreserved = writer && !writer->fenced() && writer->web_contents() == tab.contents;
    [tab captureSnapshot:^(NSImage* image) {
      self.captureDone = YES;
      NSRect rect = NSMakeRect(0, 0, image.size.width, image.size.height);
      CGImageRef cg = image ? [image CGImageForProposedRect:&rect context:nil hints:nil] : nullptr;
      NSBitmapImageRep* bitmap = cg ? [[NSBitmapImageRep alloc] initWithCGImage:cg] : nil;
      NSColor* pixel = bitmap ? [[bitmap colorAtX:bitmap.pixelsWide / 2 y:bitmap.pixelsHigh / 2] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace] : nil;
      self.snapshotPresent = pixel && pixel.redComponent > 0.7 && pixel.greenComponent < 0.3 && pixel.blueComponent < 0.3;
      std::cerr << "ararat-trace: transfer snapshot read phase=" << self.phase << " image=" << (image != nil)
                << " cg=" << (cg != nullptr) << " pixel=" << (pixel != nil)
                << " rgb=" << (pixel ? pixel.redComponent : -1) << "," << (pixel ? pixel.greenComponent : -1)
                << "," << (pixel ? pixel.blueComponent : -1) << "\n";
    }];
    self.phase = 1;
  }
  if (self.phase == 1) {
    ARTab* tab = self.host.tabs.firstObject;
    BOOL moved = self.extensionPath ? [self.host checkMoveTab:tab toHost:self.destination]
                                    : [self.destination transferTab:tab commandId:@"move-to-dest"];
    if (!moved) { ScheduleTransferTick(); return; }
    self.phase = 2;
  }
  if (self.phase == 2) {
    id cause = self.extensionPath ? @"Chrome" : @{ @"Command": @"move-to-dest" };
    self.pairedForward = [self hasPairFrom:@"transfer-source" to:@"transfer-destination" cause:cause];
    ARTab* tab = self.destination.tabs.firstObject;
    if (!self.pairedForward || !tab || ![tab.liveId isEqualToString:@"transfer-open"]) { ScheduleTransferTick(); return; }
    self.identityPreserved = reinterpret_cast<uintptr_t>(tab.contents) == self.contentsAddress &&
        RendererPid(tab) == self.rendererPid && self.rendererPid != 0 && tab.entryCount == self.entries;
    auto* writer = ararat::tab_history::TabHistory::Get().FindWriter("Default", "transfer-item");
    self.writerPreserved = self.writerPreserved && reinterpret_cast<uintptr_t>(writer) == self.writerAddress &&
        writer && !writer->fenced() && writer->admitted_at() == self.writerStamp && writer->web_contents() == tab.contents;
    self.flushDone = NO;
    [tab checkFlushHistory:^(BOOL ok) { self.flushOK = ok; self.flushDone = YES; }];
    self.phase = 21;
  }
  if (self.phase == 21) {
    if (!self.flushDone) { ScheduleTransferTick(); return; }
    self.writerPreserved = self.writerPreserved && self.flushOK;
    [self.host prepareTransferProfile:@"Default"];
    self.phase = 3;
  }
  if (self.phase == 3) {
    [self.host prepareTransferProfile:@"Default"];
    if (![self.host hasBrowserForProfile:@"Default"]) { ScheduleTransferTick(); return; }
    ARTab* tab = self.destination.tabs.firstObject;
    if (![self.host transferTab:tab commandId:@"move-back"]) { ScheduleTransferTick(); return; }
    self.phase = 4;
  }
  if (self.phase == 4) {
    self.pairedBack = [self hasPairFrom:@"transfer-destination" to:@"transfer-source" cause:@{ @"Command": @"move-back" }];
    ARTab* tab = self.host.tabs.firstObject;
    if (!self.pairedBack || !tab || !self.captureDone) { ScheduleTransferTick(); return; }
    self.identityPreserved = self.identityPreserved && reinterpret_cast<uintptr_t>(tab.contents) == self.contentsAddress &&
        RendererPid(tab) == self.rendererPid && tab.entryCount == self.entries;
    auto* writer = ararat::tab_history::TabHistory::Get().FindWriter("Default", "transfer-item");
    self.writerPreserved = self.writerPreserved && reinterpret_cast<uintptr_t>(writer) == self.writerAddress &&
        writer && !writer->fenced() && writer->admitted_at() == self.writerStamp && writer->web_contents() == tab.contents;
    self.flushDone = NO;
    [tab checkFlushHistory:^(BOOL ok) { self.flushOK = ok; self.flushDone = YES; }];
    self.phase = 5;
  }
  if (self.phase == 5) {
    if (!self.flushDone) { ScheduleTransferTick(); return; }
    self.writerPreserved = self.writerPreserved && self.flushOK;
    [self finish:NO]; return;
  }
  ScheduleTransferTick();
}

- (void)finish:(BOOL)timedOut {
  BOOL snapshotRequired = !self.extensionPath;
  BOOL barrier = [self sourceRemovalWasPaired];
  g_transfer_check_passed = !timedOut && self.pairedForward && self.pairedBack && barrier && self.recoveryBarrier && self.identityPreserved && self.writerPreserved &&
      (!snapshotRequired || self.snapshotPresent) && AraratStockBrowserCount() == 0;
  std::cout << "{\"check\":\"" << (self.extensionPath ? "transfer-ext" : "transfer")
            << "\",\"ok\":" << (g_transfer_check_passed ? "true" : "false")
            << ",\"path\":\"" << (self.extensionPath ? "TabListBridge" : "app") << "\""
            << ",\"paired_forward\":" << (self.pairedForward ? "true" : "false")
            << ",\"paired_back\":" << (self.pairedBack ? "true" : "false")
            << ",\"barrier\":" << (barrier ? "true" : "false")
            << ",\"recovery_expiry_guard\":" << (self.recoveryBarrier ? "true" : "false")
            << ",\"identity_pid_history\":" << (self.identityPreserved ? "true" : "false")
            << ",\"writer_preserved\":" << (self.writerPreserved ? "true" : "false")
            << ",\"snapshot_present\":" << (self.snapshotPresent ? "true" : "false")
            << ",\"timeout\":" << (timedOut ? "true" : "false")
            << ",\"stock_browsers\":" << AraratStockBrowserCount() << "}\n" << std::flush;
  [self.host close]; [self.destination close]; AraratQuit();
}
@end

bool AraratTransferCheckPassed() { return g_transfer_check_passed; }
void AraratCheckTransfer(bool extension_path) {
  g_transfer_check = [[ARTransferCheck alloc] init];
  g_transfer_check.extensionPath = extension_path;
  g_transfer_check.transactions = [NSMutableArray array];
  g_transfer_check.card = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
  g_transfer_check.destinationCard = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
  g_transfer_check.host = [[ARWindowHost alloc] initWithContentView:g_transfer_check.card windowId:@"transfer-source"];
  g_transfer_check.destination = [[ARWindowHost alloc] initWithContentView:g_transfer_check.destinationCard windowId:@"transfer-destination"];
  g_transfer_check.host.delegate = g_transfer_check;
  g_transfer_check.destination.delegate = g_transfer_check;
  g_transfer_check.recoveryBarrier = AraratCheckRecoveryBarrier();
  [g_transfer_check.host openURL:@"data:text/html,<body style='background:red'><title>Ararat Transfer</title>" commandId:@"transfer-open" itemId:@"transfer-item"];
  ScheduleTransferTick();
}
