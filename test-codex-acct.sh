#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

make_auth() {
  local sub="$1" email="$2" refresh="$3" out="$4"
  python3 - "$sub" "$email" "$refresh" "$out" <<'PY'
import base64
import json
import sys

sub, email, refresh, out = sys.argv[1:]

def b64(obj):
    raw = json.dumps(obj, separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")

id_token = f"{b64({'alg': 'none'})}.{b64({'email': email, 'sub': sub, 'https://api.openai.com/auth': {'chatgpt_plan_type': 'test'}})}.sig"
with open(out, "w") as f:
    json.dump({"tokens": {"id_token": id_token, "refresh_token": refresh, "account_id": sub}}, f)
PY
}

refresh_token() {
  python3 - "$1" <<'PY'
import json
import sys

print(json.load(open(sys.argv[1]))["tokens"]["refresh_token"])
PY
}

account_id() {
  python3 - "$1" <<'PY'
import json
import sys

print(json.load(open(sys.argv[1]))["tokens"]["account_id"])
PY
}

setup_home() {
  local name="$1"
  export CODEX_HOME="$TEST_ROOT/$name"
  mkdir -p "$CODEX_HOME/accounts"
  make_auth personal-sub personal@example.test personal-r1 "$CODEX_HOME/accounts/personal.json"
  make_auth work-sub work@example.test work-r1 "$CODEX_HOME/accounts/work.json"
}

setup_fake_codex() {
  local bin_dir="$TEST_ROOT/fake-bin"
  mkdir -p "$bin_dir"
  PATH="$bin_dir:$PATH"
  export PATH
  cat > "$bin_dir/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  logout)
    echo "logout-called" >> "$CODEX_HOME/codex-calls"
    exit 44
    ;;
  login)
    if [[ -e "$CODEX_HOME/auth.json" ]]; then
      echo "login-saw-auth" >> "$CODEX_HOME/codex-calls"
    else
      echo "login-no-auth" >> "$CODEX_HOME/codex-calls"
    fi
    cp "$CODEX_HOME/new-login.json" "$CODEX_HOME/auth.json"
    ;;
  *)
    echo "unsupported fake codex command: ${1:-}" >&2
    exit 2
    ;;
esac
SH
  chmod +x "$bin_dir/codex"
}

assert_eq() {
  local want="$1" got="$2" label="$3"
  if [[ "$want" != "$got" ]]; then
    echo "FAIL: $label: want '$want', got '$got'" >&2
    exit 1
  fi
}

test_sync_does_not_overwrite_stale_active_slot() {
  setup_home stale-active
  cp "$CODEX_HOME/accounts/work.json" "$CODEX_HOME/auth.json"
  printf personal > "$CODEX_HOME/accounts/.active"

  "$ROOT/codex-acct" sync >/dev/null

  assert_eq personal-sub "$(account_id "$CODEX_HOME/accounts/personal.json")" "stale .active preserved personal slot"
  assert_eq personal-r1 "$(refresh_token "$CODEX_HOME/accounts/personal.json")" "stale .active preserved personal refresh token"
  assert_eq work-sub "$(account_id "$CODEX_HOME/accounts/work.json")" "matched work slot remains work"
  assert_eq work "$(cat "$CODEX_HOME/accounts/.active")" "sync repaired active slot"
}

test_switch_preserves_live_account_even_when_active_matches_target() {
  setup_home same-target
  make_auth work-sub work@example.test work-r2 "$CODEX_HOME/auth.json"
  printf personal > "$CODEX_HOME/accounts/.active"

  "$ROOT/codex-acct" use personal >/dev/null

  assert_eq work-r2 "$(refresh_token "$CODEX_HOME/accounts/work.json")" "switch saved fresh work refresh token"
  assert_eq personal-r1 "$(refresh_token "$CODEX_HOME/accounts/personal.json")" "switch restored personal slot"
  assert_eq personal-r1 "$(refresh_token "$CODEX_HOME/auth.json")" "active auth switched to personal"
  assert_eq personal "$(cat "$CODEX_HOME/accounts/.active")" "active slot updated to target"
}

test_same_account_duplicate_slots_are_not_overwritten_when_ambiguous() {
  setup_home duplicate
  cp "$CODEX_HOME/accounts/work.json" "$CODEX_HOME/accounts/work-copy.json"
  make_auth work-sub work@example.test work-r2 "$CODEX_HOME/auth.json"
  printf personal > "$CODEX_HOME/accounts/.active"

  "$ROOT/codex-acct" sync >/dev/null

  assert_eq personal-r1 "$(refresh_token "$CODEX_HOME/accounts/personal.json")" "ambiguous sync preserved stale active slot"
  assert_eq work-r1 "$(refresh_token "$CODEX_HOME/accounts/work.json")" "ambiguous sync preserved first matching slot"
  assert_eq work-r1 "$(refresh_token "$CODEX_HOME/accounts/work-copy.json")" "ambiguous sync preserved duplicate matching slot"
  assert_eq personal "$(cat "$CODEX_HOME/accounts/.active")" "ambiguous sync did not guess active slot"
}

test_sync_does_not_save_previous_snapshot() {
  setup_home no-previous
  cp "$CODEX_HOME/accounts/work.json" "$CODEX_HOME/auth.json"
  printf work > "$CODEX_HOME/accounts/.active"

  "$ROOT/codex-acct" sync >/dev/null

  if [[ -e "$CODEX_HOME/accounts/_previous.json" ]]; then
    echo "FAIL: sync should not create _previous.json" >&2
    exit 1
  fi
}

test_add_does_not_revoke_or_expose_previous_auth_to_login() {
  setup_home add-no-revoke
  setup_fake_codex
  cp "$CODEX_HOME/accounts/personal.json" "$CODEX_HOME/auth.json"
  printf personal > "$CODEX_HOME/accounts/.active"
  make_auth work-sub work@example.test work-r2 "$CODEX_HOME/new-login.json"

  "$ROOT/codex-acct" add work2 >/dev/null

  if grep -q "logout-called" "$CODEX_HOME/codex-calls"; then
    echo "FAIL: add should not call codex logout" >&2
    exit 1
  fi
  assert_eq login-no-auth "$(cat "$CODEX_HOME/codex-calls")" "login ran without previous auth visible"
  assert_eq personal-r1 "$(refresh_token "$CODEX_HOME/accounts/personal.json")" "add preserved previous account slot"
  assert_eq work-r2 "$(refresh_token "$CODEX_HOME/accounts/work2.json")" "add saved new login"
  assert_eq work2 "$(cat "$CODEX_HOME/accounts/.active")" "add marked new slot active"
}

test_sync_does_not_overwrite_stale_active_slot
test_switch_preserves_live_account_even_when_active_matches_target
test_same_account_duplicate_slots_are_not_overwritten_when_ambiguous
test_sync_does_not_save_previous_snapshot
test_add_does_not_revoke_or_expose_previous_auth_to_login

echo "ok"
