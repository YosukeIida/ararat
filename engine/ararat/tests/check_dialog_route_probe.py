from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
start=s.index('  bool has_non_devtools_handlers = delegate_ && dialog_manager;',s.index('void WebContentsImpl::RunJavaScriptDialog('))
end=s.index('\n  if (!disable_third_party_subframe_suppresion',start)
setup=s[start:end]
start=s.index('  if (suppress_this_message) {',end)
end=s.index('\n  scoped_refptr<CloseDialogCallbackWrapper>',start)
branch=s[start:end]
pre=r'''#include <cassert>
#include <cstdio>
#include <string>
#include <utility>
#include <vector>
bool rejected=false, failure=false; int hooks=0, calls=0, shows=0;
bool hook(){ ++hooks; if(rejected) failure=true; return rejected; }
bool (*g_ararat_reject_javascript_dialog)()=&hook;
struct Callback { void Run(bool suppressed,bool success,const std::u16string& value){++calls; assert(suppressed && !success && value.empty());} };
void route(bool delegate_, bool dialog_manager, bool should_suppress, bool devtools){
 std::vector<int> page_handlers(devtools ? 1 : 0); Callback callback;
'''
post=r'''
 ++shows;
}
int main(){
 for(int kind=0;kind<3;kind++) for(int guest=0;guest<2;guest++) for(int devtools=0;devtools<2;devtools++){
  rejected=true; calls=0; shows=0; hooks=0; failure=false;
  route(!guest,true,false,devtools); assert(calls==1 && shows==0 && hooks==1 && failure);
 }
 rejected=false; calls=0; shows=0; hooks=0; failure=false; route(true,true,false,false); assert(calls==0 && shows==1 && hooks==1 && !failure);
 rejected=true; calls=0; shows=0; hooks=0; failure=false; route(true,true,true,false); assert(calls==1 && shows==0 && hooks==1 && failure);
 std::puts("extracted ordinary dialog suppression checks passed");
}'''
Path(sys.argv[2]).write_text(pre+setup+'\n'+branch+post)
