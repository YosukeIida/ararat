#ifndef ARARAT_ARARAT_PERMISSION_PROMPT_H_
#define ARARAT_ARARAT_PERMISSION_PROMPT_H_

namespace content { class WebContents; }
namespace views { class Widget; }

void AraratInstallPermissionPrompt();
unsigned AraratCheckPermissionShownCount();
bool AraratCheckPermissionDecision(content::WebContents* contents, int decision);
views::Widget* AraratCheckPermissionWidget(content::WebContents* contents);

#endif  // ARARAT_ARARAT_PERMISSION_PROMPT_H_
