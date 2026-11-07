async function probe() {
  const windows = await chrome.windows.getAll({populate: true});
  if (windows.length === 1 && windows[0].tabs.length === 0) {
    const result = {windows: windows.length, tabs: windows[0].tabs.length};
    await chrome.tabs.create({windowId: windows[0].id,
      url: chrome.runtime.getURL('report.html#' + encodeURIComponent(JSON.stringify(result)))});
    return;
  }
  setTimeout(probe, 100);
}
probe();
