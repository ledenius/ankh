# ankh

Identity bootstrap for a freshly installed machine. ankh gets three things working, then stops:

1. **a gpg key:** from another machine, a backup, a file, a smartcard, or newly generated;
2. **a [pass](https://www.passwordstore.org/) store** that this key can decrypt;
3. **SSH.**

Everything after that (logins, service credentials, other secrets) is left to other tools. ankh only builds the foundation they stand on.

## Status

Early. Today ankh has `check`. The rest is planned, in this order:
- `key` and `backup`;
- `pass`, `ssh` and `init`;
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

## Development

```sh
make lint   # shellcheck, bash -n, completions
make test   # every command against a throwaway HOME, GNUPGHOME and store
```

## License

[GNU General Public License v3.0 or later](LICENSE)
