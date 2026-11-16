from pathlib import Path
import sys

source = Path("engine/ararat/ararat_window_host.mm").read_text()
method = source.index("- (void)checkNavigate:")
gate = source[source.index("  auto* command =", method):source.index("  // A check that navigates", method)]
pre = r'''#import <Foundation/Foundation.h>
#include <cassert>
#include <cstdio>
#include <string>
namespace base {
struct CommandLine {
  bool checking = false, page_only = false;
  std::string screen;
  static CommandLine* ForCurrentProcess() { static CommandLine command; return &command; }
  bool HasSwitch(const char* name) const {
    if (std::string(name) == "ararat-check") return checking;
    assert(std::string(name) == "ararat-page-only-menu-check");
    return page_only;
  }
  std::string GetSwitchValueASCII(const char* name) const {
    assert(std::string(name) == "ararat-screen");
    return screen;
  }
};
}
bool permits(bool checking, std::string screen_name, bool page_only = false) {
  auto* args = base::CommandLine::ForCurrentProcess();
  args->checking = checking; args->screen = screen_name; args->page_only = page_only;
'''
post = r'''
  return allowed;
}
int main() {
  @autoreleasepool {
    assert(permits(false, "folder-upload"));
    assert(permits(true, ""));
    assert(permits(false, "prompts"));
    assert(!permits(false, ""));
    assert(!permits(false, "unknown"));
    assert(!permits(false, "profiles"));
    assert(permits(false, "profiles", true));
    std::puts("extracted check navigation gate checks passed");
  }
}
'''
Path(sys.argv[1]).write_text(pre + gate + post)
