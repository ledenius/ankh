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

# --- pass, ssh and init --------------------------------------------------------

d6="" d7="" d8=""
new_home d6
with_pinentry "$d6" "second passphrase"
key_source=generate gpg_name="Store User" gpg_email=store@example.invalid run_ankh "$d6" -y key >/dev/null
sfpr="$(GNUPGHOME="$d6/gnupg" gpg --with-colons --list-secret-keys 2>/dev/null | awk -F: '/^fpr/{print $10; exit}')"

out="$(pass_source=new pass_remote="$d6/remote.git" run_ankh "$d6" -y pass)"
check_contains "pass --new starts a store" "pass $d6/store" "$out"
check "the new store is encrypted to the key" "$sfpr" "$(cat "$d6/store/.gpg-id")"
check "the new store is a git repository" "true" "$(git -C "$d6/store" rev-parse --is-inside-work-tree 2>/dev/null)"
check "the remote is set" "$d6/remote.git" "$(git -C "$d6/store" remote get-url origin)"

printf 'canary-value-must-not-appear\n' |
  HOME="$d6/home" GNUPGHOME="$d6/gnupg" PASSWORD_STORE_DIR="$d6/store" pass insert -m example.invalid/login >/dev/null
out="$(run_ankh "$d6" -y pass)"
check_contains "an existing store for this key is accepted" "already here, encrypted to this key" "$out"
check_not_contains "pass never shows a value" "canary-value" "$out"

# Clone onto a second machine that has the subkeys.
git init -q --bare -b main "$d6/remote.git"
git -C "$d6/store" push -q origin HEAD:refs/heads/main 2>/dev/null
new_home d7
with_pinentry "$d7" "second passphrase"
GNUPGHOME="$d6/gnupg" gpg --batch --pinentry-mode loopback --passphrase 'second passphrase' \
  --export-secret-subkeys "$sfpr" 2>/dev/null >"$d7/sub.asc"
key_source=import key_file="$d7/sub.asc" run_ankh "$d7" -y key >/dev/null
out="$(pass_source=clone pass_remote="$d6/remote.git" run_ankh "$d7" -y pass)"
check_contains "pass --clone clones the store" "cloning $d6/remote.git" "$out"
check_contains "and proves it decrypts" "test decrypt of one entry" "$out"
check_not_contains "a clone never shows a value" "canary-value" "$out"
check "a store on a machine without a git identity commits as the key's user" "store@example.invalid" "$(git -C "$d6/store" log -1 --format=%ae 2>/dev/null)"

# A store for someone else's key.
new_home d8
with_pinentry "$d8" "third passphrase"
key_source=generate gpg_name="Other User" gpg_email=other@example.invalid run_ankh "$d8" -y key >/dev/null
cp -r "$d6/store" "$d8/store"
out="$(run_ankh "$d8" -y pass)"
check_contains "a store for another key is refused" "encrypted to another key" "$out"

# SSH: generated, named and placed as asked, backed up into pass.
out="$(ssh_source=generate ssh_no_passphrase=1 run_ankh "$d6" -y ssh)"
k="$d6/home/.ssh/id_ed25519"
check_contains "ssh --generate makes ~/.ssh/id_ed25519 by default" "ssh $k" "$out"
check "the private key is 600" "600" "$(stat -c %a "$k")"
check "the public key is 644" "644" "$(stat -c %a "$k.pub")"
check "the .ssh directory is 700" "700" "$(stat -c %a "$d6/home/.ssh")"
check_contains "the public key is printed" "ssh-ed25519 " "$out"
check "the key is backed up into pass" "same" \
  "$(HOME="$d6/home" GNUPGHOME="$d6/gnupg" PASSWORD_STORE_DIR="$d6/store" pass show ssh/id_ed25519/key 2>/dev/null | cmp -s - "$k" && echo same)"

out="$(ssh_source=generate ssh_no_passphrase=1 run_ankh "$d6" -y ssh)"
check_contains "an existing key is never overwritten" "exists already" "$out"

out="$(ssh_source=generate ssh_no_passphrase=1 ssh_name=work ssh_dir="$d6/home/.ssh/keys" run_ankh "$d6" -y ssh)"
check_contains "the name and directory can be chosen" "ssh $d6/home/.ssh/keys/work" "$out"

# An existing key keeps its own name by default.
cp "$k" "$d7/laptop_key"
out="$(ssh_source=existing ssh_file="$d7/laptop_key" run_ankh "$d7" -y ssh)"
check_contains "an existing key keeps its name" "ssh $d7/home/.ssh/laptop_key" "$out"
check "its public key is derived when missing" "1" "$([[ -s "$d7/home/.ssh/laptop_key.pub" ]] && echo 1)"

# SSH through gpg-agent.
out="$(ssh_source=gpg run_ankh "$d6" -y ssh)"
sgrip="$(GNUPGHOME="$d6/gnupg" gpg --with-colons --with-keygrip --list-secret-keys "$sfpr" |
  awk -F: '/^ssb/{a=($12 ~ /a/)} /^grp/ && a{print $10; exit}')"
check_contains "ssh --gpg turns on SSH support" "enable-ssh-support" "$(cat "$d6/gnupg/gpg-agent.conf")"
check_contains "ssh --gpg lists the keygrip in sshcontrol" "$sgrip" "$(cat "$d6/gnupg/sshcontrol")"
check_contains "ssh --gpg prints the SSH_AUTH_SOCK line" "agent-ssh-socket" "$out"
check_contains "ssh --gpg prints the public key" "ssh-ed25519 " "$out"
gsock="$(GNUPGHOME="$d6/gnupg" gpgconf --list-dirs agent-ssh-socket)"
check "gpg-agent then offers it" "1" "$(SSH_AUTH_SOCK="$gsock" ssh-add -l 2>/dev/null | grep -c ED25519)"

# init, end to end, on an empty machine.
new_home d8
with_pinentry "$d8" "fourth passphrase"
out="$(key_source=generate gpg_name="Init User" gpg_email=init@example.invalid pass_source=new \
  ssh_source=generate ssh_no_passphrase=1 run_ankh "$d8" -y init)"
rc=$?
check "init on an empty machine ends well" "0" "$rc"
check_contains "init starts with a check" "check: 3 failed" "$out"
check_contains "init ends with a clean check" "check: 0 failed" "$out"
check "init leaves a key, a store and an SSH key" "1 1 1" \
  "$([[ -n "$(GNUPGHOME="$d8/gnupg" gpg --list-secret-keys 2>/dev/null)" ]] && echo -n 1; echo -n ' '
     [[ -f "$d8/store/.gpg-id" ]] && echo -n 1; echo -n ' '
     [[ -f "$d8/home/.ssh/id_ed25519" ]] && echo -n 1)"


# --- moving between machines ------------------------------------------------
# The other machine is a second scratch home; a stand-in for ssh runs the
# command there, so nothing reaches a real host or the real home.

o="" n1="" n2="" n3="" n4="" n5="" n6="" v=""
new_home o
mkdir -p "$o/run"
chmod 700 "$o/run"
cat >"$o/fakessh" <<'FAKE'
#!/usr/bin/env bash
# A stand-in for ssh: runs the command here, in the scratch home $FAKE_REMOTE.
sftp=0
while [[ $# -gt 0 ]]; do
  case "$1" in
  -O) exit 0 ;;
  -o | -p | -l | -i | -F | -S | -E | -c | -m | -b | -J | -W | -L | -R | -D | -e) shift 2 ;;
  -s) sftp=1 && shift ;;
  --) shift && break ;;
  -*) shift ;;
  *) break ;;
  esac
done
shift
r="$FAKE_REMOTE"
export HOME="$r/home" GNUPGHOME="$r/gnupg" PASSWORD_STORE_DIR="$r/store" XDG_RUNTIME_DIR="$r/run"
unset SSH_AUTH_SOCK GPG_TTY
[[ $sftp -eq 1 ]] && exec "$FAKE_SFTP_SERVER"
[[ -n "${FAKE_NO_RSYNC:-}" && "$*" == "command -v rsync" ]] && exit 1
exec sh -c "$*"
FAKE
chmod +x "$o/fakessh"
FAKE_SFTP_SERVER="$(dirname "$(readlink -f "$(command -v ssh)")")/../libexec/sftp-server"
export FAKE_SFTP_SERVER

ofpr="$(make_key "$o" "Old Machine <old@example.invalid>")"
make_store "$o" "$ofpr"
git -C "$o/store" init -q
git -C "$o/store" config user.email old@example.invalid
git -C "$o/store" config user.name "Old Machine"
HOME="$o/home" GNUPGHOME="$o/gnupg" PASSWORD_STORE_DIR="$o/store" pass git init >/dev/null 2>&1
git -C "$o/store" remote add origin https://git.example.invalid/store.git
mkdir -p "$o/home/.ssh/keys"
chmod 700 "$o/home/.ssh"
ssh-keygen -q -t ed25519 -N '' -C old -f "$o/home/.ssh/id_ed25519" >/dev/null
ssh-keygen -q -t ed25519 -N '' -C work -f "$o/home/.ssh/keys/work" >/dev/null

move() {
  # move <here> <there> <ankh args...>: ankh in <here>, ssh reaching <there>.
  local here="$1" there="$2"
  shift 2
  ANKH_SSH="$o/fakessh" FAKE_REMOTE="$there" run_ankh "$here" "$@" --remote-ankh "bash $ANKH"
}

new_home n1
out="$(move "$n1" "$o" -y pull old.example.invalid)"
rc=$?
check "pull ends well" "0" "$rc"
check_contains "pull brings the key, the store and SSH" "received key pass ssh" "$out"
check "pull imports the subkeys only" "#" \
  "$(GNUPGHOME="$n1/gnupg" gpg --with-colons --list-secret-keys "$ofpr" 2>/dev/null | awk -F: '/^sec/{print $15}')"
check "pull sets ownertrust" "$ofpr:6:" "$(GNUPGHOME="$n1/gnupg" gpg --export-ownertrust 2>/dev/null | grep "^$ofpr:")"
check "pull clones the store" "1" "$([[ -f "$n1/store/.gpg-id" && -f "$n1/store/example.invalid/login.gpg" ]] && echo 1)"
check "the store keeps the old machine's remote" "https://git.example.invalid/store.git" \
  "$(git -C "$n1/store" remote get-url origin 2>/dev/null)"
check "the store decrypts here" "canary-value-must-not-appear" \
  "$(HOME="$n1/home" GNUPGHOME="$n1/gnupg" PASSWORD_STORE_DIR="$n1/store" pass show example.invalid/login 2>/dev/null)"
check "pull places the SSH keys as they were" "1 1" \
  "$(cmp -s "$o/home/.ssh/id_ed25519" "$n1/home/.ssh/id_ed25519" && echo -n 1; echo -n ' '
     cmp -s "$o/home/.ssh/keys/work" "$n1/home/.ssh/keys/work" && echo -n 1)"
check "placed private keys are 600" "600" "$(stat -c %a "$n1/home/.ssh/keys/work")"
check_not_contains "pull never prints a value" "canary-value" "$out"
check "pull leaves nothing behind on the old machine" "" "$(find "$o/run" -mindepth 1 -maxdepth 1)"

out="$(move "$n1" "$o" -y pull old.example.invalid)"
rc=$?
check "pulling again ends well" "0" "$rc"
check_contains "pulling again skips the store" "the bundle's store is skipped" "$out"
check_contains "pulling again skips keys already here" "is here already" "$out"

new_home n2
out="$(FAKE_NO_RSYNC=1 move "$n2" "$o" -y pull old.example.invalid key --with-primary)"
rc=$?
check "pull over scp ends well" "0" "$rc"
check_contains "pull key brings the key only" "received key" "$out"
check "--with-primary brings the primary too" "1" \
  "$(GNUPGHOME="$n2/gnupg" gpg --with-colons --list-secret-keys "$ofpr" 2>/dev/null | awk -F: '/^sec/ && $15 != "#" {print 1}')"
check "pull key leaves the store alone" "0" "$([[ -e "$n2/store" ]] && echo 1 || echo 0)"

new_home n3
out="$(move "$o" "$n3" -y send new.example.invalid ssh pass key)"
rc=$?
check "send ends well" "0" "$rc"
check_contains "send reports what it sent" "sent ssh pass key to new.example.invalid" "$out"
check "send gives the new machine the key" "#" \
  "$(GNUPGHOME="$n3/gnupg" gpg --with-colons --list-secret-keys "$ofpr" 2>/dev/null | awk -F: '/^sec/{print $15}')"
check "send gives it the store and SSH keys" "1 1" \
  "$([[ -f "$n3/store/.gpg-id" ]] && echo -n 1; echo -n ' '; [[ -f "$n3/home/.ssh/id_ed25519" ]] && echo -n 1)"
check "send leaves nothing behind on the new machine" "" "$(find "$o/run" -mindepth 1 -maxdepth 1)"

out="$(run_ankh "$o" -y send --paste pass)"
rc=$?
check "send --paste refuses the store" "1" "$rc"

out="$(run_ankh "$o" -y send --paste)"
rc=$?
check "send --paste ends well" "0" "$rc"
pw="$(grep -E '^    [a-z2-9]{4}(-[a-z2-9]{4}){5}$' <<<"$out" | tr -d ' ')"
check "send --paste shows a one-time passphrase" "1" "$([[ -n "$pw" ]] && echo 1)"
block="$(sed -n '/-----BEGIN PGP MESSAGE-----/,/-----END PGP MESSAGE-----/p' <<<"$out")"
check_contains "send --paste prints a sealed block" "-----END PGP MESSAGE-----" "$block"
check_not_contains "the block holds no readable key" "PRIVATE KEY" "$block"

new_home n4
with_pinentry "$n4" "$pw"
printf '%s\n' "$block" >"$n4/paste.asc"
out="$(run_ankh "$n4" -y receive "$n4/paste.asc")"
rc=$?
check "receive opens the block" "0" "$rc"
check_contains "receive takes the key and SSH" "received key ssh" "$out"
check "receive imports the subkeys" "#" \
  "$(GNUPGHOME="$n4/gnupg" gpg --with-colons --list-secret-keys "$ofpr" 2>/dev/null | awk -F: '/^sec/{print $15}')"
check "receive places the SSH keys" "1" "$(cmp -s "$o/home/.ssh/keys/work" "$n4/home/.ssh/keys/work" && echo 1)"

new_home n5
with_pinentry "$n5" "not the passphrase"
printf '%s\n' "$block" >"$n5/paste.asc"
out="$(run_ankh "$n5" -y receive "$n5/paste.asc")"
rc=$?
check "a wrong passphrase stops receive" "1" "$rc"
check_contains "and says so" "could not open the block" "$out"
check "and imports nothing" "" "$(GNUPGHOME="$n5/gnupg" gpg --list-secret-keys 2>/dev/null)"

new_home n6
mkdir -p "$n6/home/.ssh"
echo "another key" >"$n6/home/.ssh/id_ed25519"
out="$(move "$n6" "$o" -y pull old.example.invalid ssh)"
rc=$?
check "with -y, a taken place for an SSH key stops" "1" "$rc"
check "and the key there is untouched" "another key" "$(cat "$n6/home/.ssh/id_ed25519")"

mkdir -p "$n6/full"
touch "$n6/full/x"
out="$(run_ankh "$o" -y bundle "$n6/full" key)"
rc=$?
check "bundle refuses a non-empty directory" "1" "$rc"

# --- verify ------------------------------------------------------------------

new_home v
cp "$ANKH" "$v/ankh"
(cd "$v" && sha256sum ankh >good.sums)
printf '%064d  ankh\n' 0 >"$v/bad.sums"
printf '%064d  other\n' 0 >"$v/other.sums"
gone="http://127.0.0.1:9/SHA256SUMS"
for tool in "ankh verify" "ankh-verify"; do
  vrun() {
    if [[ "$tool" == "ankh verify" ]]; then
      run_ankh "$v" verify "$v/ankh" --no-default-checkpoints "$@"
    else
      bash "$here/../ankh-verify" "$v/ankh" --no-default-checkpoints "$@" 2>&1
    fi
  }
  out="$(vrun --checkpoint "$v/good.sums")"
  check "$tool: a matching checkpoint verifies" "0" "$?"
  check_contains "$tool: and says so" "verified $v/ankh (1 checkpoint(s))" "$out"
  out="$(vrun --checkpoint "file://$v/good.sums")"
  check "$tool: a file:// URL is a checkpoint" "0" "$?"
  out="$(vrun --checkpoint "$v/good.sums" --checkpoint "$v/bad.sums")"
  check "$tool: one mismatch is a hard stop" "1" "$?"
  check_contains "$tool: and says so" "MISMATCH" "$out"
  out="$(vrun --checkpoint "$gone" --checkpoint "$v/good.sums")"
  check "$tool: an unreachable checkpoint only warns" "0" "$?"
  check_contains "$tool: with a warning" "unreachable: $gone" "$out"
  out="$(vrun --checkpoint "$gone" --checkpoint "$v/missing.sums")"
  check "$tool: none reachable is a hard stop" "1" "$?"
  out="$(vrun --checkpoint "$v/other.sums")"
  check "$tool: a checkpoint not listing the file doesn't confirm it" "1" "$?"
  check_contains "$tool: and warns" "doesn't list ankh" "$out"
  out="$(vrun --checkpoint "$gone" --insecure-skip-verify)"
  check "$tool: --insecure-skip-verify goes on" "0" "$?"
  check_contains "$tool: loudly" "NOT verified" "$out"
  out="$(vrun --checkpoint "$v/bad.sums" --insecure-skip-verify)"
  check "$tool: --insecure-skip-verify never overrides a mismatch" "1" "$?"
  cp "$v/ankh" "$v/renamed"
  out="$(vrun --checkpoint "$v/good.sums" --as ankh)"
  check "$tool: --as names the file in the checksums" "0" "$?"
done
check_contains "the default checkpoints are the public mirrors" "codeberg.org/lede/ankh" "$(sed -n '/^_default_checkpoints/,/^}/p' "$ANKH")"
echo ""
echo "$pass_count passed, $fail_count failed"
[[ $fail_count -eq 0 ]]
