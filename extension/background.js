// Profile Router's service worker. It watches for sign-ins starting in this
// profile, asks the helper app what to do, and carries out the answer. The
// helper holds the memory shared by all profiles and makes every decision.

import { hostsOf, isHttp, matchProvider, signInFinished, siteOf } from './lib.js';

const HOST = 'com.profilerouter.host';
const PAIR_HOST = 'pair.profile-router.invalid';
// A sign-in can pass through several provider pages; treat them as one for this long.
const FLOW_TTL_MS = 10 * 60 * 1000;

const providerPatterns = chrome.runtime.getManifest().host_permissions;
const providerHosts = new Set(hostsOf(providerPatterns));

let providersPromise;
const providers = () =>
  (providersPromise ??= fetch(chrome.runtime.getURL('providers.json')).then((r) => r.json()));

const session = {
  get: async (key) => (await chrome.storage.session.get(key))[key],
  set: (key, value) => chrome.storage.session.set({ [key]: value }),
  del: (...keys) => chrome.storage.session.remove(keys),
};

async function native(message) {
  try {
    return (await chrome.runtime.sendNativeMessage(HOST, message)) ?? {};
  } catch (e) {
    return { error: String(e?.message ?? e) };
  }
}

/** Which Chrome profile this is; set once by `profile-router setup`. */
const me = async () => (await chrome.storage.local.get('profile')).profile;

async function activeFlow(tabId) {
  const flow = await session.get(`flow:${tabId}`);
  if (flow && Date.now() - flow.at > FLOW_TTL_MS) {
    await session.del(`flow:${tabId}`);
    return undefined;
  }
  return flow;
}

// ---- A sign-in starts ------------------------------------------------------

const starting = new Set();

async function onAuthUrl(tabId, url, initiator) {
  if (tabId < 0 || starting.has(tabId)) return;
  starting.add(tabId);
  try {
    const provider = matchProvider(url, await providers());
    if (!provider) return;
    const profile = await me();
    if (!profile) return;
    const flow = await activeFlow(tabId);
    if (flow?.provider === provider.id) return;

    // The page the sign-in was started from: this tab's last page, or for a
    // pop-up that has no page of its own, the tab that opened it.
    let pageUrl = await session.get(`page:${tabId}`);
    let popup = false;
    if (!pageUrl) {
      const tab = await chrome.tabs.get(tabId).catch(() => null);
      const opener = tab?.openerTabId != null ? await chrome.tabs.get(tab.openerTabId).catch(() => null) : null;
      if (isHttp(opener?.url)) {
        pageUrl = opener.url;
        popup = true;
      }
    }

    const reply = await native({
      type: 'authStart',
      profile: profile.dir,
      provider: provider.id,
      authUrl: url,
      initiator: initiator ?? null,
      pageUrl: pageUrl ?? null,
    });
    if (!reply.site) return;

    const next = {
      provider: provider.id,
      providerName: provider.name,
      site: reply.site,
      pageUrl: reply.pageUrl,
      popup,
      action: reply.action,
      at: Date.now(),
    };
    await session.set(`flow:${tabId}`, next);
    if (reply.action === 'move') await moved(tabId, next, reply.name);
    else if (reply.action === 'ask') await openPicker(tabId, next, reply.choices);
  } finally {
    starting.delete(tabId);
  }
}

// Requests catch sign-ins reached through a redirect; navigation events catch
// the rest. Both lead to the same place and the second one is ignored.
chrome.webRequest.onBeforeRequest.addListener(
  (d) => {
    onAuthUrl(d.tabId, d.url, d.initiator);
  },
  { urls: providerPatterns, types: ['main_frame'] },
);

chrome.webNavigation.onBeforeNavigate.addListener(
  (d) => {
    if (d.frameId !== 0) return;
    const u = new URL(d.url);
    if (u.hostname === PAIR_HOST) pair(d.tabId, u);
    else onAuthUrl(d.tabId, d.url);
  },
  { url: [{ hostEquals: PAIR_HOST }, ...[...providerHosts].map((hostEquals) => ({ hostEquals }))] },
);

// ---- Tracking pages, and noticing a sign-in finish -------------------------

chrome.webNavigation.onCommitted.addListener(async (d) => {
  if (d.frameId !== 0 || !isHttp(d.url)) return;
  const onProviderPage = providerHosts.has(new URL(d.url).hostname) && matchProvider(d.url, await providers());
  if (onProviderPage) {
    onAuthUrl(d.tabId, d.url);
    return;
  }
  const flow = await activeFlow(d.tabId);
  if (!flow) {
    if (!starting.has(d.tabId)) await session.set(`page:${d.tabId}`, d.url);
    return;
  }
  if (siteOf(d.url) !== flow.site) return;

  // Back at the site: the sign-in is over. If nobody had chosen a profile and
  // it went through, this profile is the answer.
  if (flow.action === 'ask' && signInFinished(d.url, d.transitionQualifiers)) {
    const profile = await me();
    if (profile) await native({ type: 'authDone', profile: profile.dir, provider: flow.provider, site: flow.site });
  }
  await closePicker(d.tabId);
  await session.del(`flow:${d.tabId}`);
  await session.set(`page:${d.tabId}`, d.url);
});

chrome.tabs.onRemoved.addListener(async (tabId) => {
  await closePicker(tabId);
  await session.del(`flow:${tabId}`, `page:${tabId}`);
});

// ---- Moving a sign-in to another profile -----------------------------------

async function moved(tabId, flow, targetName) {
  // The helper has already opened the site in the other profile.
  await chrome.tabs.remove(tabId).catch(() => {});
  const id = `moved:${Date.now()}`;
  await session.set(id, flow);
  chrome.notifications.create(id, {
    type: 'basic',
    iconUrl: 'icon128.png',
    title: `Sign-in moved to ${targetName}`,
    message: `${flow.site} signs in with ${flow.providerName} in that profile.`,
    buttons: [{ title: 'Undo' }],
  });
}

chrome.notifications.onButtonClicked.addListener(async (id) => {
  const flow = await session.get(id);
  const profile = await me();
  chrome.notifications.clear(id);
  if (!flow || !profile) return;
  await session.del(id);
  await native({ type: 'undo', profile: profile.dir, provider: flow.provider, site: flow.site });
  await chrome.tabs.create({ url: flow.pageUrl });
});

// ---- Asking which profile, the first time ----------------------------------

async function openPicker(tabId, flow, choices) {
  const win = await chrome.windows.create({
    url: chrome.runtime.getURL(`picker.html?tab=${tabId}`),
    type: 'popup',
    width: 420,
    height: Math.min(170 + 58 * choices.length, 700),
    focused: true,
  });
  await session.set(`picker:${tabId}`, { windowId: win.id, choices, flow });
}

async function closePicker(tabId) {
  const picker = await session.get(`picker:${tabId}`);
  if (!picker) return;
  await session.del(`picker:${tabId}`);
  await chrome.windows.remove(picker.windowId).catch(() => {});
}

async function picked(tabId, dir) {
  const picker = await session.get(`picker:${tabId}`);
  const profile = await me();
  if (!picker || !profile) return;
  const { flow } = picker;
  const reply = await native({
    type: 'choose',
    profile: profile.dir,
    provider: flow.provider,
    site: flow.site,
    pageUrl: flow.pageUrl,
    chosen: dir,
  });
  await closePicker(tabId);
  if (reply.action === 'move') {
    await session.del(`flow:${tabId}`);
    await chrome.tabs.remove(tabId).catch(() => {});
  } else {
    await session.set(`flow:${tabId}`, { ...flow, action: 'stay' });
  }
}

chrome.runtime.onMessage.addListener((message, sender, respond) => {
  if (sender.id !== chrome.runtime.id) return false;
  if (message.type === 'pickerInit') {
    session.get(`picker:${message.tab}`).then((picker) =>
      respond(picker ? { choices: picker.choices, site: picker.flow.site, providerName: picker.flow.providerName } : null),
    );
    return true;
  }
  if (message.type === 'pick') {
    picked(message.tab, message.dir).then(() => respond(true));
    return true;
  }
  if (message.type === 'status') {
    Promise.all([me(), native({ type: 'hello' })]).then(([profile, hello]) =>
      respond({ profile: profile ?? null, helper: hello.ok === true }),
    );
    return true;
  }
  return false;
});

// ---- Pairing: setup tells this copy of the extension which profile it is in --

async function pair(tabId, url) {
  const reply = await native({
    type: 'pair',
    dir: url.searchParams.get('dir'),
    token: url.searchParams.get('token'),
  });
  const page = new URL(chrome.runtime.getURL('paired.html'));
  if (reply.ok) {
    await chrome.storage.local.set({ profile: { dir: reply.dir, name: reply.name } });
    page.searchParams.set('name', reply.name);
    reportAccounts();
  } else {
    page.searchParams.set('error', reply.error ?? 'The helper did not answer.');
  }
  await chrome.tabs.update(tabId, { url: page.href }).catch(() => {});
}

// ---- Telling the helper which accounts live in this profile ----------------

async function reportAccounts() {
  const profile = await me();
  if (!profile) return;
  const cookie = await chrome.cookies.get({ url: 'https://github.com', name: 'dotcom_user' });
  await native({
    type: 'accounts',
    profile: profile.dir,
    provider: 'github',
    accounts: cookie?.value ? [cookie.value] : [],
  });
}

chrome.runtime.onStartup.addListener(reportAccounts);
chrome.runtime.onInstalled.addListener(reportAccounts);
chrome.cookies.onChanged.addListener(({ cookie }) => {
  if (cookie.name === 'dotcom_user' && cookie.domain.endsWith('github.com')) reportAccounts();
});
