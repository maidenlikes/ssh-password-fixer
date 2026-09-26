# SSH Password Login Fixer

A CLI script for Ubuntu Server (22.04 / 24.04) that safely enables SSH login via
root password, then sets the root password. Ideal for a freshly created VPS that
still rejects login with `Permission denied (publickey)`.

## Run it directly (no file download)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/maidenlikes/ssh-password-fixer/main/ssh-password-fixer.sh) --fix
```

Run as root (a fresh VPS is usually already root). If not root, prefix with `sudo`.

## Modes

| Command | Purpose |
|---------|---------|
| `--fix` | Backup → enable `PasswordAuthentication` + `PermitRootLogin yes` → validate → restart ssh → verify → set root password → offer to remove SSH keys |
| `--check` | Check configuration only, no changes |
| `--restore` | Restore configuration from a backup |
| `--remove-keys` | Remove all `authorized_keys` (password-only login) |
| _(no argument)_ | Interactive menu |

## Safety

- Backs up config before changes to `/var/backups/ssh-password-fixer/`.
- Validates with `sshd -t` before restart; auto-rollback if the config is invalid.
- Only restarts the `ssh` service, never reboots the VPS.
- SSH keys are only removed if you confirm, and they are backed up first.

## Warning

Keep your current SSH session open until you have successfully tested password
login from another device. Removing SSH keys before password login is proven to
work can lock you out of the server.
