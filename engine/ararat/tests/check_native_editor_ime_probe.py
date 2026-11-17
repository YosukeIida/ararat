from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
start = source.index("    BOOL sendEventToKeyWindow = NO;", source.index("- (void)sendEvent:"))
dispatch = source[start:source.index("\n  });", start)]
pre = r'''#import <Foundation/Foundation.h>
#include <CoreFoundation/CoreFoundation.h>
#include <cassert>
#include <cstdio>
#include <initializer_list>

enum { NSEventTypeKeyDown, NSEventTypeKeyUp, NSEventTypeMouseMoved };
enum { kVK_JIS_Eisu = 102, kVK_JIS_Kana = 104, NSEventModifierFlagCommand = 1 };
int contextCalls = 0, windowCalls = 0, superCalls = 0;
bool forwardCmd = true;
enum InputSources { LayoutOnly, EnabledSourceWithoutType, LayoutWithEnabledIME, IMESelected };
InputSources inputSources = LayoutOnly;
bool hasInputSourceList = true;
const CFStringRef kTISPropertyInputSourceType = CFSTR("type");
const CFStringRef kTISTypeKeyboardInputMode = CFSTR("mode");
CFArrayRef TISCreateInputSourceList(CFDictionaryRef filter, Boolean includeAllInstalled) {
  assert(!includeAllInstalled);
  assert(CFDictionaryGetCount(filter) == 1);
  const void* filterType = CFDictionaryGetValue(filter, kTISPropertyInputSourceType);
  assert(filterType && CFEqual(filterType, kTISTypeKeyboardInputMode));
  CFStringRef type = inputSources == EnabledSourceWithoutType ? nullptr :
      inputSources == LayoutOnly ? CFSTR("layout") : kTISTypeKeyboardInputMode;
  const void* modes[] = {kTISTypeKeyboardInputMode};
  return hasInputSourceList ? CFArrayCreate(kCFAllocatorDefault, modes,
      type && CFEqual(type, kTISTypeKeyboardInputMode) ? 1 : 0,
      &kCFTypeArrayCallBacks) : nullptr;
}
int kForwardCmdKeyUpEventsToWindow = 0;
namespace base { struct FeatureList {
  static bool IsEnabled(int) { return forwardCmd; }
}; }
@interface Event : NSObject
@property int type, keyCode, modifierFlags;
@end
@implementation Event @end
@interface InputContext : NSObject
@property BOOL handled;
- (BOOL)handleEvent:(Event*)event;
@end
@implementation InputContext
- (BOOL)handleEvent:(Event*)event { ++contextCalls; return self.handled; }
@end
@interface NSResponder : NSObject @end
@implementation NSResponder @end
@interface NSView : NSResponder
@property(strong) InputContext* inputContext;
@end
@implementation NSView @end
@interface RenderWidgetHostViewCocoa : NSView @end
@implementation RenderWidgetHostViewCocoa @end
@interface PageSubclass : RenderWidgetHostViewCocoa @end
@implementation PageSubclass @end
@interface TestWindow : NSObject
@property(strong) NSResponder* firstResponder;
- (void)sendEvent:(Event*)event;
@end
@implementation TestWindow
- (void)sendEvent:(Event*)event { ++windowCalls; }
@end
@interface TestApp : NSObject
@property(strong) TestWindow* keyWindow;
@end
@implementation TestApp @end
TestApp* testApp;
#define NSApp testApp
@interface BaseDispatch : NSObject
- (void)sendEvent:(Event*)event;
@end
@implementation BaseDispatch
- (void)sendEvent:(Event*)event { ++superCalls; }
@end
@interface Dispatch : BaseDispatch @end
@implementation Dispatch
- (void)sendEvent:(Event*)event {
  ^{
'''
post = r'''
  }();
}
@end
int main() {
  @autoreleasepool {
    testApp = [TestApp new];
    testApp.keyWindow = [TestWindow new];
    auto* dispatcher = [Dispatch new];
    auto* event = [Event new];
    auto check = [&](NSResponder* responder, int type, int code, int flags,
                     int contexts, int windows, int supers) {
      testApp.keyWindow.firstResponder = responder;
      event.type = type; event.keyCode = code; event.modifierFlags = flags;
      contextCalls = windowCalls = superCalls = 0;
      [dispatcher sendEvent:event];
      assert(contextCalls == contexts && windowCalls == windows && superCalls == supers);
    };
    auto* native = [NSView new];
    for (int code : {kVK_JIS_Eisu, kVK_JIS_Kana}) {
      for (InputSources sources : {LayoutOnly, EnabledSourceWithoutType,
                                   LayoutWithEnabledIME, IMESelected}) {
        inputSources = sources;
        for (BOOL handled : {NO, YES}) {
          native.inputContext = [InputContext new];
          native.inputContext.handled = handled;
          int contexts = sources == LayoutWithEnabledIME || sources == IMESelected ? 1 : 0;
          check(native, NSEventTypeKeyDown, code, 0, contexts, 0, 0);
        }
        native.inputContext = nil;
        check(native, NSEventTypeKeyDown, code, 0, 0, 0, 0);
        check(nil, NSEventTypeKeyDown, code, 0, 0, 0, 0);
        check([NSResponder new], NSEventTypeKeyDown, code, 0, 0, 0, 0);
        check([RenderWidgetHostViewCocoa new], NSEventTypeKeyDown, code, 0, 0, 1, 0);
        check([PageSubclass new], NSEventTypeKeyDown, code, 0, 0, 1, 0);
        check(native, NSEventTypeKeyUp, code, 0, 0, 0, 1);
      }
      hasInputSourceList = false;
      native.inputContext = [InputContext new];
      check(native, NSEventTypeKeyDown, code, 0, 0, 0, 0);
      hasInputSourceList = true;
    }
    check(native, NSEventTypeKeyDown, 0, 0, 0, 0, 1);
    check(native, NSEventTypeMouseMoved, 0, 0, 0, 0, 1);
    check(native, NSEventTypeKeyUp, 0, NSEventModifierFlagCommand, 0, 1, 0);
    forwardCmd = false;
    check(native, NSEventTypeKeyUp, 0, NSEventModifierFlagCommand, 0, 0, 1);
    std::puts("extracted native editor IME dispatch checks passed (70 cases; no AppKit dispatch)");
  }
}
'''
Path(sys.argv[2]).write_text(pre + dispatch + post)
