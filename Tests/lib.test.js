import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';

import { hostsOf, isHttp, matchProvider, signInFinished, siteOf } from '../extension/lib.js';

const read = (name) => JSON.parse(readFileSync(new URL(`../extension/${name}`, import.meta.url), 'utf8'));
const providers = read('providers.json');
const manifest = read('manifest.json');
const id = (url) => matchProvider(url, providers)?.id ?? null;

test('recognizes where each provider starts a sign-in', () => {
  assert.equal(id('https://accounts.google.com/o/oauth2/v2/auth?client_id=x'), 'google');
  assert.equal(id('https://accounts.google.com/gsi/select?client_id=x'), 'google');
  assert.equal(id('https://github.com/login/oauth/authorize?client_id=x'), 'github');
  assert.equal(id('https://github.com/login/device'), 'github');
  assert.equal(id('https://login.microsoftonline.com/common/oauth2/v2.0/authorize'), 'microsoft');
  assert.equal(id('https://login.live.com/oauth20_authorize.srf?x=1'), 'microsoft');
  assert.equal(id('https://appleid.apple.com/auth/authorize'), 'apple');
  assert.equal(id('https://gitlab.com/oauth/authorize'), 'gitlab');
  assert.equal(id('https://slack.com/openid/connect/authorize'), 'slack');
});

test('ignores every other page', () => {
  assert.equal(id('https://github.com/login'), null);
  assert.equal(id('https://github.com/anthropics/claude-code'), null);
  assert.equal(id('https://accounts.google.com/ServiceLogin'), null);
  assert.equal(id('http://github.com/login/oauth/authorize'), null);
  assert.equal(id('https://evil.example/login/oauth/authorize'), null);
  assert.equal(id('not a url'), null);
});

test('the extension has host access to every provider it watches', () => {
  const hosts = new Set(hostsOf(manifest.host_permissions));
  for (const provider of providers) for (const m of provider.matches) assert.ok(hosts.has(m.host), m.host);
});

test('names a site by its host without www', () => {
  assert.equal(siteOf('https://www.Example.com/login?x=1'), 'example.com');
  assert.equal(siteOf('https://app.example.com'), 'app.example.com');
  assert.equal(siteOf('chrome://extensions'), null);
  assert.equal(siteOf(undefined), null);
  assert.equal(isHttp('https://a.b'), true);
  assert.equal(isHttp('chrome://newtab'), false);
  assert.equal(isHttp(undefined), false);
});

test('a sign-in counts as finished only when it went through', () => {
  assert.equal(signInFinished('https://app.example.com/callback?code=abc', []), true);
  assert.equal(signInFinished('https://app.example.com/callback?error=access_denied', []), false);
  assert.equal(signInFinished('https://app.example.com/login', ['forward_back']), false);
});
