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
  # new_home <var>: sets var, not a $(...) subshell, so cleanup sees the dir.
  local _nh_dir
  _nh_dir="$(mktemp -d /tmp/ankh-test.XXXXXX)"
  scratch_dirs+=("$_nh_dir")
  mkdir -p "$_nh_dir/home" "$_nh_dir/gnupg"
  chmod 700 "$_nh_dir/gnupg"
  printf -v "$1" '%s' "$_nh_dir"
}

# Scratch homes, set by new_home.
d="" d2="" d3="" d4="" d5=""

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

new_home d
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

new_home d
out="$(run_ankh "$d" check)"
rc=$?
check "check on an empty machine exits 1" "1" "$rc"
check_contains "no keys is a failure" "FAIL  no secret keys" "$out"
check_contains "no store is a failure" "FAIL  no store at" "$out"
check_contains "no SSH key is a failure" "FAIL  no SSH key" "$out"
check_contains "no agent is a warning" "warn  no agent: SSH_AUTH_SOCK is not set" "$out"

# --- check: a key and a store -----------------------------------------------

new_home d
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
new_home d2
make_key "$d2" >/dev/null
mkdir -p "$d2/store"
cp -r "$d/store/." "$d2/store/"
out="$(run_ankh "$d2" check)"
check_contains "a store for another key is a failure" "none of them is usable here" "$out"

# Only subkeys on the machine: the primary key is a stub.
new_home d3
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

# --- key and backup: through gpg-agent and a fake pinentry ------------------

# A pinentry that answers every GETPIN with a fixed passphrase, the way a
# user would; gpg-agent drives it exactly as it drives a real one.
with_pinentry() {
  local d="$1" pw="$2"
  cat >"$d/pinentry" <<PIN
#!/usr/bin/env bash
echo "OK Pleased to meet you"
while IFS= read -r line; do
  case "\$line" in
  GETPIN*) printf 'D %s\nOK\n' '$pw' ;;
  BYE*) echo OK; exit 0 ;;
  *) echo OK ;;
  esac
done
PIN
  chmod +x "$d/pinentry"
  echo "pinentry-program $d/pinentry" >"$d/gnupg/gpg-agent.conf"
}

hex40='^[0-9A-F]{40}$'

new_home d
with_pinentry "$d" "first passphrase"
mkdir -p "$d/home/.ssh"
ssh-keygen -q -t ed25519 -N '' -C laptop -f "$d/home/.ssh/id_ed25519" >/dev/null
out="$(key_source=generate gpg_name="Gen User" gpg_email=gen@example.invalid run_ankh "$d" -y key)"
fpr="$(awk '/^key /{print $2}' <<<"$out")"
check "key --generate prints a fingerprint" "1" "$([[ "$fpr" =~ $hex40 ]] && echo 1)"
caps="$(GNUPGHOME="$d/gnupg" gpg --with-colons --list-secret-keys "$fpr" 2>/dev/null | awk -F: '/^(sec|ssb)/{printf "%s %s %s|", $1, $4, $12}')"
check_contains "the primary is ed25519 and itself only certifies" "sec 22 cESCA" "$caps"
check_contains "an ed25519 signing subkey" "ssb 22 s|" "$caps"
check_contains "an ed25519 authentication subkey" "ssb 22 a|" "$caps"
check_contains "a cv25519 encryption subkey" "ssb 18 e|" "$caps"
check_contains "ownertrust is ultimate" "$fpr:6:" "$(GNUPGHOME="$d/gnupg" gpg --export-ownertrust 2>/dev/null)"
check_contains "the backup is suggested" "ankh backup" "$out"

out="$(run_ankh "$d" -y key --existing)"
check_contains "key --existing takes the only key" "key $fpr" "$out"

b="$d/backup"
out="$(run_ankh "$d" -y backup "$b")"
rc=$?
check "backup exits 0" "0" "$rc"
check_contains "the full key is verified" "ok: secret.asc restores the full key" "$out"
check_contains "the subkeys are verified" "ok: subkeys.asc restores the subkeys" "$out"
for f in secret.asc subkeys.asc public.asc revocation.asc ownertrust.txt README.txt ssh/id_ed25519 ssh/id_ed25519.pub; do
  check "backup holds $f" "1" "$([[ -f "$b/$f" ]] && echo 1)"
done
check "the backup directory is private" "700" "$(stat -c %a "$b")"
check "the backup's files are private" "600" "$(stat -c %a "$b/secret.asc")"
check_contains "the README names the fingerprint" "fingerprint: $fpr" "$(cat "$b/README.txt")"
check "the primary is still here without --remove-primary" "1" \
  "$(GNUPGHOME="$d/gnupg" gpg --with-colons --list-secret-keys "$fpr" | awk -F: '/^sec/{print ($15=="" || $15=="+") ? 1 : 0}')"

out="$(run_ankh "$d" -y backup "$b")"
rc=$?
check "backup into a non-empty directory exits 1" "1" "$rc"
check_contains "and says why" "is not empty" "$out"

git init -q "$d/repo"
out="$(run_ankh "$d" -y backup "$d/repo/backup")"
check_contains "backup refuses a git work tree" "inside a git work tree" "$out"

# Restoring onto another machine: subkeys by default, the full key on request.
new_home d2
with_pinentry "$d2" "first passphrase"
out="$(key_source=import key_file="$b" run_ankh "$d2" -y key)"
check_contains "import from a backup takes its key" "key $fpr" "$out"
out="$(run_ankh "$d2" check)"
check_contains "a backup import is subkeys only by default" "primary  certify  not on this machine (stub)" "$out"

new_home d3
with_pinentry "$d3" "first passphrase"
key_source=import key_file="$b" key_import=full run_ankh "$d3" -y key >/dev/null
out="$(run_ankh "$d3" check)"
check_contains "key_import=full restores the primary" "primary  certify  on this machine" "$out"

new_home d5
out="$(key_source=import key_file="$b/public.asc" run_ankh "$d5" -y key)"
check_contains "a file without a secret key is refused" "exactly one secret key" "$out"

# Sealed: one archive and a README, and it restores.
s="$d/sealed"
out="$(run_ankh "$d" -y backup "$s" --encrypt)"
check_contains "an encrypted backup is written" "backup $s" "$out"
check "an encrypted backup holds only the archive and a README" "README.txt ankh-backup.tar.gpg" "$(find "$s" -mindepth 1 -printf '%P\n' | LC_ALL=C sort | paste -sd " ")"
new_home d4
with_pinentry "$d4" "first passphrase"
out="$(key_source=import key_file="$s" run_ankh "$d4" -y key)"
check_contains "an encrypted backup restores" "key $fpr" "$out"

# --remove-primary leaves the subkeys and a stub.
out="$(run_ankh "$d" -y backup "$d/final" --remove-primary)"
check_contains "--remove-primary removes it" "the primary key is gone from this machine" "$out"
out="$(run_ankh "$d" check)"
check_contains "after removal the primary is a stub" "primary  certify  not on this machine (stub)" "$out"
check_contains "the subkeys stay after the removal" "encrypt" "$out"
out="$(run_ankh "$d" -y backup "$d/after")"
check_contains "a backup without the primary says so" "the backup holds the subkeys only" "$out"
check "and writes no secret.asc" "" "$([[ -f "$d/after/secret.asc" ]] && echo 1)"

echo ""
echo "$pass_count passed, $fail_count failed"
[[ $fail_count -eq 0 ]]
