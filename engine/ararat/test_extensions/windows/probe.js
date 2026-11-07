const focusEvents = [];
function tabSummary(tab) {
  return {id: tab.id, windowId: tab.windowId, active: tab.active, incognito: tab.incognito};
}
function windowSummary(window) {
  const result = {id: window.id, type: window.type, focused: window.focused, incognito: window.incognito};
  if (window.tabs) result.tabs = window.tabs.map(tabSummary);
  return result;
}
async function report() {
  const windows = await chrome.windows.getAll({populate: true});
  const last = await chrome.windows.getLastFocused();
  const tabs = await chrome.tabs.query({active: true, currentWindow: true});
  const current = await chrome.windows.getCurrent();
  const byId = await chrome.windows.get(current.id, {populate: true});
  document.title = JSON.stringify({windows: windows.map(windowSummary), last: windowSummary(last),
    tabs: tabs.map(tabSummary), current: windowSummary(current), byId: windowSummary(byId),
    focusEvents, hash: location.hash, focusResult,
    focusBefore, targetId, otherId, popupResult, probeError});
}
let focusResult = null;
let focusBefore = null;
let targetId = null;
let otherId = null;
let popupResult = null;
let probeError = null;
chrome.windows.onFocusChanged.addListener(id => { focusEvents.push(id); report(); });
window.addEventListener('hashchange', async () => {
  try {
    if (location.hash === '#prepare-hidden') {
      targetId = (await chrome.windows.getCurrent()).id;
      const other = await chrome.windows.create({url: 'about:blank', focused: false});
      otherId = other.id;
      await chrome.windows.update(otherId, {focused: true});
      focusBefore = (await chrome.windows.getLastFocused()).id;
    }
    if (location.hash === '#prepare-focus') {
      targetId = (await chrome.windows.getCurrent()).id;
      const other = await chrome.windows.create({url: 'about:blank', focused: true});
      otherId = other.id;
      await chrome.windows.update(otherId, {focused: true});
      focusBefore = (await chrome.windows.getLastFocused()).id;
    }
    if (location.hash === '#focus') {
      await chrome.windows.update(targetId, {focused: true});
      focusResult = (await chrome.windows.getLastFocused()).id === targetId;
    }
    if (location.hash === '#popup') {
      const popup = await chrome.windows.create({type: 'popup', url: 'popup.html'});
      popupResult = windowSummary(await chrome.windows.get(popup.id));
    }
    if (location.hash === '#remove-popup' && popupResult) {
      await chrome.windows.remove(popupResult.id);
      popupResult.removed = true;
    }
    if (location.hash === '#action-popup') {
      await chrome.action.openPopup();
    }
  } catch (error) {
    probeError = String(error);
  }
  await report();
});
report();
