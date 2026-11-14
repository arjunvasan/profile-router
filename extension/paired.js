const params = new URLSearchParams(location.search);
const title = document.getElementById('title');
const detail = document.getElementById('detail');

if (params.has('name')) {
  title.textContent = `Paired as "${params.get('name')}"`;
  title.className = 'ok';
  detail.textContent = 'Sign-ins started in this profile are now routed. This tab closes itself.';
  setTimeout(async () => {
    const tab = await chrome.tabs.getCurrent();
    if (tab) chrome.tabs.remove(tab.id);
  }, 2000);
} else {
  title.textContent = 'Could not pair this profile';
  detail.textContent = params.get('error') ?? '';
}
