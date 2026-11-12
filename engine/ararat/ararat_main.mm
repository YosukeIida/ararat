// The browser process's entry (architecture 4.5). Helpers never reach this
// file: their executable runs the stock ChromeMain, and the extra-parts hook
// stays unset, so they behave stock.

#include "ararat/core/public/AraratEngine.h"

#include <atomic>
#include <cstdio>
#include <iostream>
#include <string_view>
#include <vector>

#include "ararat/core/ararat_hooks.h"
#include "ararat/core/ararat_permission_prompt.h"
#include "ararat/core/ararat_tab_history.h"
#include "ararat/core/ararat_window_check.h"
#include "ararat/core/ararat_window_host.h"
#include "base/command_line.h"
#include "base/files/file_util.h"
#include "base/functional/bind.h"
#include "base/scoped_observation.h"
#include "base/path_service.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/chrome_browser_main.h"
#include "chrome/browser/chrome_browser_main_extra_parts.h"
#include "chrome/browser/global_features.h"
#include "chrome/browser/lifetime/application_lifetime.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/startup/startup_tab_provider.h"
#include "chrome/browser/ui/browser_window/public/browser_collection.h"
#include "chrome/browser/ui/browser_window/public/browser_collection_observer.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/common/chrome_paths.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/web_contents.h"
#import "ararat/core/public/AraratHostAPI.h"

// 157 declares ChromeMain file-locally (chrome/app/chrome_main.cc:89-93) and
// exports no header for it, so the entry file declares what it calls.
extern "C" int ChromeMain(int argc, const char** argv);

namespace {

AraratCallbacks g_ararat_callbacks = {};
// AraratQuit is callable from anywhere, including before the browser's task
// executor exists; the request is honoured at the started stage when it is.
std::atomic<bool> g_quit_requested{false};
std::atomic<bool> g_ui_ready{false};
bool g_check_tabs = false;
bool g_check_split = false;
bool g_check_transfer = false;
bool g_check_slice = false;
bool g_slice_passed = false;
bool g_shared_compositor = false;
unsigned long g_stock_browsers = 0;
bool g_check_devtools_destroyed = false;
bool g_trace_teardown = false;

bool TraceTeardown() {
  return g_trace_teardown;
}

void TraceAttemptExit() {
  if (TraceTeardown()) std::fprintf(stderr, "ararat-teardown: AttemptExit entered\n");
  chrome::AttemptExit();
}

void DispatchCommandLineURLs(Profile* profile) {
  if (!profile || !g_ararat_open_urls) return;
  StartupTabProviderImpl provider;
  auto tabs = provider.GetCommandLineTabs(*base::CommandLine::ForCurrentProcess(),
                                          base::FilePath(), profile);
  NSMutableArray* urls = [NSMutableArray array];
  for (const auto& tab : tabs) {
    NSURL* url = [NSURL URLWithString:[NSString stringWithUTF8String:tab.url.spec().c_str()]];
    if (url) [urls addObject:@{ @"url": url, @"untrusted": @(tab.is_untrusted_launch) }];
  }
  if (urls.count) g_ararat_open_urls(urls, ProfileManager::MaybeForceOffTheRecordMode(profile));
}

class StockBrowserObserver : public BrowserCollectionObserver {
 public:
  void OnBrowserCreated(BrowserWindowInterface* browser) override {
    if (!g_ararat_is_window || !g_ararat_is_window(browser)) ++g_stock_browsers;
  }
  void OnBrowserClosed(BrowserWindowInterface* browser) override {
    if (base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check") == "profiles" &&
        browser->GetType() == BrowserWindowInterface::TYPE_DEVTOOLS)
      g_check_devtools_destroyed = true;
  }
};

// The engine's own browser main extra parts: the two callbacks fire at the
// engine's own stages, and the check run prints its one JSON line and quits.
class AraratBrowserMainExtraParts : public ChromeBrowserMainExtraParts {
 public:
  void PreBrowserStart() override {
    ChromeBrowserMainExtraParts::PreBrowserStart();
    observation_.Observe(GlobalBrowserCollection::GetInstance());
  }
  void PostBrowserStart() override {
    ChromeBrowserMainExtraParts::PostBrowserStart();
    ararat::tab_history::StartHistoryWatcher();
    g_ui_ready.store(true, std::memory_order_release);
    // A quit requested before the loop exists is honoured here; the posted task
    // runs once the main loop runs.
    if (g_quit_requested.load(std::memory_order_acquire)) {
      content::GetUIThreadTaskRunner({})->PostTask(
          FROM_HERE, base::BindOnce(&chrome::AttemptExit));
    }
    if (g_ararat_callbacks.started) {
      g_ararat_callbacks.started(g_ararat_callbacks.ctx);
    }
    if (!base::CommandLine::ForCurrentProcess()->GetArgs().empty()) {
      if (Profile* profile = ProfileManager::GetLastUsedProfileIfLoaded()) {
        DispatchCommandLineURLs(profile);
      } else {
        g_browser_process->profile_manager()->LoadProfile(
            ProfileManager::GetLastUsedProfileBaseName(), false,
            base::BindOnce(&DispatchCommandLineURLs));
      }
    }
    RunCheck();
  }

  void PostMainMessageLoopRun() override {
    if (TraceTeardown()) std::fprintf(stderr, "ararat-teardown: main message loop returned\n");
    AraratClearDetachedTransfers();
    observation_.Reset();
    ChromeBrowserMainExtraParts::PostMainMessageLoopRun();
    if (g_ararat_callbacks.will_shut_down) {
      g_ararat_callbacks.will_shut_down(g_ararat_callbacks.ctx);
    }
  }

 private:
  StockBrowserObserver stock_observer_;
  base::ScopedObservation<GlobalBrowserCollection, BrowserCollectionObserver>
      observation_{&stock_observer_};
  // The guards ran in AraratMain before the engine started, so reaching here
  // means the run is a scratch one and the JSON line is the whole contract.
  void RunCheck() {
    auto* command_line = base::CommandLine::ForCurrentProcess();
    if (command_line->GetSwitchValueASCII("ararat-check") == "window") {
      AraratCheckWindow();
      return;
    }
    if (command_line->GetSwitchValueASCII("ararat-check") == "tabs") {
      AraratCheckTabs();
      return;
    }
    if (command_line->GetSwitchValueASCII("ararat-check") == "split") {
      AraratCheckSplit();
      return;
    }
    if (command_line->GetSwitchValueASCII("ararat-check") == "transfer" ||
        command_line->GetSwitchValueASCII("ararat-check") == "transfer-ext") {
      AraratCheckTransfer(command_line->GetSwitchValueASCII("ararat-check") == "transfer-ext");
      return;
    }
    if (command_line->GetSwitchValueASCII("ararat-check") != "started") {
      return;
    }
    int browsers = 0;
    if (auto* features = g_browser_process ? g_browser_process->GetFeatures() : nullptr) {
      if (auto* collection = features->global_browser_collection()) {
        browsers = static_cast<int>(collection->GetSize());
      }
    }
    std::cout << "{\"check\":\"started\",\"ok\":true,\"browsers\":" << browsers
              << "}\n" << std::flush;
    AraratQuit();
  }
};

// Why not base::CommandLine: ChromeMain initialises it later, and the guards
// must run before the engine starts at all. Why not base::GetTempDir: on macOS
// it reads NSTemporaryDirectory(), not the $TMPDIR the rules name.
void CheckGuards(int argc, const char** argv) {
  const char* temp = getenv("TMPDIR");
  std::string temp_dir = temp ? temp : "";
  while (!temp_dir.empty() && temp_dir.back() == '/') { temp_dir.pop_back(); }
  bool has_check = false;
  bool bare_check = false;
  bool check_started = false;
  bool under_temp = false;
  bool mock_keychain = false;
  bool check_slice = false;
  bool check_permissions = false;
  bool check_dialogs = false;
  bool check_protocol = false;
  bool check_autofill = false;
  bool check_devtools = false;
  bool disable_system_notifications = false;
  bool enable_features = false;
  unsigned disable_features_count = 0;
  bool option_terminator = false;
  bool db_under_temp = false;
  bool has_measure = false;
  bool valid_measure = false;
  bool has_screen = false;
  bool valid_screen = false;
  bool screen_prompts = false;
  bool check_downloads = false;
  bool screen_downloads = false;
  bool check_toasts = false;
  bool screen_toasts = false;
  for (int i = 0; i < argc; ++i) {
    const char* arg = argv[i] ? argv[i] : "";
    if (strcmp(arg, "--") == 0) option_terminator = true;
    if (strncmp(arg, "--disable-features", 18) == 0) ++disable_features_count;
    if (strncmp(arg, "--ararat-compositor=", 20) == 0) {
      std::string_view compositor(arg + 20);
      if (compositor != "c1" && compositor != "c2") {
        std::cerr << "engine: --ararat-compositor must be c1 or c2" << std::endl;
        exit(2);
      }
      g_shared_compositor = compositor == "c2";
    } else if (strcmp(arg, "--ararat-compositor") == 0) {
      std::cerr << "engine: --ararat-compositor must be c1 or c2" << std::endl;
      exit(2);
    }
    if (strncmp(arg, "--ararat-measure=", 17) == 0) {
      has_measure = true;
      std::string_view name(arg + 17);
      valid_measure = name == "switch" || name == "background" ||
                      name == "occlusion" || name == "resize" || name == "display" || name == "split";
    } else if (strcmp(arg, "--ararat-measure") == 0) {
      has_measure = true;
      valid_measure = false;
    }
    if (strncmp(arg, "--ararat-screen=", 16) == 0) {
      has_screen = true;
      screen_prompts = std::string_view(arg + 16) == "prompts";
      screen_downloads = std::string_view(arg + 16) == "downloads";
      screen_toasts = std::string_view(arg + 16) == "toasts";
      valid_screen = std::string_view(arg + 16) == "quit" || std::string_view(arg + 16) == "links" || std::string_view(arg + 16) == "profiles" || std::string_view(arg + 16) == "prompts" || std::string_view(arg + 16) == "devtools" || std::string_view(arg + 16) == "extensions" || std::string_view(arg + 16) == "fullscreen" || std::string_view(arg + 16) == "keyboard" || std::string_view(arg + 16) == "organize" || std::string_view(arg + 16) == "look" || std::string_view(arg + 16) == "dock" || std::string_view(arg + 16) == "commandbar" || std::string_view(arg + 16) == "sidebar-rows" || std::string_view(arg + 16) == "folder-empty" || std::string_view(arg + 16) == "today" || std::string_view(arg + 16) == "space-name" || std::string_view(arg + 16) == "site-controls" || std::string_view(arg + 16) == "ext-actions";
      if (std::string_view(arg + 16) == "links" || std::string_view(arg + 16) == "profiles" || std::string_view(arg + 16) == "prompts" || std::string_view(arg + 16) == "devtools" || std::string_view(arg + 16) == "extensions" || std::string_view(arg + 16) == "fullscreen" || std::string_view(arg + 16) == "keyboard" || std::string_view(arg + 16) == "organize" || std::string_view(arg + 16) == "look" || std::string_view(arg + 16) == "dock" || std::string_view(arg + 16) == "commandbar" || std::string_view(arg + 16) == "sidebar-rows" || std::string_view(arg + 16) == "folder-empty" || std::string_view(arg + 16) == "today" || std::string_view(arg + 16) == "space-name" || std::string_view(arg + 16) == "site-controls" || std::string_view(arg + 16) == "ext-actions") g_check_slice = true;
      if (std::string_view(arg + 16) == "errorpages") { valid_screen = true; g_check_slice = true; }
      if (std::string_view(arg + 16) == "dialogs") { valid_screen = true; g_check_slice = true; }
      if (screen_downloads) { valid_screen = true; g_check_slice = true; }
      if (screen_toasts) { valid_screen = true; g_check_slice = true; }
    } else if (strcmp(arg, "--ararat-screen") == 0) {
      has_screen = true;
    }
    if (strcmp(arg, "--ararat-check") == 0) {
      // Chrome would read the switch as empty and open "started" as a URL in
      // the given profile, so the bare form is refused outright.
      bare_check = true;
    } else if (strncmp(arg, "--ararat-check=", 15) == 0) {
      has_check = true;
      std::string_view name(arg + 15);
      check_permissions = name == "permissions";
      check_dialogs = name == "dialogs";
      check_protocol = name == "protocol";
      check_autofill = name == "autofill";
      check_devtools = name == "devtools";
      check_downloads = name == "downloads";
      check_toasts = name == "toasts";
      bool browser_check = name == "newtab" || name == "popup" ||
                           name == "menu" || name == "empty" || name == "deferred" || name == "profiles" ||
                           name == "ext-windows" || name == "ext-popup" || name == "ext-windows-popup" || name == "incognito" || name == "permissions" || name == "dialogs" || name == "protocol" || name == "autofill" || name == "devtools" || name == "fullscreen" || name == "keyboard" || name == "organize" || name == "look" || name == "download-close" || name == "sidebar-rows" || name == "folder-empty" || name == "today" || name == "space-name" || name == "dock" || name == "commandbar" || name == "sadtab" || name == "relaunch-seed" || name == "relaunch-verify" || name == "history-clear" || name == "history-purge" || name == "site-controls" || name == "ext-actions";
      browser_check = browser_check || name == "errorpages";
      browser_check = browser_check || check_downloads;
      browser_check = browser_check || check_toasts;
      g_check_tabs = name == "tabs";
      g_check_split = name == "split";
      g_check_transfer = name == "transfer" || name == "transfer-ext";
      check_slice = name == "slice";
      g_check_slice = check_slice;
      check_started = name == "started" || name == "window" || name == "tabs" || name == "split" || g_check_transfer || name == "relaunch-pins" ||
                      name == "slice" || name == "quit" || name == "quit-cancel" ||
                      name == "close" || browser_check;
      check_slice = check_slice || name == "quit" || name == "quit-cancel" || name == "relaunch-pins" ||
                    name == "close" || browser_check;
      // Why not require g_slice_passed: DevTools validates after ChromeMain returns.
      g_check_slice = g_check_slice || (browser_check && !check_devtools);
    } else if (strncmp(arg, "--user-data-dir=", 16) == 0) {
      base::FilePath dir(std::string(arg + 16));
      under_temp = !temp_dir.empty() && !dir.empty() && !dir.ReferencesParent()
          && base::FilePath(temp_dir).IsParent(dir);
    } else if (std::string_view(arg) == "--use-mock-keychain") {
      mock_keychain = true;
    } else if (std::string_view(arg) == "--disable-features=SystemNotifications") {
      disable_system_notifications = true;
    } else if (strncmp(arg, "--enable-features", 17) == 0) {
      enable_features = true;
    } else if (strncmp(arg, "--ararat-db=", 12) == 0) {
      base::FilePath db(std::string(arg + 12));
      db_under_temp = !temp_dir.empty() && !db.empty() &&
                      !db.ReferencesParent() && base::FilePath(temp_dir).IsParent(db);
    }
  }
  auto refuse = [check_permissions, check_dialogs, check_protocol, check_autofill, check_devtools](const char* reason) {
    std::cerr << "engine: --ararat-check refused (" << reason << ")"
              << std::endl;
    if (check_permissions) {
      std::cout << "{\"check\":\"permissions\",\"ok\":false,\"error\":\"invalid arguments\",\"exit\":2}" << std::endl;
    }
    if (check_dialogs) {
      std::cout << "{\"check\":\"dialogs\",\"ok\":false,\"error\":\"invalid arguments\",\"exit\":2}" << std::endl;
    }
    if (check_protocol) {
      std::cout << "{\"check\":\"protocol\",\"ok\":false,\"error\":\"invalid arguments\",\"exit\":2}" << std::endl;
    }
    if (check_autofill) {
      std::cout << "{\"check\":\"autofill\",\"ok\":false,\"error\":\"invalid arguments\",\"exit\":2}" << std::endl;
    }
    if (check_devtools) {
      std::cout << "{\"check\":\"devtools\",\"ok\":false,\"error\":\"invalid arguments\",\"exit\":2}" << std::endl;
    }
    exit(2);
  };
  if (bare_check) {
    refuse("the switch needs a =name");
  }
  if ((check_downloads || screen_downloads || check_toasts || screen_toasts) && (!disable_system_notifications || disable_features_count != 1 || enable_features || option_terminator)) {
    refuse("downloads and toasts checks require --disable-features=SystemNotifications and no --enable-features");
  }
  if (has_measure && (!valid_measure || has_check || temp_dir.empty() || !under_temp || !mock_keychain)) {
    std::cerr << "engine: --ararat-measure requires a scenario, scratch profile and mock keychain" << std::endl;
    exit(2);
  }
  if (has_screen && (!valid_screen || has_check || has_measure || temp_dir.empty() ||
                     !under_temp || !mock_keychain || !db_under_temp)) {
    std::cerr << "engine: --ararat-screen requires a scenario, scratch profile and database, and mock keychain" << std::endl;
    if (screen_prompts)
      std::cout << "{\"screen\":\"prompts\",\"check\":\"prompts\",\"ok\":false,\"error\":\"invalid arguments\",\"exit\":2}" << std::endl;
    exit(2);
  }
  if (!has_check) {
    return;
  }
  if (temp_dir.empty()) {
    refuse("TMPDIR is not set");
  }
  if (!under_temp) {
    refuse("the user data dir is not under $TMPDIR");
  }
  if (!mock_keychain) {
    refuse("the mock keychain is missing");
  }
  if ((check_permissions || check_dialogs || check_protocol || check_autofill) && (!disable_system_notifications || disable_features_count != 1 || enable_features || option_terminator)) {
    refuse("prompts checks require --disable-features=SystemNotifications and no --enable-features");
  }
  if (check_slice && !db_under_temp) {
    refuse("the slice database is not under $TMPDIR");
  }
  if (!check_started) {
    refuse("the check name must be started, window, tabs, slice, quit, quit-cancel, close or a browser check");
  }
}

}  // namespace

bool AraratUsesSharedCompositor() { return g_shared_compositor; }
unsigned long AraratStockBrowserCount() { return g_stock_browsers; }
bool AraratCheckDevToolsDestroyed() { return g_check_devtools_destroyed; }
bool AraratHasHostCallback() { return g_ararat_callbacks.create_host != nullptr; }
void* AraratRequestHost(bool popup, const std::string& profile, const gfx::Rect& bounds) {
  return g_ararat_callbacks.create_host
      ? g_ararat_callbacks.create_host(g_ararat_callbacks.ctx, popup, profile.c_str(), bounds.x(),
                                       bounds.y(), bounds.width(), bounds.height())
      : nullptr;
}

__attribute__((visibility("default"))) int AraratMain(int argc, const char** argv, const AraratCallbacks* callbacks) {
  g_ararat_callbacks = callbacks ? *callbacks : AraratCallbacks{};
  CheckGuards(argc, argv);
  content::g_ararat_reject_javascript_dialog = &AraratCheckRejectJavaScriptDialog;
  content::g_ararat_begin_beforeunload = &AraratCheckBeginBeforeUnload;
  content::g_ararat_finish_beforeunload = &AraratCheckFinishBeforeUnload;
  content::g_ararat_enter_beforeunload_manager = &AraratCheckEnterBeforeUnloadManager;
  content::g_ararat_leave_beforeunload_manager = &AraratCheckLeaveBeforeUnloadManager;
  bool profiles = false;
  bool reverse = false;
  for (int i = 1; i < argc; ++i) {
    if (!argv[i]) continue;
    if (strcmp(argv[i], "--") == 0) break;
    if (strcmp(argv[i], "--ararat-check=profiles") == 0) profiles = true;
    if (strncmp(argv[i], "--ararat-cross-window-reverse-check=", 36) == 0) reverse = true;
  }
  g_trace_teardown = profiles && reverse;
  AraratInstallWindowFactory();
  AraratInstallPermissionPrompt();
  g_ararat_reopen = [](bool has_visible_windows) {
    return g_ararat_callbacks.reopen &&
           g_ararat_callbacks.reopen(g_ararat_callbacks.ctx, has_visible_windows);
  };
  g_ararat_dock_menu = []() -> NSMenu* { return nil; };
  g_ararat_open_urls = [](NSArray* urls, Profile* profile) {
    if (profile && profile->IsOffTheRecord()) {
      AraratOpenOffTheRecordURLs(profile, urls);
      return;
    }
    if (g_ararat_callbacks.open_urls)
      g_ararat_callbacks.open_urls(g_ararat_callbacks.ctx, (__bridge void*)urls);
  };
  // The hook is what the browser process adds; from here Chrome runs its own
  // path and our extra parts ride the stock client.
  g_ararat_add_browser_main_extra_parts = [](ChromeBrowserMainParts* parts) {
    parts->AddParts(std::make_unique<AraratBrowserMainExtraParts>());
  };
  std::vector<const char*> browser_args(argv, argv + argc);
  // The site-controls check serves a throwaway self-signed loopback certificate and allows
  // exactly that key, so Chromium reports a secure connection without touching trust stores.
  for (int i = 1; i < argc; ++i) {
    if (argv[i] && (strcmp(argv[i], "--ararat-check=site-controls") == 0 ||
                    strcmp(argv[i], "--ararat-screen=site-controls") == 0)) {
      browser_args.push_back(
          "--ignore-certificate-errors-spki-list=41bhvYwNSFKJywXg6t2xbgeAoiBIlI83FdLJO/ILKZg=");
      break;
    }
  }
  bool has_no_startup_window = false;
  for (const char* arg : browser_args) {
    if (arg && strcmp(arg, "--") == 0) break;
    if (arg && (strcmp(arg, "--no-startup-window") == 0 ||
                strncmp(arg, "--no-startup-window=", 20) == 0)) {
      has_no_startup_window = true;
      break;
    }
  }
  if (!has_no_startup_window)
    browser_args.insert(browser_args.begin() + 1, "--no-startup-window");
  int browser_argc = static_cast<int>(browser_args.size());
  browser_args.push_back(nullptr);
  int result = ChromeMain(browser_argc, browser_args.data());
  if (TraceTeardown()) std::fprintf(stderr, "ararat-teardown: ChromeMain returned=%d\n", result);
  return result == 0 && (!AraratCheckDialogIntegrity() || !AraratWindowCheckPassed() || (g_check_tabs && !AraratTabsCheckPassed()) || (g_check_split && !AraratSplitCheckPassed()) || (g_check_transfer && !AraratTransferCheckPassed()) ||
                         (g_check_slice && !g_slice_passed)) ? 1 : result;
}

__attribute__((visibility("default"))) void AraratQuit(void) {
  g_quit_requested.store(true, std::memory_order_release);
  // Before the started stage there is no task executor to post to; the extra
  // parts post the request once the loop is near. After it, any thread can
  // post, and AttemptExit is the engine's own quit path.
  bool ready = g_ui_ready.load(std::memory_order_acquire);
  if (TraceTeardown()) std::fprintf(stderr, "ararat-teardown: quit entered ui_ready=%d\n", ready);
  if (!ready) {
    return;
  }
  if (TraceTeardown()) {
    bool posted = content::GetUIThreadTaskRunner({})->PostTask(
        FROM_HERE, base::BindOnce(&TraceAttemptExit));
    std::fprintf(stderr, "ararat-teardown: AttemptExit posted=%d\n", posted);
  } else {
    content::GetUIThreadTaskRunner({})->PostTask(
        FROM_HERE, base::BindOnce(&chrome::AttemptExit));
  }
}

__attribute__((visibility("default"))) NSString* AraratUserDataDirectory(void) {
  base::FilePath path;
  if (!base::PathService::Get(chrome::DIR_USER_DATA, &path))
    return nil;
  return [NSString stringWithUTF8String:path.value().c_str()];
}

__attribute__((visibility("default"))) NSUInteger AraratBrowserCount(void) {
  return GlobalBrowserCollection::GetInstance()->GetSize();
}

__attribute__((visibility("default"))) void AraratFinishSliceCheck(BOOL passed) {
  if (TraceTeardown()) std::fprintf(stderr, "ararat-teardown: finish entered passed=%d\n", passed);
  g_slice_passed = passed;
  AraratQuit();
}
