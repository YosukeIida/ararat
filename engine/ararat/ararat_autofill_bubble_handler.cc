// Based on Ardia's ac_autofill_bubble_handler.mm and ac_autofill_prompt.mm
// (mantrakp04/ardia, GPL-3.0).
#include "ararat/core/ararat_autofill_bubble_handler.h"

#include <memory>
#include <optional>
#include <utility>

#include "base/functional/bind.h"
#include "base/command_line.h"
#include "base/location.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/strings/string_number_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "base/time/time.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/ui/autofill/autofill_bubble_base.h"
#include "chrome/browser/ui/autofill/autofill_ai/autofill_ai_import_data_controller.h"
#include "chrome/browser/ui/autofill/payments/save_card_bubble_controller.h"
#include "chrome/browser/ui/autofill/payments/save_card_ui.h"
#include "chrome/browser/ui/autofill/payments/iban_bubble_controller_impl.h"
#include "chrome/browser/ui/autofill/payments/offer_notification_bubble_controller_impl.h"
#include "chrome/browser/ui/autofill/payments/filled_card_information_bubble_controller_impl.h"
#include "chrome/browser/ui/autofill/payments/mandatory_reauth_bubble_controller_impl.h"
#include "chrome/browser/ui/autofill/payments/virtual_card_enroll_bubble_controller_impl.h"
#include "chrome/browser/ui/autofill/save_address_bubble_controller.h"
#include "chrome/browser/ui/autofill/update_address_bubble_controller.h"
#include "components/autofill/core/browser/data_model/addresses/autofill_profile.h"
#include "components/autofill/core/browser/data_model/payments/credit_card.h"
#include "components/autofill/core/browser/foundations/autofill_client.h"
#include "components/autofill/core/browser/payments/legal_message_line.h"
#include "components/autofill/core/browser/payments/payments_autofill_client.h"
#include "components/autofill/core/browser/ui/addresses/autofill_address_util.h"
#include "components/autofill/core/browser/ui/payments/payments_ui_closed_reasons.h"
#include "components/autofill/core/browser/ui/payments/save_payment_method_and_virtual_card_enroll_confirmation_ui_params.h"
#include "components/constrained_window/constrained_window_views.h"
#include "content/public/browser/web_contents.h"
#include "ui/base/interaction/element_identifier.h"
#include "ui/base/models/dialog_model.h"
#include "ui/base/models/dialog_model_field.h"
#include "ui/views/bubble/bubble_dialog_model_host.h"
#include "ui/views/controls/styled_label.h"
#include "ui/views/widget/widget.h"
#include "ui/views/window/dialog_delegate.h"

namespace {

DEFINE_LOCAL_ELEMENT_IDENTIFIER_VALUE(kCardName);
DEFINE_LOCAL_ELEMENT_IDENTIFIER_VALUE(kExpiryMonth);
DEFINE_LOCAL_ELEMENT_IDENTIFIER_VALUE(kExpiryYear);
using AddressDecision = autofill::AutofillClient::AddressPromptUserDecision;
using ClosedReason = autofill::PaymentsUiClosedReason;
class Bubble;
struct AutofillCheckState {
  base::WeakPtr<Bubble> bubble;
  base::WeakPtr<content::WebContents> contents;
  bool card = false;
};
AutofillCheckState& GetAutofillCheckState() {
  static base::NoDestructor<AutofillCheckState> state;
  return *state;
}

class Bubble : public autofill::AutofillBubbleBase {
 public:
  Bubble() = default;
  ~Bubble() override = default;
  void Hide() override {
    hidden_ = true;
    if (widget_) widget_->Close();
  }
  bool IsMouseHovered() const override { return false; }
  void CheckDecline() {
    if (widget_) widget_->widget_delegate()->AsDialogDelegate()->CancelDialog();
  }

 protected:
  autofill::AutofillBubbleBase* Show(content::WebContents* contents,
                                      ui::DialogModel::Builder& builder,
                                      std::optional<bool> card = std::nullopt) {
    auto weak = weak_factory_.GetWeakPtr();
    builder.SetCloseActionCallback(base::BindOnce(&Bubble::Close, weak));
    builder.SetDialogDestroyingCallback(base::BindOnce(&Bubble::Destroyed, weak));
    auto model = builder.Build();
    model_ = model.get();
    widget_ = constrained_window::ShowWebModal(std::move(model), contents);
    if (card && base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check") == "autofill") {
      auto& state = GetAutofillCheckState();
      state.bubble = weak;
      state.contents = contents->GetWeakPtr();
      state.card = *card;
    }
    return this;
  }
  base::WeakPtr<Bubble> GetWeakPtr() { return weak_factory_.GetWeakPtr(); }
  ui::DialogModel* model() const { return model_; }
  bool hidden() const { return hidden_; }
  virtual void Closed() = 0;
  virtual void Close() = 0;

 private:
  void Destroyed() {
    if (GetAutofillCheckState().bubble.get() == this)
      GetAutofillCheckState().bubble.reset();
    widget_ = nullptr;
    model_ = nullptr;
    Closed();
    base::SingleThreadTaskRunner::GetCurrentDefault()->DeleteSoon(FROM_HERE, this);
  }
  bool hidden_ = false;
  raw_ptr<views::Widget> widget_ = nullptr;
  raw_ptr<ui::DialogModel> model_ = nullptr;
  base::WeakPtrFactory<Bubble> weak_factory_{this};
};

class SkippedBubble : public autofill::AutofillBubbleBase {
 public:
  using CloseCallback =
      base::OnceCallback<void(content::WebContents*, autofill::AutofillBubbleBase*)>;

  SkippedBubble(content::WebContents* contents, CloseCallback close)
      : contents_(contents->GetWeakPtr()), close_(std::move(close)) {
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&SkippedBubble::CloseNow, weak_factory_.GetWeakPtr()));
  }

  void Hide() override {
    if (!hidden_) {
      hidden_ = true;
      base::SingleThreadTaskRunner::GetCurrentDefault()->DeleteSoon(FROM_HERE, this);
    }
  }
  bool IsMouseHovered() const override { return false; }

 private:
  void CloseNow() {
    if (hidden_) {
      return;
    }
    hidden_ = true;
    if (contents_) {
      std::move(close_).Run(contents_.get(), this);
    }
    delete this;
  }

  base::WeakPtr<content::WebContents> contents_;
  CloseCallback close_;
  bool hidden_ = false;
  base::WeakPtrFactory<SkippedBubble> weak_factory_{this};
};

class SaveAddressBubble final : public Bubble {
 public:
  explicit SaveAddressBubble(std::unique_ptr<autofill::SaveAddressBubbleController> controller)
      : controller_(std::move(controller)) {}
  autofill::AutofillBubbleBase* Open(content::WebContents* contents) {
    ui::DialogModel::Builder builder;
    builder.SetTitle(controller_->GetWindowTitle());
    builder.AddParagraph(ui::DialogModelLabel(controller_->GetBodyText()));
    builder.AddParagraph(ui::DialogModelLabel(controller_->GetAddressSummary()));
    if (!controller_->GetProfileEmail().empty())
      builder.AddParagraph(ui::DialogModelLabel(controller_->GetProfileEmail()));
    if (!controller_->GetProfilePhone().empty())
      builder.AddParagraph(ui::DialogModelLabel(controller_->GetProfilePhone()));
    if (!controller_->GetFooterMessage().empty())
      builder.AddParagraph(ui::DialogModelLabel(controller_->GetFooterMessage()));
    builder.AddOkButton(base::BindOnce(&SaveAddressBubble::Accept, weak_.GetWeakPtr()),
                        ui::DialogModel::Button::Params().SetLabel(controller_->GetOkButtonLabel()));
    builder.AddCancelButton(base::BindOnce(&SaveAddressBubble::Decline, weak_.GetWeakPtr()),
                            ui::DialogModel::Button::Params().SetLabel(controller_->GetNegativeButtonLabel()));
    return Show(contents, builder, false);
  }
 private:
  void Accept() { controller_->OnUserDecision(AddressDecision::kAccepted, controller_->GetAutofillProfile()); }
  void Decline() { controller_->OnUserDecision(controller_->GetCancelCallbackValue(), std::nullopt); }
  void Close() override {}
  void Closed() override { controller_->OnBubbleClosed(); }
  std::unique_ptr<autofill::SaveAddressBubbleController> controller_;
  base::WeakPtrFactory<SaveAddressBubble> weak_{this};
};

class UpdateAddressBubble final : public Bubble {
 public:
  explicit UpdateAddressBubble(std::unique_ptr<autofill::UpdateAddressBubbleController> controller)
      : controller_(std::move(controller)) {}
  autofill::AutofillBubbleBase* Open(content::WebContents* contents) {
    ui::DialogModel::Builder builder;
    builder.SetTitle(controller_->GetWindowTitle(false));
    const auto& locale = g_browser_process->GetApplicationLocale();
    builder.AddParagraph(ui::DialogModelLabel(autofill::GetProfileDescription(controller_->GetOriginalProfile(), locale, true)));
    builder.AddParagraph(ui::DialogModelLabel(autofill::GetProfileDescription(controller_->GetProfileToSave(), locale, true)));
    if (!controller_->GetFooterMessage().empty())
      builder.AddParagraph(ui::DialogModelLabel(controller_->GetFooterMessage()));
    builder.AddOkButton(base::BindOnce(&UpdateAddressBubble::Accept, weak_.GetWeakPtr()),
                        ui::DialogModel::Button::Params().SetLabel(controller_->GetPositiveButtonText(false)));
    builder.AddCancelButton(base::BindOnce(&UpdateAddressBubble::Decline, weak_.GetWeakPtr()),
                            ui::DialogModel::Button::Params().SetLabel(controller_->GetNegativeButtonText(false)));
    return Show(contents, builder);
  }
 private:
  void Accept() { controller_->OnUserDecision(AddressDecision::kAccepted, controller_->GetProfileToSave()); }
  void Decline() { controller_->OnUserDecision(AddressDecision::kDeclined, std::nullopt); }
  void Close() override {}
  void Closed() override { controller_->OnBubbleClosed(); }
  std::unique_ptr<autofill::UpdateAddressBubbleController> controller_;
  base::WeakPtrFactory<UpdateAddressBubble> weak_{this};
};

class SaveCardBubble final : public Bubble {
 public:
  explicit SaveCardBubble(autofill::SaveCardBubbleController* controller, bool confirmation)
      : controller_(controller), on_closed_(controller->GetOnBubbleClosedCallback()), confirmation_(confirmation) {}
  void Hide() override {
    controller_ = nullptr;
    if (on_closed_) std::move(on_closed_).Run(reason_);
    Bubble::Hide();
  }
  autofill::AutofillBubbleBase* Open(content::WebContents* contents) {
    ui::DialogModel::Builder builder;
    if (confirmation_) {
      const auto& params = controller_->GetConfirmationUiParams();
      builder.SetTitle(params.title_text);
      builder.AddParagraph(ui::DialogModelLabel(params.description_text));
      builder.AddOkButton(base::BindOnce(&SaveCardBubble::Confirm, weak_.GetWeakPtr()));
      return Show(contents, builder);
    }
    builder.SetTitle(controller_->GetWindowTitle());
    builder.AddParagraph(ui::DialogModelLabel(controller_->GetExplanatoryMessage()));
    builder.AddParagraph(ui::DialogModelLabel(controller_->GetCard().CardNameAndLastFourDigits()));
    needs_name_ = controller_->ShouldRequestNameFromUser();
    needs_date_ = controller_->ShouldRequestExpirationDateFromUser();
    if (needs_name_) builder.AddTextfield(kCardName, u"Cardholder name", u"");
    if (needs_date_) {
      builder.AddTextfield(kExpiryMonth, u"Expiration month", u"");
      builder.AddTextfield(kExpiryYear, u"Expiration year", u"");
    }
    for (const auto& line : controller_->GetLegalMessageLines()) {
      auto label = std::make_unique<views::StyledLabel>();
      label->SetText(line.text());
      for (const auto& link : line.links()) {
        label->AddStyleRange(link.range, views::StyledLabel::RangeStyleInfo::CreateForLink(
            base::BindRepeating(&SaveCardBubble::OpenLegalLink, weak_.GetWeakPtr(), link.url)));
      }
      builder.AddCustomField(std::make_unique<views::BubbleDialogModelHost::CustomView>(
          std::move(label), views::BubbleDialogModelHost::FieldType::kText));
    }
    builder.AddOkButton(base::BindRepeating(&SaveCardBubble::AcceptIfAlive, weak_.GetWeakPtr()),
                        ui::DialogModel::Button::Params().SetLabel(controller_->GetAcceptButtonText()));
    builder.AddCancelButton(base::BindOnce(&SaveCardBubble::Decline, weak_.GetWeakPtr()),
                            ui::DialogModel::Button::Params().SetLabel(controller_->GetDeclineButtonText()));
    return Show(contents, builder, true);
  }
 private:
  static bool AcceptIfAlive(base::WeakPtr<SaveCardBubble> bubble) {
    return !bubble || bubble->Accept();
  }
  bool Accept() {
    if (hidden()) return true;
    autofill::payments::PaymentsAutofillClient::UserProvidedCardDetails details;
    if (needs_name_) {
      details.cardholder_name = model()->GetTextfieldByUniqueId(kCardName)->text();
      if (details.cardholder_name.empty()) return false;
    }
    if (needs_date_) {
      details.expiration_date_month = model()->GetTextfieldByUniqueId(kExpiryMonth)->text();
      details.expiration_date_year = model()->GetTextfieldByUniqueId(kExpiryYear)->text();
      int month = 0, year = 0;
      base::Time::Exploded now;
      base::Time::Now().LocalExplode(&now);
      if (!base::StringToInt(details.expiration_date_month, &month) || month < 1 || month > 12 ||
          details.expiration_date_year.size() != 4 ||
          !base::StringToInt(details.expiration_date_year, &year) ||
          year < now.year || (year == now.year && month < now.month)) return false;
    }
    const auto type = controller_->GetPaymentsBubbleType();
    reason_ = (type == autofill::PaymentsBubbleType::kUploadSave ||
               type == autofill::PaymentsBubbleType::kUploadCardholderNameUpdate)
                  ? ClosedReason::kNotInteracted : ClosedReason::kAccepted;
    controller_->OnSaveButton(details);
    return true;
  }
  void Decline() { reason_ = ClosedReason::kCancelled; }
  void Confirm() { reason_ = ClosedReason::kAccepted; }
  void OpenLegalLink(const GURL& url) { if (!hidden() && controller_) controller_->OnLegalMessageLinkClicked(url); }
  void Close() override { if (!hidden()) reason_ = ClosedReason::kClosed; }
  void Closed() override {
    controller_ = nullptr;
    if (on_closed_) std::move(on_closed_).Run(reason_);
  }
  raw_ptr<autofill::SaveCardBubbleController> controller_;
  base::OnceCallback<void(ClosedReason)> on_closed_;
  ClosedReason reason_ = ClosedReason::kNotInteracted;
  bool confirmation_;
  bool needs_name_ = false;
  bool needs_date_ = false;
  base::WeakPtrFactory<SaveCardBubble> weak_{this};
};

autofill::AutofillBubbleBase* SkipIbanBubble(content::WebContents* contents) {
  return new SkippedBubble(
      contents,
      base::BindOnce([](content::WebContents* contents, autofill::AutofillBubbleBase* bubble) {
        auto* controller = autofill::IbanBubbleControllerImpl::FromWebContents(contents);
        if (controller && controller->GetPaymentBubbleView() == bubble) {
          controller->OnBubbleClosed(autofill::PaymentsUiClosedReason::kNotInteracted);
        }
      }));
}

autofill::AutofillBubbleBase* SkipOfferNotification(content::WebContents* contents) {
  return new SkippedBubble(
      contents,
      base::BindOnce([](content::WebContents* contents, autofill::AutofillBubbleBase* bubble) {
        auto* controller =
            autofill::OfferNotificationBubbleControllerImpl::FromWebContents(contents);
        if (controller && controller->GetOfferNotificationBubbleView() == bubble) {
          controller->OnBubbleClosed(autofill::PaymentsUiClosedReason::kNotInteracted);
        }
      }));
}

autofill::AutofillBubbleBase* SkipFilledCard(content::WebContents* contents) {
  return new SkippedBubble(contents, base::BindOnce(
      [](content::WebContents* tab, autofill::AutofillBubbleBase* bubble) {
        auto* controller = autofill::FilledCardInformationBubbleControllerImpl::FromWebContents(tab);
        if (controller && controller->GetBubble() == bubble)
          controller->OnBubbleClosed(ClosedReason::kNotInteracted);
      }));
}
autofill::AutofillBubbleBase* SkipReauth(content::WebContents* contents) {
  return new SkippedBubble(contents, base::BindOnce(
      [](content::WebContents* tab, autofill::AutofillBubbleBase* bubble) {
        auto* controller = autofill::MandatoryReauthBubbleControllerImpl::FromWebContents(tab);
        if (controller && controller->GetBubbleView() == bubble)
          controller->OnBubbleClosed(ClosedReason::kNotInteracted);
      }));
}
autofill::AutofillBubbleBase* SkipVirtualCard(content::WebContents* contents) {
  return new SkippedBubble(contents, base::BindOnce(
      [](content::WebContents* tab, autofill::AutofillBubbleBase* bubble) {
        auto* controller = autofill::VirtualCardEnrollBubbleControllerImpl::FromWebContents(tab);
        if (controller && controller->GetVirtualCardBubbleView() == bubble)
          controller->OnBubbleClosed(ClosedReason::kNotInteracted);
      }));
}

autofill::AutofillBubbleBase* SkipAutofillAi(
    content::WebContents* contents, autofill::AutofillAiImportDataController* controller) {
  return new SkippedBubble(contents, base::BindOnce(
      [](base::WeakPtr<autofill::AutofillAiImportDataController> target,
         content::WebContents*, autofill::AutofillBubbleBase*) {
        if (target) target->OnBubbleClosed(
            autofill::AutofillClient::AutofillAiBubbleResult::kNotInteracted);
      }, controller->GetWeakPtr()));
}

}  // namespace

bool AraratCheckAutofillBubble(content::WebContents* contents, bool card,
                               bool decline) {
  auto& state = GetAutofillCheckState();
  if (base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII("ararat-check") != "autofill" ||
      !state.bubble || state.contents.get() != contents || state.card != card)
    return false;
  if (decline) state.bubble->CheckDecline();
  return true;
}

AraratAutofillBubbleHandler::AraratAutofillBubbleHandler() = default;
AraratAutofillBubbleHandler::~AraratAutofillBubbleHandler() = default;

#define AC_NO_BUBBLE(...) \
  {                       \
    return nullptr;       \
  }
autofill::AutofillBubbleBase* AraratAutofillBubbleHandler::ShowSaveCreditCardBubble(
    content::WebContents* web_contents,
    autofill::SaveCardBubbleController* controller,
    bool) {
  return (new SaveCardBubble(controller, false))->Open(web_contents);
}
autofill::AutofillBubbleBase* AraratAutofillBubbleHandler::ShowIbanBubble(
    content::WebContents* web_contents,
    autofill::IbanBubbleController*,
    bool,
    autofill::IbanBubbleType) {
  return SkipIbanBubble(web_contents);
}
autofill::AutofillBubbleBase* AraratAutofillBubbleHandler::
    ShowOfferNotificationBubble(content::WebContents* web_contents,
                                autofill::OfferNotificationBubbleController*,
                                bool) {
  return SkipOfferNotification(web_contents);
}
autofill::AutofillBubbleBase* AraratAutofillBubbleHandler::
    ShowSaveAutofillAiDataBubble(content::WebContents* contents,
                                 autofill::AutofillAiImportDataController* controller)
        { return SkipAutofillAi(contents, controller); }
autofill::AutofillBubbleBase* AraratAutofillBubbleHandler::
    ShowAutofillAiLocalSaveNotification(
        content::WebContents* contents,
        autofill::AutofillAiImportDataController* controller) { return SkipAutofillAi(contents, controller); }
autofill::AutofillBubbleBase* AraratAutofillBubbleHandler::
    ShowSaveAddressProfileBubble(
        content::WebContents* web_contents,
        std::unique_ptr<autofill::SaveAddressBubbleController> controller,
        bool) {
  return (new SaveAddressBubble(std::move(controller)))->Open(web_contents);
}
#if BUILDFLAG(ENABLE_DICE_SUPPORT)
autofill::AutofillBubbleBase* AraratAutofillBubbleHandler::ShowAddressSignInPromo(
    content::WebContents* web_contents,
    const autofill::AutofillProfile&) {
  return nullptr;
}
#endif
autofill::AutofillBubbleBase* AraratAutofillBubbleHandler::
    ShowUpdateAddressProfileBubble(
        content::WebContents* web_contents,
        std::unique_ptr<autofill::UpdateAddressBubbleController> controller,
        bool) {
  return (new UpdateAddressBubble(std::move(controller)))->Open(web_contents);
}
autofill::AutofillBubbleBase* AraratAutofillBubbleHandler::
    ShowFilledCardInformationBubble(
        content::WebContents* contents,
        autofill::FilledCardInformationBubbleController*,
        bool) { return SkipFilledCard(contents); }
autofill::AutofillBubbleBase* AraratAutofillBubbleHandler::
    ShowVirtualCardEnrollBubble(content::WebContents* contents,
                                autofill::VirtualCardEnrollBubbleController*,
                                bool) { return SkipVirtualCard(contents); }
autofill::AutofillBubbleBase* AraratAutofillBubbleHandler::
    ShowVirtualCardEnrollConfirmationBubble(
        content::WebContents* contents,
        autofill::VirtualCardEnrollBubbleController*) { return SkipVirtualCard(contents); }
autofill::AutofillBubbleBase* AraratAutofillBubbleHandler::
    ShowMandatoryReauthBubble(content::WebContents* contents,
                              autofill::MandatoryReauthBubbleController*,
                              bool,
                              autofill::MandatoryReauthBubbleType) { return SkipReauth(contents); }
autofill::AutofillBubbleBase* AraratAutofillBubbleHandler::
    ShowSaveCardConfirmationBubble(
        content::WebContents* web_contents,
        autofill::SaveCardBubbleController* controller) {
  return (new SaveCardBubble(controller, true))->Open(web_contents);
}
autofill::AutofillBubbleBase* AraratAutofillBubbleHandler::
    ShowSaveIbanConfirmationBubble(content::WebContents* contents,
                                   autofill::IbanBubbleController*) { return SkipIbanBubble(contents); }
autofill::AutofillBubbleBase* AraratAutofillBubbleHandler::
    ShowOmniboxAutofillBubble(content::WebContents*,
                              autofill::OmniboxAutofillBubbleController*)
        AC_NO_BUBBLE()
autofill::AutofillBubbleBase* AraratAutofillBubbleHandler::
    ShowPaymentsChurnedUsersBubble(
        content::WebContents*,
        autofill::PaymentsChurnedUsersBubbleController*,
        bool) AC_NO_BUBBLE()
autofill::AutofillBubbleBase* AraratAutofillBubbleHandler::
    ShowPaymentsChurnedUsersConfirmationBubble(
        content::WebContents*,
        autofill::PaymentsChurnedUsersBubbleController*) AC_NO_BUBBLE()
autofill::AutofillBubbleBase* AraratAutofillBubbleHandler::
    ShowWalletReminderNoticeBubble(
        content::WebContents*,
        autofill::WalletReminderNoticeBubbleController*,
        bool) AC_NO_BUBBLE()
#undef AC_NO_BUBBLE
