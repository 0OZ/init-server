# init-server

One command to harden and kit out a **fresh Ubuntu server**. Installs fish,
fail2ban, Docker + Compose, GitHub CLI, and Claude Code; locks SSH to keys,
enables UFW, and creates a sudo user. Idempotent and re-runnable.

Nothing is hardcoded to one box — the same command provisions **every server in
the farm**. Pass the per-server details as env vars, or leave them off to be
prompted.

---

## Add a server with Claude Code

Paste this into Claude Code (running locally). It asks you for the details, then
drives the whole flow for the new server:

```text
Provision a new server in my farm using github.com/0OZ/init-server.

Ask me for, one at a time:
  1. Server IP or hostname
  2. The non-root username to create
  3. (optional) A GitHub token for private repos — skip if I say no

Then, showing me each command before you run it:

  1. Copy my SSH key to root:
       ssh-copy-id root@<HOST>
  2. Run the hardening script over SSH, non-interactively, passing my answers
     as env vars (only include INIT_GH_TOKEN if I gave you a token):
       ssh root@<HOST> "INIT_USER=<USERNAME> INIT_YES=1 \
         bash <(curl -fsSL https://raw.githubusercontent.com/0OZ/init-server/main/init.sh)"
  3. Verify I can log in as the new user:
       ssh <USERNAME>@<HOST> "echo ok; fish --version; docker --version"
  4. Summarize the health-check output and tell me if any check failed.

Do NOT close the root SSH session until step 3 confirms key login works.
```

That's the whole farm workflow: paste, answer three questions, done — for any
server you add.

---

## Manual quick start

Replace `<SERVER_IP>` and `<USERNAME>`.

```bash
# 1. Put your key on root (uses the provider's root password once)
ssh-copy-id root@<SERVER_IP>
```
```bash
# 2. Harden the box + create <USERNAME> (copies your key onward, locks SSH)
ssh root@<SERVER_IP> "INIT_USER=<USERNAME> INIT_YES=1 \
  bash <(curl -fsSL https://raw.githubusercontent.com/0OZ/init-server/main/init.sh)"
```
```bash
# 3. Log in as the new user
ssh <USERNAME>@<SERVER_IP>
```

Drop the env vars to run it interactively (SSH in first, then run the `curl`
line) and answer the prompts by hand.

---

## Environment variables

All optional. Unset → you're prompted. **When piped / non-interactive** (as in
the one-line `ssh host "…"` form above), a value must come from its env var or
the run aborts instead of hanging on a prompt no one can answer.

| Variable | Effect | If unset |
|---|---|---|
| `INIT_USER` | Non-root user to configure/create | falls back to `SUDO_USER`, else prompts |
| `INIT_YES=1` | Auto-confirm prompts (create user, version-continue) | prompts `[y/N]` |
| `INIT_SSH_PUBKEY` | Public key to add for the user | only needed if root has no key; else prompts |
| `INIT_GH_TOKEN` | GitHub token for private repos | skips GitHub auth |
| `INIT_GIT_NAME` | git `user.name` | prompts (only when configuring GitHub) |
| `INIT_GIT_EMAIL` | git `user.email` | prompts (only when configuring GitHub) |

> **Secret note:** `INIT_GH_TOKEN` on an `ssh host "…"` command line is briefly
> visible in the server's process list. Fine for a homelab farm; for stricter
> setups, SSH in first and paste the token at the interactive prompt instead.

In the normal flow you do **not** need `INIT_SSH_PUBKEY` — `ssh-copy-id` already
placed your key on root, and the script copies it to the new user.

---

## What it does

1. Resolve/create the sudo user, copy SSH keys onward
2. System update + prefetch GPG keys/installers, one batched `apt` install
3. fish shell, set as the user's default
4. fail2ban with an SSH jail (10 tries → 5m ban, escalating to 1h)
5. SSH hardening — no root login, key-only auth (validated before reload)
6. Docker + Compose, user added to the `docker` group
7. GitHub CLI (optional token auth for private repos)
8. Claude Code (native installer)
9. UFW firewall (SSH allowed)
10. Cleanup, then a parallel **health check** + version report

---

## Flags

```bash
bash init.sh --version   # print script version
bash init.sh --check     # compare local vs remote version
```

## Tests

```bash
bash tests/ask_test.sh   # covers the env-var / prompt input resolver
```

---

## Safety

**Do not close the root session until you've confirmed key-based login as the
new user in a second terminal.** The script disables root login and password
auth — a bad key means lockout.
