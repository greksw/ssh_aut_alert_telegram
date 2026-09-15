# SSH Login Alerting

A small Linux operations/security utility that sends a Telegram notification when an SSH PAM session is opened.

The original script embedded Telegram credentials in the source file and was designed to run from shell profiles. This refactor separates secrets from code and uses an SSH PAM session hook that immediately queues a transient systemd worker. Telegram/DNS/network failures therefore do not need to block an SSH login.

## What it does

- accepts SSH session metadata from `pam_exec` (`PAM_USER`, `PAM_RHOST`, `PAM_SERVICE`, `PAM_TTY`, `PAM_TYPE`);
- generates alerts only for `PAM_TYPE=open_session` and `PAM_SERVICE=sshd`;
- queues delivery with `systemd-run --no-block`;
- reads Telegram credentials from `/etc/ssh-login-alert.conf`;
- requires the configuration file to be root-owned and inaccessible to group/other users;
- keeps the Telegram bot token out of the curl command line by using a mode-0600 temporary curl config;
- applies bounded connect/total HTTP timeouts;
- sanitizes control characters in PAM-provided fields;
- logs delivery failures through `logger` without changing the login result;
- does not clear or otherwise modify the user's terminal session.

## Repository layout

- `ssh-login-alert.sh` — PAM hook and asynchronous Telegram worker;
- `notify_telegram.sh` — compatibility wrapper for the legacy filename;
- `config/ssh-login-alert.conf.example` — credential/configuration template;
- `.github/workflows/ci.yml` — syntax, ShellCheck, and behavioral validation.

## Requirements

Target environment:

- Linux with systemd;
- OpenSSH using PAM;
- Bash 4+;
- `curl`, `systemd-run`, `logger`, `stat`, `hostname`, `readlink`;
- outbound HTTPS access to Telegram Bot API.

This implementation intentionally targets Linux/systemd rather than trying to behave as a generic POSIX login hook.

## Installation

Install the notifier:

```bash
sudo install -o root -g root -m 0755 \
  ssh-login-alert.sh \
  /usr/local/sbin/ssh-login-alert
```

Create the root-only configuration:

```bash
sudo install -o root -g root -m 0600 \
  config/ssh-login-alert.conf.example \
  /etc/ssh-login-alert.conf

sudoedit /etc/ssh-login-alert.conf
```

Set the real bot token and destination chat ID in `/etc/ssh-login-alert.conf`. Do not store real credentials in this repository, shell history, issue comments, or screenshots.

## Preview without Telegram

The preview mode renders a sample message and does not read secrets or access the network:

```bash
./ssh-login-alert.sh --preview \
  --user runer \
  --remote 192.0.2.10 \
  --host srv-example.example.net
```

Example structure:

```text
SSH login detected
Host: srv-example.example.net
User: runer
Remote: 192.0.2.10
Service: sshd
TTY: ssh
Time (UTC): 2026-09-15T10:00:00Z
```

## PAM integration

**PAM configuration is authentication-critical. Back up and review the target file before editing it. Keep a second privileged session open while testing.**

Back up the current SSH PAM policy:

```bash
sudo cp -a /etc/pam.d/sshd /etc/pam.d/sshd.before-ssh-login-alert
```

Add this as an optional session rule in `/etc/pam.d/sshd`:

```text
session optional pam_exec.so quiet /usr/local/sbin/ssh-login-alert
```

Why `optional` matters: Telegram alerting is observability, not an authentication control. A broken notifier must not become a reason to deny SSH access.

The hook also exits successfully for PAM event types other than `open_session` and for services other than `sshd`.

## Testing safely

1. Keep an existing root/admin SSH session open.
2. Validate the script and configuration permissions.
3. Add the PAM rule.
4. Open a **new** SSH session in a separate terminal.
5. Confirm the login succeeds regardless of Telegram delivery state.
6. Check the system journal for transient worker failures if no message arrives.

Useful commands:

```bash
journalctl -t ssh-login-alert --since '10 minutes ago'
systemctl list-units --type=service --all | grep run-
```

Do not test PAM changes from your only administrative session on a remote server.

## Configuration

Example:

```text
TELEGRAM_BOT_TOKEN=123456789:replace_with_real_bot_token
TELEGRAM_CHAT_ID=123456789
CURL_CONNECT_TIMEOUT=2
CURL_MAX_TIME=5
```

The parser intentionally accepts only these four keys. The config is data, not sourced as shell code.

Permissions must prevent access by group/other users. Recommended:

```bash
sudo chown root:root /etc/ssh-login-alert.conf
sudo chmod 0600 /etc/ssh-login-alert.conf
```

## Operational notes

### Telegram is not a security boundary

The notification is a secondary visibility signal. It does not replace:

- SSH key policy;
- MFA where appropriate;
- disabling/restricting password authentication;
- source-address controls/VPN/bastion access;
- fail2ban or equivalent controls;
- centralized auth/audit logs;
- SIEM/Wazuh/Zabbix/Prometheus monitoring where applicable.

### Delivery is intentionally asynchronous

`pam_exec` queues a transient systemd worker using `systemd-run --no-block` and returns. The external HTTP request is performed by that worker with strict timeouts.

If `systemd-run` is unavailable, the notifier logs that the alert was skipped and still exits successfully.

### Secret exposure model

The bot token is kept in a root-only file and copied into a root-only temporary curl configuration for the request URL. It is not embedded in the script or passed directly as a curl process argument.

Root can always inspect root-owned process/filesystem state; this design primarily prevents routine disclosure through source control, shell history, and ordinary process command lines.

### Duplicate notifications

A normal OpenSSH login should produce one `open_session` event. PAM stacks can vary across distributions and custom configurations. Validate the behavior on the actual target host before broad rollout.

## CI validation

GitHub Actions performs:

- `bash -n` parsing;
- ShellCheck;
- preview rendering with control characters in fields;
- PAM event filtering for a non-open session event;
- repository scan to ensure placeholder configuration is used rather than a credential-like hardcoded production token.

CI does not modify PAM or call Telegram.

## License

No open-source license has been selected yet.
