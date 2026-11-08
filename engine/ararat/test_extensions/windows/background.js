chrome.commands.onCommand.addListener(async (command, tab) => {
  const state = await chrome.storage.local.get({commands: []});
  state.commands.push(command);
  await chrome.storage.local.set(state);
  if (tab?.id) await chrome.tabs.sendMessage(tab.id, command).catch(() => {});
});
