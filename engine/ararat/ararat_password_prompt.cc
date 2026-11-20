#include "ararat/core/ararat_password_prompt.h"

#include <cstdio>
#include <memory>
#include <utility>

#include "ararat/core/ararat_hooks.h"
#include "base/command_line.h"
#include "base/containers/flat_map.h"
#include "base/functional/bind.h"
#include "base/logging.h"
#include "base/memory/raw_ptr.h"
#include "base/metrics/histogram_base.h"
#include "base/metrics/histogram_samples.h"
#include "base/metrics/statistics_recorder.h"
#include "base/no_destructor.h"
#include "base/task/single_thread_task_runner.h"
#include "chrome/browser/password_manager/chrome_password_manager_client.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/autofill/bubble_controller_base.h"
#include "chrome/browser/ui/autofill/bubble_manager.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/passwords/manage_passwords_ui_controller.h"
#include "chrome/browser/ui/passwords/passwords_model_delegate.h"
#include "components/constrained_window/constrained_window_views.h"
#include "components/password_manager/core/browser/password_form.h"
#include "components/password_manager/core/common/password_manager_pref_names.h"
#include "components/prefs/pref_change_registrar.h"
#include "components/url_formatter/elide_url.h"
#include "components/web_modal/web_contents_modal_dialog_manager.h"
#include "components/web_modal/web_contents_modal_dialog_manager_delegate.h"
#include "content/public/browser/web_contents.h"
#include "ui/base/models/dialog_model.h"
#include "ui/base/mojom/ui_base_types.mojom.h"
#include "ui/views/bubble/bubble_dialog_model_host.h"
#include "ui/views/controls/button/button.h"
#include "ui/views/controls/label.h"
#include "ui/views/interaction/element_tracker_views.h"
#include "ui/views/widget/widget.h"

using password_manager::ui::State;
using Action = AraratPasswordPromptModel::Action;

bool AraratPasswordPromptModel::Supports(State state) {
  return state == State::PENDING_PASSWORD_STATE ||
         state == State::PENDING_PASSWORD_UPDATE_STATE;
}

AraratPasswordPromptModel::AraratPasswordPromptModel(
    base::WeakPtr<PasswordsModelDelegate> delegate,
    base::RepeatingCallback<bool()> can_save)
    : delegate_(delegate),
      initial_state_(delegate->GetState()),
      can_save_(std::move(can_save)),
      controller_(std::move(delegate),
                  PasswordBubbleControllerBase::DisplayReason::kAutomatic,
                  /*count_implicit_dismissals=*/false) {}

AraratPasswordPromptModel::~AraratPasswordPromptModel() = default;

const password_manager::PasswordForm& AraratPasswordPromptModel::credential()
    const {
  return controller_.pending_password();
}

void AraratPasswordPromptModel::EditUsername(const std::u16string& username) {
  if (!finished_) {
    controller_.OnCredentialEdited(username, credential().password_value);
  }
}

bool AraratPasswordPromptModel::IsUpdate() const {
  return controller_.IsCurrentStateUpdate();
}

bool AraratPasswordPromptModel::CanNever() const {
  return initial_state_ == State::PENDING_PASSWORD_STATE && !IsUpdate();
}

bool AraratPasswordPromptModel::Act(Action action) {
  if (finished_ || !delegate_ || delegate_->GetState() != initial_state_ ||
      !can_save_.Run() || (action == Action::kNever && !CanNever()) ||
      (action == Action::kAccept &&
       controller_.IsSavingBlockedByTrustedVaultError())) {
    return false;
  }
  finished_ = true;
  switch (action) {
    case Action::kAccept:
      controller_.OnSaveClicked();
      break;
    case Action::kNotNow:
      if (initial_state_ == State::PENDING_PASSWORD_UPDATE_STATE) {
        controller_.OnNoThanksClicked();
      } else {
        controller_.OnNotNowClicked();
      }
      break;
    case Action::kNever:
      controller_.OnNeverForThisSiteClicked();
      break;
  }
  return true;
}

void AraratPasswordPromptModel::Close() {
  finished_ = true;
  controller_.OnBubbleClosing();
}

namespace {

DEFINE_LOCAL_ELEMENT_IDENTIFIER_VALUE(kUsername);
DEFINE_LOCAL_ELEMENT_IDENTIFIER_VALUE(kAccept);
DEFINE_LOCAL_ELEMENT_IDENTIFIER_VALUE(kNever);

bool CheckMode() {
  return base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII(
             "ararat-screen") == "password-prompt";
}

bool CanSave(content::WebContents* contents, const url::Origin& origin) {
  auto* client = ChromePasswordManagerClient::FromWebContents(contents);
  return client && ChromePasswordManagerClient::CanShowBubbleOnURL(
                       contents->GetLastCommittedURL()) &&
         client->IsSavingAndFillingEnabled(origin);
}

void ReleaseSkippedBubble(ManagePasswordsUIController& controller) {
  // The queue suppresses advancement while it dispatches ShowBubble().
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(
          [](base::WeakPtr<autofill::BubbleControllerBase> pending) {
            if (!pending || pending->IsShowingBubble()) {
              return;
            }
            auto* controller =
                static_cast<ManagePasswordsUIController*>(pending.get());
            if (auto* manager = autofill::BubbleManager::GetForWebContents(
                    controller->GetWebContents())) {
              manager->OnBubbleHiddenByController(*controller, true);
            }
          },
          controller.GetBubbleControllerBaseWeakPtr()));
}

class Prompt;
auto& Prompts() {
  static base::NoDestructor<base::flat_map<content::WebContents*, Prompt*>>
      prompts;
  return *prompts;
}

class Prompt {
 public:
  Prompt(content::WebContents* contents,
         base::WeakPtr<PasswordsModelDelegate> delegate)
      : contents_(contents),
        model_(delegate, base::BindRepeating(
                             [](base::WeakPtr<content::WebContents> contents,
                                const url::Origin& origin) {
                               return contents && CanSave(contents.get(), origin);
                             },
                             contents->GetWeakPtr(), delegate->GetOrigin())),
        has_never_button_(model_.CanNever()) {}

  void Show() {
    const auto weak = weak_.GetWeakPtr();
    auto* prefs =
        Profile::FromBrowserContext(contents_->GetBrowserContext())->GetPrefs();
    prefs_.Init(prefs);
    prefs_.Add(password_manager::prefs::kAraratPasswordManagerEnabled,
               base::BindRepeating(&Prompt::Hide, weak));
    prefs_.Add(password_manager::prefs::kCredentialsEnableService,
               base::BindRepeating(&Prompt::Hide, weak));

    auto site = std::make_unique<views::Label>(
        url_formatter::FormatOriginForSecurityDisplay(
            url::Origin::Create(model_.credential().url)));
    site->SetHorizontalAlignment(gfx::ALIGN_LEFT);
    site->SetMultiLine(true);
    site->SetAllowCharacterBreak(true);

    ui::DialogModel::Builder builder;
    builder.SetInternalName("AraratPasswordPrompt")
        .DisableCloseOnDeactivate()
        .SetTitle(Title())
        .AddCustomField(std::make_unique<views::BubbleDialogModelHost::CustomView>(
            std::move(site), views::BubbleDialogModelHost::FieldType::kText))
        .AddTextfield(kUsername, u"User name", model_.credential().username_value)
        .SetInitiallyFocusedField(kUsername)
        .AddOkButton(base::BindOnce(&Prompt::Act, weak, Action::kAccept),
                     ui::DialogModel::Button::Params().SetId(kAccept).SetLabel(
                         model_.IsUpdate() ? u"Update" : u"Save"))
        .AddCancelButton(base::BindOnce(&Prompt::Act, weak, Action::kNotNow),
                         ui::DialogModel::Button::Params().SetLabel(u"Not Now"))
        .SetDialogDestroyingCallback(base::BindOnce(&Prompt::Destroyed, weak));
    if (has_never_button_) {
      builder.AddExtraButton(
          base::BindRepeating(&Prompt::Never, weak),
          ui::DialogModel::Button::Params().SetId(kNever).SetLabel(
              u"Never for This Site"));
    }
    auto dialog = builder.Build();
    dialog_ = dialog.get();
    username_ = dialog_->GetTextfieldByUniqueId(kUsername);
    edit_subscription_ = username_->AddOnFieldChangedCallback(
        base::BindRepeating(&Prompt::UsernameChanged, weak));
    auto host = views::BubbleDialogModelHost::CreateModal(
        std::move(dialog), ui::mojom::ModalType::kChild);
    host->set_esc_should_cancel_dialog_override(true);
    widget_ = constrained_window::ShowWebModalDialogViews(host.release(), contents_);
  }

  void Hide() {
    if (Detach() && widget_) {
      widget_->Close();
    }
  }

  views::Widget* widget() const { return widget_; }

 private:
  std::u16string Title() const {
    return model_.IsUpdate() ? u"Update password?" : u"Save password?";
  }

  void UsernameChanged() {
    model_.EditUsername(username_->text());
    dialog_->SetButtonLabel(dialog_->GetButtonByUniqueId(kAccept),
                            model_.IsUpdate() ? u"Update" : u"Save");
    if (has_never_button_) {
      dialog_->SetVisible(kNever, model_.CanNever());
    }
    if (widget_) {
      widget_->widget_delegate()->SetTitle(Title());
    }
  }

  void Act(Action action) { model_.Act(action); }

  void Never(const ui::Event&) {
    Act(Action::kNever);
    Hide();
  }

  bool Detach() {
    if (!contents_) {
      return false;
    }
    Prompts().erase(std::exchange(contents_, nullptr));
    prefs_.RemoveAll();
    model_.Close();
    return true;
  }

  void Destroyed() {
    widget_ = nullptr;
    edit_subscription_ = {};
    username_ = nullptr;
    dialog_ = nullptr;
    Detach();
    base::SingleThreadTaskRunner::GetCurrentDefault()->DeleteSoon(FROM_HERE,
                                                                 this);
  }

  raw_ptr<content::WebContents> contents_;
  AraratPasswordPromptModel model_;
  const bool has_never_button_;
  PrefChangeRegistrar prefs_;
  base::CallbackListSubscription edit_subscription_;
  raw_ptr<ui::DialogModelTextfield> username_ = nullptr;
  raw_ptr<ui::DialogModel> dialog_ = nullptr;
  raw_ptr<views::Widget> widget_ = nullptr;
  base::WeakPtrFactory<Prompt> weak_{this};
};

bool HandlePasswordPrompt(content::WebContents* contents,
                          bool show,
                          bool user_action) {
  auto found = Prompts().find(contents);
  if (found != Prompts().end()) {
    found->second->Hide();
    if (!show) {
      return true;
    }
  }

  auto* browser = GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(
      contents);
  if (!browser || !g_ararat_is_window || !g_ararat_is_window(browser)) {
    return false;
  }
  if (!show) {
    return true;
  }
  auto* controller = ManagePasswordsUIController::FromWebContents(contents);
  if (!controller) {
    return true;
  }
  auto* manager = web_modal::WebContentsModalDialogManager::FromWebContents(
      contents);
  const State state = controller->GetState();
  if (CheckMode()) {
    std::fprintf(stderr, "ararat-trace: password-engine hook state=%d\n",
                 static_cast<int>(state));
  }
  if (user_action || !AraratPasswordPromptModel::Supports(state) || !manager ||
      !manager->delegate() ||
      !manager->delegate()->GetWebContentsModalDialogHost(contents) ||
      !CanSave(contents, controller->GetOrigin()) ||
      controller->GetPendingPassword().password_value.empty() ||
      controller->IsSavingBlockedByTrustedVaultError()) {
    VLOG(1) << "Ararat skipped password prompt state=" << static_cast<int>(state);
    if (CheckMode()) {
      std::fprintf(stderr, "ararat-trace: password prompt skipped state=%d\n",
                   static_cast<int>(state));
    }
    ReleaseSkippedBubble(*controller);
    return true;
  }

  auto* prompt = new Prompt(contents, controller->GetModelDelegateProxy());
  Prompts().emplace(contents, prompt);
  prompt->Show();
  if (CheckMode()) {
    std::fprintf(stderr, "ararat-trace: password-engine dialog_created\n");
  }
  return true;
}

}  // namespace

void AraratInstallPasswordPrompt() {
  g_ararat_password_prompt = &HandlePasswordPrompt;
}

views::Widget* AraratCheckPasswordPromptWidget(content::WebContents* contents) {
  auto found = Prompts().find(contents);
  return CheckMode() && found != Prompts().end() ? found->second->widget()
                                                : nullptr;
}

bool AraratCheckPressNeverButton(views::Widget* widget) {
  auto context = views::ElementTrackerViews::GetContextForWidget(widget);
  for (auto* view : views::ElementTrackerViews::GetInstance()->GetAllMatchingViews(
           kNever, context, /*require_visible=*/true)) {
    auto* button = views::Button::AsButton(view);
    if (button && button->GetWidget() == widget && button->GetEnabled()) {
      return button->AcceleratorPressed(ui::Accelerator(ui::VKEY_SPACE, ui::EF_NONE));
    }
  }
  return false;
}

int AraratCheckPasswordPromptNotNowCount() {
  if (!CheckMode()) {
    return 0;
  }
  auto* histogram = base::StatisticsRecorder::FindHistogram(
      "PasswordManager.SaveUIDismissalReason");
  return histogram ? histogram->SnapshotSamples()->GetCount(
                         password_manager::metrics_util::CLICKED_NOT_NOW)
                   : 0;
}
