#import "ararat/core/ararat_passwords.h"

#include <map>
#include <memory>
#include <string>
#include <utility>

#include "base/functional/bind.h"
#include "base/memory/raw_ptr.h"
#include "base/strings/sys_string_conversions.h"
#include "base/uuid.h"
#include "chrome/browser/affiliations/affiliation_service_factory.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/password_manager/factories/profile_password_store_factory.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/profiles/profile_observer.h"
#include "components/password_manager/core/browser/password_manager_util.h"
#include "components/password_manager/core/browser/password_store/password_store_interface.h"
#include "components/password_manager/core/browser/ui/saved_passwords_presenter.h"
#include "components/password_manager/core/common/password_manager_pref_names.h"
#include "components/prefs/pref_service.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/common/url_constants.h"
#include "url/gurl.h"

bool AraratIsPasswordsURL(const GURL& url) {
  return url.SchemeIs(content::kChromeUIScheme) &&
         url.host() == "password-manager";
}

using password_manager::CredentialUIEntry;
using password_manager::SavedPasswordsPresenter;

@interface ARPasswordRow : NSObject <ARPasswordRowAPI>
@property(nonatomic, readwrite, copy) NSString* rowID;
@property(nonatomic, readwrite, copy) NSString* website;
@property(nonatomic, readwrite, copy) NSString* username;
@end
@implementation ARPasswordRow
@synthesize rowID = _rowID, website = _website, username = _username;
@end

@interface ARPasswords : NSObject <ARPasswordsAPI>
- (instancetype)initWithProfile:(Profile*)profile;
- (void)storeChanged;
@end

namespace {

class PasswordsObserver final : public ProfileObserver,
                                public SavedPasswordsPresenter::Observer {
 public:
  void SetOwner(ARPasswords* owner) { owner_ = owner; }

  void OnProfileWillBeDestroyed(Profile*) override { [owner_ invalidate]; }

  void OnSavedPasswordsChanged(
      const password_manager::PasswordStoreChangeList&) override {
    [owner_ storeChanged];
  }

 private:
  __weak ARPasswords* owner_;
};

NSMapTable<NSString*, ARPasswords*>* Handles() {
  static NSMapTable<NSString*, ARPasswords*>* handles =
      [NSMapTable strongToWeakObjectsMapTable];
  return handles;
}

}  // namespace

@implementation ARPasswords {
  raw_ptr<Profile> profile_;
  PasswordsObserver observer_;
  scoped_refptr<password_manager::PasswordStoreInterface> store_;
  std::unique_ptr<SavedPasswordsPresenter> presenter_;
  std::map<std::string, CredentialUIEntry> credentials_;
  NSArray<id<ARPasswordRowAPI>>* rows_;
  void (^changed_)(void);
  BOOL started_;
  BOOL changePending_;
}

- (instancetype)initWithProfile:(Profile*)profile {
  if ((self = [super init])) {
    profile_ = profile;
    observer_.SetOwner(self);
    profile_->AddObserver(&observer_);
  }
  return self;
}

- (void)dealloc {
  if (profile_)
    [self invalidate];
}

- (void)invalidate {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (profile_) {
    NSString* key = base::SysUTF8ToNSString(profile_->GetPath().value());
    if ([Handles() objectForKey:key] == self)
      [Handles() removeObjectForKey:key];
    profile_->RemoveObserver(&observer_);
    profile_ = nullptr;
  }
  if (presenter_)
    presenter_->RemoveObserver(&observer_);
  presenter_.reset();
  store_.reset();
  credentials_.clear();
  rows_ = nil;
  changed_ = nil;
}

- (BOOL)enabled {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  return profile_ && profile_->GetPrefs()->GetBoolean(
      password_manager::prefs::kAraratPasswordManagerEnabled);
}

- (BOOL)setManagerEnabled:(BOOL)enabled {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!profile_)
    return NO;
  profile_->GetPrefs()->SetBoolean(
      password_manager::prefs::kAraratPasswordManagerEnabled, enabled);
  return YES;
}

- (void)startStore {
  if (started_ || !profile_)
    return;
  started_ = YES;
  store_ = ProfilePasswordStoreFactory::GetForProfile(
      profile_, ServiceAccessType::IMPLICIT_ACCESS);
  auto* affiliation = AffiliationServiceFactory::GetForProfile(profile_);
  if (store_ && affiliation) {
    presenter_ = std::make_unique<SavedPasswordsPresenter>(
        affiliation, store_, nullptr);
    presenter_->AddObserver(&observer_);
    presenter_->Init();
  }
}

- (ARPasswordsState)state {
  if (!profile_ || !presenter_)
    return ARPasswordsStateFailed;
  if (presenter_->IsWaitingForPasswordStore())
    return ARPasswordsStateLoading;
  return !presenter_->HasStoreReadError() &&
                 store_->GetError() == password_manager::ActionableError::kNoError
             ? ARPasswordsStateReady
             : ARPasswordsStateFailed;
}

- (void)storeChanged {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  credentials_.clear();
  rows_ = nil;
  if (changePending_)
    return;
  changePending_ = YES;
  __weak ARPasswords* weak = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    ARPasswords* strong = weak;
    if (strong) {
      strong->changePending_ = NO;
      if (strong->changed_)
        strong->changed_();
    }
  });
}

- (void)setChangedHandler:(void (^)(void))handler {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!profile_)
    return;
  changed_ = [handler copy];
  if (changed_)
    [self startStore];
}

- (NSArray<id<ARPasswordRowAPI>>*)rows {
  if (!rows_) {
    auto* result = [NSMutableArray<id<ARPasswordRowAPI>> array];
    for (auto& credential : presenter_->GetSavedPasswords()) {
      std::string key = base::Uuid::GenerateRandomV4().AsLowercaseString();
      ARPasswordRow* row = [[ARPasswordRow alloc] init];
      row.rowID = base::SysUTF8ToNSString(key);
      row.website = base::SysUTF8ToNSString(credential.GetURL().spec());
      row.username = base::SysUTF16ToNSString(credential.username);
      [result addObject:row];
      credentials_.emplace(std::move(key), std::move(credential));
    }
    rows_ = [result copy];
  }
  return rows_;
}

- (void)snapshot:(void (^)(ARPasswordsState, NSArray<id<ARPasswordRowAPI>>*))completion {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  [self startStore];
  __weak ARPasswords* weak = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    ARPasswords* strong = weak;
    ARPasswordsState state = strong ? [strong state] : ARPasswordsStateFailed;
    completion(state, state == ARPasswordsStateReady ? [strong rows] : @[]);
  });
}

- (BOOL)addWebsite:(NSString*)website username:(NSString*)username
          password:(const unichar*)password length:(NSUInteger)length {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if ([self state] != ARPasswordsStateReady || !password || !length)
    return NO;
  CredentialUIEntry entry;
  password_manager::CredentialFacet facet;
  facet.url = password_manager_util::StripAuthAndParams(
      password_manager_util::ConstructGURLWithScheme(
          base::SysNSStringToUTF8(website)));
  facet.signon_realm = password_manager_util::GetSignonRealm(facet.url);
  entry.facets.push_back(std::move(facet));
  entry.username = base::SysNSStringToUTF16(username);
  entry.password = password_manager::PasswordString(std::u16string(
      password, password + length));
  entry.stored_in = {password_manager::PasswordForm::Store::kProfileStore};
  return presenter_->AddCredential(entry);
}

- (BOOL)editRow:(NSString*)rowID username:(NSString*)username
       password:(const unichar*)password length:(NSUInteger)length {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto it = credentials_.find(base::SysNSStringToUTF8(rowID));
  if ([self state] != ARPasswordsStateReady || it == credentials_.end() ||
      (!password && length))
    return NO;
  CredentialUIEntry next = it->second;
  next.username = base::SysNSStringToUTF16(username);
  if (password) {
    next.password = password_manager::PasswordString(std::u16string(
        password, password + length));
  }
  auto result = presenter_->EditSavedCredentials(it->second, next);
  if (result == SavedPasswordsPresenter::EditResult::kSuccess) {
    [self removeRow:rowID];
  }
  return result == SavedPasswordsPresenter::EditResult::kSuccess ||
         result == SavedPasswordsPresenter::EditResult::kNothingChanged;
}

- (void)removeRow:(NSString*)rowID {
  credentials_.erase(base::SysNSStringToUTF8(rowID));
  NSMutableArray<id<ARPasswordRowAPI>>* remaining = [rows_ mutableCopy];
  const NSUInteger index = [remaining indexOfObjectPassingTest:
      ^BOOL(id<ARPasswordRowAPI> row, NSUInteger, BOOL*) {
        return [row.rowID isEqualToString:rowID];
      }];
  if (index != NSNotFound)
    [remaining removeObjectAtIndex:index];
  rows_ = [remaining copy];
}

- (BOOL)deleteRow:(NSString*)rowID {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto it = credentials_.find(base::SysNSStringToUTF8(rowID));
  if ([self state] != ARPasswordsStateReady || it == credentials_.end() ||
      !presenter_->RemoveCredential(it->second))
    return NO;
  [self removeRow:rowID];
  return YES;
}

@end

id<ARPasswordsAPI> AraratPasswords(
    NSString* directory, void (^loaded)(id<ARPasswordsAPI>)) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto* manager = g_browser_process ? g_browser_process->profile_manager() : nullptr;
  base::FilePath name(base::SysNSStringToUTF8(directory));
  if (!manager || name.empty() || name.IsAbsolute() || name.ReferencesParent() ||
      name.BaseName() != name || name.value() == ".")
    return nil;
  const auto path = manager->user_data_dir().Append(name);
  if (auto* profile = manager->GetProfileByPath(path))
    return AraratPasswordsForProfile(profile);
  if (loaded) {
    manager->CreateProfileAsync(path, base::BindOnce(^(Profile* profile) {
      loaded(AraratPasswordsForProfile(profile));
    }));
  }
  return nil;
}

id<ARPasswordsAPI> AraratPasswordsForProfile(Profile* profile) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!profile || !profile->IsRegularProfile() || profile->IsOffTheRecord())
    return nil;
  NSString* key = base::SysUTF8ToNSString(profile->GetPath().value());
  if (ARPasswords* handle = [Handles() objectForKey:key])
    return handle;
  ARPasswords* handle = [[ARPasswords alloc] initWithProfile:profile];
  [Handles() setObject:handle forKey:key];
  return handle;
}
