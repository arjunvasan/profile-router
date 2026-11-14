const status = await chrome.runtime.sendMessage({ type: 'status' });
const title = document.getElementById('title');
const detail = document.getElementById('detail');

if (!status.helper) {
  title.textContent = 'Helper not reachable';
  detail.textContent = 'Run "profile-router setup" in a terminal.';
} else if (!status.profile) {
  title.textContent = 'Not paired yet';
  detail.textContent = 'Run "profile-router setup" so this profile is recognized.';
} else {
  title.textContent = `This profile: ${status.profile.name}`;
  title.className = 'ok';
  detail.textContent = 'Sign-ins started here are routed to the profile that holds the account.';
}
