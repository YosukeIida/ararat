from pathlib import Path
import sys

source = Path("engine/ararat/ararat_tab.mm").read_text()
decision = source[source.index("enum class TabFaviconKind"):source.index("void TraceSwitcherThumbnail")]
getter = source[source.index("- (NSImage*)favicon {"):source.index("- (NSDictionary<NSString*, id>*)checkFaviconState")]

pre = r'''#import <Foundation/Foundation.h>
#include <cassert>
#include <cstdio>

@class NSImage;

namespace content {
struct Image {
  NSImage* value = nil;
  bool IsEmpty() const { return value == nil; }
  NSImage* ToNSImage() const { return value; }
};
struct FaviconStatus {
  bool valid = false;
  Image image;
};
struct NavigationEntry {
  FaviconStatus status;
  FaviconStatus& GetFavicon() { return status; }
};
struct Controller {
  NavigationEntry* visible = nullptr;
  NavigationEntry* committed = nullptr;
  NavigationEntry* GetVisibleEntry() { return visible; }
  NavigationEntry* GetLastCommittedEntry() { return committed; }
};
struct WebContents {
  Controller controller;
  Controller& GetController() { return controller; }
};
}

''' + decision + r'''
@interface ProbeTab : NSObject {
@public
  content::WebContents* contents_;
}
- (NSImage*)favicon;
@end

@implementation ProbeTab
''' + getter + r'''
@end

int main() {
  @autoreleasepool {
    ProbeTab* tab = [ProbeTab new];
    assert(tab.favicon == nil);
    content::WebContents contents;
    tab->contents_ = &contents;
    auto& controller = contents.controller;
    assert(ClassifyTabFavicon(nullptr, nullptr) == TabFaviconKind::kNone);
    assert(tab.favicon == nil);

    NSImage* default_icon = (NSImage*)@"default";
    NSImage* page_icon = (NSImage*)@"page";
    content::NavigationEntry old_page{{true, {page_icon}}};
    content::NavigationEntry next_page{{false, {default_icon}}};
    controller.committed = &old_page;
    controller.visible = &old_page;
    assert(ClassifyTabFavicon(&old_page, &old_page) == TabFaviconKind::kPage);
    assert(tab.favicon == page_icon);

    controller.visible = &next_page;
    assert(ClassifyTabFavicon(&next_page, &old_page) == TabFaviconKind::kDefault);
    assert(!tab.favicon);
    controller.committed = &next_page;
    assert(ClassifyTabFavicon(&next_page, &next_page) == TabFaviconKind::kDefault);
    assert(!tab.favicon);

    controller.visible = &old_page;
    assert(ClassifyTabFavicon(&old_page, &next_page) == TabFaviconKind::kStale);
    assert(!tab.favicon);
    controller.committed = &old_page;
    assert(tab.favicon == page_icon);
  }
  std::puts("Live favicon: page icon, pending and committed default, and stale entry passed.");
}
'''
Path(sys.argv[1]).write_text(pre)
