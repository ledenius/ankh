# ankh

Identity bootstrap for a freshly installed machine. ankh gets three things working, then stops:

1. **a gpg key:** from another machine, a backup, a file, a smartcard, or newly generated;
2. **a [pass](https://www.passwordstore.org/) store** that this key can decrypt;
3. **SSH.**

Everything after that (logins, service credentials, other secrets) is left to other tools. ankh only builds the foundation they stand on.

ankh is published on [Codeberg](https://codeberg.org/lede/ankh). Any copy can serve the script: releases are checked the same way wherever it came from.

## Status

Early. Today ankh has `init`, `check`, `key`, `backup`, `pass`, `ssh`, moving between machines (`pull`, `send`, `receive`) and `verify`. Still planned: smartcards (`card`).

## Install

ankh is a single bash script, and it handles your gpg key and your pass store. **Read it before you run it**, and install a release, not whatever `main` holds today:

```sh
git clone https://codeberg.org/lede/ankh.git
cd ankh
git checkout <release tag>
less ankh ankh-verify
./ankh-verify               # against the checksums on the mirrors
make install                # into ~/.local/bin
make install-completions    # bash, zsh and fish
```

Each release publishes `ankh`, `ankh-verify` and their checksums (`SHA256SUMS`). `ankh-verify` compares a copy against the checksums on every mirror. Keep a copy of the checksums somewhere you trust (your offline backup is a good place) and give it as a `--checkpoint` too.

Releases aren't signed yet. The mirrors copy one origin, so until they are, the checksums catch a tampered download host but not a release tampered with at its origin. A gpg signature over `SHA256SUMS`, and the fingerprint to check it against, come in a later release.

With Nix: `nix run --no-write-lock-file 'git+https://codeberg.org/lede/ankh?ref=refs/tags/<release tag>'` (the flake ships without a lock file, so it builds against your nixpkgs), or `homeManagerModules.default` from the flake.

## Requirements

| | |
|---|---|
| Required | bash 5+, gpg (with gpg-agent and a pinentry), git, pass, OpenSSH (ssh, ssh-keygen, ssh-add, scp) |
| Optional | rsync (used to copy between machines; scp otherwise), paperkey (printable backups), ykman (YubiKey touch policy), qrencode (QR codes for pasted bundles), curl or wget (fetching checkpoints) |

## init

```sh
ankh init
```

The whole bootstrap, in order: `check`, then `key`, `pass` and `ssh`, then `check` again. Each step asks what it needs.

## pass

```sh
ankh pass                         # check the store here, or ask how to get one
ankh pass --clone <git url>       # clone your existing store
ankh pass --new [--remote <url>]  # a new store, encrypted to the key
```

- A store that's already here is accepted only if it's encrypted to a key this machine has.
- A store encrypted to another key is refused, with the `pass init` that would re-encrypt it.
- After a clone, one entry is decrypted to prove the key works; the value is discarded.
- **Git identity:** pass commits every change. If git doesn't know who you are yet (common on a fresh machine), the store gets a local identity from the gpg key's user ID.

## ssh

```sh
ankh ssh                           # choose interactively
ankh ssh --generate                # a new ed25519 key
ankh ssh --existing <private key>  # place a key from a backup or a stick
ankh ssh --gpg                     # the gpg key's authentication subkey, through gpg-agent
ankh ssh --fido2                   # an ed25519-sk key on a security key (untested yet)
```

- **Placing a key:** ankh asks each key's name and directory. The defaults are its own name (`id_ed25519` for a new key) and `~/.ssh`. An existing file is never overwritten.
- **Passphrases** are asked by `ssh-keygen`. `--no-passphrase` skips it, with a warning.
- **Backups:** key files are backed up into pass as `ssh/<name>/key`, once there's a store.
- **The public key** is printed at the end, ready for `authorized_keys` and your git hosts.
- **`--gpg`:**
  - turns on `enable-ssh-support` in `gpg-agent.conf`, after asking;
  - adds the chosen authentication subkey's keygrip to `sshcontrol`;
  - prints the `SSH_AUTH_SOCK` line for your shell config. Your shell config is never edited.

## check

```sh
ankh check            # reads and reports; changes nothing
ankh check --decrypt  # also decrypts one entry; the value is discarded
```

Reports, section by section:
- **tools:** what's installed and the versions;
- **gpg-agent:** reachable, its pinentry, `GPG_TTY` against this terminal;
- **keys:** each secret key and subkey, its use, where it lives (on this machine, a stub, or on a card), its expiry, and a card if one is present;
- **pass:** the store, its git remote, and whether its entries are encrypted to a subkey this machine has. That's read from the entries' headers, with no decryption. A real test decrypt only runs with `--decrypt`;
- **ssh:** the keys on disk, which agent `SSH_AUTH_SOCK` points to (gpg-agent, ssh-agent, a forwarded one, GNOME Keyring, macOS's), which keys it holds, and, for gpg-agent, which authentication subkeys `sshcontrol` offers.

Each line is `ok`, `warn`, `FAIL` (a required piece is missing or broken) or `--` (for information). The exit status is 1 when anything failed.

`GNUPGHOME` and `PASSWORD_STORE_DIR` are honoured.

## key

```sh
ankh key                       # choose interactively
ankh key --existing            # a key already in the keyring
ankh key --generate
ankh key --import <file|dir|-> # an armored file, a backup directory, or a paste
```

- **Generated keys:** an ed25519 primary key that only certifies (default expiry 5y), and ed25519 signing, ed25519 authentication and cv25519 encryption subkeys (default 2y). gpg-agent's pinentry asks for the passphrase: ankh never sees it. You're offered a backup straight away.
- **From a backup directory:** the subkeys only by default, which is what a daily machine needs. The full key, with its primary, is offered too. Encrypted backups are opened first.
- In every case the key gets ultimate ownertrust.
- `ankh -y key` runs without questions, taking its answers from the environment: `key_source` (`existing`, `generate`, `import`), `key_file`, `key_import` (`subkeys`, `full`), `gpg_fpr`, `gpg_name`, `gpg_email`, `gpg_expire`, `gpg_subkey_expire`; for the other steps, `pass_source` (`clone`, `new`), `pass_remote`, `ssh_source` (`generate`, `existing`, `gpg`, `fido2`), `ssh_file`, `ssh_name`, `ssh_dir`, `ssh_subkey`, `ssh_no_passphrase`. Passphrases are still asked by gpg-agent and ssh-keygen.

## backup

```sh
ankh backup <dir> [--key <fpr>] [--encrypt] [--remove-primary]
```

Writes a complete backup into an empty directory: typically a USB stick that then stays in a drawer, never a synced folder (ankh refuses a git work tree).

| File | Contents |
|---|---|
| `secret.asc` | the full secret key, primary and all subkeys (only when the primary is on this machine) |
| `subkeys.asc` | the subkeys only, for daily machines |
| `public.asc` | the public key |
| `revocation.asc` | the revocation certificate gpg wrote when the key was made |
| `ownertrust.txt` | trust settings |
| `paperkey.txt` | the secret part, for printing (with paperkey installed) |
| `ssh/` | SSH key pairs from `~/.ssh` (and `~/.ssh/keys`), in the same layout |
| `README.txt` | the fingerprint, the date, how to restore |

The secret keys stay protected by the key's passphrase.

**Verified before ankh calls it good:** each secret file is imported into a throwaway gpg home, then used to sign and decrypt a test message.

- `--encrypt` seals everything into `ankh-backup.tar.gpg` with a passphrase of its own, so a lost stick needs two passphrases. The backup is built and checked in a private scratch directory, in memory (tmpfs) where there is one, and **only the sealed archive is written to the target**. Flash drives remap writes, so files deleted on them can often be recovered: nothing readable should ever land there. The new passphrase is asked twice, then once more to prove the archive opens.
- `--remove-primary` removes the primary key from this machine once the backup is verified, leaving only the subkeys. Without the flag, ankh asks.

## Moving between machines

```sh
ankh pull <user@old> [key] [pass] [ssh]   # on the new machine
ankh send <user@new> [key] [pass] [ssh]   # the same, from the old machine
ankh send --paste [key] [ssh] [--qr]      # no network between them
ankh receive                              # on the new machine, then paste
```

ankh has to be installed on both machines. With no parts named, `pull` and `send` move all three:

- **the key:** its subkeys only, unless `--with-primary` (keep the primary on one machine, or only in the backup). Ownertrust comes along.
- **the store:** cloned from a git bundle of the old one, keeping its remote. A store already here is left alone.
- **SSH keys:** every key pair in `~/.ssh` (and `~/.ssh/keys`). For each, ankh asks its name and directory, defaulting to the old ones, and never overwrites a file.

The connection is SSH (a password is fine, asked once for the whole move). Files go through rsync when both machines have it, scp otherwise, via a private directory on the other machine that is removed afterwards. `--remote-ankh <cmd>` says how to run ankh there, if it isn't on that machine's `PATH`.

**Paste** needs no network path at all. `send --paste` prints the key and SSH keys as a block sealed with a one-time passphrase (`gpg --symmetric`), shown once. Copy the block across however you like (`--qr` also draws it as a QR code, if it fits). Give the passphrase by another way than the block. `ankh receive` asks for the block, or takes a file holding it. The store is too big to paste: `ankh pass --clone` it instead.

## verify

```sh
./ankh-verify [<file>] [--checkpoint <url|file>]... [--no-default-checkpoints] [--as <name>]
ankh verify <file>     [--checkpoint <url|file>]... [--no-default-checkpoints] [--as <name>]
```

Checks a downloaded ankh against checksum files ("checkpoints", in `sha256sum` format): by default the release's `SHA256SUMS` on the public mirrors, plus any you give, as URLs or local files. Your own copy of the checksums (in your offline backup, say) is a checkpoint too. `--no-default-checkpoints` uses only yours, so nothing depends on the mirrors.

- **A mismatch on any checkpoint stops.** Don't run the file.
- A checkpoint that can't be reached, or doesn't list the file, is only a warning.
- **None confirming it stops**, unless `--insecure-skip-verify`. That never overrides a mismatch.

A script can't vouch for itself, so the first check on a new machine is done by `ankh-verify`, a separate script of about 50 lines: read it, then run it on `ankh`. `ankh verify` does the same from an ankh you already trust, for newer versions.

The mirrors copy one origin, so their checkpoints catch a tampered download host, not a tampered release. The release's gpg signature covers that.

## Development

```sh
make lint   # shellcheck, bash -n, completions
make test   # every command against a throwaway HOME, GNUPGHOME and store
```

## License

[GNU General Public License v3.0 or later](LICENSE)
