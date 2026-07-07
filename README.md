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

Codex rotates refresh tokens on every use — if any other session (the ChatGPT app, an IDE, another CLI invocation) refreshes a token, the snapshot you have on disk becomes invalid and the next `codex-acct use` fails with `token_invalidated`. The `codex-acct-watch` watcher closes that gap by mirroring `~/.codex/auth.json` into the active slot whenever it changes.

Start it once:

```sh
codex-acct watch start
```

To start it automatically on every shell, add this to `~/.bashrc` or `~/.zshrc`:

```sh
command -v codex-acct >/dev/null && codex-acct watch start >/dev/null 2>&1 || true
```

Polling interval defaults to 3 s — override with `CODEX_ACCT_WATCH_INTERVAL=<seconds>` in your shell rc. Works on Linux and macOS (pure bash, no dependencies).

### Or sync on exit via the Codex launcher wrapper

Instead of (or alongside) the watcher, route every `codex` invocation through
`codex-acct`. It keeps the original Codex CLI as `codex.codex-acct-real`, writes
a small managed wrapper at `~/.local/bin/codex`, and syncs any rotated tokens
back into the active slot on exit:

```sh
codex-acct install-wrapper
```

After that, use normal `codex` commands. The wrapper is reversible with
`codex-acct uninstall-wrapper`. This only captures refreshes from runs you
launch yourself; the watcher additionally catches refreshes from the desktop app
and other sessions, so the two are complementary.

### Surviving codex updates

`npm install -g @openai/codex` — whether typed by hand, run by the Codex TUI's
"Update now" prompt, or by `codex update` — replaces `~/.local/bin/codex` with
the stock npm symlink, silently removing the managed wrapper (npm's update path
does not check ownership of existing bin entries). Two defenses:

- The watcher also monitors the wrapper and re-asserts it automatically about
  ten seconds after a clobber (debounced so it never races a mid-flight npm
  install). `codex-acct repair-wrapper` is the same reconciler by hand: no-op
  when healthy, repairs only the recognizable clobber shapes (stock npm symlink
  or missing file), and fails closed on anything it doesn't recognize.
- `codex-acct update` updates the npm package and immediately repairs the
  wrapper in one step — prefer it over calling npm directly.

## Usage

```sh
codex-acct add personal        # runs `codex login` without revoking the current saved account
codex-acct add work            # log in to a second account, save as "work"
codex-acct use personal        # atomic swap, then restart the app-server daemon
codex-acct use work --no-daemon-restart   # swap without bouncing the daemon
codex-acct use odin            # switch to the Odin Responses provider slot
codex-acct list                # show all saved accounts + which is active
codex-acct who                 # show the active account (email, plan, account_id)
codex-acct restore             # swap back to the previous account
codex-acct provider status     # show active model provider from ~/.codex/config.toml
codex-acct provider use odin   # explicit form of: codex-acct use odin
codex-acct provider use openai # switch config.toml back to default OpenAI provider
codex-acct primary personal    # mark the account paired with a ChatGPT app (warns if you leave it)
codex-acct codex [args...]     # run `codex`, then sync rotated tokens back into the active slot
codex-acct install-wrapper     # make plain `codex` run through codex-acct
codex-acct repair-wrapper      # re-assert the wrapper after an npm codex update clobbered it
codex-acct update              # npm install -g @openai/codex + repair-wrapper
codex-acct watch start|stop|status   # background watcher, see "Keep tokens fresh"
```

Existing logins can be captured without re-authenticating:

```sh
codex login                    # if you don't already have a session
codex-acct save personal       # snapshot the current ~/.codex/auth.json
```

`odin` is a virtual slot because it needs a different Codex provider block than
normal ChatGPT/Codex accounts. Switching to `odin` edits only the top-level
`model` / `model_provider` settings and the `[model_providers.odin]` block in
`~/.codex/config.toml`; it does not rewrite `auth.json` or the saved account
slots. Switching back to any real saved account restores the normal provider
config if the current provider is Odin. The switcher loads
`~/projects/odin/.env.1password` automatically when Odin is active, exports the
resolved Odin variables for the child Codex process, and then launches the real
Codex binary directly so interactive terminal stdio stays intact. Override the
env path with `CODEX_ACCT_ODIN_ENV_FILE=/path/to/.env.1password` if needed:

```sh
codex-acct use odin

codex exec "Reply exactly: codex odin ok"
```

## Switching restarts the app-server daemon

Codex can run a long-lived **app-server daemon** that caches your auth in memory. Swapping `auth.json` underneath it is not enough on its own — the daemon keeps using the old account until it re-reads the file. So `use`, `add`, and `restore` restart that daemon by default: they try the managed `codex app-server daemon restart` API, and if the daemon is running unmanaged they adopt it under the managed lifecycle and replace its listener with a fresh process that reads the new `auth.json` at startup.

This means switching accounts briefly interrupts any in-flight app-server session — including the **Codex desktop app**, which runs its own daemon. Pass `--no-daemon-restart` to skip the bounce; the swapped account then takes effect only the next time the daemon restarts on its own:

```sh
codex-acct use work --no-daemon-restart
```

## How it works

`codex login` writes JWTs and a refresh token to `~/.codex/auth.json`. `codex-acct` keeps named copies of that file under `~/.codex/accounts/<name>.json` and atomically swaps the active one into place. Before each swap it also copies the live `auth.json` back into the matching saved slot so any token refresh that happened during use is preserved. The tool validates the account identity before saving live auth into a slot, so a stale `.active` marker or background watcher cannot overwrite the wrong saved account. After the swap it restarts the app-server daemon (see above) so the running Codex process picks up the new account.

## License

MIT
