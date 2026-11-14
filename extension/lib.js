// Pure helpers, shared by the service worker and the tests.

export function isHttp(url) {
  return /^https?:\/\//i.test(url ?? '');
}

/** The site a URL belongs to: its host, lowercased, without a leading "www.". */
export function siteOf(url) {
  try {
    const u = new URL(url);
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;
    return u.hostname.toLowerCase().replace(/^www\./, '');
  } catch {
    return null;
  }
}

/** The provider whose sign-in page this URL is, if any. */
export function matchProvider(url, providers) {
  let u;
  try {
    u = new URL(url);
  } catch {
    return null;
  }
  if (u.protocol !== 'https:') return null;
  for (const provider of providers) {
    for (const m of provider.matches) {
      if (u.hostname === m.host && new RegExp(m.path).test(u.pathname)) return provider;
    }
  }
  return null;
}

/** Hosts named by the manifest's host permissions ("https://github.com/*" -> "github.com"). */
export function hostsOf(patterns) {
  return patterns.map((p) => p.replace(/^https:\/\//, '').replace(/\/\*$/, ''));
}

/**
 * Whether a tab's navigation back to the site means the sign-in finished here.
 * Going back, or returning with an error (the user pressed Cancel), does not.
 */
export function signInFinished(url, qualifiers = []) {
  if (qualifiers.includes('forward_back')) return false;
  return !/[?&#](error|error_code|error_description)=/.test(url);
}
