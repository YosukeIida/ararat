**Three findings, ranked by severity. No files were changed.**

1. **Major — Outside-window reveal has no detection path while hidden**

   **Location:** [docs/architecture.md:237](/Users/yosuke/workspace/github.com/YosukeIida/ararat/docs/architecture.md:237), §7.

   **Problem:** The specified implementation cannot detect the pointer arriving outside the window while the sidebar is hidden.

   **Evidence:** The paragraph requires reveal when the pointer stays “left of the window,” states that outside-window tracking areas “report nothing,” and says pointer sampling “stops when the sidebar hides.” A pointer arriving directly from another window therefore has no specified detection mechanism.

   **Suggested fix:** Specify how outside-window movement is detected while hidden. Separate that detection from the sampling used to decide when a shown sidebar should hide.

2. **Major — Capture latency is not independently measured**

   **Locations:** [yabprobe.swift:29](/Users/yosuke/workspace/github.com/YosukeIida/ararat/docs/research/yab/yabprobe.swift:29), [yab-observed.md:5](/Users/yosuke/workspace/github.com/YosukeIida/ararat/docs/research/yab-observed.md:5), [arc-ardia-observed.md:3](/Users/yosuke/workspace/github.com/YosukeIida/ararat/docs/research/arc-ardia-observed.md:3).

   **Problem:** The method cannot separate capture latency from application reaction time. Consequently, the stated 15–20 ms capture latency and conclusions about immediate hiding are unsupported by this probe.

   **Evidence:** Frame timestamps come from `now()` when the callback prints; mouse timestamps are printed after posting the event ([yabprobe.swift:59](/Users/yosuke/workspace/github.com/YosukeIida/ararat/docs/research/yab/yabprobe.swift:59)). No sample presentation timestamp or independent calibration is recorded. The latency estimate is explicitly “judged from the hide reaction,” while the hide conclusion subsequently says movement starts “within capture latency” ([yab-observed.md:29](/Users/yosuke/workspace/github.com/YosukeIida/ararat/docs/research/yab-observed.md:29)). That reasoning is circular.

   **Suggested fix:** Report these as event-post-to-frame-callback measurements, with application and capture delays unresolved. Independently calibrate capture delivery before attributing a specific delay to capture. Preserve dwell-test brackets separately from first-visible-frame timings.

3. **Minor — Edge detection differs from the documented method and can miss a floating sidebar**

   **Locations:** [yabprobe.swift:21](/Users/yosuke/workspace/github.com/YosukeIida/ararat/docs/research/yab/yabprobe.swift:21), [README.md:48](/Users/yosuke/workspace/github.com/YosukeIida/ararat/docs/research/yab/README.md:48).

   **Problem:** A blank page row alone does not ensure correct detection. The algorithm can stop before reaching the sidebar.

   **Evidence:** The README describes the result as the last pixel differing from the page colour. The implementation instead stops after a sufficiently long page-coloured gap and applies an RGB-distance threshold of 24. Reproducing the loop with eight page-coloured pixels followed by a contrasting sidebar returns `0`, although the sidebar extends farther along the row. This matters for an inset floating sidebar or a sidebar region close to the page colour.

   **Suggested fix:** Make the detector match its documented definition, or document and validate the contiguous-contrast requirement. Before relying on small overshoots, retain a synthetic-row check and verify that the selected row tracks the geometric edge rather than a shadow or colour boundary.

The remaining evidence has these limits:

- **Thresholds:** The reported tests support brackets: Arc’s right slack is between 70 and 75 pt, its left retention boundary between 240 and 260 pt, and Yab’s right slack between 35 and 40 pt. The approximate summaries are reasonable within that setup. Arc’s notes explicitly leave window-size dependence and interference from another Arc window unresolved ([arc-ardia-observed.md:33](/Users/yosuke/workspace/github.com/YosukeIida/ararat/docs/research/arc-ardia-observed.md:33)); §7 should distinguish chosen Ararat constants from established general Arc behaviour.
- **Numerical verification:** The supplied files contain summaries rather than per-run traces. I could not recompute the 20-run median, frame cadence, overshoots, or animation fits. The Yab spring estimate is mathematically consistent with the stated 2% overshoot and 135 ms peak, conditional on those measurements.
- **Personal data:** I found no owner-specific space names, tab titles, or browsing URLs in the reviewed documents. `settingstext` can print personal data: it reads AX values as labels and traverses settings controls ([settingstext.swift:8](/Users/yosuke/workspace/github.com/YosukeIida/ararat/docs/research/yab/settingstext.swift:8)). The README correctly warns that its output includes owner data and must stay outside the repository.
- **Closed-source material:** I found no copied application implementation or assets in the reviewed files. The static note records identifiers, interfaces, and observations; that inspection cannot establish the provenance of every statement or snippet.

**Verdict:** Resolve findings 1 and 2 before treating §7 as a measurement-backed implementation specification.

Not checked: live browser behaviour, private settings output, or original analysis traces. The recorded timings remain unverified measurements.