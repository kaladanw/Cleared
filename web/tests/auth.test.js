import test from "node:test";
import assert from "node:assert/strict";

import {
  DEFAULT_API_URL,
  SESSION_KEY,
  clearSession,
  getSession,
  requestAuth,
  saveSession,
} from "../src/auth.js";

function memoryStorage() {
  const values = new Map();
  return {
    getItem: (key) => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, value),
    removeItem: (key) => values.delete(key),
  };
}

test("signup sends the documented Railway auth payload", async () => {
  let request;
  const result = await requestAuth("signup", { email: "member@example.com", password: "secret" }, async (url, options) => {
    request = { url, options };
    return { ok: true, json: async () => ({ access_token: "token", user: { email: "member@example.com" } }) };
  });

  assert.equal(request.url, `${DEFAULT_API_URL}/auth/signup`);
  assert.deepEqual(JSON.parse(request.options.body), { email: "member@example.com", password: "secret" });
  assert.equal(request.options.headers["Content-Type"], "application/json");
  assert.equal(result.access_token, "token");
});

test("allowlist and login failures are explained without leaking backend detail", async () => {
  const forbidden = () => Promise.resolve({ ok: false, status: 403 });
  const unauthorized = () => Promise.resolve({ ok: false, status: 401 });

  await assert.rejects(requestAuth("signup", {}, forbidden), /isn’t on the invite list/);
  await assert.rejects(requestAuth("login", {}, unauthorized), /don’t match/);
});

test("network failures have a retryable message", async () => {
  await assert.rejects(requestAuth("login", {}, async () => { throw new Error("socket detail"); }), /couldn’t reach the account service/);
});

test("session helpers keep only the returned web session and can clear it", () => {
  const storage = memoryStorage();
  const session = { accessToken: "token", user: { email: "member@example.com" } };

  saveSession(session, storage);
  assert.deepEqual(getSession(storage), session);
  assert.match(storage.getItem(SESSION_KEY), /accessToken/);
  clearSession(storage);
  assert.equal(getSession(storage), null);
});
