#ifndef ARARAT_ARARAT_HOOKS_H_
#define ARARAT_ARARAT_HOOKS_H_

// Every hook is a g_ararat_* function pointer: defined in the Chrome file
// that owns the behaviour, declared here for our layer to set. Unset means
// stock, so the Chrome file reads the pointer before every call. Hook sites
// live only in .cc/.mm files.

#ifdef __cplusplus

#include <memory>
#include "components/permissions/permission_prompt.h"

namespace content { class WebContents; }
namespace history { class HistoryService; }
extern void (*g_ararat_history_deleting)(history::HistoryService*);
extern void (*g_ararat_devtools_changed)(content::WebContents*,
                                         content::WebContents*);
extern std::unique_ptr<permissions::PermissionPrompt> (*g_ararat_create_permission_prompt)(
    content::WebContents*, permissions::PermissionPrompt::Delegate*);

#ifdef __OBJC__
@class NSMenu;
@class NSURL;
@class NSArray<ObjectType>;
@class NSWindow;
class BrowserWindowInterface;
class Profile;
extern bool (*g_ararat_reopen)(bool has_visible_windows);
extern NSMenu* (*g_ararat_dock_menu)();
extern void (*g_ararat_open_urls)(NSArray* urls, Profile* profile);
extern BrowserWindowInterface* (*g_ararat_shown_browser)(NSWindow*, bool*);
#endif

class BrowserWindowInterface;
class BrowserWindow;
extern BrowserWindow* (*g_ararat_create_browser_window)(
    BrowserWindowInterface*);
extern bool (*g_ararat_is_window)(BrowserWindowInterface*);

// chrome/browser/chrome_content_browser_client.cc hands the browser main parts
// it created to this hook, and our layer adds its own extra parts through it.
// Unset means stock.
class ChromeBrowserMainParts;
extern "C" void (*g_ararat_add_browser_main_extra_parts)(
    ChromeBrowserMainParts* parts);

#endif

#endif  // ARARAT_ARARAT_HOOKS_H_
