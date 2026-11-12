#ifndef ARARAT_CORE_ARARAT_DOWNLOADS_H_
#define ARARAT_CORE_ARARAT_DOWNLOADS_H_

#import <Foundation/Foundation.h>
#include <memory>

class Profile;
class BrowserWindowInterface;

class AraratDownloads {
 public:
  AraratDownloads(Profile* profile, void (^changed)(NSArray*, NSString*, BrowserWindowInterface*));
  ~AraratDownloads();
  NSArray* Snapshot();
  bool Perform(NSString* guid, NSString* action);

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

void AraratConfigurePrivateDownloads(Profile* profile);

#endif
