#include "ararat/core/ararat_password_prompt.h"

#include <memory>
#include <vector>

#include "base/functional/bind.h"
#include "base/test/bind.h"
#include "chrome/browser/password_manager/factories/profile_password_store_factory.h"
#include "chrome/browser/ui/passwords/bubble_controllers/manage_passwords_bubble_controller.h"
#include "chrome/browser/ui/passwords/passwords_model_delegate_mock.h"
#include "chrome/test/base/chrome_render_view_host_test_harness.h"
#include "chrome/test/base/testing_profile.h"
#include "components/password_manager/core/browser/password_form.h"
#include "components/password_manager/core/browser/password_manager_test_utils.h"
#include "components/password_manager/core/browser/password_store/interactions_stats.h"
#include "components/password_manager/core/browser/password_store/mock_smart_bubble_stats_store.h"
#include "components/password_manager/core/browser/password_store/test_password_store.h"
#include "testing/gmock/include/gmock/gmock.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace {

using Action = AraratPasswordPromptModel::Action;
using DisplayReason = PasswordBubbleControllerBase::DisplayReason;
using password_manager::ui::State;
using testing::_;
using testing::NiceMock;
using testing::Return;
using testing::ReturnRef;

class TestStore : public password_manager::TestPasswordStore {
 public:
  password_manager::MockSmartBubbleStatsStore* GetSmartBubbleStatsStore()
      override {
    return &stats_;
  }

 private:
  ~TestStore() override = default;
  NiceMock<password_manager::MockSmartBubbleStatsStore> stats_;
};

class AraratPasswordPromptTest : public ChromeRenderViewHostTestHarness {
 protected:
  void SetUp() override {
    ChromeRenderViewHostTestHarness::SetUp();
    pending_.url = GURL("https://example.test/");
    pending_.username_value = u"new-user";
    pending_.password_value = password_manager::PasswordString(u"fixture");
    auto existing = std::make_unique<password_manager::PasswordForm>(pending_);
    existing->username_value = u"existing-user";
    current_.push_back(std::move(existing));
    delegate_ = std::make_unique<NiceMock<PasswordsModelDelegateMock>>();
    ON_CALL(*delegate_, GetState()).WillByDefault([this] { return state_; });
    ON_CALL(*delegate_, GetOrigin())
        .WillByDefault(Return(url::Origin::Create(pending_.url)));
    ON_CALL(*delegate_, GetPendingPassword()).WillByDefault(ReturnRef(pending_));
    ON_CALL(*delegate_, GetCurrentForms()).WillByDefault(ReturnRef(current_));
    ON_CALL(*delegate_, GetWebContents()).WillByDefault(Return(web_contents()));
  }

  TestingProfile::TestingFactories GetTestingFactories() const override {
    return {TestingProfile::TestingFactory(
        ProfilePasswordStoreFactory::GetInstance(),
        base::BindRepeating(
            &password_manager::BuildPasswordStore<
                content::BrowserContext, TestStore>))};
  }

  password_manager::MockSmartBubbleStatsStore& stats_store() {
    return *static_cast<TestStore*>(ProfilePasswordStoreFactory::GetForProfile(
                                        profile(), ServiceAccessType::IMPLICIT_ACCESS)
                                        .get())
                ->GetSmartBubbleStatsStore();
  }

  std::unique_ptr<AraratPasswordPromptModel> Show(
      DisplayReason reason = DisplayReason::kAutomatic) {
    EXPECT_CALL(*delegate_, OnBubbleShown()).Times(1);
    return std::make_unique<AraratPasswordPromptModel>(
        delegate_->AsWeakPtr(),
        base::BindLambdaForTesting([this] { return can_save_; }), reason);
  }

  password_manager::PasswordForm pending_;
  std::vector<std::unique_ptr<password_manager::PasswordForm>> current_;
  std::unique_ptr<NiceMock<PasswordsModelDelegateMock>> delegate_;
  State state_ = State::PENDING_PASSWORD_STATE;
  bool can_save_ = true;
};

TEST_F(AraratPasswordPromptTest, OnlyPendingSaveAndUpdateAreSupported) {
  EXPECT_TRUE(AraratPasswordPromptModel::Supports(State::PENDING_PASSWORD_STATE));
  EXPECT_TRUE(AraratPasswordPromptModel::Supports(State::PENDING_PASSWORD_UPDATE_STATE));
  EXPECT_FALSE(AraratPasswordPromptModel::Supports(State::INACTIVE_STATE));
  EXPECT_FALSE(AraratPasswordPromptModel::Supports(State::SAVE_CONFIRMATION_STATE));
  EXPECT_FALSE(AraratPasswordPromptModel::Supports(State::UPDATE_CONFIRMATION_STATE));
  EXPECT_FALSE(AraratPasswordPromptModel::Supports(State::GENERATED_PASSWORD_CONFIRMATION_STATE));
  EXPECT_TRUE(AraratPasswordPromptModel::SupportsConfirmation(State::SAVE_CONFIRMATION_STATE));
  EXPECT_TRUE(AraratPasswordPromptModel::SupportsConfirmation(State::UPDATE_CONFIRMATION_STATE));
  EXPECT_FALSE(AraratPasswordPromptModel::SupportsConfirmation(State::GENERATED_PASSWORD_CONFIRMATION_STATE));
  EXPECT_FALSE(AraratPasswordPromptModel::SupportsConfirmation(State::MANAGE_STATE));
}

TEST_F(AraratPasswordPromptTest, UsernameEditRetargetsSaveToAnExistingLogin) {
  auto prompt = Show();
  EXPECT_FALSE(prompt->IsUpdate());
  EXPECT_TRUE(prompt->CanNever());
  prompt->EditCredential(u"existing-user", pending_.password_value);
  EXPECT_TRUE(prompt->IsUpdate());
  EXPECT_FALSE(prompt->CanNever());
  EXPECT_CALL(*delegate_, NeverSavePassword()).Times(0);
  EXPECT_FALSE(prompt->Act(Action::kNever));
  EXPECT_CALL(*delegate_, SavePassword(std::u16string(u"existing-user"),
                                       pending_.password_value));
  EXPECT_CALL(*delegate_, OnBubbleHidden()).Times(1);
  EXPECT_TRUE(prompt->Act(Action::kAccept));
  EXPECT_FALSE(prompt->Act(Action::kAccept));
  prompt->Close();
  prompt->Close();
}

TEST_F(AraratPasswordPromptTest, EditingAnUpdateCanCreateANewLogin) {
  state_ = State::PENDING_PASSWORD_UPDATE_STATE;
  pending_.username_value = u"existing-user";
  auto prompt = Show();
  EXPECT_TRUE(prompt->IsUpdate());
  prompt->EditCredential(u"new-user", pending_.password_value);
  EXPECT_FALSE(prompt->IsUpdate());
  EXPECT_FALSE(prompt->CanNever());
  EXPECT_CALL(*delegate_, SavePassword(std::u16string(u"new-user"),
                                       pending_.password_value));
  EXPECT_CALL(*delegate_, OnBubbleHidden()).Times(1);
  EXPECT_TRUE(prompt->Act(Action::kAccept));
}

TEST_F(AraratPasswordPromptTest, NeverBlocksOnlyOnce) {
  auto prompt = Show();
  EXPECT_CALL(*delegate_, NeverSavePassword()).Times(1);
  EXPECT_CALL(*delegate_, SavePassword(_, _)).Times(0);
  EXPECT_CALL(*delegate_, OnBubbleHidden()).Times(1);
  EXPECT_TRUE(prompt->Act(Action::kNever));
  EXPECT_FALSE(prompt->Act(Action::kNever));
}

TEST_F(AraratPasswordPromptTest, NotNowRoutesToSaveDismissal) {
  auto prompt = Show();
  EXPECT_CALL(*delegate_, OnNotNowClicked()).Times(1);
  EXPECT_CALL(*delegate_, SavePassword(_, _)).Times(0);
  EXPECT_CALL(*delegate_, NeverSavePassword()).Times(0);
  EXPECT_CALL(*delegate_, OnBubbleHidden()).Times(1);
  EXPECT_TRUE(prompt->Act(Action::kNotNow));
  EXPECT_FALSE(prompt->Act(Action::kNotNow));
}

TEST_F(AraratPasswordPromptTest, AutomaticImplicitCloseIncreasesDismissals) {
  auto prompt = Show();
  EXPECT_CALL(*delegate_, OnNoInteraction()).Times(1);
  EXPECT_CALL(*delegate_, OnNotNowClicked()).Times(0);
  EXPECT_CALL(stats_store(), AddSiteStats(testing::Field(
                                 &password_manager::InteractionsStats::dismissal_count,
                                 1)));
  prompt->Close();
}

TEST_F(AraratPasswordPromptTest, ManualImplicitCloseDoesNotIncreaseDismissals) {
  auto prompt = Show(DisplayReason::kUserAction);
  EXPECT_CALL(*delegate_, OnNoInteraction()).Times(1);
  EXPECT_CALL(stats_store(), AddSiteStats(_)).Times(0);
  prompt->Close();
}

TEST_F(AraratPasswordPromptTest, EditingPasswordRejectsEmptyAndSavesChangedValue) {
  auto prompt = Show();
  prompt->EditCredential(pending_.username_value, {});
  EXPECT_FALSE(prompt->Act(Action::kAccept));
  password_manager::PasswordString edited(u"edited");
  prompt->EditCredential(pending_.username_value, edited);
  EXPECT_CALL(*delegate_, SavePassword(pending_.username_value, edited));
  EXPECT_TRUE(prompt->Act(Action::kAccept));
}

TEST_F(AraratPasswordPromptTest, AutomaticConfirmationIsReadOnly) {
  state_ = State::SAVE_CONFIRMATION_STATE;
  EXPECT_CALL(*delegate_, GetPendingPassword()).Times(0);
  EXPECT_CALL(*delegate_, SavePassword(_, _)).Times(0);
  EXPECT_CALL(*delegate_, OnBubbleShown()).Times(1);
  EXPECT_CALL(*delegate_, OnBubbleHidden()).Times(1);
  ManagePasswordsBubbleController confirmation(delegate_->AsWeakPtr());
  confirmation.OnBubbleClosing();
}

TEST_F(AraratPasswordPromptTest, ManualReopenRequiresAuthenticationToReveal) {
  auto prompt = Show(DisplayReason::kUserAction);
  EXPECT_CALL(*delegate_, AuthenticateUserWithMessage(_, _))
      .WillOnce([](const std::u16string&, auto callback) {
        std::move(callback).Run(false);
      });
  bool called = false;
  prompt->ShouldRevealPasswords(base::BindLambdaForTesting([&called](bool shown) {
    called = true;
    EXPECT_FALSE(shown);
  }));
  EXPECT_TRUE(called);
}

TEST_F(AraratPasswordPromptTest, NotNowIncreasesExistingDismissalCount) {
  password_manager::InteractionsStats prior;
  prior.origin_domain = url::Origin::Create(pending_.url).GetURL();
  prior.username_value = pending_.username_value;
  prior.dismissal_count = 2;
  ON_CALL(*delegate_, GetCurrentInteractionStats()).WillByDefault(Return(&prior));
  auto prompt = Show();
  EXPECT_CALL(*delegate_, OnNotNowClicked()).Times(1);
  EXPECT_CALL(*delegate_, OnNoInteraction()).Times(0);
  EXPECT_CALL(stats_store(), AddSiteStats(testing::Field(
                                 &password_manager::InteractionsStats::dismissal_count,
                                 3)));
  EXPECT_TRUE(prompt->Act(Action::kNotNow));
  prompt->Close();
}

TEST_F(AraratPasswordPromptTest, NotNowRoutesToUpdateDismissal) {
  state_ = State::PENDING_PASSWORD_UPDATE_STATE;
  auto prompt = Show();
  EXPECT_CALL(*delegate_, OnNopeUpdateClicked()).Times(1);
  EXPECT_CALL(*delegate_, SavePassword(_, _)).Times(0);
  EXPECT_CALL(*delegate_, OnBubbleHidden()).Times(1);
  EXPECT_TRUE(prompt->Act(Action::kNotNow));
  EXPECT_FALSE(prompt->Act(Action::kNotNow));
}

TEST_F(AraratPasswordPromptTest, ClosedGateAndClosedPromptCannotSaveOrBlock) {
  auto prompt = Show();
  EXPECT_CALL(*delegate_, SavePassword(_, _)).Times(0);
  EXPECT_CALL(*delegate_, NeverSavePassword()).Times(0);
  EXPECT_CALL(*delegate_, OnBubbleHidden()).Times(1);
  can_save_ = false;
  EXPECT_FALSE(prompt->Act(Action::kAccept));
  EXPECT_FALSE(prompt->Act(Action::kNever));
  prompt->Close();
  can_save_ = true;
  EXPECT_FALSE(prompt->Act(Action::kAccept));
  EXPECT_FALSE(prompt->Act(Action::kNever));
}

TEST_F(AraratPasswordPromptTest, OldStateAndInvalidDelegateCannotSave) {
  auto prompt = Show();
  EXPECT_CALL(*delegate_, SavePassword(_, _)).Times(0);
  state_ = State::PENDING_PASSWORD_UPDATE_STATE;
  EXPECT_FALSE(prompt->Act(Action::kAccept));
  state_ = State::PENDING_PASSWORD_STATE;
  delegate_.reset();
  EXPECT_FALSE(prompt->Act(Action::kAccept));
}

}  // namespace
