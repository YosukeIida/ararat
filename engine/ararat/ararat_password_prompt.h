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
  AraratPasswordPromptModel(base::WeakPtr<PasswordsModelDelegate> delegate,
                            base::RepeatingCallback<bool()> can_save);
  ~AraratPasswordPromptModel();

  const password_manager::PasswordForm& credential() const;
  void EditUsername(const std::u16string& username);
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
views::Widget* AraratCheckPasswordPromptWidget(content::WebContents* contents);
bool AraratCheckNeverSavePassword(content::WebContents* contents);

#endif  // ARARAT_CORE_ARARAT_PASSWORD_PROMPT_H_
