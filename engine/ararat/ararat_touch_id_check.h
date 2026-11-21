#ifndef ARARAT_CORE_ARARAT_TOUCH_ID_CHECK_H_
#define ARARAT_CORE_ARARAT_TOUCH_ID_CHECK_H_

#include "ararat/core/public/AraratHostAPI.h"

class Profile;

bool AraratConfigureTouchIDCheck(NSString* profile_root, NSString* workspace);
void AraratFinishTouchIDCheck();
bool AraratTouchIDCheckWasActivated();
bool AraratStartTouchIDCheck(Profile* profile);
bool AraratTouchIDCheckHasProfile(Profile* profile);
bool AraratArmTouchIDCheck(Profile* profile, ARTouchIDCheckOutcome outcome);
bool AraratTouchIDCheckConsumedPrompt(Profile* profile);
bool AraratEnableTouchIDCheckFillPreference(Profile* profile);

#endif  // ARARAT_CORE_ARARAT_TOUCH_ID_CHECK_H_
