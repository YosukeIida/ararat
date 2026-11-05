#ifndef ARARAT_ARARAT_HOOKS_H_
#define ARARAT_ARARAT_HOOKS_H_

// Every hook is a g_ararat_* function pointer: defined in the Chrome file
// that owns the behaviour, declared here for our layer to set. Unset means
// stock, so the Chrome file reads the pointer before every call. Hook sites
// live only in .cc/.mm files.

#endif  // ARARAT_ARARAT_HOOKS_H_
