#ifndef ARARAT_PUBLIC_ARARAT_ENGINE_H_
#define ARARAT_PUBLIC_ARARAT_ENGINE_H_

// The engine's C entry points, for launchers outside the engine tree. The
// exported definitions carry default visibility in ararat_main.mm; the names
// are listed in both ararat.exports and the framework.order block the link
// patch appends.

#ifdef __cplusplus
extern "C" {
#endif

// The callbacks the engine calls on its own stages; any function may be null.
typedef struct AraratCallbacks {
  void (*started)(void* ctx);
  void (*will_shut_down)(void* ctx);
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
