#ifndef ARARAT_CORE_ARARAT_PASSWORDS_H_
#define ARARAT_CORE_ARARAT_PASSWORDS_H_

#import "ararat/core/public/AraratHostAPI.h"

class GURL;
class Profile;

bool AraratIsPasswordsURL(const GURL& url);
id<ARPasswordsAPI> AraratPasswordsForProfile(Profile* profile);

#endif  // ARARAT_CORE_ARARAT_PASSWORDS_H_
