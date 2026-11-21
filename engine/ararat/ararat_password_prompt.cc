#include "ararat/core/ararat_password_prompt.h"

#include <cstdio>
#include <memory>
#include <utility>
#include <vector>

#include "ararat/core/ararat_hooks.h"
#include "base/command_line.h"
#include "base/containers/flat_map.h"
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
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
#include "chrome/browser/ui/passwords/bubble_controllers/manage_passwords_bubble_controller.h"
#include "chrome/browser/ui/passwords/manage_passwords_ui_controller.h"
#include "chrome/browser/ui/passwords/passwords_model_delegate.h"
#include "components/constrained_window/constrained_window_views.h"
#include "components/password_manager/core/browser/password_form.h"
#include "components/password_manager/core/common/password_manager_pref_names.h"
#include "components/prefs/pref_change_registrar.h"
#include "components/tabs/public/tab_interface.h"
#include "components/url_formatter/elide_url.h"
#include "components/web_modal/web_contents_modal_dialog_manager.h"
#include "components/web_modal/web_contents_modal_dialog_manager_delegate.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/web_contents_user_data.h"
#include "net/base/registry_controlled_domains/registry_controlled_domain.h"
#include "ui/base/models/dialog_model.h"
#include "ui/base/models/simple_combobox_model.h"
#include "ui/base/mojom/ui_base_types.mojom.h"
#include "ui/views/accessibility/view_accessibility.h"
#include "ui/views/bubble/bubble_dialog_model_host.h"
#include "ui/views/controls/button/button.h"
#include "ui/views/controls/editable_combobox/editable_password_combobox.h"
#include "ui/views/controls/label.h"
#include "ui/views/focus/focus_manager.h"
#include "ui/views/interaction/element_tracker_views.h"
#include "ui/views/widget/widget.h"

using password_manager::ui::State;
using Action = AraratPasswordPromptModel::Action;
using DisplayReason = PasswordBubbleControllerBase::DisplayReason;

bool AraratPasswordPromptModel::Supports(State state) {
  return state == State::PENDING_PASSWORD_STATE ||
         state == State::PENDING_PASSWORD_UPDATE_STATE;
}

bool AraratPasswordPromptModel::SupportsConfirmation(State state) {
  return state == State::SAVE_CONFIRMATION_STATE ||
         state == State::UPDATE_CONFIRMATION_STATE;
}

AraratPasswordPromptModel::AraratPasswordPromptModel(
    base::WeakPtr<PasswordsModelDelegate> delegate,
    base::RepeatingCallback<bool()> can_save,
    DisplayReason reason)
    : delegate_(delegate),
      initial_state_(delegate->GetState()),
      can_save_(std::move(can_save)),
      controller_(std::move(delegate), reason) {}

AraratPasswordPromptModel::~AraratPasswordPromptModel() = default;

const password_manager::PasswordForm& AraratPasswordPromptModel::credential()
    const {
  return controller_.pending_password();
}

void AraratPasswordPromptModel::EditCredential(
    const std::u16string& username,
    password_manager::PasswordString password) {
  if (!finished_) {
    controller_.OnCredentialEdited(username, std::move(password));
  }
}

void AraratPasswordPromptModel::ShouldRevealPasswords(
    base::OnceCallback<void(bool)> callback) {
  if (!finished_ && delegate_ && delegate_->GetState() == initial_state_ &&
      can_save_.Run()) {
    controller_.ShouldRevealPasswords(std::move(callback));
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
       (credential().password_value.empty() ||
        controller_.IsSavingBlockedByTrustedVaultError()))) {
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
DEFINE_LOCAL_ELEMENT_IDENTIFIER_VALUE(kPassword);
DEFINE_LOCAL_ELEMENT_IDENTIFIER_VALUE(kAccept);
DEFINE_LOCAL_ELEMENT_IDENTIFIER_VALUE(kNever);

}  // namespace

void AraratAddPasswordField(
    ui::DialogModel& dialog,
    std::unique_ptr<views::EditablePasswordCombobox> field) {
  dialog.AddCustomField(
      std::make_unique<views::BubbleDialogModelHost::CustomView>(
          std::move(field), views::BubbleDialogModelHost::FieldType::kControl),
      kPassword);
}

namespace {

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

bool CanHostPrompt(content::WebContents* contents) {
  auto* manager = web_modal::WebContentsModalDialogManager::FromWebContents(contents);
  return manager && manager->delegate() &&
         manager->delegate()->GetWebContentsModalDialogHost(contents);
}

class PasswordOffer : public content::WebContentsUserData<PasswordOffer>,
                      public content::WebContentsObserver {
 public:
  void SetSubmitted(bool submitted) {
    auto* controller = ManagePasswordsUIController::FromWebContents(web_contents());
    if (submitted && controller && CanSave(web_contents(), controller->GetOrigin())) {
      static unsigned long next_generation = 0;
      generation_ = ++next_generation;
      url_ = web_contents()->GetLastCommittedURL();
    } else {
      generation_ = 0;
    }
    Notify();
  }

  unsigned long generation() const { return generation_; }

  void Notify() {
    if (changed) {
      changed.Run();
    }
  }

  base::RepeatingClosure changed;

 private:
  explicit PasswordOffer(content::WebContents* contents)
      : WebContentsUserData(*contents), WebContentsObserver(contents) {
    prefs_.Init(Profile::FromBrowserContext(contents->GetBrowserContext())->GetPrefs());
    for (const char* name : {password_manager::prefs::kAraratPasswordManagerEnabled,
                             password_manager::prefs::kCredentialsEnableService}) {
      prefs_.Add(name, base::BindRepeating(&PasswordOffer::PrefsChanged,
                                          base::Unretained(this)));
    }
  }

  void PrefsChanged() {
    auto* controller = ManagePasswordsUIController::FromWebContents(web_contents());
    if (generation_ && (!controller || !CanSave(web_contents(), controller->GetOrigin()))) {
      SetSubmitted(false);
    }
  }

  void DidFinishNavigation(content::NavigationHandle* navigation) override {
    if (generation_ && navigation->HasCommitted() &&
        navigation->IsInPrimaryMainFrame() && !navigation->IsSameDocument() &&
        (navigation->IsErrorPage() ||
         !net::registry_controlled_domains::SameDomainOrHost(
             url_, navigation->GetURL(),
             net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES))) {
      SetSubmitted(false);
    }
  }

  void PrimaryMainFrameRenderProcessGone(base::TerminationStatus) override {
    if (generation_) {
      SetSubmitted(false);
    }
  }

  friend WebContentsUserData;
  WEB_CONTENTS_USER_DATA_KEY_DECL();
  PrefChangeRegistrar prefs_;
  unsigned long generation_ = 0;
  GURL url_;
};

WEB_CONTENTS_USER_DATA_KEY_IMPL(PasswordOffer);

void SetOfferSubmitted(content::WebContents* contents, bool submitted) {
  if (auto* offer = PasswordOffer::FromWebContents(contents)) {
    offer->SetSubmitted(submitted);
  }
}

void NotifyOfferChanged(content::WebContents* contents) {
  if (auto* offer = PasswordOffer::FromWebContents(contents)) {
    offer->Notify();
  }
}

bool CanActOnOffer(content::WebContents* contents,
                   const url::Origin& origin,
                   unsigned long generation) {
  auto* offer = contents ? PasswordOffer::FromWebContents(contents) : nullptr;
  return generation && offer && offer->generation() == generation &&
         CanSave(contents, origin);
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
         base::WeakPtr<PasswordsModelDelegate> delegate,
         DisplayReason reason,
         unsigned long generation)
      : contents_(contents),
        origin_(delegate->GetOrigin()),
        generation_(generation) {
    if (AraratPasswordPromptModel::SupportsConfirmation(delegate->GetState())) {
      confirmation_ = std::make_unique<ManagePasswordsBubbleController>(
          std::move(delegate));
    } else {
      model_ = std::make_unique<AraratPasswordPromptModel>(
          std::move(delegate),
          base::BindRepeating(
              [](base::WeakPtr<content::WebContents> contents,
                 const url::Origin& origin, unsigned long generation) {
                return CanActOnOffer(contents.get(), origin, generation);
              },
              contents->GetWeakPtr(), origin_, generation_),
          reason);
      has_never_button_ = model_->CanNever();
    }
  }

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
            model_ ? url::Origin::Create(model_->credential().url) : origin_));
    site->SetHorizontalAlignment(gfx::ALIGN_LEFT);
    site->SetMultiLine(true);
    site->SetAllowCharacterBreak(true);

    ui::DialogModel::Builder builder;
    builder.SetInternalName("AraratPasswordPrompt")
        .DisableCloseOnDeactivate()
        .SetTitle(confirmation_ ? confirmation_->GetTitle() : Title())
        .AddCustomField(std::make_unique<views::BubbleDialogModelHost::CustomView>(
            std::move(site), views::BubbleDialogModelHost::FieldType::kText))
        .SetDialogDestroyingCallback(base::BindOnce(&Prompt::Destroyed, weak));
    std::unique_ptr<views::EditablePasswordCombobox> password;
    if (model_) {
      password = std::make_unique<views::EditablePasswordCombobox>(
          std::make_unique<ui::SimpleComboboxModel>(
              std::vector<ui::SimpleComboboxModel::Item>()),
          views::style::CONTEXT_TEXTFIELD, views::style::STYLE_PRIMARY_MONOSPACED,
          /*display_arrow=*/false, base::BindRepeating(&Prompt::ToggleReveal, weak));
      password->GetViewAccessibility().SetName(u"Password");
      password->SetPasswordIconTooltips(u"Show password", u"Hide password");
      password->SetText(model_->credential().password_value.secure_value());
      password->SetCallback(base::BindRepeating(&Prompt::CredentialChanged, weak));
      password_ = password.get();
      builder.AddTextfield(kUsername, u"User name", model_->credential().username_value)
          .SetInitiallyFocusedField(kUsername)
          .AddOkButton(base::BindOnce(&Prompt::Act, weak, Action::kAccept),
                       ui::DialogModel::Button::Params().SetId(kAccept).SetLabel(
                           model_->IsUpdate() ? u"Update" : u"Save"))
          .AddCancelButton(base::BindOnce(&Prompt::Act, weak, Action::kNotNow),
                           ui::DialogModel::Button::Params().SetLabel(u"Not Now"));
      if (has_never_button_) {
        builder.AddExtraButton(
            base::BindRepeating(&Prompt::Never, weak),
            ui::DialogModel::Button::Params().SetId(kNever).SetLabel(
                u"Never for This Site"));
      }
    } else {
      builder.AddOkButton(base::DoNothing(),
                          ui::DialogModel::Button::Params().SetLabel(u"Done"));
    }
    auto dialog = builder.Build();
    if (model_) {
      AraratAddPasswordField(*dialog, std::move(password));
      dialog_ = dialog.get();
      username_ = dialog_->GetTextfieldByUniqueId(kUsername);
      edit_subscription_ = username_->AddOnFieldChangedCallback(
          base::BindRepeating(&Prompt::CredentialChanged, weak));
    }
    auto host = views::BubbleDialogModelHost::CreateModal(
        std::move(dialog), ui::mojom::ModalType::kChild);
    host->set_esc_should_cancel_dialog_override(model_ != nullptr);
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
    return model_->IsUpdate() ? u"Update password?" : u"Save password?";
  }

  void CredentialChanged() {
    if (!contents_) {
      return;
    }
    model_->EditCredential(username_->text(), password_manager::PasswordString(
                                                 std::u16string(password_->GetText())));
    auto* accept = dialog_->GetButtonByUniqueId(kAccept);
    dialog_->SetButtonEnabled(accept, !password_->GetText().empty());
    dialog_->SetButtonLabel(accept, model_->IsUpdate() ? u"Update" : u"Save");
    if (has_never_button_) {
      dialog_->SetVisible(kNever, model_->CanNever());
    }
    if (widget_) {
      widget_->widget_delegate()->SetTitle(Title());
    }
  }

  void ToggleReveal(const ui::Event&) {
    if (password_->ArePasswordsRevealed()) {
      password_->RevealPasswords(false);
      return;
    }
    model_->ShouldRevealPasswords(base::BindOnce(
        [](base::WeakPtr<Prompt> prompt, bool allowed) {
          if (prompt && prompt->password_ && allowed &&
              CanActOnOffer(prompt->contents_, prompt->origin_, prompt->generation_)) {
            prompt->password_->RevealPasswords(true);
          }
        },
        weak_.GetWeakPtr()));
  }

  void Act(Action action) { model_->Act(action); }

  void Never(const ui::Event&) {
    Act(Action::kNever);
    Hide();
  }

  bool Detach() {
    if (!contents_) {
      return false;
    }
    auto* contents = contents_.get();
    contents_ = nullptr;
    Prompts().erase(contents);
    prefs_.RemoveAll();
    if (model_) {
      model_->Close();
    } else {
      confirmation_->OnBubbleClosing();
    }
    NotifyOfferChanged(contents);
    return true;
  }

  void Destroyed() {
    widget_ = nullptr;
    edit_subscription_ = {};
    username_ = nullptr;
    password_ = nullptr;
    dialog_ = nullptr;
    Detach();
    base::SingleThreadTaskRunner::GetCurrentDefault()->DeleteSoon(FROM_HERE,
                                                                 this);
  }

  raw_ptr<content::WebContents> contents_;
  const url::Origin origin_;
  const unsigned long generation_;
  std::unique_ptr<AraratPasswordPromptModel> model_;
  std::unique_ptr<ManagePasswordsBubbleController> confirmation_;
  bool has_never_button_ = false;
  PrefChangeRegistrar prefs_;
  base::CallbackListSubscription edit_subscription_;
  raw_ptr<ui::DialogModelTextfield> username_ = nullptr;
  raw_ptr<views::EditablePasswordCombobox> password_ = nullptr;
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
  const State state = controller->GetState();
  auto* offer = PasswordOffer::FromWebContents(contents);
  const bool pending = AraratPasswordPromptModel::Supports(state) &&
      offer && offer->generation() &&
      !controller->GetPendingPassword().password_value.empty() &&
      !controller->IsSavingBlockedByTrustedVaultError();
  const bool confirm = !user_action &&
      AraratPasswordPromptModel::SupportsConfirmation(state);
  if (CheckMode()) {
    std::fprintf(stderr, "ararat-trace: password-engine hook state=%d\n",
                 static_cast<int>(state));
  }
  if ((!pending && !confirm) || !CanHostPrompt(contents) ||
      !CanSave(contents, controller->GetOrigin())) {
    VLOG(1) << "Ararat skipped password prompt state=" << static_cast<int>(state);
    if (CheckMode()) {
      std::fprintf(stderr, "ararat-trace: password prompt skipped state=%d\n",
                   static_cast<int>(state));
    }
    ReleaseSkippedBubble(*controller);
    return true;
  }

  auto* prompt = new Prompt(contents, controller->GetModelDelegateProxy(),
                            user_action ? DisplayReason::kUserAction
                                        : DisplayReason::kAutomatic,
                            pending ? offer->generation() : 0);
  Prompts().emplace(contents, prompt);
  prompt->Show();
  NotifyOfferChanged(contents);
  if (CheckMode()) {
    std::fprintf(stderr, "ararat-trace: password-engine dialog_created\n");
  }
  return true;
}

}  // namespace

void AraratInstallPasswordPrompt() {
  g_ararat_password_prompt = &HandlePasswordPrompt;
  g_ararat_password_offer = &SetOfferSubmitted;
}

void AraratObservePasswordOffer(content::WebContents* contents,
                                base::RepeatingClosure changed) {
  if (!Profile::FromBrowserContext(contents->GetBrowserContext())->IsOffTheRecord()) {
    PasswordOffer::GetOrCreateForWebContents(contents)->changed = std::move(changed);
  }
}

AraratPasswordOffer AraratGetPasswordOffer(content::WebContents* contents) {
  auto* offer = PasswordOffer::FromWebContents(contents);
  auto* controller = ManagePasswordsUIController::FromWebContents(contents);
  auto* tab = tabs::TabInterface::MaybeGetFromContents(contents);
  auto* manager = autofill::BubbleManager::GetForWebContents(contents);
  if (!offer || !offer->generation() || !controller || !tab ||
      !tab->IsActivated() || !manager ||
      manager->HasPendingBubbleOfSameType(autofill::BubbleType::kPassword) ||
      controller->IsShowingBubble() ||
      !AraratPasswordPromptModel::Supports(controller->GetState()) ||
      !CanSave(contents, controller->GetOrigin()) || !CanHostPrompt(contents) ||
      controller->GetPendingPassword().password_value.empty() ||
      controller->IsSavingBlockedByTrustedVaultError()) {
    return {};
  }
  return {offer->generation(),
          controller->GetState() == State::PENDING_PASSWORD_UPDATE_STATE};
}

bool AraratReopenPasswordOffer(content::WebContents* contents,
                              unsigned long generation) {
  if (!generation || AraratGetPasswordOffer(contents).generation != generation) {
    return false;
  }
  ManagePasswordsUIController::FromWebContents(contents)->QueueOrShowBubble(
      /*user_action=*/true);
  return true;
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

bool AraratCheckEditPassword(views::Widget* widget, bool empty) {
  auto context = views::ElementTrackerViews::GetContextForWidget(widget);
  auto* tracker = views::ElementTrackerViews::GetInstance();
  auto fields = tracker->GetAllMatchingViews(kPassword, context, true);
  if (fields.size() != 1 || fields.front()->GetWidget() != widget) {
    return false;
  }
  auto* password = static_cast<views::EditablePasswordCombobox*>(fields.front());
  if (password->ArePasswordsRevealed()) {
    return false;
  }
  password->SetText(empty ? u"" : u"fixture-edited-56");
  return widget->widget_delegate()->AsDialogDelegate()->IsDialogButtonEnabled(
             ui::mojom::DialogButton::kOk) == !empty;
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
