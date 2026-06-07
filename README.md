# rustdesk-client-bootstrap

One PowerShell script that prepares a Windows laptop for unattended remote access through a self-hosted, **Tailscale-only** RustDesk relay. No router ports, no public internet exposure, no per-client server config.

The relay, the ACL cage, and the controlling-side config are already done. **This repo is only for adding new clients.**

> **Honesty up front:** the script automates everything that is safe to automate on RustDesk 1.4.x (Tailscale join, install, and **pre-filling** the relay/key so nobody types them). The last 3 steps stay in the GUI on purpose — on 1.4.x they are the *only* method verified to configure the unattended service. See [Why some steps stay manual](#why-some-steps-stay-manual). Don't "optimise" them into silent CLI calls without re-verifying on your RustDesk version.

---

## TL;DR — install on a new client laptop

Admin PowerShell on the laptop (drop your auth key into line 3):

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
iwr https://raw.githubusercontent.com/inkwellsights/rustdesk-client-bootstrap/main/bootstrap-client.ps1 -OutFile bootstrap-client.ps1
.\bootstrap-client.ps1 -AuthKey tskey-auth-PASTE-YOURS-HERE
```

RustDesk opens with the relay/key **already filled in**. Then, in the window:

1. Wait for the **green status dot** (bottom).
2. **≡ menu → Security → Use permanent password ON** → set one.
3. **≡ menu → General → Start RustDesk on boot ON**.
4. Read the **9-digit ID** on the main window.

Send the **9-digit ID + permanent password** to whoever's controlling. Done.

---

## Who runs what

| Role | Where | What they do |
|---|---|---|
| **Operator** | Your own PC | Generate an auth key, send the install message, test the connection, revoke the key. |
| **Client** | The laptop being onboarded | Paste 3 lines, do 4 GUI clicks, send back the ID + password. |

If both are you, follow the operator section then the client section yourself.

---

## Operator playbook (once per new laptop)

### 1. Generate a one-shot auth key

Tailscale admin console → **Settings → Keys → Generate auth key**:

- Description: `rustdesk-bootstrap <client name>`
- Reusable: **OFF**
- Ephemeral: **OFF**
- Tags: tick **`tag:client`**
- Expiration: 7 days (used once, revoked after)

Copy the `tskey-auth-...` string — shown only once.

### 2. Send this to the client

> Hey — here's the unattended-access install. Run it on the laptop as **Administrator**.
>
> 1. Right-click Start → **Terminal (Administrator)** → Yes on the prompt.
> 2. Paste these three lines (Enter after each):
>
> ```powershell
> Set-ExecutionPolicy -Scope Process Bypass -Force
> iwr https://raw.githubusercontent.com/inkwellsights/rustdesk-client-bootstrap/main/bootstrap-client.ps1 -OutFile bootstrap-client.ps1
> .\bootstrap-client.ps1 -AuthKey tskey-auth-XXXXXXXXXXXX
> ```
>
> 3. A RustDesk window opens with the server already filled in. Wait for the small status dot at the bottom to turn **green**.
> 4. **≡ menu (top-right) → Security → Use permanent password ON** → set a password, write it down.
> 5. **≡ menu → General → Start RustDesk on boot ON**.
> 6. Send me the **9-digit ID** on the main window + the password you set.

### 3. Test from your machine

Open RustDesk → paste the 9-digit ID → Connect → enter the permanent password. Their desktop should appear in seconds. Stuck? See [Troubleshooting](#troubleshooting).

### 4. Revoke the auth key

Admin console → **Settings → Keys** → the key you used → **Revoke**. Membership stays; this just stops the key being reused if it leaks.

---

## What the script does

1. **Installs Tailscale** if missing (winget).
2. **Joins the tailnet** as `tag:client` via the one-shot key, with `--accept-dns=false --accept-routes=false --reset` so the laptop's normal internet is never disturbed. *(Verified.)*
3. **Verifies relay reachability** (`tailscale ping`). *(Verified.)*
4. **Installs RustDesk** if missing (winget; GitHub release fallback if winget's source cache is broken). *(Verified.)*
5. **Pre-fills the RustDesk user config** (`%APPDATA%\RustDesk\config\RustDesk2.toml`), written **without a BOM**, so the Network panel shows the right ID server / relay / key on first launch — no manual typing. *(Verified to pre-fill the GUI.)*
6. **Launches RustDesk** and prints the remaining GUI steps.

Optional: pass `-RustdeskPassword '...'` for a best-effort `--password` call. **Unverified on 1.4.x — confirm in the GUI that a password is actually set.**

---

## Why some steps stay manual

On RustDesk **1.4.x** (current), the fully-silent deployment paths are unreliable, confirmed on a real 1.4.4 box:

- **`--config <blob>` drops the relay.** Known bug — [rustdesk/rustdesk #7118](https://github.com/rustdesk/rustdesk/discussions/7118). The ID server applies but the relay silently doesn't.
- **`--get-id` returns nothing** from the GUI-subsystem build, so the 9-digit ID can't be captured by a script. You read it off the window.
- **The unattended service runs as LocalSystem**, but the config it reads sits under a *different* profile (observed under `LocalService`). Which file a fresh host's service reads is account/version dependent, so blind-writing a service-profile TOML is a guess.

The proven path on 1.4.x: pre-fill the user config (this script) **then** set the permanent password and enable the service **in the GUI**. Enabling the service is what propagates the relay settings into the service context. That's why steps 2–4 are GUI, not CLI. If a future RustDesk version fixes `--config`/`--get-id`, revisit this — but **re-verify on a fresh box before trusting it.**

---

## Constants (already in the script — no editing)

| Field | Value |
|---|---|
| Relay IP (ID + Relay Server) | `100.78.88.63` |
| Relay pubkey | `yIABL36cWQnguBPXRQZcUwyYsyRSZD++vhjQyh7Ctu8=` |
| Tailscale tag | `tag:client` |

Safe to commit publicly: the IP is a Tailscale `100.x` address (unreachable off-tailnet), the key is a *public* key (grants nothing on its own), the tag is just an ACL label. The only per-install secret is the auth key, passed as a parameter and rotated per install.

---

## Troubleshooting

### "Run this in PowerShell as Administrator"
The window isn't elevated. Right-click Start → **Terminal (Administrator)** → Yes → retry.

### "tailscale up failed"
Auth key wrong, expired, or untagged. Generate a new one with `tag:client` ticked; re-run.

### "Relay unreachable"
Laptop joined but the ACL grant `tag:client → tag:rustdesk` isn't matching. Admin console → **Machines** → the laptop's row should show `tag:client` (not your email). If it shows your email, the key wasn't tagged — revoke, regenerate tagged, `tailscale logout`, re-run.

### "Failed when opening source(s)" during winget
Stale winget cache. Run `winget source reset --force; winget source update`, then re-run. (RustDesk falls back to GitHub automatically; this mainly affects Tailscale.)

### Laptop's internet dies when Tailscale comes on
DNS hijack from a previous Tailscale session on a different tailnet. The script uses `--accept-dns=false --accept-routes=false --reset` to prevent this on fresh joins; if it was already on another tailnet, `tailscale logout` first, then re-run.

### Green dot stays red
Run `& "C:\Program Files\Tailscale\tailscale.exe" ping 100.78.88.63` on the laptop. Fails → see "Relay unreachable". Succeeds but still red → relay containers may be down; operator: `ssh msa@100.78.88.63 'docker compose -f ~/rustdesk-server/docker-compose.yml ps'`.

### Connect stalls on "Connecting…"
Usually the two ends disagree on relay/key. Check `≡ → Network` on both — the three values must match exactly. Less likely: the laptop fell off the tailnet (`tailscale status`).

---

## Relay recovery (operator, when saiftrw dies)

The relay isn't in this repo; this is the survival note. The pubkey is generated by `hbbs` on first start and stored at `~/rustdesk-server/data/id_ed25519.pub`. **As long as `~/rustdesk-server/data/` is backed up**, restoring is:

```bash
mkdir -p ~/rustdesk-server
# restore docker-compose.yml + data/ from backup
cd ~/rustdesk-server
docker compose up -d
```

Pubkey stays the same → every existing client keeps working, zero re-bootstrapping.

If `data/` is lost, `hbbs` generates a **new** keypair and every client's saved key is now wrong — they all need re-bootstrapping with the new pubkey, and you'd ship an updated script. **So: snapshot `~/rustdesk-server/data/` regularly.**

---

## Repo layout

```
rustdesk-client-bootstrap/
├── README.md               # this file
└── bootstrap-client.ps1    # Windows install script (parameterized)
```

No Linux variant yet — add one if/when a Linux client needs onboarding.
