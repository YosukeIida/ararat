#ifndef ARARAT_PUBLIC_ARARAT_ENGINE_H_
#define ARARAT_PUBLIC_ARARAT_ENGINE_H_

#include <stdbool.h>

// The engine's C entry points, for launchers outside the engine tree. The
// exported definitions carry default visibility in ararat_main.mm; the names
// are listed in both ararat.exports and the link patch's framework.order additions.

#ifdef __cplusplus
extern "C" {
#endif

// The callbacks the engine calls on its own stages; any function may be null.
typedef struct AraratCallbacks {
  void (*started)(void* ctx);
  void (*will_shut_down)(void* ctx);
  bool (*reopen)(void* ctx, bool has_visible_windows);
  void* (*create_host)(void* ctx, bool popup, const char* profile, int x, int y, int width, int height);
  void (*open_urls)(void* ctx, void* urls);
  void* ctx;
} AraratCallbacks;

// Runs the browser process with the engine's main delegate. Helpers must not
// call this: they run the stock ChromeMain.
int AraratMain(int argc, const char** argv, const AraratCallbacks* callbacks);

// Posts the engine's own exit to the UI thread; callable from anywhere.
void AraratQuit(void);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // ARARAT_PUBLIC_ARARAT_ENGINE_H_
