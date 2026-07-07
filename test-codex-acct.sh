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

toml_get() {
  python3 - "$1" "$2" <<'PY'
import sys
import tomllib

data = tomllib.load(open(sys.argv[1], "rb"))
cur = data
for part in sys.argv[2].split("."):
    cur = cur[part]
print(cur)
PY
}

toml_get_optional() {
  python3 - "$1" "$2" <<'PY'
import sys
import tomllib

data = tomllib.load(open(sys.argv[1], "rb"))
cur = data
for part in sys.argv[2].split("."):
    if not isinstance(cur, dict) or part not in cur:
        print("")
        raise SystemExit
    cur = cur[part]
print(cur)
PY
}

toml_project_trust() {
  python3 - "$1" "$2" <<'PY'
import sys
import tomllib

data = tomllib.load(open(sys.argv[1], "rb"))
print(data["projects"][sys.argv[2]]["trust_level"])
PY
}

setup_home() {
  local name="$1"
  export CODEX_HOME="$TEST_ROOT/$name"
  mkdir -p "$CODEX_HOME/accounts"
  make_auth personal-sub personal@example.test personal-r1 "$CODEX_HOME/accounts/personal.json"
  make_auth work-sub work@example.test work-r1 "$CODEX_HOME/accounts/work.json"

  # Stub the app-server daemon lifecycle so switches don't spawn real app-servers.
  # Records the provider + resolved token codex-acct would hand the daemon on restart,
  # so tests can assert intent (see CODEX_ACCT_DAEMON_MANAGER in restart_daemon).
  cat > "$CODEX_HOME/daemon-manager" <<'SH'
#!/usr/bin/env bash
{ echo "provider=${1:-}"; echo "token=${2:-}"; } > "$CODEX_HOME/daemon-restart"
SH
  chmod +x "$CODEX_HOME/daemon-manager"
  export CODEX_ACCT_DAEMON_MANAGER="$CODEX_HOME/daemon-manager"
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

setup_fake_op_and_codex_run() {
  local bin_dir="$TEST_ROOT/fake-bin"
  mkdir -p "$bin_dir"
  PATH="$bin_dir:$PATH"
  export PATH
  cat > "$bin_dir/op" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "read" ]]; then
  echo "read $2" >> "$CODEX_HOME/op-read-commands"
  case "${2:-}" in
    op://odin/gateway/token) printf '%s\n' "resolved-token" ;;
    op://odin/gateway/base-url) printf '%s\n' "https://gateway.example/api/odin/gateway" ;;
    op://odin/gateway/model) printf '%s\n' "gpt-5.5" ;;
    *) echo "unknown fake op ref: ${2:-}" >&2; exit 2 ;;
  esac
  exit 0
fi
if [[ "${1:-}" != "run" ]]; then
  echo "unsupported fake op command: $*" >&2
  exit 2
fi
shift
env_file=""
while (($#)); do
  case "$1" in
    --env-file)
      env_file="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      shift
      ;;
  esac
done
[[ -n "$env_file" ]] || { echo "missing --env-file" >&2; exit 2; }
printf '%s\n' "$*" >> "$CODEX_HOME/op-run-commands"
set -a
. "$env_file"
set +a
exec "$@"
SH
  chmod +x "$bin_dir/op"
  cat > "$bin_dir/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
{
  echo "token=${ODIN_GATEWAY_TOKEN:-}"
  echo "args=$*"
} > "$CODEX_HOME/codex-run"
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

test_provider_switch_writes_odin_config_without_clobbering_other_sections() {
  setup_home provider-odin
  cat > "$CODEX_HOME/config.toml" <<'TOML'
model = "gpt-5"
sandbox_mode = "workspace-write"

[projects."/tmp/example"]
trust_level = "trusted"
TOML

  ODIN_GATEWAY_TOKEN=test-token "$ROOT/codex-acct" use odin --base-url https://gateway.example/api/odin/gateway --model gpt-5.5 >/dev/null

  assert_eq gpt-5.5 "$(toml_get "$CODEX_HOME/config.toml" model)" "odin switch set model"
  assert_eq odin "$(toml_get "$CODEX_HOME/config.toml" model_provider)" "odin switch set provider"
  assert_eq "https://gateway.example/api/odin/gateway/openai/v1" "$(toml_get "$CODEX_HOME/config.toml" model_providers.odin.base_url)" "odin switch normalized base URL"
  assert_eq ODIN_GATEWAY_TOKEN "$(toml_get "$CODEX_HOME/config.toml" model_providers.odin.env_key)" "odin switch set env key"
  assert_eq trusted "$(toml_project_trust "$CODEX_HOME/config.toml" /tmp/example)" "odin switch preserved project trust"
  assert_eq odin "$(cat "$CODEX_HOME/providers/.active")" "odin switch recorded active provider"
}

test_use_odin_reads_default_env_file_without_outer_op_run() {
  setup_home provider-odin-env
  setup_fake_op_and_codex_run
  cat > "$CODEX_HOME/odin.env" <<'SH'
ODIN_GATEWAY_BASE_URL=https://gateway.example/api/odin/gateway
ODIN_GATEWAY_MODEL=gpt-5.4
ODIN_GATEWAY_TOKEN=test-token
SH

  CODEX_ACCT_ODIN_ENV_FILE="$CODEX_HOME/odin.env" "$ROOT/codex-acct" use odin --no-daemon-restart >/dev/null

  assert_eq gpt-5.4 "$(toml_get "$CODEX_HOME/config.toml" model)" "use odin read model from env file"
  assert_eq odin "$(toml_get "$CODEX_HOME/config.toml" model_provider)" "use odin read provider from env file"
  assert_eq "https://gateway.example/api/odin/gateway/openai/v1" "$(toml_get "$CODEX_HOME/config.toml" model_providers.odin.base_url)" "use odin read base URL from env file"
}

test_codex_run_loads_odin_env_before_launch() {
  setup_home provider-odin-run
  setup_fake_op_and_codex_run
  cat > "$CODEX_HOME/odin.env" <<'SH'
ODIN_GATEWAY_BASE_URL=https://gateway.example/api/odin/gateway
ODIN_GATEWAY_MODEL=gpt-5.5
ODIN_GATEWAY_TOKEN=test-token
SH
  cat > "$CODEX_HOME/config.toml" <<'TOML'
model = "gpt-5.5"
model_provider = "odin"

[model_providers.odin]
name = "Odin Gateway"
base_url = "https://gateway.example/api/odin/gateway/openai/v1"
env_key = "ODIN_GATEWAY_TOKEN"
wire_api = "responses"
TOML

  CODEX_ACCT_ODIN_ENV_FILE="$CODEX_HOME/odin.env" "$ROOT/codex-acct" codex exec "hi"

  assert_eq test-token "$(sed -n 's/^token=//p' "$CODEX_HOME/codex-run")" "codex run loaded Odin token from env file"
  assert_eq "exec hi" "$(sed -n 's/^args=//p' "$CODEX_HOME/codex-run")" "codex run preserved args"
  if [[ -f "$CODEX_HOME/op-run-commands" ]] && grep -q '^codex ' "$CODEX_HOME/op-run-commands"; then
    echo "FAIL: codex run should not wrap the Codex TUI with op run" >&2
    exit 1
  fi
}

test_codex_run_resolves_1password_env_refs_before_launch() {
  setup_home provider-odin-op-read
  setup_fake_op_and_codex_run
  cat > "$CODEX_HOME/odin.env" <<'SH'
ODIN_GATEWAY_BASE_URL=op://odin/gateway/base-url
ODIN_GATEWAY_MODEL=op://odin/gateway/model
ODIN_GATEWAY_TOKEN=op://odin/gateway/token
SH
  cat > "$CODEX_HOME/config.toml" <<'TOML'
model = "gpt-5.5"
model_provider = "odin"

[model_providers.odin]
name = "Odin Gateway"
base_url = "https://gateway.example/api/odin/gateway/openai/v1"
env_key = "ODIN_GATEWAY_TOKEN"
wire_api = "responses"
TOML

  CODEX_ACCT_ODIN_ENV_FILE="$CODEX_HOME/odin.env" "$ROOT/codex-acct" codex exec "hi"

  assert_eq resolved-token "$(sed -n 's/^token=//p' "$CODEX_HOME/codex-run")" "codex run resolved Odin token with op read"
  if [[ ! -f "$CODEX_HOME/op-read-commands" ]] || ! grep -q 'op://odin/gateway/token' "$CODEX_HOME/op-read-commands"; then
    echo "FAIL: codex run should resolve token ref with op read" >&2
    exit 1
  fi
  if [[ -f "$CODEX_HOME/op-run-commands" ]] && grep -q '^codex ' "$CODEX_HOME/op-run-commands"; then
    echo "FAIL: codex run should not wrap the Codex TUI with op run" >&2
    exit 1
  fi
}

test_install_wrapper_routes_plain_codex_through_switcher() {
  setup_home plain-codex-wrapper
  setup_fake_op_and_codex_run
  local bin_dir="$TEST_ROOT/plain-wrapper-bin"
  mkdir -p "$bin_dir"
  PATH="$bin_dir:$PATH"
  export PATH
  cat > "$bin_dir/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
{
  echo "real=$0"
  echo "token=${ODIN_GATEWAY_TOKEN:-}"
  echo "args=$*"
} > "$CODEX_HOME/plain-codex-run"
SH
  chmod +x "$bin_dir/codex"
  cat > "$CODEX_HOME/odin.env" <<'SH'
ODIN_GATEWAY_BASE_URL=https://gateway.example/api/odin/gateway
ODIN_GATEWAY_MODEL=gpt-5.5
ODIN_GATEWAY_TOKEN=test-token
SH
  cat > "$CODEX_HOME/config.toml" <<'TOML'
model = "gpt-5.5"
model_provider = "odin"

[model_providers.odin]
name = "Odin Gateway"
base_url = "https://gateway.example/api/odin/gateway/openai/v1"
env_key = "ODIN_GATEWAY_TOKEN"
wire_api = "responses"
TOML

  CODEX_ACCT_CODEX_WRAPPER="$bin_dir/codex" \
    CODEX_ACCT_REAL_CODEX="$bin_dir/codex.codex-acct-real" \
    "$ROOT/codex-acct" install-wrapper >/dev/null

  CODEX_ACCT_ODIN_ENV_FILE="$CODEX_HOME/odin.env" "$bin_dir/codex" exec hi

  assert_eq "$bin_dir/codex.codex-acct-real" "$(sed -n 's/^real=//p' "$CODEX_HOME/plain-codex-run")" "plain codex used preserved real binary"
  assert_eq test-token "$(sed -n 's/^token=//p' "$CODEX_HOME/plain-codex-run")" "plain codex loaded Odin token from env file"
  assert_eq "exec hi" "$(sed -n 's/^args=//p' "$CODEX_HOME/plain-codex-run")" "plain codex preserved args"
  if [[ -f "$CODEX_HOME/op-run-commands" ]] && grep -q '^codex ' "$CODEX_HOME/op-run-commands"; then
    echo "FAIL: plain codex should not wrap the real Codex binary with op run" >&2
    exit 1
  fi
}

test_list_shows_odin_as_virtual_slot() {
  setup_home provider-list
  cp "$CODEX_HOME/accounts/personal.json" "$CODEX_HOME/auth.json"
  printf personal > "$CODEX_HOME/accounts/.active"
  cat > "$CODEX_HOME/config.toml" <<'TOML'
model = "gpt-5.5"
TOML

  "$ROOT/codex-acct" list > "$CODEX_HOME/list.out"

  if ! grep -q '^odin[[:space:]]\+(provider)' "$CODEX_HOME/list.out"; then
    echo "FAIL: list should show odin virtual provider slot" >&2
    exit 1
  fi
}

test_use_real_account_leaves_normal_provider_unchanged() {
  setup_home real-account-provider
  cp "$CODEX_HOME/accounts/work.json" "$CODEX_HOME/auth.json"
  printf work > "$CODEX_HOME/accounts/.active"
  cat > "$CODEX_HOME/config.toml" <<'TOML'
model = "gpt-5.4"
sandbox_mode = "workspace-write"

[projects."/tmp/example"]
trust_level = "trusted"
TOML

  "$ROOT/codex-acct" use personal >/dev/null

  assert_eq gpt-5.4 "$(toml_get "$CODEX_HOME/config.toml" model)" "normal account switch preserved model"
  assert_eq "" "$(toml_get_optional "$CODEX_HOME/config.toml" model_provider)" "normal account switch preserved default provider"
  assert_eq trusted "$(toml_project_trust "$CODEX_HOME/config.toml" /tmp/example)" "normal account switch preserved project trust"
}

test_use_real_account_after_odin_restores_normal_provider() {
  setup_home odin-to-real
  cp "$CODEX_HOME/accounts/work.json" "$CODEX_HOME/auth.json"
  printf work > "$CODEX_HOME/accounts/.active"
  cat > "$CODEX_HOME/config.toml" <<'TOML'
model = "gpt-5.5"
model_provider = "odin"
sandbox_mode = "workspace-write"

[model_providers.odin]
name = "Odin Gateway"
base_url = "https://gateway.example/api/odin/gateway/openai/v1"
env_key = "ODIN_GATEWAY_TOKEN"
wire_api = "responses"

[projects."/tmp/example"]
trust_level = "trusted"
TOML

  "$ROOT/codex-acct" use personal >/dev/null

  assert_eq gpt-5.5 "$(toml_get "$CODEX_HOME/config.toml" model)" "real account after odin preserved model"
  assert_eq "" "$(toml_get_optional "$CODEX_HOME/config.toml" model_provider)" "real account after odin restored default provider"
  assert_eq "https://gateway.example/api/odin/gateway/openai/v1" "$(toml_get "$CODEX_HOME/config.toml" model_providers.odin.base_url)" "real account after odin preserved odin block"
  assert_eq openai "$(cat "$CODEX_HOME/providers/.active")" "real account after odin recorded normal provider"
}

test_openai_can_be_a_saved_account_name() {
  setup_home openai-account-name
  make_auth openai-sub openai@example.test openai-r1 "$CODEX_HOME/accounts/openai.json"
  cp "$CODEX_HOME/accounts/work.json" "$CODEX_HOME/auth.json"
  printf work > "$CODEX_HOME/accounts/.active"

  "$ROOT/codex-acct" use openai >/dev/null

  assert_eq openai-r1 "$(refresh_token "$CODEX_HOME/auth.json")" "openai remains usable as a normal account name"
  assert_eq openai "$(cat "$CODEX_HOME/accounts/.active")" "openai account marked active"
}

test_provider_switch_openai_removes_top_level_provider_and_preserves_odin_block() {
  setup_home provider-openai
  cat > "$CODEX_HOME/config.toml" <<'TOML'
model = "gpt-5.5"
model_provider = "odin"
sandbox_mode = "workspace-write"

[model_providers.odin]
name = "Odin Gateway"
base_url = "https://gateway.example/api/odin/gateway/openai/v1"
env_key = "ODIN_GATEWAY_TOKEN"
wire_api = "responses"

[projects."/tmp/example"]
trust_level = "trusted"
TOML

  "$ROOT/codex-acct" provider use openai --model gpt-5.4 >/dev/null

  assert_eq gpt-5.4 "$(toml_get "$CODEX_HOME/config.toml" model)" "openai switch set model"
  assert_eq "" "$(toml_get_optional "$CODEX_HOME/config.toml" model_provider)" "openai switch removed explicit provider"
  assert_eq "https://gateway.example/api/odin/gateway/openai/v1" "$(toml_get "$CODEX_HOME/config.toml" model_providers.odin.base_url)" "openai switch preserved odin block"
  assert_eq trusted "$(toml_project_trust "$CODEX_HOME/config.toml" /tmp/example)" "openai switch preserved project trust"
  assert_eq openai "$(cat "$CODEX_HOME/providers/.active")" "openai switch recorded active provider"
}

test_daemon_restart_carries_odin_token_and_clears_it_for_openai() {
  setup_home daemon-env
  setup_fake_op_and_codex_run
  cat > "$CODEX_HOME/odin.env" <<'SH'
ODIN_GATEWAY_BASE_URL=op://odin/gateway/base-url
ODIN_GATEWAY_MODEL=op://odin/gateway/model
ODIN_GATEWAY_TOKEN=op://odin/gateway/token
SH

  # Switch to odin WITH a daemon restart: the daemon must be handed the resolved token,
  # because env_key is read in the daemon process, not the client.
  CODEX_ACCT_ODIN_ENV_FILE="$CODEX_HOME/odin.env" "$ROOT/codex-acct" use odin >/dev/null
  assert_eq odin "$(sed -n 's/^provider=//p' "$CODEX_HOME/daemon-restart")" "odin switch restarts daemon as odin"
  assert_eq resolved-token "$(sed -n 's/^token=//p' "$CODEX_HOME/daemon-restart")" "odin switch hands the resolved token to the daemon"

  # Switch back to the default provider: the daemon must come up with no Odin token.
  "$ROOT/codex-acct" provider use openai --model gpt-5.4 >/dev/null
  assert_eq openai "$(sed -n 's/^provider=//p' "$CODEX_HOME/daemon-restart")" "openai switch restarts daemon as openai"
  assert_eq "" "$(sed -n 's/^token=//p' "$CODEX_HOME/daemon-restart")" "openai switch clears the odin token from the daemon env"
}

test_provider_status_without_active_marker_succeeds() {
  setup_home provider-status
  cat > "$CODEX_HOME/config.toml" <<'TOML'
model = "gpt-5.5"
TOML

  "$ROOT/codex-acct" provider status > "$CODEX_HOME/status.out"

  if ! grep -q "provider: openai" "$CODEX_HOME/status.out"; then
    echo "FAIL: provider status should show default OpenAI provider" >&2
    exit 1
  fi
}

test_sync_does_not_overwrite_stale_active_slot
test_switch_preserves_live_account_even_when_active_matches_target
test_same_account_duplicate_slots_are_not_overwritten_when_ambiguous
test_sync_does_not_save_previous_snapshot
test_add_does_not_revoke_or_expose_previous_auth_to_login
test_provider_switch_writes_odin_config_without_clobbering_other_sections
test_use_odin_reads_default_env_file_without_outer_op_run
test_codex_run_loads_odin_env_before_launch
test_codex_run_resolves_1password_env_refs_before_launch
test_install_wrapper_routes_plain_codex_through_switcher
test_list_shows_odin_as_virtual_slot
test_use_real_account_leaves_normal_provider_unchanged
test_use_real_account_after_odin_restores_normal_provider
test_openai_can_be_a_saved_account_name
test_provider_switch_openai_removes_top_level_provider_and_preserves_odin_block
test_daemon_restart_carries_odin_token_and_clears_it_for_openai
test_provider_status_without_active_marker_succeeds

echo "ok"
