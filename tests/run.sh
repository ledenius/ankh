#!/usr/bin/env bash
# Functional tests: every command runs against a throwaway HOME, GNUPGHOME and
# pass store, never the real ones.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANKH="$here/../ankh"

pass_count=0
fail_count=0

check() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "ok - $desc"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL - $desc"
    echo "  expected: $expected"
    echo "  actual:   $actual"
    fail_count=$((fail_count + 1))
  fi
}

check_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "ok - $desc"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL - $desc (expected to contain: $needle)"
    echo "  actual: $haystack"
    fail_count=$((fail_count + 1))
  fi
}

check_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "ok - $desc"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL - $desc (should not contain: $needle)"
    echo "  actual: $haystack"
    fail_count=$((fail_count + 1))
  fi
}

# A scratch home under /tmp: gpg-agent's socket path must stay short.
scratch_dirs=()
agents=()
cleanup() {
  local d
  for d in "${scratch_dirs[@]}"; do
    GNUPGHOME="$d/gnupg" gpgconf --kill all 2>/dev/null || true
    rm -rf "$d"
  done
  local a
  for a in "${agents[@]}"; do kill "$a" 2>/dev/null || true; done
}
trap cleanup EXIT

new_home() {
  local d
  d="$(mktemp -d /tmp/ankh-test.XXXXXX)"
  scratch_dirs+=("$d")
  mkdir -p "$d/home" "$d/gnupg"
  chmod 700 "$d/gnupg"
  printf '%s' "$d"
}

# Runs ankh in a scratch home; the caller's agents are never reachable.
run_ankh() {
  local d="$1"
  shift
  env -u SSH_AUTH_SOCK -u GPG_TTY HOME="$d/home" GNUPGHOME="$d/gnupg" \
    PASSWORD_STORE_DIR="$d/store" ${TEST_SSH_AUTH_SOCK:+SSH_AUTH_SOCK="$TEST_SSH_AUTH_SOCK"} \
    bash "$ANKH" "$@" </dev/null 2>&1
}

# A key like ankh generates, without a passphrase so tests need no pinentry.
make_key() {
  local d="$1" uid="${2:-Test User <test@example.invalid>}"
  local g=(env GNUPGHOME="$d/gnupg" gpg --batch --quiet --pinentry-mode loopback --passphrase '')
  "${g[@]}" --quick-generate-key "$uid" ed25519 cert 1y 2>/dev/null
  local fpr
  fpr="$(GNUPGHOME="$d/gnupg" gpg --with-colons --list-keys "$uid" 2>/dev/null | awk -F: '/^fpr/{print $10; exit}')"
  "${g[@]}" --quick-add-key "$fpr" ed25519 sign 1y 2>/dev/null
  "${g[@]}" --quick-add-key "$fpr" ed25519 auth 1y 2>/dev/null
  "${g[@]}" --quick-add-key "$fpr" cv25519 encr 1y 2>/dev/null
  printf '%s' "$fpr"
}

make_store() {
  local d="$1" fpr="$2"
  HOME="$d/home" GNUPGHOME="$d/gnupg" PASSWORD_STORE_DIR="$d/store" pass init "$fpr" >/dev/null
  printf 'canary-value-must-not-appear\n' |
    HOME="$d/home" GNUPGHOME="$d/gnupg" PASSWORD_STORE_DIR="$d/store" pass insert -m example.invalid/login >/dev/null
}

# --- the banner and usage ---------------------------------------------------

d="$(new_home)"
out="$(run_ankh "$d")"
rc=$?
check "plain ankh exits 0" "0" "$rc"
check_contains "plain ankh prints the banner" "█████╗" "$out"
check_contains "plain ankh prints the usage" "Usage: ankh" "$out"

out="$(run_ankh "$d" nonsense)"
rc=$?
check "an unknown command exits 1" "1" "$rc"
check_not_contains "an unknown command prints no banner" "█████╗" "$out"

out="$(run_ankh "$d" version)"
check_contains "version prints the version" "ankh 0." "$out"

# --- check: an empty machine ------------------------------------------------

d="$(new_home)"
out="$(run_ankh "$d" check)"
rc=$?
check "check on an empty machine exits 1" "1" "$rc"
check_contains "no keys is a failure" "FAIL  no secret keys" "$out"
check_contains "no store is a failure" "FAIL  no store at" "$out"
check_contains "no SSH key is a failure" "FAIL  no SSH key" "$out"
check_contains "no agent is a warning" "warn  no agent: SSH_AUTH_SOCK is not set" "$out"

# --- check: a key and a store -----------------------------------------------

d="$(new_home)"
fpr="$(make_key "$d")"
make_store "$d" "$fpr"
out="$(run_ankh "$d" check)"
check_contains "the key is listed" "ok    $fpr Test User <test@example.invalid>" "$out"
check_contains "the primary key is reported present" "primary  certify  on this machine" "$out"
check_contains "the store's recipient is matched" "which this machine has" "$out"
check_contains "the decrypt is skipped by default" "test decrypt skipped" "$out"
check_not_contains "the entry's value never appears" "canary-value" "$out"

out="$(run_ankh "$d" check --decrypt)"
check_contains "check --decrypt decrypts" "ok    test decrypt succeeded" "$out"
check_not_contains "check --decrypt never shows the value" "canary-value" "$out"

# A store encrypted to someone else's key.
d2="$(new_home)"
make_key "$d2" >/dev/null
mkdir -p "$d2/store"
cp -r "$d/store/." "$d2/store/"
out="$(run_ankh "$d2" check)"
check_contains "a store for another key is a failure" "none of them is usable here" "$out"

# Only subkeys on the machine: the primary key is a stub.
d3="$(new_home)"
GNUPGHOME="$d/gnupg" gpg --batch --pinentry-mode loopback --passphrase '' \
  --export-secret-subkeys "$fpr" 2>/dev/null | GNUPGHOME="$d3/gnupg" gpg --batch --quiet --import 2>/dev/null
out="$(run_ankh "$d3" check)"
check_contains "a primary stub is reported" "primary  certify  not on this machine (stub)" "$out"
check_not_contains "a stub gets no removal hint" "once backed up" "$out"

# --- check: SSH --------------------------------------------------------------

mkdir -p "$d/home/.ssh/keys"
ssh-keygen -q -t ed25519 -N '' -C test -f "$d/home/.ssh/keys/test" >/dev/null
ssh-keygen -q -t ed25519 -N '' -C work -f "$d/home/.ssh/work" >/dev/null
sock="$d/agent.sock"
eval "$(ssh-agent -a "$sock" -s)" >/dev/null
agents+=("$SSH_AGENT_PID")

out="$(TEST_SSH_AUTH_SOCK="$sock" run_ankh "$d" check)"
check_contains "an empty agent is found" "no keys loaded" "$out"
check_contains "keys in ~/.ssh and ~/.ssh/keys are both found" "2 key(s) on disk" "$out"
check_contains "a key in ~/.ssh is reported" "not loaded  ~/.ssh/work.pub" "$out"
check_contains "an unloaded key is reported" "not loaded  ~/.ssh/keys/test.pub" "$out"

SSH_AUTH_SOCK="$sock" ssh-add -q "$d/home/.ssh/keys/test" 2>/dev/null
out="$(TEST_SSH_AUTH_SOCK="$sock" run_ankh "$d" check)"
check_contains "a loaded key is reported" "loaded      ~/.ssh/keys/test.pub" "$out"
check_contains "the agent counts its keys" "1 key(s) loaded" "$out"

out="$(TEST_SSH_AUTH_SOCK="$d/missing.sock" run_ankh "$d" check)"
check_contains "a missing socket is a warning" "is not a socket" "$out"

# gpg-agent as the SSH agent: the authentication subkey and sshcontrol.
GNUPGHOME="$d/gnupg" gpg-connect-agent /bye >/dev/null 2>&1
gsock="$(GNUPGHOME="$d/gnupg" gpgconf --list-dirs agent-ssh-socket)"
echo enable-ssh-support >>"$d/gnupg/gpg-agent.conf"
GNUPGHOME="$d/gnupg" gpgconf --kill gpg-agent
GNUPGHOME="$d/gnupg" gpg-connect-agent /bye >/dev/null 2>&1
out="$(TEST_SSH_AUTH_SOCK="$gsock" run_ankh "$d" check)"
check_contains "gpg-agent is recognised" "gpg-agent at $gsock" "$out"
check_contains "an unlisted authentication subkey is reported" "not offered authentication subkey" "$out"
grip="$(GNUPGHOME="$d/gnupg" gpg --with-colons --with-keygrip --list-secret-keys "$fpr" |
  awk -F: '/^ssb/{a=($12 ~ /a/)} /^grp/ && a{print $10; exit}')"
echo "$grip" >>"$d/gnupg/sshcontrol"
out="$(TEST_SSH_AUTH_SOCK="$gsock" run_ankh "$d" check)"
check_contains "a listed authentication subkey is offered" "offered     authentication subkey $grip" "$out"

echo ""
echo "$pass_count passed, $fail_count failed"
[[ $fail_count -eq 0 ]]
