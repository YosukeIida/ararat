from pathlib import Path
import sys

root = Path(__file__).resolve().parents[3]
patch = (root / "engine/patches/ararat/app-controller-hooks.patch").read_text()
normalization = "if (profile) profile = ProfileManager::MaybeForceOffTheRecordMode(profile->GetOriginalProfile());"
assert patch.count(normalization) == 2
for call in ["g_ararat_open_urls(accepted, profile);", 'g_ararat_open_urls(@[@{ @"url": url, @"untrusted": @YES }], profile);']:
    callback = patch[:patch.index(call)].rsplit("base::BindOnce(^(Profile* profile) {", 1)[1]
    assert normalization in callback

main = (root / "engine/ararat/ararat_main.mm").read_text()
assert 'IncognitoModePrefs::ShouldLaunchIncognito(command_line, profile)' in main
assert 'AraratOpenOffTheRecordURLs(profile, urls);' in main

Path(sys.argv[1]).write_text(r'''
#include <cassert>
struct Profile {
  Profile* original = this;
  Profile* otr = nullptr;
  bool forced = false;
  Profile* GetOriginalProfile() { return original; }
};
struct ProfileManager {
  static Profile* MaybeForceOffTheRecordMode(Profile* profile) {
    return profile->forced ? profile->otr : profile;
  }
};
Profile* nativeProfile(Profile* profile) {
''' + normalization + r'''
  return profile;
}
int main() {
  Profile regular, privateProfile, other;
  regular.otr = &privateProfile;
  privateProfile.original = &regular;
  assert(nativeProfile(nullptr) == nullptr);
  assert(nativeProfile(&regular) == &regular);
  assert(nativeProfile(&privateProfile) == &regular);
  assert(nativeProfile(&other) == &other);
  regular.forced = true;
  assert(nativeProfile(&regular) == &privateProfile);
  assert(nativeProfile(&privateProfile) == &privateProfile);
}
''')
