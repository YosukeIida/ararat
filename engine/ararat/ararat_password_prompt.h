#ifndef ARARAT_CORE_ARARAT_PASSWORD_PROMPT_H_
#define ARARAT_CORE_ARARAT_PASSWORD_PROMPT_H_

#include <string>

#include "base/functional/callback.h"
#include "base/memory/weak_ptr.h"
#include "chrome/browser/ui/passwords/bubble_controllers/save_update_bubble_controller.h"
#include "components/password_manager/core/common/password_manager_ui.h"

namespace content {
class WebContents;
}
namespace views {
class Widget;
}

class AraratPasswordPromptModel {
 public:
  enum class Action { kAccept, kNotNow, kNever };

  static bool Supports(password_manager::ui::State state);
  static bool SupportsConfirmation(password_manager::ui::State state);
  AraratPasswordPromptModel(base::WeakPtr<PasswordsModelDelegate> delegate,
                            base::RepeatingCallback<bool()> can_save,
                            PasswordBubbleControllerBase::DisplayReason reason);
  ~AraratPasswordPromptModel();

  const password_manager::PasswordForm& credential() const;
  void EditCredential(const std::u16string& username,
                      password_manager::PasswordString password);
  void ShouldRevealPasswords(base::OnceCallback<void(bool)> callback);
  bool IsUpdate() const;
  bool CanNever() const;
  bool Act(Action action);
  void Close();

 private:
  base::WeakPtr<PasswordsModelDelegate> delegate_;
  const password_manager::ui::State initial_state_;
  base::RepeatingCallback<bool()> can_save_;
  SaveUpdateBubbleController controller_;
  bool finished_ = false;
};

void AraratInstallPasswordPrompt();
struct AraratPasswordOffer {
  unsigned long generation = 0;
  bool is_update = false;
};
void AraratObservePasswordOffer(content::WebContents*, base::RepeatingClosure);
AraratPasswordOffer AraratGetPasswordOffer(content::WebContents*);
bool AraratReopenPasswordOffer(content::WebContents*, unsigned long generation);
views::Widget* AraratCheckPasswordPromptWidget(content::WebContents* contents);
bool AraratCheckPressNeverButton(views::Widget* widget);
bool AraratCheckEditPassword(views::Widget* widget, bool empty);
int AraratCheckPasswordPromptNotNowCount();

#endif  // ARARAT_CORE_ARARAT_PASSWORD_PROMPT_H_
