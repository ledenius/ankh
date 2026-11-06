# ankh

Identity bootstrap for a freshly installed machine. ankh gets three things working, then stops:

1. **a gpg key:** from another machine, a backup, a file, a smartcard, or newly generated;
2. **a [pass](https://www.passwordstore.org/) store** that this key can decrypt;
3. **SSH.**

Everything after that (logins, service credentials, other secrets) is left to other tools. ankh only builds the foundation they stand on.

ankh is published on [Codeberg](https://codeberg.org/lede/ankh). Any copy can serve the script: releases are checked the same way wherever it came from.

## Status

Early. Today ankh has `init`, `check`, `key`, `backup`, `pass` and `ssh`. Still planned, in this order:
- moving everything between machines (`pull`, `send`, paste);
- smartcards (`card`).

## Install

ankh is a single bash script, and it handles your gpg key and your pass store. **Read it before you run it**, and install a release, not whatever `main` holds today:

```sh
git clone https://codeberg.org/lede/ankh.git
cd ankh
git checkout <release tag>
less ankh
make install                # into ~/.local/bin
make install-completions    # bash, zsh and fish
```

From 0.1.0, each release also publishes the script with a SHA-256 checksum and a gpg signature. Keep the checksum, or the signing key's fingerprint, somewhere you trust (your offline backup is a good place), and check against it before running a downloaded copy. Checking a signature only needs the public key, so it works on a machine that has none of your secrets yet.

With Nix: `nix run 'git+https://codeberg.org/lede/ankh?ref=<release tag>'`, or `homeManagerModules.default` from the flake.

## Requirements

| | |
|---|---|
| Required | bash 5+, gpg (with gpg-agent and a pinentry), git, pass, OpenSSH (ssh, ssh-keygen, ssh-add, scp) |
| Optional | rsync (used to copy between machines; scp otherwise), paperkey (printable backups), ykman (YubiKey touch policy), qrencode (QR codes for pasted bundles) |

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

## Development

```sh
make lint   # shellcheck, bash -n, completions
make test   # every command against a throwaway HOME, GNUPGHOME and store
```

## License

[GNU General Public License v3.0 or later](LICENSE)
