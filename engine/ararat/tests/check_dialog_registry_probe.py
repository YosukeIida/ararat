from pathlib import Path
import sys
s = Path('engine/ararat/ararat_window_host.mm').read_text()
controller_source = Path(sys.argv[2]).read_text()
content_source = Path(sys.argv[3]).read_text()
def extract(start, source=s):
    s = source
    i = s.index(start); brace = s.index('{', i); depth = 0
    for j in range(brace, len(s)):
        if s[j] == '{': depth += 1
        if s[j] == '}':
            depth -= 1
            if not depth: return s[i:j+1]
    raise ValueError(start)
pre = r'''#import <Foundation/Foundation.h>
#include <cassert>
#include <cstdio>
#include <cstdint>
#include <map>
#include <set>
#include <string>
#include <memory>
#include <functional>
#include <optional>
#include <vector>
#include <unistd.h>
namespace base {
template<class T> struct WeakPtr { T* p = nullptr; bool* alive = nullptr; T* get() const {return alive && *alive ? p : nullptr;} explicit operator bool() const { return get()!=nullptr; } };
struct OnceClosure { std::function<void()> f; explicit operator bool() const { return bool(f); } void Run(){auto fn=std::move(f);fn();} };
template<class F> OnceClosure BindOnce(F f, uint64_t token) {return {[f,token]{f(token);}};}
template<class T> class AutoReset { T* p; T old; public: AutoReset(T* p, T x):p(p),old(*p){*p=x;} ~AutoReset(){*p=old;} };
struct CommandLine { std::string check="profiles"; bool screen=false; static CommandLine* ForCurrentProcess(){static CommandLine c;return &c;} bool HasSwitch(const char* s){return std::string(s)=="ararat-screen"?screen:!check.empty();} std::string GetSwitchValueASCII(const char*){return check;} };
std::string SysNSStringToUTF8(NSString* s){return [s UTF8String];}
}
namespace content {
struct RenderFrameHost;
struct WeakDocumentPtr { RenderFrameHost* p=nullptr; bool* alive=nullptr; RenderFrameHost* AsRenderFrameHostIfValid() const {return alive && *alive?p:nullptr;} };
struct RenderFrameHost { bool alive=true; WeakDocumentPtr GetWeakDocumentPtr(){return {this,&alive};} };
struct WebContents { bool alive=true; RenderFrameHost* frame=nullptr; RenderFrameHost* GetPrimaryMainFrame(){return frame;} base::WeakPtr<WebContents> GetWeakPtr(){return {this,&alive};} };
}
@interface ARWindowHost : NSObject
- (NSDictionary*)checkDialogPage:(content::WebContents*)contents;
@end
@implementation ARWindowHost
- (NSDictionary*)checkDialogPage:(content::WebContents*)contents { return contents ? @{ @"live": @"x", @"item": @"item" } : nil; }
@end
using NSUInteger=unsigned long;
__weak ARWindowHost* g_check_dialog_host;
bool g_check_dialog_failed=false, g_check_dialog_installed=true;
NSUInteger g_check_dialog_count=0, g_check_cancel_dialog=1, g_check_dialog_limit=2;
'''
struct = s[s.index('struct CheckDocument {'):s.index('bool g_fullscreen_completion_called')]
parts = [extract('bool CheckRequestCurrent('), extract('bool AraratCheckRejectJavaScriptDialog()'), extract('bool AraratCheckRegisterBeforeUnload('), extract('void AraratCheckUnregisterBeforeUnload('), extract('void AraratCheckRevokeChangedDocument('), extract('uint64_t AraratCheckBeginBeforeUnload('), extract('bool AraratCheckFinishBeforeUnload('), extract('uint64_t AraratCheckEnterBeforeUnloadManager('), extract('void AraratCheckLeaveBeforeUnloadManager(')]
respond = extract('  void Respond()')
resolve = extract('  void Resolve(bool accept, bool scripted)')
accept = extract('  void AcceptAppModalDialog()')
cancel = extract('  void CancelAppModalDialog()')
wrapper_run = extract('  void Run(bool dialog_was_suppressed,', content_source)
manager_lambda = extract('[](scoped_refptr<CloseDialogCallbackWrapper>', content_source)
post = r'''
template<class T> using scoped_refptr=std::shared_ptr<T>;
struct Callback { std::function<void(bool)> f; bool is_null() const {return !f;} void Run(bool, bool success, const std::u16string&) {auto once=std::move(f); f={}; once(success);} };
struct CloseDialogCallbackWrapper { Callback callback_;
'''+wrapper_run+r'''
};
auto* g_ararat_enter_beforeunload_manager = &AraratCheckEnterBeforeUnloadManager;
auto* g_ararat_leave_beforeunload_manager = &AraratCheckLeaveBeforeUnloadManager;
auto manager_route = '''+manager_lambda+r''';
namespace chrome_browser_application_mac { void CancelTerminate() {} }
struct Controller {
 content::WebContents* contents; uint64_t token; int calls=0; bool result=false; bool alive=true; std::function<void()> during_complete; std::function<void()> during_notify; std::shared_ptr<CloseDialogCallbackWrapper> wrapper=std::make_shared<CloseDialogCallbackWrapper>(); std::optional<std::u16string> override_prompt_text_;
 struct WeakFactory { Controller* p; base::WeakPtr<Controller> GetWeakPtr(){ return {p,&p->alive}; } } weak_ptr_factory_{this};
 Controller(content::WebContents* w, uint64_t t):contents(w),token(t){ wrapper->callback_.f=[this](bool success){++calls;result=AraratCheckFinishBeforeUnload(token,success);}; }
 content::WebContents* web_contents(){return contents;}
 void CompleteDialog(){ if(during_complete) during_complete(); }
 void External(bool success) { wrapper->Run(false,success,u"" ); }
 void NotifyDelegate(bool success,const std::u16string&,bool) { if(during_notify) during_notify(); manager_route(wrapper,token,success,u"" ); }
 void OnAccept(const std::u16string& prompt_text, bool suppress_js_messages, base::OnceClosure ararat_authorize);
 void OnCancel(bool suppress_js_messages, base::OnceClosure ararat_authorize);
};
'''+extract('void AppModalDialogController::OnAccept(',controller_source).replace('AppModalDialogController','Controller')+'\n'+extract('void AppModalDialogController::OnCancel(',controller_source).replace('AppModalDialogController','Controller')+r'''
struct FakeWeak { operator bool() const {return false;} }; struct FakeFactory { FakeWeak GetWeakPtr(){return {};} };
struct FakeDialog { Controller* controller_; bool expected_=true; bool cancel_=false; uint64_t request_; FakeFactory weak_factory_;
'''+accept.replace(' override','')+'\n'+cancel.replace(' override','')+'\n'+respond+'\n'+resolve+r'''
};
int main(){ @autoreleasepool {
 ARWindowHost* host=[ARWindowHost new]; g_check_dialog_host=host;
 content::RenderFrameHost a,b; content::WebContents w; w.frame=&a;
 assert(AraratCheckRegisterBeforeUnload("x",&w));
 // Uncommitted and same-document navigation leave the registered frame unchanged.
 AraratCheckRevokeChangedDocument("x",&w); assert(g_check_beforeunload_lives.count("x"));
 auto begin=[&]{g_check_dialog_seen.clear(); g_check_admitted_count=0; return AraratCheckBeginBeforeUnload(&w,&a,false);};
 assert(AraratCheckBeginBeforeUnload(&w,&b,false)==1 && g_check_dialog_failed);
 g_check_dialog_failed=false; assert(AraratCheckBeginBeforeUnload(&w,&a,true)==1 && g_check_dialog_failed);
 g_check_dialog_failed=false; uint64_t t=begin(); assert(t>1); Controller c{&w,t}; FakeDialog d{&c,true,true,t}; d.Respond(); assert(c.calls==1 && !c.result && !g_check_dialog_failed && g_check_requests.empty());
 t=begin(); Controller c2{&w,t}; FakeDialog d2{&c2,true,true,t}; d2.AcceptAppModalDialog(); assert(c2.calls==1 && !c2.result && g_check_dialog_failed);
 g_check_dialog_failed=false; g_check_cancel_dialog=0; t=begin(); Controller c3{&w,t}; FakeDialog d3{&c3,true,false,t}; d3.Respond(); assert(c3.calls==1 && c3.result && !g_check_dialog_failed);
 t=begin(); { base::AutoReset<uint64_t> outer(&g_check_scripted_request, 777); Controller nested{&w,t}; FakeDialog dn{&nested,true,false,t}; dn.Respond(); assert(nested.calls==1 && nested.result && g_check_scripted_request==777); } assert(g_check_scripted_request==0);
 for(bool cancel_choice : {false,true}) for(bool stale : {false,true}) for(bool manager : {false,true}) {
  g_check_dialog_failed=false; g_check_cancel_dialog=cancel_choice?1:0; t=begin(); Controller attack{&w,t}; FakeDialog victim{&attack,true,cancel_choice,t};
  attack.during_complete=[&]{ if(stale) ++g_check_attempt_generation; if(manager) manager_route(attack.wrapper,t,!cancel_choice,u"" ); else attack.External(!cancel_choice); };
  victim.Respond(); assert(attack.calls==1 && !attack.result && g_check_dialog_failed && g_check_requests.empty());
 }
 for(bool cancel_choice : {false,true}) {
  g_check_dialog_failed=false; g_check_cancel_dialog=cancel_choice?1:0; t=begin(); Controller attack{&w,t}; FakeDialog victim{&attack,true,cancel_choice,t};
  attack.during_notify=[&]{ attack.External(!cancel_choice); }; victim.Respond();
  assert(attack.calls==1 && !attack.result && g_check_dialog_failed && g_check_requests.empty());
 }
 g_check_cancel_dialog=0; g_check_dialog_failed=false;
 t=begin(); Controller destroyed{&w,t}; FakeDialog lost{&destroyed,true,false,t}; destroyed.during_complete=[&]{destroyed.alive=false;}; lost.Respond(); assert(destroyed.calls==0 && g_check_dialog_failed && g_check_requests.empty());
 g_check_dialog_failed=false; t=begin(); assert(!AraratCheckFinishBeforeUnload(t,true) && g_check_dialog_failed); // DevTools completion outside scripted controller
 g_check_dialog_failed=false; t=begin(); ++g_check_attempt_generation; Controller c4{&w,t}; FakeDialog d4{&c4,true,false,t}; d4.Respond(); assert(c4.calls==1 && !c4.result && g_check_dialog_failed);
 g_check_dialog_failed=false; t=begin(); w.frame=&b; Controller c5{&w,t}; FakeDialog d5{&c5,true,false,t}; d5.Respond(); assert(c5.calls==1 && !c5.result && g_check_dialog_failed); w.frame=&a;
 content::WebContents replacement; replacement.frame=&b; assert(AraratCheckRegisterBeforeUnload("x",&replacement)); AraratCheckUnregisterBeforeUnload("x",&w); assert(g_check_beforeunload_lives.at("x").contents.get()==&replacement); assert(AraratCheckRegisterBeforeUnload("x",&w));
 g_check_dialog_failed=false; AraratCheckUnregisterBeforeUnload("x",&w); assert(AraratCheckBeginBeforeUnload(&w,&a,false)==1 && g_check_dialog_failed); assert(AraratCheckRegisterBeforeUnload("x",&w));
 g_check_dialog_failed=false; auto saved_serial=g_check_request_serial; g_check_request_serial=UINT64_MAX; assert(begin()==1 && g_check_dialog_failed); g_check_request_serial=saved_serial;
 g_check_dialog_failed=false; auto* args=base::CommandLine::ForCurrentProcess(); args->screen=true; assert(AraratCheckBeginBeforeUnload(&w,&b,true)==0 && !g_check_dialog_failed); args->screen=false; args->check="dialogs"; assert(AraratCheckBeginBeforeUnload(&w,&b,true)==0 && !g_check_dialog_failed);
 args->check="profiles"; g_check_dialog_failed=false; AraratCheckUnregisterBeforeUnload("x",&w);
 std::vector<content::RenderFrameHost> frames(65); std::vector<content::WebContents> items(65);
 for(int i=0;i<64;i++){items[i].frame=&frames[i];assert(AraratCheckRegisterBeforeUnload(std::to_string(i),&items[i]));}
 items[64].frame=&frames[64]; assert(!AraratCheckRegisterBeforeUnload("overflow",&items[64])); items[0].alive=false; assert(AraratCheckRegisterBeforeUnload("pruned",&items[64])); assert(g_check_beforeunload_lives.size()==64);
 std::puts("extracted admission and completion checks passed");
} }
'''
Path(sys.argv[1]).write_text(pre + struct + '\n' + '\n'.join(parts) + '\n' + post)
