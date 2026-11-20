from pathlib import Path
import sys

source = Path("engine/ararat/ararat_tab.mm").read_text()
decision = source[source.index("bool IsBlankSwitcherURL"):source.index("enum class TabFaviconKind")]
reserve_start = source.index("- (void)reserveSwitcherThumbnail {")
reserve_gate = source[source.index("  if (!contents_", reserve_start):source.index("  ARWindowHost* host", reserve_start)]
capture_start = source.index("- (void)captureSwitcherThumbnailForReserve:")
capture_gate = source[source.index("  const char* skip", capture_start):source.index('  else if (!view)', capture_start)]
commit_start = source.index("    if (navigation->HasCommitted() && navigation->IsInPrimaryMainFrame())")
commit_gate = source[commit_start:source.index("      const auto error", commit_start)]
load_finish_start = source.index("  void DidStopLoading() override")
load_finish = source[load_finish_start:source.index("  void NavigationEntriesDeleted", load_finish_start)]
load_finish = load_finish.replace(" override", "")

pre = r'''#import <Foundation/Foundation.h>
#include <cassert>
#include <cstdio>
#include <string_view>

struct GURL {
  std::string_view spec;
  bool IsAboutBlank() const { return spec == "about:blank"; }
  bool IsAboutSrcdoc() const { return spec == "about:srcdoc"; }
};

namespace content {
enum class Visibility { VISIBLE, HIDDEN };
struct Frame {
  GURL url;
  const GURL& GetLastCommittedURL() const { return url; }
};
struct WebContents {
  Frame primary;
  GURL visible_url;
  bool painted = true;
  Visibility visibility = Visibility::VISIBLE;
  const Frame* GetPrimaryMainFrame() const { return &primary; }
  Visibility GetVisibility() const { return visibility; }
  bool CompletedFirstVisuallyNonEmptyPaint() const { return painted; }
};
}

static const char* reserve_skip;
void TraceSwitcherThumbnail(void*, NSString* live, std::string_view source,
                            std::string_view status, const char* reason, int, double) {
  assert([live isEqualToString:@"test-live"]);
  assert(source == "reserve" && status == "skipped");
  reserve_skip = reason;
}

''' + decision + r'''
@interface ProbeTab : NSObject {
@public
  content::WebContents* contents_;
  bool thumbnail_navigating_;
  bool hasPicture;
  bool reserveAllowed;
  NSString* live_id_;
  void* host_;
}
- (void)invalidateSwitcherThumbnail;
- (void)refresh;
- (void)reserveSwitcherThumbnail;
@end

@implementation ProbeTab
- (void)invalidateSwitcherThumbnail { hasPicture = false; }
- (void)refresh {}
- (void)reserveSwitcherThumbnail {
'''
post_reserve = r'''
  reserveAllowed = true;
}
@end

const char* PrehideSkip(content::WebContents* contents_, bool thumbnail_navigating_) {
'''
post_capture = r'''
  return skip;
}

struct Navigation {
  bool committed;
  bool primary;
  bool HasCommitted() const { return committed; }
  bool IsInPrimaryMainFrame() const { return primary; }
};

struct Observer {
  ProbeTab* tab_;
  content::WebContents* web_contents() { return tab_->contents_; }
  void Finish(Navigation* navigation) {
'''
test = r'''
};

int main() {
  @autoreleasepool {
    content::WebContents contents;
    ProbeTab* tab = [ProbeTab new];
    tab->contents_ = &contents;
    tab->live_id_ = @"test-live";
    Observer observer{tab};
    constexpr auto normal = "https://example.test/";
    for (const char* blank : {"about:blank", "about:srcdoc"}) {
      contents.primary.url = {blank};
      contents.visible_url = {normal};
      assert(std::string_view(PrehideSkip(&contents, false)) == "blank-url");
      tab->reserveAllowed = false;
      reserve_skip = nullptr;
      observer.DidStopLoading();
      assert(!tab->reserveAllowed && reserve_skip && std::string_view(reserve_skip) == "blank-url");

      Navigation committed{true, true};
      tab->hasPicture = true;
      observer.Finish(&committed);
      assert(!tab->hasPicture);
    }

    contents.primary.url = {normal};
    contents.visible_url = {"about:blank"};
    assert(PrehideSkip(&contents, false) == nullptr);
    reserve_skip = nullptr;
    observer.DidStopLoading();
    assert(tab->reserveAllowed && !reserve_skip);
    Navigation committed{true, true};
    tab->hasPicture = true;
    observer.Finish(&committed);
    assert(tab->hasPicture);

    contents.primary.url = {"about:blank"};
    Navigation uncommitted{false, true};
    observer.Finish(&uncommitted);
    assert(tab->hasPicture);
    Navigation subframe{true, false};
    observer.Finish(&subframe);
    assert(tab->hasPicture);
    assert(std::string_view(PrehideSkip(&contents, true)) == "navigation-pending");
  }
  std::puts("Blank and srcdoc gates, normal URL, pending navigation, and primary commit invalidation passed.");
}
'''
Path(sys.argv[1]).write_text(
    pre + reserve_gate + post_reserve + capture_gate + post_capture + commit_gate + "    }\n  }\n" + load_finish + test
)
