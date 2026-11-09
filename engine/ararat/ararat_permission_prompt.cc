#include "ararat/core/ararat_permission_prompt.h"

#include <memory>
#include <optional>
#include <vector>

#include "ararat/core/ararat_hooks.h"
#include "base/functional/bind.h"
#include "base/command_line.h"
#include "base/location.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "components/constrained_window/constrained_window_views.h"
#include "components/permissions/permission_request.h"
#include "components/permissions/permission_uma_constants.h"
#include "components/permissions/permission_util.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/web_contents.h"
#include "ui/base/models/dialog_model.h"
#include "ui/base/models/dialog_model_field.h"
#include "ui/views/widget/widget.h"
#include "ui/views/widget/widget_observer.h"
#include "url/origin.h"

namespace {

enum class Decision { kAllow, kOnce, kBlock, kDismiss };
class AraratPermissionPrompt;
struct CheckState {
  base::WeakPtr<AraratPermissionPrompt> prompt;
  base::WeakPtr<content::WebContents> contents;
  unsigned shown_count = 0;
};
CheckState& GetCheckState() {
  static base::NoDestructor<CheckState> state;
  return *state;
}

bool IsPermissionCheck() {
  auto* command = base::CommandLine::ForCurrentProcess();
  return command->GetSwitchValueASCII("ararat-check") == "permissions" ||
         command->GetSwitchValueASCII("ararat-screen") == "prompts" ||
         command->GetSwitchValueASCII("ararat-check") == "keyboard" ||
         command->GetSwitchValueASCII("ararat-screen") == "keyboard";
}

void ApplyDecision(base::WeakPtr<permissions::PermissionPrompt::Delegate> delegate,
                   Decision decision,
                   PromptOptions options) {
  if (!delegate) return;
  switch (decision) {
    case Decision::kAllow: delegate->Accept(options); break;
    case Decision::kOnce: delegate->AcceptThisTime(options); break;
    case Decision::kBlock: delegate->Deny(options); break;
    case Decision::kDismiss: delegate->Dismiss(options); break;
  }
}

class AraratPermissionPrompt : public permissions::PermissionPrompt,
                               public views::WidgetObserver {
 public:
  AraratPermissionPrompt(content::WebContents* contents, Delegate* delegate)
      : delegate_(delegate->GetWeakPtr()) {
    auto builder = ui::DialogModel::Builder();
    builder.SetTitle(base::UTF8ToUTF16(url::Origin::Create(delegate->GetRequestingOrigin()).Serialize()));
    bool can_allow_once = !delegate->Requests().empty();
    for (const auto& request : delegate->Requests()) {
      builder.AddParagraph(ui::DialogModelLabel(request->GetMessageTextFragment()));
      can_allow_once &= permissions::PermissionUtil::DoesSupportTemporaryGrants(
          request->GetContentSettingsType());
    }
    can_allow_once_ = can_allow_once;
    auto weak = weak_factory_.GetWeakPtr();
    builder.AddOkButton(base::BindOnce(&AraratPermissionPrompt::Choose, weak, Decision::kAllow),
                        ui::DialogModel::Button::Params().SetLabel(u"Allow"));
    builder.AddCancelButton(base::BindOnce(&AraratPermissionPrompt::Choose, weak, Decision::kBlock),
                            ui::DialogModel::Button::Params().SetLabel(u"Block"));
    builder.SetCloseActionCallback(base::BindOnce(&AraratPermissionPrompt::Choose, weak, Decision::kDismiss));
    if (can_allow_once) {
      builder.AddExtraButton(base::BindRepeating(&AraratPermissionPrompt::ChooseOnce, weak),
                             ui::DialogModel::Button::Params().SetLabel(u"Allow this time"));
    }
    widget_ = constrained_window::ShowWebModal(builder.Build(), contents);
    if (widget_) widget_->AddObserver(this);
    if (IsPermissionCheck()) {
      GetCheckState().prompt = weak_factory_.GetWeakPtr();
      GetCheckState().contents = contents->GetWeakPtr();
      ++GetCheckState().shown_count;
    }
    delegate->SetPromptShown();
  }
  ~AraratPermissionPrompt() override {
    if (widget_) {
      widget_->RemoveObserver(this);
      widget_->Close();
    }
  }
  bool UpdateAnchor() override { return true; }
  TabSwitchingBehavior GetTabSwitchingBehavior() override { return kKeepPromptAlive; }
  permissions::PermissionPromptDisposition GetPromptDisposition() const override {
    return permissions::PermissionPromptDisposition::CUSTOM_MODAL_DIALOG;
  }
  bool IsAskPrompt() const override { return true; }
  std::optional<gfx::Rect> GetViewBoundsInScreen() const override {
    if (!widget_) return std::nullopt;
    return widget_->GetWindowBoundsInScreen();
  }
  std::vector<permissions::ElementAnchoredBubbleVariant> GetPromptVariants() const override { return {}; }
  std::optional<permissions::feature_params::PermissionElementPromptPosition> GetPromptPosition() const override {
    return std::nullopt;
  }
  void OnWidgetDestroying(views::Widget* widget) override {
    widget->RemoveObserver(this);
    widget_ = nullptr;
    Choose(Decision::kDismiss);
  }
  bool CheckDecision(int decision) {
    if (decision < 0 || decision > 3 || answered_) return false;
    if (decision == 1 && !can_allow_once_) return false;
    Choose(static_cast<Decision>(decision));
    if (widget_) widget_->Close();
    return true;
  }
  views::Widget* CheckWidget() { return widget_; }

 private:
  void ChooseOnce(const ui::Event&) {
    Choose(Decision::kOnce);
    if (widget_) widget_->Close();
  }
  void Choose(Decision decision) {
    if (answered_ || !delegate_) return;
    answered_ = true;
    PromptOptions options = std::monostate{};
    if ((decision == Decision::kAllow || decision == Decision::kOnce) &&
        delegate_->GetGeolocationPromptType()) {
      options = GeolocationPromptOptions{delegate_->GetInitialGeolocationAccuracySelection()};
    }
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&ApplyDecision, delegate_, decision, options));
  }
  base::WeakPtr<Delegate> delegate_;
  raw_ptr<views::Widget> widget_ = nullptr;
  bool answered_ = false;
  bool can_allow_once_ = false;
  base::WeakPtrFactory<AraratPermissionPrompt> weak_factory_{this};
};

std::unique_ptr<permissions::PermissionPrompt> CreatePrompt(
    content::WebContents* contents, permissions::PermissionPrompt::Delegate* delegate) {
  auto* tab = tabs::TabInterface::MaybeGetFromContents(contents);
  auto* browser = tab ? tab->GetBrowserWindowInterface() : nullptr;
  if (!browser || !g_ararat_is_window || !g_ararat_is_window(browser)) return nullptr;
  return std::make_unique<AraratPermissionPrompt>(contents, delegate);
}

}  // namespace

void AraratInstallPermissionPrompt() {
  g_ararat_create_permission_prompt = &CreatePrompt;
}

unsigned AraratCheckPermissionShownCount() {
  return IsPermissionCheck() ? GetCheckState().shown_count : 0;
}

bool AraratCheckPermissionDecision(content::WebContents* contents, int decision) {
  auto& state = GetCheckState();
  return IsPermissionCheck() && state.contents.get() == contents && state.prompt &&
         state.prompt->CheckDecision(decision);
}

views::Widget* AraratCheckPermissionWidget(content::WebContents* contents) {
  auto& state = GetCheckState();
  return base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-screen") == "prompts" &&
                 state.contents.get() == contents && state.prompt
             ? state.prompt->CheckWidget() : nullptr;
}
