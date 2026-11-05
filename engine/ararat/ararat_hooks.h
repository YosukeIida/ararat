#ifndef ARARAT_ARARAT_HOOKS_H_
#define ARARAT_ARARAT_HOOKS_H_

// Every hook is a g_ararat_* function pointer: defined in the Chrome file
// that owns the behaviour, declared here for our layer to set. Unset means
// stock, so the Chrome file reads the pointer before every call. Hook sites
// live only in .cc/.mm files.

#ifdef __cplusplus

// chrome/browser/chrome_content_browser_client.cc hands the browser main parts
// it created to this hook, and our layer adds its own extra parts through it.
// Unset means stock.
class ChromeBrowserMainParts;
extern "C" void (*g_ararat_add_browser_main_extra_parts)(
    ChromeBrowserMainParts* parts);

#endif

#endif  // ARARAT_ARARAT_HOOKS_H_
