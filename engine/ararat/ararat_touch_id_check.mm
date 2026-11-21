#include "ararat/core/ararat_touch_id_check.h"

#include <limits.h>
#include <unistd.h>

#include <memory>

#include "base/check.h"
#include "base/command_line.h"
#include "base/containers/flat_set.h"
#include "base/files/file_util.h"
#include "base/no_destructor.h"
#include "base/path_service.h"
#include "base/strings/sys_string_conversions.h"
#include "base/threading/thread_restrictions.h"
#include "base/time/time.h"
#include "chrome/browser/device_reauth/chrome_device_authenticator_factory.h"
#include "chrome/browser/device_reauth/mac/authenticator_mac.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/common/chrome_paths.h"
#include "components/device_reauth/device_authenticator.h"
#include "components/device_reauth/device_authenticator_common.h"
#include "components/password_manager/core/common/password_manager_pref_names.h"
#include "components/prefs/pref_service.h"
#include "content/public/browser/browser_thread.h"
#include "device/fido/mac/scoped_touch_id_test_environment.h"

extern std::unique_ptr<AuthenticatorMacInterface> (
    *g_ararat_touch_id_authenticator)(Profile*);

namespace {

using device::fido::mac::ScopedTouchIdTestEnvironment;

struct TouchIDCheckState {
  base::FilePath root;
  base::flat_set<base::FilePath> profiles;
  std::unique_ptr<ScopedTouchIdTestEnvironment> environment;
  base::FilePath armed_profile;
  bool activated = false;
};

TouchIDCheckState& State() {
  static base::NoDestructor<TouchIDCheckState> state;
  return *state;
}

base::FilePath ScratchPath(NSString* value) {
  if (!value.isAbsolutePath)
    return {};
  const base::FilePath path(base::SysNSStringToUTF8(value));
  if (path.ReferencesParent())
    return {};
  // Resolve the existing ancestor before Chromium creates the profile or DB.
  NSMutableArray<NSString*>* tail = [NSMutableArray array];
  NSString* ancestor = value;
  NSFileManager* files = NSFileManager.defaultManager;
  while (![files fileExistsAtPath:ancestor]) {
    if ([files destinationOfSymbolicLinkAtPath:ancestor error:nullptr])
      return {};
    [tail insertObject:ancestor.lastPathComponent atIndex:0];
    ancestor = ancestor.stringByDeletingLastPathComponent;
  }
  auto canonical = base::MakeAbsoluteFilePath(
      base::FilePath(base::SysNSStringToUTF8(ancestor)));
  if (canonical.empty())
    return {};
  for (NSString* component in tail)
    canonical = canonical.Append(base::SysNSStringToUTF8(component));
  char temp[PATH_MAX];
  const size_t temp_size = confstr(_CS_DARWIN_USER_TEMP_DIR, temp, sizeof(temp));
  const bool under_user_temp = temp_size > 0 && temp_size <= sizeof(temp) &&
      base::MakeAbsoluteFilePath(base::FilePath(temp)).IsParent(canonical);
  if (under_user_temp || base::FilePath("/private/tmp").IsParent(canonical))
    return canonical;
  return {};
}

bool IsRegistered(Profile* profile) {
  return profile && profile->IsRegularProfile() &&
         State().profiles.contains(profile->GetPath());
}

class AraratTouchIDAvailability final : public AuthenticatorMacInterface {
 public:
  bool CheckIfBiometricsAvailable() override { return true; }
  bool CheckIfBiometricsOrScreenLockAvailable() override { return true; }
  bool AuthenticateUserWithNonBiometrics(const std::u16string&) override {
    return false;
  }
};

std::unique_ptr<AuthenticatorMacInterface> CreateCheckAuthenticator(
    Profile* profile) {
  if (!IsRegistered(profile))
    return nullptr;
  CHECK(!State().root.empty() && State().environment);
  return std::make_unique<AraratTouchIDAvailability>();
}

}  // namespace

bool AraratConfigureTouchIDCheck(NSString* profile_root, NSString* workspace) {
  const auto root = ScratchPath(profile_root);
  if (root.empty() || ScratchPath(workspace).empty())
    return false;
  State().root = root;
  return true;
}

void AraratFinishTouchIDCheck() {
  auto& state = State();
  if (state.root.empty()) {
    CHECK(!state.activated && !state.environment &&
          !g_ararat_touch_id_authenticator);
  }
  g_ararat_touch_id_authenticator = nullptr;
  state.environment.reset();
  state.profiles.clear();
}

bool AraratTouchIDCheckWasActivated() {
  return State().activated;
}

bool AraratStartTouchIDCheck(Profile* profile) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto& state = State();
  if (state.root.empty() || !profile || !profile->IsRegularProfile() ||
      !base::CommandLine::ForCurrentProcess()->HasSwitch("use-mock-keychain"))
    return false;
  base::ScopedAllowBlockingForTesting allow_blocking;
  base::FilePath user_data;
  if (!base::PathService::Get(chrome::DIR_USER_DATA, &user_data) ||
      base::MakeAbsoluteFilePath(user_data) != state.root ||
      !state.root.IsParent(base::MakeAbsoluteFilePath(profile->GetPath())))
    return false;
  if (state.profiles.contains(profile->GetPath()))
    return true;
  if (!state.environment) {
    state.environment = std::make_unique<ScopedTouchIdTestEnvironment>(
        device::fido::mac::AuthenticatorConfig{});
    state.environment->SetTouchIdAvailable(true);
    g_ararat_touch_id_authenticator = &CreateCheckAuthenticator;
    state.activated = true;
  }
  state.profiles.insert(profile->GetPath());
  const device_reauth::DeviceAuthParams params(
      base::Seconds(0), device_reauth::DeviceAuthSource::kPasswordManager);
  return ChromeDeviceAuthenticatorFactory::GetForProfile(profile, params)
      ->CanAuthenticateWithBiometrics();
}

bool AraratTouchIDCheckHasProfile(Profile* profile) {
  return IsRegistered(profile);
}

bool AraratArmTouchIDCheck(Profile* profile, ARTouchIDCheckOutcome outcome) {
  auto& state = State();
  if (!IsRegistered(profile) || !state.environment ||
      state.environment->HasPendingPrompt())
    return false;
  switch (outcome) {
    case ARTouchIDCheckOutcomeSuccess:
      state.environment->SimulateTouchIdPromptSuccess();
      break;
    case ARTouchIDCheckOutcomeFailure:
      state.environment->SimulateTouchIdPromptFailure();
      break;
    case ARTouchIDCheckOutcomeUnresolved:
      state.environment->DoNotResolveNextPrompt();
      break;
    default:
      return false;
  }
  state.armed_profile = profile->GetPath();
  return true;
}

bool AraratTouchIDCheckConsumedPrompt(Profile* profile) {
  const auto& state = State();
  return IsRegistered(profile) && state.environment &&
         state.armed_profile == profile->GetPath() &&
         !state.environment->HasPendingPrompt();
}

bool AraratEnableTouchIDCheckFillPreference(Profile* profile) {
  if (!IsRegistered(profile))
    return false;
  profile->GetPrefs()->SetBoolean(
      password_manager::prefs::kBiometricAuthenticationBeforeFilling, true);
  return true;
}
