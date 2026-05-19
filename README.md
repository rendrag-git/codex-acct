# codex-acct

Switch between Codex (ChatGPT) accounts by swapping `~/.codex/auth.json`.

Lets you keep several `codex login` sessions on one machine — e.g. a personal Plus account, a Team account, and a Pro account — and flip between them with one command. Slots are stored mode-0600 under `~/.codex/accounts/`. Token refreshes are persisted back into the active slot so snapshots don't grow stale.

## Install

```sh
for f in codex-acct codex-acct-watch; do
  curl -fsSL "https://raw.githubusercontent.com/rendrag-git/codex-acct/main/$f" \
    -o "$HOME/.local/bin/$f" && chmod +x "$HOME/.local/bin/$f"
done
```

Make sure `~/.local/bin` is on your `PATH`. Requires `bash`, `python3`, and the [Codex CLI](https://github.com/openai/codex).

## Keep tokens fresh (recommended)

Codex rotates refresh tokens on every use — if any other session (the ChatGPT app, an IDE, another CLI invocation) refreshes a token, the snapshot you have on disk becomes invalid and the next `codex-acct use` fails with `token_invalidated`. The `codex-acct-watch` daemon closes that gap by mirroring `~/.codex/auth.json` into the active slot whenever it changes.

Start it once:

```sh
codex-acct watch start
```

To start it automatically on every shell, add this to `~/.bashrc` or `~/.zshrc`:

```sh
command -v codex-acct >/dev/null && codex-acct watch start >/dev/null 2>&1 || true
```

Polling interval defaults to 3 s — override with `CODEX_ACCT_WATCH_INTERVAL=<seconds>` in your shell rc. Works on Linux and macOS (pure bash, no dependencies).

## Usage

```sh
codex-acct add personal        # runs `codex login`, saves the result as "personal"
codex-acct add work            # log in to a second account, save as "work"
codex-acct use personal        # atomic swap back
codex-acct list                # show all saved accounts + which is active
codex-acct who                 # show the active account (email, plan, account_id)
codex-acct restore             # swap back to the previous account
codex-acct primary personal    # mark the account paired with a ChatGPT app (warns if you leave it)
codex-acct codex [args...]     # run `codex`, then sync rotated tokens back into the active slot
codex-acct watch start|stop|status   # background daemon, see "Keep tokens fresh"
```

Existing logins can be captured without re-authenticating:

```sh
codex login                    # if you don't already have a session
codex-acct save personal       # snapshot the current ~/.codex/auth.json
```

## How it works

`codex login` writes JWTs and a refresh token to `~/.codex/auth.json`. `codex-acct` keeps named copies of that file under `~/.codex/accounts/<name>.json` and atomically swaps the active one into place. Before each swap it also copies the live `auth.json` back into the previously-active slot so any token refresh that happened during use is preserved.

## License

MIT
