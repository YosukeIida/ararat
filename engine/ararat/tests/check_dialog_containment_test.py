from pathlib import Path
p = Path(__file__).resolve().parents[3]
swift = (p/'macos/Sources/Ararat/main.swift').read_text()
host = (p/'engine/ararat/ararat_window_host.mm').read_text()
tab = (p/'engine/ararat/ararat_tab.mm').read_text()
main = (p/'engine/ararat/ararat_main.mm').read_text()
dialog_patch = (p/'engine/patches/ararat/hidden-dialog-containment.patch').read_text()
factory = host[host.index('- (void)installCheckDialogFactory {'):host.index('- (NSDictionary*)checkDialogPage:', host.index('- (void)installCheckDialogFactory {'))]
assert 'args->HasSwitch("ararat-screen")' in factory
for name in ['profiles','keyboard','quit-cancel','close']:
    assert f'check != "{name}"' in factory
assert 'g_check_dialog_failed = false' not in factory
assert 'controller->is_before_unload_dialog() && owned && request != g_check_requests.end()' in factory
assert 'if (!expected) g_check_dialog_failed = true;' in factory
assert 'if (expected && contents->GetDelegate()) contents->GetDelegate()->ActivateContents(contents);' in factory
assert 'controller_->OnCancel(false, std::move(authorize))' in host and 'controller_->OnAccept(u"", false, std::move(authorize))' in host
assert 'frame == contents->GetPrimaryMainFrame()' in host
assert '!guest' in host and 'CheckRequestCurrent(it->second)' in host
assert 'g_check_scripted_request == token' in host
assert 'Resolve(true, false)' in host and 'Resolve(!cancel_, true)' in host
assert '!AraratCheckDialogIntegrity()' in main
assert 'g_ararat_reject_javascript_dialog = &AraratCheckRejectJavaScriptDialog' in main
assert 'bool suppress_this_message = should_suppress || !has_handlers || ararat_rejected;' in dialog_patch
assert 'document.AsRenderFrameHostIfValid()' in host
assert 'request.attempt_generation != g_check_attempt_generation' in host
assert 'request.document_generation != it->second.generation' in host
assert 'navigation->HasCommitted() && navigation->IsInPrimaryMainFrame()' in tab
assert '!navigation->IsSameDocument()' in tab
assert 'AraratCheckUnregisterBeforeUnload' in tab[tab.index('- (void)replaceContents:'):]
assert 'AraratCheckDocumentRevision() != generation' in tab
assert 'let ok = ok && (host?.checkDialogIntegrity() ?? true)' in swift
start = swift[swift.index('adapter.attach(host)'):swift.index('if reopening {',swift.index('adapter.attach(host)'))]
assert 'session == nil' in start and '--ararat-screen=' in start and 'host.installCheckDialogFactory()' in start
assert 'if (script == 5 && !AraratCheckRegisterBeforeUnload' in tab
assert tab.index('AraratCheckRegisterBeforeUnload',tab.index('- (void)prepareCheckBeforeUnload')) < tab.index('ExecuteJavaScriptWithUserGestureForTests',tab.index('- (void)prepareCheckBeforeUnload'))
assert 'if passed { host.configureProfileCloseCheck(0) }' in swift
assert 'beginCloseRaceCheck(host) { host.expectCheckDialogs(1); NSApp.terminate(nil) }' in swift
assert 'beginCloseRaceCheck(host) { host.expectCheckDialogs(2); NSApp.terminate(nil) }' in swift
assert 'g_check_dialog_failed = false' not in host[host.index('- (void)installCheckDialogFactory {'):]
print('containment source checks passed')
