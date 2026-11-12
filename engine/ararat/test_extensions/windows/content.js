chrome.runtime.onMessage.addListener(command => {
  document.documentElement.dataset.extensionCommand = command;
});

// U26e ext-actions fixture: ?badge=7 badges this tab only.
const badge = new URL(location.href).searchParams.get('badge');
if (badge !== null) {
  chrome.runtime.sendMessage({type: 'ararat-badge', text: badge, color: '#3366FF'}).catch(() => {});
}
