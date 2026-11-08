chrome.runtime.onMessage.addListener(command => {
  document.documentElement.dataset.extensionCommand = command;
});
