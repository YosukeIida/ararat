#ifndef ARARAT_PUBLIC_ARARAT_ENGINE_H_
#define ARARAT_PUBLIC_ARARAT_ENGINE_H_

#include <stdbool.h>

// The engine's C entry points, for launchers outside the engine tree. The
// exported definitions carry default visibility in ararat_main.mm; the names
// are listed in both ararat.exports and the link patch's framework.order additions.

#ifdef __cplusplus
extern "C" {
#endif

#ifdef __BLOCKS__
typedef void (^AraratContinueQuit)(void);
#else
typedef void* AraratContinueQuit;
#endif

// The callbacks the engine calls on its own stages; any function may be null.
typedef struct AraratCallbacks {
  void (*started)(void* ctx);
  void (*will_shut_down)(void* ctx);
  bool (*reopen)(void* ctx, bool has_visible_windows);
  // `popup` is a real popup, app popup or devtools host; an off-the-record normal Browser is
  // a full window, so `off_the_record` and the Profile* travel beside the name (the name of an
  // OTR profile is its parent's, which cannot tell two OTR profiles apart).
  void* (*create_host)(void* ctx, bool popup, bool off_the_record, void* profile, const char* profile_name, int x, int y, int width, int height);
  void (*open_urls)(void* ctx, void* urls);
  bool (*confirm_quit)(void* ctx, bool powering_off, bool shortcut,
                       bool is_repeat, AraratContinueQuit continue_quit);
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
