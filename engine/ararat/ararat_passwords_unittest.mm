#import "ararat/core/ararat_passwords.h"

#include <memory>

#include "base/memory/ref_counted.h"
#include "base/functional/bind.h"
#include "base/test/test_future.h"
#include "chrome/browser/affiliations/affiliation_service_factory.h"
#include "chrome/browser/password_manager/factories/profile_password_store_factory.h"
#include "chrome/test/base/testing_profile.h"
#include "components/affiliations/core/browser/fake_affiliation_service.h"
#include "components/password_manager/core/browser/password_store/test_password_store.h"
#include "content/public/test/browser_task_environment.h"
#include "testing/gtest/include/gtest/gtest.h"
#include "url/gurl.h"

namespace {

using Snapshot = base::test::TestFuture<ARPasswordsState,
                                       NSArray<id<ARPasswordRowAPI>>*>;

void TakeSnapshot(id<ARPasswordsAPI> handle, Snapshot& done) {
  Snapshot* reply = &done;
  [handle snapshot:^(ARPasswordsState state, NSArray<id<ARPasswordRowAPI>>* rows) {
    reply->SetValue(state, rows);
  }];
}

TEST(AraratPasswordsTest, RecognizesOnlyThePasswordManagerHost) {
  EXPECT_TRUE(AraratIsPasswordsURL(GURL("chrome://password-manager")));
  EXPECT_TRUE(AraratIsPasswordsURL(GURL("chrome://password-manager/passwords")));
  EXPECT_TRUE(AraratIsPasswordsURL(GURL("chrome://PASSWORD-MANAGER/settings?x=1#y")));
  EXPECT_FALSE(AraratIsPasswordsURL(GURL("https://password-manager/passwords")));
  EXPECT_FALSE(AraratIsPasswordsURL(GURL("chrome://password-manager-internals/")));
  EXPECT_FALSE(AraratIsPasswordsURL(GURL("view-source:chrome://password-manager/")));
}

TEST(AraratPasswordsTest, StoresSyntheticCredentialsAndRejectsStaleHandles) {
  content::BrowserTaskEnvironment environment;
  TestingProfile profile;
  ProfilePasswordStoreFactory::GetInstance()->SetTestingFactory(
      &profile, base::BindRepeating([](content::BrowserContext*)
          -> scoped_refptr<RefcountedKeyedService> {
        auto store = base::MakeRefCounted<password_manager::TestPasswordStore>();
        store->Init();
        return store;
      }));
  AffiliationServiceFactory::GetInstance()->SetTestingFactory(
      &profile, base::BindRepeating([](content::BrowserContext*)
          -> std::unique_ptr<KeyedService> {
        return std::make_unique<affiliations::FakeAffiliationService>();
      }));

  id<ARPasswordsAPI> handle = AraratPasswordsForProfile(&profile);
  ASSERT_TRUE(handle);
  ASSERT_TRUE(handle.enabled);
  EXPECT_FALSE(AraratPasswordsForProfile(
      profile.GetPrimaryOTRProfile(/*create_if_needed=*/true)));

  const unichar secret[] = {'t', 'e', 's', 't'};
  base::test::TestFuture<void> changed;
  auto* notification = &changed;
  [handle setChangedHandler:^{ if (!notification->IsReady()) notification->SetValue(); }];
  ASSERT_TRUE(changed.Wait());
  Snapshot empty;
  TakeSnapshot(handle, empty);
  ASSERT_EQ(empty.Get<0>(), ARPasswordsStateReady);
  EXPECT_EQ(empty.Get<1>().count, 0u);

  changed.Clear();
  EXPECT_FALSE([handle addWebsite:@"data:text/html,invalid" username:@"user"
                          password:secret length:4]);
  ASSERT_TRUE([handle addWebsite:@"example.com/sign-in?ignored=1" username:@"user"
                         password:secret length:4]);
  ASSERT_TRUE(changed.Wait());
  Snapshot added;
  TakeSnapshot(handle, added);
  ASSERT_EQ(added.Get<0>(), ARPasswordsStateReady);
  ASSERT_EQ(added.Get<1>().count, 1u);
  id<ARPasswordRowAPI> row = added.Get<1>().firstObject;
  EXPECT_TRUE([row.website isEqualToString:@"https://example.com/sign-in"]);
  EXPECT_TRUE([row.username isEqualToString:@"user"]);

  changed.Clear();
  NSString* oldID = row.rowID;
  ASSERT_TRUE([handle editRow:oldID username:@"renamed" password:nullptr length:0]);
  EXPECT_FALSE([handle deleteRow:oldID]);
  ASSERT_TRUE(changed.Wait());
  Snapshot edited;
  TakeSnapshot(handle, edited);
  ASSERT_EQ(edited.Get<1>().count, 1u);
  EXPECT_TRUE([edited.Get<1>().firstObject.username isEqualToString:@"renamed"]);

  changed.Clear();
  ASSERT_TRUE([handle deleteRow:edited.Get<1>().firstObject.rowID]);
  ASSERT_TRUE(changed.Wait());
  Snapshot removed;
  TakeSnapshot(handle, removed);
  ASSERT_EQ(removed.Get<0>(), ARPasswordsStateReady);
  EXPECT_EQ(removed.Get<1>().count, 0u);

  [handle invalidate];
  EXPECT_FALSE([handle deleteRow:oldID]);
  Snapshot closed;
  TakeSnapshot(handle, closed);
  EXPECT_EQ(closed.Get<0>(), ARPasswordsStateFailed);
  [handle setChangedHandler:nil];
}

}  // namespace
