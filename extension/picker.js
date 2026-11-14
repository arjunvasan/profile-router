const tab = Number(new URLSearchParams(location.search).get('tab'));
const data = await chrome.runtime.sendMessage({ type: 'pickerInit', tab });

if (!data) {
  window.close();
} else {
  document.getElementById('question').textContent =
    `Which profile signs in to ${data.site} with ${data.providerName}?`;
  const list = document.getElementById('choices');
  for (const choice of data.choices) {
    const button = document.createElement('button');
    button.className = 'choice';
    button.textContent = choice.current ? `${choice.name} (this profile)` : choice.name;
    if (choice.accounts.length) {
      const accounts = document.createElement('small');
      accounts.textContent = choice.accounts.join(', ');
      button.append(accounts);
    }
    button.addEventListener('click', async () => {
      for (const b of list.querySelectorAll('button')) b.disabled = true;
      await chrome.runtime.sendMessage({ type: 'pick', tab, dir: choice.dir });
      window.close();
    });
    list.append(button);
  }
}
