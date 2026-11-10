#include "ararat/core/ararat_window_host.h"
#include "ararat/core/ararat_tab.h"
#include "ararat/core/public/AraratEngine.h"
#include "ararat/core/public/AraratHostAPI.h"

#import <AppKit/AppKit.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <memory>
#include <string>

#include "base/functional/bind.h"
#include "base/metrics/statistics_recorder.h"
#include "base/process/process.h"
#include "base/strings/string_number_conversions.h"
#include "base/time/time.h"
#include "base/values.h"
#include "chrome/common/chrome_isolated_world_ids.h"
#include "content/public/browser/browser_child_process_host_iterator.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_process_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/web_contents.h"
#include "content/public/common/process_type.h"

@interface ARMeasure : NSObject
- (instancetype)initWithHost:(ARWindowHost*)host scenario:(NSString*)scenario;
- (void)start;
- (void)tick:(NSTimer*)timer;
- (void)sample:(NSArray<ARTab*>*)tabs completion:(void (^)(NSArray*))completion;
- (void)sampleSplit:(NSArray<ARTab*>*)tabs completion:(void (^)(NSArray*))completion;
- (void)finishRun:(NSDictionary*)values;
@end

namespace {
ARMeasure* g_measure;

void ExecutePage(ARTab* tab, const std::u16string& script,
                 void (^completion)(base::Value)) {
  content::WebContents* contents = tab.contents;
  if (!contents || !contents->GetPrimaryMainFrame()) {
    completion(base::Value());
    return;
  }
  contents->GetPrimaryMainFrame()->ExecuteJavaScriptInIsolatedWorld(
      script, base::BindOnce(completion), ISOLATED_WORLD_ID_CHROME_INTERNAL);
}

void ReadCounter(ARTab* tab, void (^completion)(NSNumber*)) {
  ExecutePage(tab, u"document.documentElement.dataset.raf",
      ^(base::Value value) {
        const std::string* result = value.GetIfString();
        int count = 0;
        completion(result && base::StringToInt(*result, &count) ? @(count) : nil);
      });
}

void ReadFrameTimes(ARTab* tab, void (^completion)(NSString*)) {
  ExecutePage(tab, u"document.documentElement.dataset.frames",
      ^(base::Value value) {
        const std::string* result = value.GetIfString();
        completion(result ? [NSString stringWithUTF8String:result->c_str()] : nil);
      });
}
}  // namespace

@implementation ARMeasure {
  ARWindowHost* host_;
  NSString* scenario_;
  NSTimer* timer_;
  NSWindow* cover_;
  NSArray<ARTab*>* tabs_;
  NSArray* before_;
  NSArray* covered_;
  NSRect initial_frame_;
  base::TimeTicks stage_start_;
  base::TimeTicks hidden_since_;
  base::TimeTicks counter_start_;
  double uncover_epoch_ms_;
  NSInteger stage_;
  NSInteger run_;
  NSInteger generation_;
  BOOL pending_;
  NSInteger switch_ms_;
  NSInteger refresh_rate_;
  NSInteger split_count_;
  NSArray* split_visible_;
  NSArray* split_after_visible_;
  NSArray* split_after_switch_;
  NSArray* split_after_drag_;
  double split_drag_seconds_;
  double split_open_epoch_;
  double split_release_epoch_;
  std::unique_ptr<base::StatisticsRecorder::ScopedHistogramSampleObserver> observer_;
}

- (void)sampleSplit:(NSArray<ARTab*>*)tabs completion:(void (^)(NSArray*))completion {
  if (pending_) return;
  pending_ = YES;
  NSInteger generation = generation_;
  NSMutableArray* values = [NSMutableArray arrayWithCapacity:tabs.count];
  for (NSUInteger i = 0; i < tabs.count; ++i) [values addObject:NSNull.null];
  if (!tabs.count) { pending_ = NO; completion(values); return; }
  __block NSUInteger remaining = tabs.count;
  __weak ARMeasure* weakSelf = self;
  for (NSUInteger i = 0; i < tabs.count; ++i) {
    ExecutePage(tabs[i], u"(()=>{let d=document.documentElement.dataset;let s=JSON.stringify({raf:Number(d.raf||0),resize:Number(d.resize||0),gap:Number(d.gap||0),frames:d.frames||''});d.reset='1';return s})()", ^(base::Value value) {
      ARMeasure* strongSelf = weakSelf;
      if (!strongSelf || strongSelf->generation_ != generation) return;
      const std::string* text = value.GetIfString();
      NSData* data = text ? [[NSString stringWithUTF8String:text->c_str()] dataUsingEncoding:NSUTF8StringEncoding] : nil;
      id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
      values[i] = [parsed isKindOfClass:NSDictionary.class] ? parsed : (id)NSNull.null;
      if (--remaining == 0) { strongSelf->pending_ = NO; completion(values); }
    });
  }
}

- (instancetype)initWithHost:(ARWindowHost*)host scenario:(NSString*)scenario {
  self = [super init];
  if (self) { host_ = host; scenario_ = [scenario copy]; }
  return self;
}

- (void)setStage:(NSInteger)stage {
  stage_ = stage;
  stage_start_ = base::TimeTicks::Now();
  pending_ = NO;
  ++generation_;
}

- (void)sample:(NSArray<ARTab*>*)tabs completion:(void (^)(NSArray*))completion {
  if (pending_) return;
  pending_ = YES;
  NSInteger generation = generation_;
  NSMutableArray* results = [NSMutableArray arrayWithCapacity:tabs.count];
  for (NSUInteger i = 0; i < tabs.count; ++i) [results addObject:NSNull.null];
  if (!tabs.count) { pending_ = NO; completion(results); return; }
  __block NSUInteger remaining = tabs.count;
  __weak ARMeasure* weakSelf = self;
  for (NSUInteger i = 0; i < tabs.count; ++i) {
    ReadCounter(tabs[i], ^(NSNumber* value) {
      ARMeasure* strongSelf = weakSelf;
      if (!strongSelf || strongSelf->generation_ != generation) return;
      results[i] = value ?: (id)NSNull.null;
      if (--remaining == 0) {
        strongSelf->pending_ = NO;
        completion(results);
      }
    });
  }
}

- (void)start {
  run_ = 1;
  initial_frame_ = host_.window.frame;
  refresh_rate_ = std::max(1, (int)host_.window.screen.maximumFramesPerSecond);
  if (refresh_rate_ <= 1) refresh_rate_ = 60;
  [host_.window makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];
  if ([scenario_ isEqualToString:@"display"] && NSScreen.screens.count == 1) {
    for (int i = 0; i < 10; ++i) [self finishRun:@{ @"skipped": @"one display" }];
    return;
  }
  NSInteger count = [scenario_ isEqualToString:@"background"] ? 10 :
                    ([scenario_ isEqualToString:@"switch"] || [scenario_ isEqualToString:@"split"]) ? 3 : 1;
  BOOL record_times = [scenario_ isEqualToString:@"occlusion"] || [scenario_ isEqualToString:@"display"] || [scenario_ isEqualToString:@"split"];
  NSString* url = [NSString stringWithFormat:@"data:text/html,<style>div{width:100px;height:100px;background:red;animation:a 1s infinite alternate}@keyframes a{from{transform:translateX(0)}to{transform:translateX(200px)}}</style><div></div><script>let n=0,q=[],last=0,gap=0,r=0;addEventListener('resize',()=>document.documentElement.dataset.resize=String(++r));function f(t){let d=document.documentElement.dataset;if(d.reset){gap=0;delete d.reset}if(last)gap=Math.max(gap,t-last);last=t;d.gap=String(gap);d.raf=String(++n);if(%@){q.push(performance.timeOrigin+t);if(q.length>32)q.shift();d.frames=q.join(',')}requestAnimationFrame(f)}requestAnimationFrame(f)</script>", record_times ? @"true" : @"false"];
  for (NSInteger i = 0; i < count; ++i) {
    NSString* identifier = [NSString stringWithFormat:@"measure-%ld", (long)i];
    [host_ openURL:url commandId:identifier itemId:identifier];
  }
  [self setStage:0];
  timer_ = [NSTimer timerWithTimeInterval:1.0 / refresh_rate_ target:self selector:@selector(tick:) userInfo:nil repeats:YES];
  [NSRunLoop.mainRunLoop addTimer:timer_ forMode:NSRunLoopCommonModes];
}

- (void)finishRun:(NSDictionary*)values {
  NSMutableDictionary* result = [@{ @"measure": scenario_, @"compositor": AraratUsesSharedCompositor() ? @"c2" : @"c1", @"run": @(run_) } mutableCopy];
  [result addEntriesFromDictionary:values];
  NSData* data = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
  if (data) { fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout); fflush(stdout); }
  if (++run_ > 10) {
    [timer_ invalidate];
    [cover_ orderOut:nil];
    [host_.window setFrame:initial_frame_ display:YES];
    observer_.reset();
    AraratQuit();
    return;
  }
  before_ = nil;
  covered_ = nil;
  switch_ms_ = -1;
  [self setStage:1];
}

- (NSArray*)deltasFrom:(NSArray*)before to:(NSArray*)after {
  NSMutableArray* result = [NSMutableArray array];
  for (NSUInteger i = 0; i < before.count; ++i) {
    id a = before[i];
    id b = i < after.count ? after[i] : NSNull.null;
    [result addObject:[a isKindOfClass:NSNumber.class] && [b isKindOfClass:NSNumber.class] ? @([b integerValue] - [a integerValue]) : (id)NSNull.null];
  }
  return result;
}

- (NSDictionary*)pids {
  NSMutableOrderedSet* renderers = [NSMutableOrderedSet orderedSet];
  for (ARTab* tab in tabs_) {
    if (tab.contents && tab.contents->GetPrimaryMainFrame()) {
      auto& process = tab.contents->GetPrimaryMainFrame()->GetProcess()->GetProcess();
      if (process.IsValid()) [renderers addObject:@(process.Pid())];
    }
  }
  NSMutableArray* gpus = [NSMutableArray array];
  for (content::BrowserChildProcessHostIterator it(content::PROCESS_TYPE_GPU); !it.Done(); ++it) {
    if (it.GetProcess().IsValid()) [gpus addObject:@(it.GetProcess().Pid())];
  }
  return @{ @"renderer_pids": renderers.array, @"gpu_pids": gpus };
}

- (void)tick:(NSTimer*)timer {
  double elapsed = (base::TimeTicks::Now() - stage_start_).InSecondsF();
  if (stage_ == 0) {
    NSInteger needed = [scenario_ isEqualToString:@"background"] ? 10 : ([scenario_ isEqualToString:@"switch"] || [scenario_ isEqualToString:@"split"]) ? 3 : 1;
    tabs_ = host_.tabs;
    BOOL ready = tabs_.count >= needed;
    for (ARTab* tab in tabs_) if (tab.isLoading || !tab.contents) ready = NO;
    if (ready) { [self setStage:1]; return; }
    if (elapsed > 30) {
      for (int i = 0; i < 10; ++i) [self finishRun:@{ @"timeout": @"loading" }];
    }
    return;
  }
  if (stage_ == 1 && [scenario_ isEqualToString:@"display"]) {
    [self setStage:2];
    [self sample:@[tabs_[0]] completion:^(NSArray* values) {
      self->before_ = values;
      self->covered_ = values;
      NSScreen* other = NSScreen.screens.firstObject == self->host_.window.screen ? NSScreen.screens.lastObject : NSScreen.screens.firstObject;
      NSRect frame = self->host_.window.frame;
      frame.origin = other.visibleFrame.origin;
      [self->host_.window setFrame:frame display:YES];
      self->uncover_epoch_ms_ = base::Time::Now().InMillisecondsFSinceUnixEpochIgnoringNull();
      [self setStage:6];
    }];
    return;
  }
  if ([scenario_ isEqualToString:@"split"]) {
    if (stage_ == 1) {
      split_count_ = (run_ % 2) ? 2 : 3;
      id<ARWindowHostDelegate> delegate = host_.delegate;
      split_open_epoch_ = base::Time::Now().InMillisecondsFSinceUnixEpochIgnoringNull();
      if (![delegate respondsToSelector:@selector(windowHost:installSplitMeasurement:)] ||
          ![delegate windowHost:host_ installSplitMeasurement:split_count_]) {
        [self finishRun:@{ @"unsupported": @YES }]; return;
      }
      [tabs_[0] activateWithCommandId:@"split-measure-focus"];
      [self setStage:20]; return;
    }
    NSArray<ARTab*>* observed = [tabs_ subarrayWithRange:NSMakeRange(0, split_count_)];
    if (stage_ == 20 && elapsed >= 0.2) {
      [self setStage:21];
      [self sampleSplit:observed completion:^(NSArray* stats) { self->split_visible_ = stats; [self setStage:22]; }];
      return;
    }
    if (stage_ == 22 && elapsed >= 5) {
      [self setStage:23];
      [self sampleSplit:observed completion:^(NSArray* stats) {
        self->split_after_visible_ = stats;
        [self->tabs_[1] activateWithCommandId:@"split-measure-switch-1"];
        [self setStage:24];
      }];
      return;
    }
    if (stage_ == 24 && elapsed >= 0.5) {
      [tabs_[0] activateWithCommandId:@"split-measure-switch-2"];
      [self setStage:25]; return;
    }
    if (stage_ == 25 && elapsed >= 0.5) {
      [self setStage:26];
      [self sampleSplit:observed completion:^(NSArray* stats) { self->split_after_switch_ = stats; [self setStage:27]; }];
      return;
    }
    if (stage_ == 27) {
      BOOL finished = elapsed >= 1;
      CGFloat delta = 60 * sin(std::min(1.0, elapsed) * 6.28318530718);
      id<ARWindowHostDelegate> delegate = host_.delegate;
      if (finished) split_release_epoch_ = base::Time::Now().InMillisecondsFSinceUnixEpochIgnoringNull();
      if (![delegate respondsToSelector:@selector(windowHost:dragSplitMeasurement:finished:)] ||
          ![delegate windowHost:host_ dragSplitMeasurement:delta finished:finished]) {
        [self finishRun:@{ @"error": @"divider unavailable" }]; return;
      }
      if (!finished) return;
      split_drag_seconds_ = elapsed;
      [self setStage:28];
      [self sampleSplit:observed completion:^(NSArray* stats) { self->split_after_drag_ = stats; [self setStage:29]; }];
      return;
    }
    if (stage_ == 29 && elapsed >= 0.2) {
      [self setStage:30];
      [self sampleSplit:observed completion:^(NSArray* afterRelease) {
        NSMutableArray* visibleRaf = [NSMutableArray array];
        NSMutableArray* switchGaps = [NSMutableArray array];
        NSMutableArray* dragResize = [NSMutableArray array];
        NSMutableArray* releaseResize = [NSMutableArray array];
        NSMutableArray* dragDropped = [NSMutableArray array];
        NSMutableArray* openRaf = [NSMutableArray array];
        NSMutableArray* releaseRaf = [NSMutableArray array];
        for (NSInteger i = 0; i < self->split_count_; ++i) {
          id start = self->split_visible_[i], end = self->split_after_visible_[i];
          id switched = self->split_after_switch_[i], dragged = self->split_after_drag_[i], released = afterRelease[i];
          BOOL valid = [start isKindOfClass:NSDictionary.class] && [end isKindOfClass:NSDictionary.class] &&
              [switched isKindOfClass:NSDictionary.class] && [dragged isKindOfClass:NSDictionary.class] && [released isKindOfClass:NSDictionary.class];
          if (!valid) {
            [visibleRaf addObject:NSNull.null]; [switchGaps addObject:NSNull.null]; [dragResize addObject:NSNull.null];
            [releaseResize addObject:NSNull.null];
            [dragDropped addObject:NSNull.null]; [openRaf addObject:NSNull.null]; [releaseRaf addObject:NSNull.null]; continue;
          }
          [visibleRaf addObject:@([end[@"raf"] integerValue] - [start[@"raf"] integerValue])];
          [switchGaps addObject:switched[@"gap"] ?: (id)NSNull.null];
          [dragResize addObject:@([dragged[@"resize"] integerValue] - [switched[@"resize"] integerValue])];
          [releaseResize addObject:@([released[@"resize"] integerValue] - [dragged[@"resize"] integerValue])];
          NSInteger raf = [dragged[@"raf"] integerValue] - [switched[@"raf"] integerValue];
          [dragDropped addObject:@(std::max<NSInteger>(0, std::lround(self->refresh_rate_ * self->split_drag_seconds_) - raf))];
          NSNumber* (^firstAfter)(NSDictionary*, double) = ^NSNumber*(NSDictionary* stats, double epoch) {
            for (NSString* value in [stats[@"frames"] componentsSeparatedByString:@","]) {
              double timestamp = value.doubleValue;
              if (timestamp >= epoch) return @(timestamp - epoch);
            }
            return nil;
          };
          [openRaf addObject:firstAfter(start, self->split_open_epoch_) ?: (id)NSNull.null];
          [releaseRaf addObject:firstAfter(released, self->split_release_epoch_) ?: (id)NSNull.null];
        }
        [self finishRun:@{ @"panes": @(self->split_count_), @"visible_raf_5s": visibleRaf,
          @"switch_max_gap_ms": switchGaps, @"drag_resize_events": dragResize, @"release_resize_events": releaseResize, @"drag_dropped_frames": dragDropped,
          @"open_first_raf_ms": openRaf, @"release_first_raf_ms": releaseRaf,
          @"open_presented_ms": NSNull.null, @"release_presented_ms": NSNull.null,
          @"drag_kind": @"synthetic-divider-events" }];
      }];
      return;
    }
    if ((stage_ == 21 || stage_ == 23 || stage_ == 26 || stage_ == 28 || stage_ == 30) && elapsed > 10)
      [self finishRun:@{ @"timeout": @"split sampling" }];
    return;
  }
  if ([scenario_ isEqualToString:@"switch"]) {
    if (stage_ == 1) {
      if (run_ % 2) {
        [tabs_[(run_ / 2) % 2] activateWithCommandId:@"measure-base"];
        hidden_since_ = base::TimeTicks::Now();
      }
      [self setStage:2];
      return;
    }
    bool ready = run_ % 2 ? elapsed >= 1 :
        (base::TimeTicks::Now() - hidden_since_).InSecondsF() >= 30;
    if (stage_ == 2 && ready) {
      ARTab* target = tabs_[(run_ % 2) ? 1 - (run_ / 2) % 2 : 2];
      content::WebContents* contents = target.contents;
      auto* view = contents->GetRenderWidgetHostView();
      switch_ms_ = -1;
      __weak ARMeasure* weakSelf = self;
      observer_ = std::make_unique<base::StatisticsRecorder::ScopedHistogramSampleObserver>(
          "Browser.Tabs.TotalSwitchDuration3", base::BindRepeating(^(std::string_view, uint64_t, base::HistogramBase::Sample32 sample) {
            ARMeasure* strongSelf = weakSelf;
            if (strongSelf && strongSelf->stage_ == 3 && strongSelf->switch_ms_ < 0) strongSelf->switch_ms_ = sample;
          }));
      contents->SetTabSwitchStartTime(base::TimeTicks::Now(), !target.isLoading, view && view->HasSavedCompositorFrame(), false);
      [self setStage:3];
      [target activateWithCommandId:@"measure-switch"];
      return;
    }
    if (stage_ == 3 && (switch_ms_ >= 0 || elapsed > 10)) {
      observer_.reset();
      [self finishRun:@{ @"kind": (run_ % 2) ? @"loaded" : @"hidden30s", @"switch_ms": switch_ms_ >= 0 ? @(switch_ms_) : (id)NSNull.null }];
    }
    return;
  }
  if (stage_ == 1) {
    [tabs_[0] activateWithCommandId:@"measure-visible"];
    NSArray* observed = [scenario_ isEqualToString:@"background"] ? [tabs_ subarrayWithRange:NSMakeRange(1, tabs_.count - 1)] : @[tabs_[0]];
    [self setStage:2];
    [self sample:observed completion:^(NSArray* values) {
      self->before_ = values;
      self->counter_start_ = base::TimeTicks::Now();
      [self setStage:3];
    }];
    return;
  }
  if (stage_ == 2 && elapsed > 10) { [self finishRun:@{ @"timeout": @"initial counter" }]; return; }
  if (stage_ == 3) {
    if ([scenario_ isEqualToString:@"occlusion"]) {
      cover_ = [[NSWindow alloc] initWithContentRect:host_.window.frame styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
      cover_.opaque = YES; cover_.backgroundColor = NSColor.blackColor;
      [cover_ orderWindow:NSWindowAbove relativeTo:host_.window.windowNumber];
    }
    [self setStage:4];
    return;
  }
  if (stage_ == 4) {
    if ([scenario_ isEqualToString:@"resize"]) {
      NSRect frame = initial_frame_;
      frame.size.width += 80 * sin(elapsed * 6.28318530718);
      [host_.window setFrame:frame display:YES];
    }
    double duration = [scenario_ isEqualToString:@"background"] ? 30 : [scenario_ isEqualToString:@"occlusion"] ? 10 : 5;
    if (elapsed < duration) return;
    NSArray* observed = [scenario_ isEqualToString:@"background"] ? [tabs_ subarrayWithRange:NSMakeRange(1, tabs_.count - 1)] : @[tabs_[0]];
    [self setStage:5];
    [self sample:observed completion:^(NSArray* values) {
      if ([self->scenario_ isEqualToString:@"background"]) {
        NSMutableDictionary* result = [[self pids] mutableCopy];
        result[@"raf_delta"] = [self deltasFrom:self->before_ to:values];
        [self finishRun:result];
      } else if ([self->scenario_ isEqualToString:@"resize"]) {
        id delta = [self deltasFrom:self->before_ to:values].firstObject;
        double interval = (base::TimeTicks::Now() - self->counter_start_).InSecondsF();
        NSInteger expected = std::lround(self->refresh_rate_ * interval);
        [self finishRun:@{ @"expected_frames": @(expected), @"interval_s": @(interval), @"raf_count": delta, @"dropped": [delta isKindOfClass:NSNumber.class] ? @(std::max<NSInteger>(0, expected - [delta integerValue])) : (id)NSNull.null }];
      } else {
        self->covered_ = values;
        [self->cover_ orderOut:nil]; self->cover_ = nil;
        self->uncover_epoch_ms_ = base::Time::Now().InMillisecondsFSinceUnixEpochIgnoringNull();
        [self setStage:6];
      }
    }];
    return;
  }
  if (stage_ == 5 && elapsed > 10) { [cover_ orderOut:nil]; cover_ = nil; [self finishRun:@{ @"timeout": @"final counter" }]; return; }
  if (stage_ == 6) {
    if (elapsed > 10) { [self finishRun:@{ @"raf_delta": [self deltasFrom:before_ to:covered_].firstObject, @"first_frame_after_ms": NSNull.null }]; return; }
    [self sample:@[tabs_[0]] completion:^(NSArray* values) {
      id previous = self->covered_.firstObject;
      id current = values.firstObject;
      if ([previous isKindOfClass:NSNumber.class] && [current isKindOfClass:NSNumber.class] && [current integerValue] > [previous integerValue]) {
        self->pending_ = YES;
        NSInteger generation = self->generation_;
        ReadFrameTimes(self->tabs_[0], ^(NSString* times) {
          if (self->generation_ != generation) return;
          self->pending_ = NO;
          NSNumber* first = nil;
          for (NSString* item in [times componentsSeparatedByString:@","]) {
            double timestamp = item.doubleValue;
            if (timestamp >= self->uncover_epoch_ms_) { first = @(timestamp - self->uncover_epoch_ms_); break; }
          }
          if (first) [self finishRun:@{ @"raf_delta": [self deltasFrom:self->before_ to:self->covered_].firstObject, @"first_frame_after_ms": first }];
        });
      }
    }];
  }
}
@end

__attribute__((visibility("default"))) void AraratStartMeasure(id<ARWindowHostAPI> host, NSString* scenario) {
  g_measure = [[ARMeasure alloc] initWithHost:(ARWindowHost*)host scenario:scenario];
  [g_measure start];
}
