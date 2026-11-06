// The browser process's entry (architecture 4.5). Helpers never reach this
// file: their executable runs the stock ChromeMain, and the extra-parts hook
// stays unset, so they behave stock.

#include "ararat/core/public/AraratEngine.h"

#include <atomic>
#include <iostream>

#include "ararat/core/ararat_hooks.h"
#include "ararat/core/ararat_window_check.h"
#include "base/command_line.h"
#include "base/files/file_util.h"
#include "base/functional/bind.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/chrome_browser_main.h"
#include "chrome/browser/chrome_browser_main_extra_parts.h"
#include "chrome/browser/global_features.h"
#include "chrome/browser/lifetime/application_lifetime.h"
#include "chrome/browser/ui/browser_window/public/browser_collection.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "content/public/browser/browser_thread.h"

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

// The engine's own browser main extra parts: the two callbacks fire at the
// engine's own stages, and the check run prints its one JSON line and quits.
class AraratBrowserMainExtraParts : public ChromeBrowserMainExtraParts {
 public:
  void PostBrowserStart() override {
    ChromeBrowserMainExtraParts::PostBrowserStart();
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
    RunCheck();
  }

  void PostMainMessageLoopRun() override {
    ChromeBrowserMainExtraParts::PostMainMessageLoopRun();
    if (g_ararat_callbacks.will_shut_down) {
      g_ararat_callbacks.will_shut_down(g_ararat_callbacks.ctx);
    }
  }

 private:
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
  for (int i = 0; i < argc; ++i) {
    const char* arg = argv[i] ? argv[i] : "";
    if (strcmp(arg, "--ararat-check") == 0) {
      // Chrome would read the switch as empty and open "started" as a URL in
      // the given profile, so the bare form is refused outright.
      bare_check = true;
    } else if (strncmp(arg, "--ararat-check=", 15) == 0) {
      has_check = true;
      g_check_tabs = std::string_view(arg + 15) == "tabs";
      check_started = std::string_view(arg + 15) == "started" ||
                      std::string_view(arg + 15) == "window" ||
                      std::string_view(arg + 15) == "tabs";
    } else if (strncmp(arg, "--user-data-dir=", 16) == 0) {
      base::FilePath dir(std::string(arg + 16));
      under_temp = !temp_dir.empty() && !dir.empty() && !dir.ReferencesParent()
          && base::FilePath(temp_dir).IsParent(dir);
    } else if (std::string_view(arg) == "--use-mock-keychain") {
      mock_keychain = true;
    }
  }
  auto refuse = [](const char* reason) {
    std::cerr << "engine: --ararat-check refused (" << reason << ")"
              << std::endl;
    exit(2);
  };
  if (bare_check) {
    refuse("the switch needs a =name");
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
  if (!check_started) {
    refuse("the check name must be started, window or tabs");
  }
}

}  // namespace

__attribute__((visibility("default"))) int AraratMain(int argc, const char** argv, const AraratCallbacks* callbacks) {
  g_ararat_callbacks = callbacks ? *callbacks : AraratCallbacks{};
  CheckGuards(argc, argv);
  // The hook is what the browser process adds; from here Chrome runs its own
  // path and our extra parts ride the stock client.
  g_ararat_add_browser_main_extra_parts = [](ChromeBrowserMainParts* parts) {
    parts->AddParts(std::make_unique<AraratBrowserMainExtraParts>());
  };
  int result = ChromeMain(argc, argv);
  return result == 0 && (!AraratWindowCheckPassed() || (g_check_tabs && !AraratTabsCheckPassed())) ? 1 : result;
}

__attribute__((visibility("default"))) void AraratQuit(void) {
  g_quit_requested.store(true, std::memory_order_release);
  // Before the started stage there is no task executor to post to; the extra
  // parts post the request once the loop is near. After it, any thread can
  // post, and AttemptExit is the engine's own quit path.
  if (!g_ui_ready.load(std::memory_order_acquire)) {
    return;
  }
  content::GetUIThreadTaskRunner({})->PostTask(
      FROM_HERE, base::BindOnce(&chrome::AttemptExit));
}
