# Session handoff — live working state

> Snapshot for a fresh Claude Code instance picking up mid-flight. Read the root
> `CLAUDE.md` first (it auto-loads and imports `phase-1.md`) for the locked
> decisions and architecture — this file is only the *live state* on top of that.
> Delete this file once you've absorbed it; it goes stale fast.

## Where we are

Phase 1 (the Claude vision → `CheckReport` engine) is **built and wired**. We just
finished a batch of git/identity housekeeping and were in the middle of getting
the backend to actually load the API key from `.env`. Not yet validated against a
real listing.

## ⚠️ Immediate open issue — `.env` not loading the key

Last check (just now) reported:

```
NO — key not found in backend/.env
key reaches os.environ: False
```

So `backend/.env` either doesn't have `ANTHROPIC_API_KEY` or it's in the wrong
place/format. **Next action:** verify `backend/.env` exists and contains a line
exactly like `ANTHROPIC_API_KEY=sk-ant-...` (no quotes, no spaces around `=`, not
at the repo root — it must be `backend/.env`, which is what `load_dotenv` points
at in `app/main.py`). Then re-run:

```sh
cd backend && ./.venv/bin/python -c "import app.main, os; print(bool(os.environ.get('ANTHROPIC_API_KEY')))"
```

Expect `True`.

## 🔐 Security

The user pasted a live API key into the chat earlier. Remind them to **rotate it**
(console.anthropic.com → revoke + regenerate → update `backend/.env`). Never echo
or write keys anywhere.

## Uncommitted working-tree changes right now (mine, this turn — NOT committed)

- `backend/app/main.py` — added `load_dotenv(backend/.env)` at the top.
- `backend/requirements.txt` — added `python-dotenv>=1.0`.
- `.gitignore` — added `test_shots/` (local screenshots, not committed).
- Created empty `test_shots/` dir for local listing screenshots.

Commit these once `.env` loading is confirmed working.

## The next milestone (what we were heading toward)

First real verdict. The plan: user drops a **listing screenshot** into
`test_shots/` (input is screenshots, NOT a URL — Depop hard-blocks fetches; see
`phase-0.md`), then:

```sh
# shell 1
cd backend && ./.venv/bin/uvicorn app.main:app --port 8000
# shell 2
curl -s -X POST localhost:8000/check \
  -F 'images=@test_shots/shot.png' \
  -F 'user_context=...' | python3 -m json.tool
```

This first real call **also validates a flagged risk**: combining structured
output (`output_format=CheckReport`) with the `web_search` server tool in ONE
`messages.parse` call. If the API rejects that combo, split into two passes
(search/reason, then format) — see `phase-1.md`.

Prefer a file on disk + curl over pasting the image into chat: the bytes go
disk → backend → Claude and never enter the conversation context (token-cheap),
and it actually exercises the backend path.

## Git state

- Branch `main`, synced with `origin/main` at `f66d0d9` (dead URL-fetch path
  removed). Plus the uncommitted changes listed above.
- Identity is now `kaladanw <97216785+kaladanw@users.noreply.github.com>`
  (global; repo-local override removed). Older commits show "kalwoo" — left as-is.

## Env notes

- Use Python 3.13: `/opt/homebrew/bin/python3.13`. Venv at `backend/.venv`.
- Run from `backend/` so imports resolve (`app.main:app`).
