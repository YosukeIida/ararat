#include "ararat/core/ararat_permission_prompt.h"

#include <memory>
#include <map>
#include <cstdio>
#include <optional>
#include <tuple>
#include <vector>

#include "ararat/core/ararat_hooks.h"
#include "base/functional/bind.h"
#include "base/command_line.h"
#include "base/location.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/task/single_thread_task_runner.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "components/constrained_window/constrained_window_views.h"
#include "components/permissions/permission_request.h"
#include "components/permissions/permission_uma_constants.h"
#include "components/permissions/permission_util.h"
#include "components/tabs/public/tab_interface.h"
#include "components/url_formatter/elide_url.h"
#include "content/public/browser/web_contents.h"
#include "ui/base/models/dialog_model.h"
#include "ui/base/models/dialog_model_field.h"
#include "ui/views/bubble/bubble_dialog_model_host.h"
#include "ui/views/controls/button/md_text_button.h"
#include "ui/views/controls/label.h"
#include "ui/views/layout/box_layout_view.h"
#include "ui/views/widget/widget.h"
#include "ui/views/widget/widget_observer.h"
#include "ui/views/window/dialog_client_view.h"
#include "url/origin.h"

namespace {

enum class Decision { kAllow, kOnce, kBlock, kDismiss };
class AraratPermissionPrompt;
std::map<const void*, base::WeakPtr<AraratPermissionPrompt>>& Prompts() {
  static base::NoDestructor<std::map<const void*, base::WeakPtr<AraratPermissionPrompt>>> prompts;
  return *prompts;
}
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

class AraratPermissionPrompt : public permissions::PermissionPrompt,
                               public views::WidgetObserver {
 public:
  AraratPermissionPrompt(content::WebContents* contents, Delegate* delegate)
      : delegate_(delegate->GetWeakPtr()), contents_(contents) {
    auto builder = ui::DialogModel::Builder();
    builder.SetTitle(u"Site permissions");
    auto origin = std::make_unique<views::Label>(
        url_formatter::FormatOriginForSecurityDisplay(
            url::Origin::Create(delegate->GetRequestingOrigin()),
            url_formatter::SchemeDisplay::OMIT_CRYPTOGRAPHIC));
    origin->SetMultiLine(true);
    origin->SetAllowCharacterBreak(true);
    origin->SetHorizontalAlignment(gfx::ALIGN_LEFT);
    origin_label_ = origin.get();
    builder.AddCustomField(std::make_unique<views::BubbleDialogModelHost::CustomView>(
        std::move(origin), views::BubbleDialogModelHost::FieldType::kText));
    bool can_allow_once = !delegate->Requests().empty();
    for (const auto& request : delegate->Requests()) {
      builder.AddParagraph(ui::DialogModelLabel(request->GetMessageTextFragment()));
      can_allow_once &= permissions::PermissionUtil::DoesSupportTemporaryGrants(
          request->GetContentSettingsType());
    }
    can_allow_once_ = can_allow_once;
    auto weak = weak_factory_.GetWeakPtr();
    builder.SetCloseActionCallback(base::BindOnce(&AraratPermissionPrompt::Choose, weak, Decision::kDismiss));
    auto buttons = std::make_unique<views::BoxLayoutView>();
    buttons->SetOrientation(views::BoxLayout::Orientation::kHorizontal);
    buttons->SetMainAxisAlignment(views::BoxLayout::MainAxisAlignment::kEnd);
    buttons->SetBetweenChildSpacing(8);
    block_button_ = buttons->AddChildView(std::make_unique<views::MdTextButton>(
        base::BindRepeating(&AraratPermissionPrompt::ChooseButton, weak, Decision::kBlock), u"Block"));
    if (can_allow_once) {
      buttons->AddChildView(std::make_unique<views::MdTextButton>(
          base::BindRepeating(&AraratPermissionPrompt::ChooseButton, weak, Decision::kOnce), u"Allow this time"));
    }
    buttons->AddChildView(std::make_unique<views::MdTextButton>(
        base::BindRepeating(&AraratPermissionPrompt::ChooseButton, weak, Decision::kAllow), u"Allow"));
    builder.AddCustomField(std::make_unique<views::BubbleDialogModelHost::CustomView>(
        std::move(buttons), views::BubbleDialogModelHost::FieldType::kControl));
    auto dialog = views::BubbleDialogModelHost::CreateModal(
        builder.Build(), ui::mojom::ModalType::kChild);
    dialog->set_esc_should_cancel_dialog_override(false);
    dialog->set_fixed_width(340);
    widget_ = constrained_window::ShowWebModalDialogViews(dialog.release(), contents);
    Prompts()[contents_] = weak_factory_.GetWeakPtr();
    if (widget_) {
      widget_->AddObserver(this);
      if (widget_->IsVisible()) AraratSetPermissionDim(contents_, true);
      TraceWidget("created");
    }
    if (IsPermissionCheck()) {
      GetCheckState().prompt = weak_factory_.GetWeakPtr();
      GetCheckState().contents = contents->GetWeakPtr();
      ++GetCheckState().shown_count;
    }
    delegate->SetPromptShown();
  }
  ~AraratPermissionPrompt() override {
    AraratSetPermissionDim(contents_, false);
    auto it = Prompts().find(contents_);
    if (it != Prompts().end() && it->second.get() == this) Prompts().erase(it);
    if (widget_) {
      widget_->RemoveObserver(this);
      block_button_ = nullptr;
      origin_label_ = nullptr;
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
    AraratSetPermissionDim(contents_, false);
    widget->RemoveObserver(this);
    widget_ = nullptr;
    block_button_ = nullptr;
    origin_label_ = nullptr;
    Choose(Decision::kDismiss);
  }
  void OnWidgetVisibilityChanged(views::Widget*, bool visible) override {
    AraratSetPermissionDim(contents_, visible);
    TraceWidget("visibility");
  }
  void OnWidgetBoundsChanged(views::Widget* widget, const gfx::Rect&) override {
    if (widget->IsVisible()) AraratSetPermissionDim(contents_, true);
  }
  bool CheckDecision(int decision) {
    if (decision < 0 || decision > 3 || answered_) return false;
    if (decision == 1 && !can_allow_once_) return false;
    Choose(static_cast<Decision>(decision));
    if (widget_) widget_->Close();
    return true;
  }
  views::Widget* CheckWidget() { return widget_; }
  views::View* CheckBlockButton() { return block_button_; }
  bool CheckOriginWrapped() {
    return origin_label_ && origin_label_->GetRequiredLines() > 1 &&
           !origin_label_->IsDisplayTextTruncated();
  }
  void RefreshDim() {
    if (widget_ && widget_->IsVisible()) AraratSetPermissionDim(contents_, true);
  }

 private:
  void TraceWidget(const char* phase) {
    if (!widget_ || !IsPermissionCheck()) return;
    auto* dialog = widget_->widget_delegate() ? widget_->widget_delegate()->AsDialogDelegate() : nullptr;
    std::fprintf(stderr, "ararat-trace: permission %s widget=%s dialog=%s bounds=%s preferred=%s visible=%d buttons=%d fixed=%d\n",
                 phase, widget_->GetName().c_str(),
                 dialog ? std::string(dialog->GetContentsView()->GetClassName()).c_str() : "none",
                 widget_->GetWindowBoundsInScreen().ToString().c_str(),
                 widget_->GetRootView()->GetPreferredSize({}).ToString().c_str(), widget_->IsVisible(),
                 dialog ? dialog->buttons() : -1, dialog ? dialog->fixed_width() : -1);
  }
  void ChooseButton(Decision decision, const ui::Event& event) {
    auto* dialog = widget_ && widget_->widget_delegate() ? widget_->widget_delegate()->AsDialogDelegate() : nullptr;
    auto* client = dialog ? dialog->GetDialogClientView() : nullptr;
    if (!dialog || !client || client->IsPossiblyUnintendedInteraction(
            event, dialog->ShouldAllowKeyEventsDuringInputProtection())) return;
    Choose(decision);
    if (widget_) widget_->Close();
  }
  void Choose(Decision decision) {
    if (answered_ || !delegate_) return;
    answered_ = true;
    for (const auto& request : delegate_->Requests())
      request_ids_.emplace_back(request->request_type(), request->requesting_origin(),
                                request->get_requesting_frame_id());
    PromptOptions options = std::monostate{};
    if ((decision == Decision::kAllow || decision == Decision::kOnce) &&
        delegate_->GetGeolocationPromptType()) {
      options = GeolocationPromptOptions{delegate_->GetInitialGeolocationAccuracySelection()};
    }
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&AraratPermissionPrompt::ApplyDecision,
                                  weak_factory_.GetWeakPtr(), decision, options));
  }
  void ApplyDecision(Decision decision, PromptOptions options) {
    if (!delegate_ || delegate_->GetCurrentPrompt() != this || request_ids_.empty() ||
        delegate_->Requests().size() != request_ids_.size()) return;
    for (size_t i = 0; i < request_ids_.size(); ++i) {
      const auto& request = delegate_->Requests()[i];
      if (request_ids_[i] != std::make_tuple(request->request_type(), request->requesting_origin(),
                                             request->get_requesting_frame_id())) return;
    }
    switch (decision) {
      case Decision::kAllow: delegate_->Accept(options); break;
      case Decision::kOnce: delegate_->AcceptThisTime(options); break;
      case Decision::kBlock: delegate_->Deny(options); break;
      case Decision::kDismiss: delegate_->Dismiss(options); break;
    }
  }
  base::WeakPtr<Delegate> delegate_;
  const void* contents_;
  raw_ptr<views::Widget> widget_ = nullptr;
  raw_ptr<views::MdTextButton> block_button_ = nullptr;
  raw_ptr<views::Label> origin_label_ = nullptr;
  bool answered_ = false;
  bool can_allow_once_ = false;
  std::vector<std::tuple<permissions::RequestType, GURL, content::GlobalRenderFrameHostId>> request_ids_;
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

void AraratRefreshPermissionDim(content::WebContents* contents) {
  auto it = Prompts().find(contents);
  if (it != Prompts().end() && it->second) it->second->RefreshDim();
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

views::View* AraratCheckPermissionBlockButton(content::WebContents* contents) {
  auto& state = GetCheckState();
  return IsPermissionCheck() && state.contents.get() == contents && state.prompt
             ? state.prompt->CheckBlockButton() : nullptr;
}

bool AraratCheckPermissionOriginWrapped(content::WebContents* contents) {
  auto& state = GetCheckState();
  return IsPermissionCheck() && state.contents.get() == contents && state.prompt &&
         state.prompt->CheckOriginWrapped();
}
