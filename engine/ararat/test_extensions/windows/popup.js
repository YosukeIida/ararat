document.title = 'Ararat extension popup';
chrome.storage.session.set({popup: 'Ararat extension popup'}).then(async () => {
  document.body.dataset.stored = (await chrome.storage.session.get('popup')).popup;
});
