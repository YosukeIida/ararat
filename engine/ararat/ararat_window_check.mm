#include "ararat/core/ararat_window_check.h"
#include "ararat/core/ararat_window_host.h"

#import <AppKit/AppKit.h>

#include <iostream>
#include <memory>

#include "ararat/core/public/AraratEngine.h"
#include "base/command_line.h"
#include "base/functional/bind.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/ui/browser_window.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/create_browser_window.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/navigation_throttle.h"
#include "content/public/browser/navigation_throttle_registry.h"
#include "net/base/net_errors.h"
#include "url/gurl.h"

namespace {
class OfflineCheckThrottle final : public content::NavigationThrottle {
 public:
  using NavigationThrottle::NavigationThrottle;
  ThrottleCheckResult WillStartRequest() override {
    return {CANCEL, net::ERR_INTERNET_DISCONNECTED};
  }
  const char* GetNameForLogging() override { return "AraratOfflineCheck"; }
};

ARWindowHost* g_check_host;
NSView* g_check_view;
bool g_check_passed = true;

void WaitForClose(int remaining) {
  auto* collection = GlobalBrowserCollection::GetInstance();
  if ((collection->GetSize() == 0 && ![g_check_host hasBrowser]) ||
      remaining == 0) {
    if (collection->GetSize() != 0 || [g_check_host hasBrowser]) {
      std::cerr << "engine: window check did not close its browser\n";
      g_check_passed = false;
    }
    if (collection->GetSize() == 0 && ![g_check_host hasBrowser]) {
      g_check_host = nil;
      g_check_view = nil;
    }
    AraratQuit();
    return;
  }
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(
      FROM_HERE, base::BindOnce(&WaitForClose, remaining - 1),
      base::Milliseconds(100));
}
}  // namespace

void AraratCheckAddNavigationThrottle(content::NavigationThrottleRegistry& registry) {
  const auto& command = *base::CommandLine::ForCurrentProcess();
  if (command.GetSwitchValueASCII("ararat-check") != "errorpages" &&
      command.GetSwitchValueASCII("ararat-screen") != "errorpages")
    return;
  auto& handle = registry.GetNavigationHandle();
  if (handle.IsInPrimaryMainFrame() &&
      handle.GetURL() == GURL("https://docs.example.org/"))
    registry.AddThrottle(std::make_unique<OfflineCheckThrottle>(registry));
}

bool AraratWindowCheckPassed() {
  return g_check_passed;
}

void AraratCheckWindow() {
  g_check_view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
  g_check_host = [[ARWindowHost alloc] initWithContentView:g_check_view windowId:@"window-1"];
  [g_check_host makePending];
  Profile* profile = ProfileManager::GetLastUsedProfileIfLoaded();
  BrowserWindowInterface* browser =
      profile ? CreateBrowserWindow(BrowserWindowCreateParams(profile, true))
              : nullptr;
  auto* collection = GlobalBrowserCollection::GetInstance();
  NSWindow* native_window = [g_check_host window];
  [native_window.contentView layoutSubtreeIfNeeded];
  NSRect bounds = g_check_view.bounds;
  NSPoint point =
      [g_check_view convertPoint:NSMakePoint(NSMidX(bounds), NSMidY(bounds))
                          toView:native_window.contentView.superview];
  NSView* hit = [native_window.contentView hitTest:point];
  bool native_is_host =
      browser && browser->GetWindow()->GetNativeWindow().GetNativeNSWindow() ==
                     native_window;
  bool hit_in_app =
      hit && (hit == g_check_view || [hit isDescendantOf:g_check_view]);
  bool browser_view =
      browser && BrowserWindow::FromBrowser(browser)->AsBrowserView();
  auto count = collection->GetSize();
  bool ok = count == 1 && !browser_view && native_is_host && hit_in_app;
  g_check_passed = ok;
  std::cout << "{\"check\":\"window\",\"ok\":" << (ok ? "true" : "false")
            << ",\"browsers\":" << count
            << ",\"browser_view\":" << (browser_view ? "true" : "false")
            << ",\"native_window_is_host\":"
            << (native_is_host ? "true" : "false")
            << ",\"hit_test_in_app_view\":" << (hit_in_app ? "true" : "false")
            << "}\n"
            << std::flush;
  [g_check_host close];
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&WaitForClose, 200));
}
