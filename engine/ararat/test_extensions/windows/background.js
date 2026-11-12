chrome.commands.onCommand.addListener(async (command, tab) => {
  const state = await chrome.storage.local.get({commands: []});
  state.commands.push(command);
  await chrome.storage.local.set(state);
  if (tab?.id) await chrome.tabs.sendMessage(tab.id, command).catch(() => {});
});

// U26e ext-actions fixture: a page asks for a badge on its own tab through the content script.
chrome.runtime.onMessage.addListener((message, sender) => {
  if (!message || message.type !== 'ararat-badge' || !sender.tab?.id) return;
  const text = String(message.text ?? '');
  try {
    chrome.action.setBadgeText({tabId: sender.tab.id, text});
    chrome.action.setBadgeBackgroundColor({tabId: sender.tab.id, color: message.color ?? '#3366FF'});
    if (chrome.action.setBadgeTextColor) {
      try { chrome.action.setBadgeTextColor({tabId: sender.tab.id, color: '#FFFFFF'}); } catch (error) {}
    }
  } catch (error) {
    chrome.storage.session.set({badgeError: String(error)});
  }
});
