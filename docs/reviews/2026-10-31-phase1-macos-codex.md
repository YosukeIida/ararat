1. **Major — Sidebar rows cannot be operated with the keyboard.**  
   **Location:** `macos/Sources/AraratUI/SidebarRowView.swift:5–60`.  
   **Problem:** Pinned and Today rows cannot receive keyboard focus or activate through Space/Return.  
   **Evidence:** `SidebarRowView` subclasses `NSView`; activation exists only in `mouseUp` and `accessibilityPerformPress` (lines 59–60). It implements neither `acceptsFirstResponder` nor keyboard handling. A read-only AppKit probe confirmed that plain `NSView.acceptsFirstResponder` is false.  
   **Suggested fix:** Use an appropriately styled `NSButton`, or implement focus, keyboard activation, and a visible focus indicator.

2. **Major — The harness dynamically links the core through an absolute checkout path.**  
   **Location:** `macos/Package.swift:18–20`.  
   **Problem:** Moving the built harness or removing the Rust build directory makes it fail at launch.  
   **Evidence:** The package uses `-lararat_ffi`, while `core/ararat-ffi/Cargo.toml:8` produces both static and dynamic libraries. `otool -L` on the existing harness reports:
   `/Users/yosuke/workspace/github.com/YosukeIida/ararat/core/target/release/deps/libararat_ffi.dylib`. This contradicts the static-library layout in `docs/architecture.md:55` and the description in `macos/scripts/build-core.sh:2`.  
   **Suggested fix:** Link the explicit `libararat_ffi.a` archive instead of resolving the library by name. The dylib can remain available for binding generation.

3. **Minor — Layer colors do not follow appearance changes.**  
   **Location:** `macos/Sources/AraratUI/SidebarRowView.swift:62–64,89–91`; `macos/Sources/AraratHarness/main.swift:91–95`.  
   **Problem:** Switching between light and dark appearance leaves existing layer backgrounds using previously resolved colors. Row highlights refresh only after hover or selection changes; tile and placeholder backgrounds have no refresh path.  
   **Evidence:** These assignments convert semantic `NSColor` values into fixed `CGColor` values. None of these classes implements `viewDidChangeEffectiveAppearance`.  
   **Suggested fix:** Refresh layer colors when effective appearance changes, resolving each color under the view’s effective appearance.

4. **Minor — The harness has no command channel for exercising the UI.**  
   **Location:** `macos/Sources/AraratHarness/main.swift:30–34,115–119`.  
   **Problem:** The documented pointer-free UI validation cannot select rows or switch spaces.  
   **Evidence:** `--check` prints imported counts and exits before constructing any views. Interactive mode starts `app.run()` without a command receiver. This differs from `docs/architecture.md:301`, which requires a command channel driving the components.  
   **Suggested fix:** Add a minimal channel for selecting a row and changing spaces, with observable results.

5. **Minor — The first-build hitch monitor is absent.**  
   **Location:** `macos/Sources/AraratHarness/main.swift:115–119`.  
   **Problem:** The harness cannot detect main-thread stalls during sidebar interactions.  
   **Evidence:** Startup installs no monitor, and no monitor implementation exists under `macos/`. `docs/architecture.md:305` explicitly requires one “from the first build.”  
   **Suggested fix:** Install a minimal main-thread hitch monitor at harness startup.

The §7 requirement for keyed row reuse is also deferred: `SidebarView.swift:82` explicitly documents rebuilding as a shortcut until the sidebar becomes live. I have not treated that declared phase-1 limitation as a separate defect. UI classes are main-actor isolated, and rows and tiles are layer-backed.

Validation: the existing harness passed the bundled fixture’s `--check`; shell syntax validation passed. No files changed.  
Not checked: fresh-clone compilation, visible layout, or VoiceOver behavior. Build and GUI correctness therefore remain unverified.