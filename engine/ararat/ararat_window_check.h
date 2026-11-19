#ifndef ARARAT_ARARAT_WINDOW_CHECK_H_
#define ARARAT_ARARAT_WINDOW_CHECK_H_

namespace content { class NavigationThrottleRegistry; }
void AraratCheckAddNavigationThrottle(content::NavigationThrottleRegistry&);

void AraratCheckWindow();
bool AraratWindowCheckPassed();
void AraratCheckTabs();
bool AraratTabsCheckPassed();
void AraratCheckSplit();
bool AraratSplitCheckPassed();
void AraratCheckTransfer(bool extension_path);
bool AraratTransferCheckPassed();

#endif  // ARARAT_ARARAT_WINDOW_CHECK_H_
