# rustdesk-client-bootstrap

One-script onboarding for putting a new client Windows laptop onto a self-hosted, Tailscale-only RustDesk relay.

The relay, ACL cage, and controlling-side config are already done. **This repo is only about adding new clients.**

## What this does

`bootstrap-client.ps1` runs on a fresh client Windows 10/11 box as Administrator and:

1. Installs Tailscale (if missing).
2. Joins the tailnet as a **tagged device** (`tag:client`) using a one-shot auth key — never as a user-owned device. Disables DNS hijack and subnet route acceptance so the laptop's normal internet keeps working.
3. Verifies it can reach the relay over Tailscale.
4. Installs RustDesk (if missing; winget first, GitHub release as fallback).
5. Writes the RustDesk network config to point at the self-hosted relay + pubkey.
6. Launches RustDesk and prints the three GUI clicks that finish the install.

It's idempotent. Safe to re-run if the first attempt half-completes.

## Constants (already burned into the script)

| Field | Value |
|---|---|
| Relay IP (ID Server + Relay Server) | `100.78.88.63` |
| Relay pubkey | `yIABL36cWQnguBPXRQZcUwyYsyRSZD++vhjQyh7Ctu8=` |
| Tailscale tag | `tag:client` |

These are safe to commit publicly:
- The relay IP is a Tailscale 100.x address — unreachable outside the tailnet.
- The relay key is a *public* key. Knowing it lets clients verify the relay's identity; it grants no access on its own.
- Tag is just an ACL label.

The only per-install secret is the Tailscale auth key, which is passed as a script parameter (never committed) and rotated per install.

## Per-client procedure

### 1. Generate a fresh auth key

Tailscale admin console → **Settings → Keys → Generate auth key**:
- Description: `rustdesk-bootstrap <client name>`
- Reusable: **OFF**
- Ephemeral: **OFF**
- Tags: tick **`tag:client`**
- Expiration: 7 days is plenty (you'll use it once and revoke after)

Copy the `tskey-auth-...` string — it's only shown once.

### 2. Get the script onto the client machine

Option A (preferred — clean repo clone):
```powershell
git clone https://github.com/inkwellsights/rustdesk-client-bootstrap.git
cd rustdesk-client-bootstrap
```

Option B (one-liner, no git needed):
```powershell
iwr https://raw.githubusercontent.com/inkwellsights/rustdesk-client-bootstrap/main/bootstrap-client.ps1 -OutFile bootstrap-client.ps1
```

### 3. Run it as Administrator

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\bootstrap-client.ps1 -AuthKey tskey-auth-XXXXXXXXXXXX
```

The script handles steps 1–6 above. When it finishes, RustDesk's window is open and waiting.

### 4. Finish in the RustDesk GUI (~30 seconds)

The script prints these at the end:

1. Wait for the **green status dot** at the bottom of the RustDesk window.
2. **≡ menu → Security → Use permanent password ON →** set one, write it down.
3. **≡ menu → General → Start RustDesk on boot ON** (also tick **Enable service** if shown).
4. Note the **9-digit ID** on the main window.

Hand the **9-digit ID + permanent password** back to your controlling end.

### 5. Verify from your end

Open your own RustDesk → punch in the 9-digit ID → connect → enter the password. You should land on their desktop in a few seconds. If it stalls, see **Troubleshooting** below.

### 6. Revoke the auth key

Tailscale admin console → **Settings → Keys** → find the key you just used → **Revoke**. The client's tailnet membership stays intact (already authorized); revoking just prevents the key from being reused if it leaked.

## Troubleshooting

### "Failed when opening source(s)" during winget install
winget's source cache is stale. The script auto-falls-back to the GitHub release download for RustDesk. For Tailscale, run `winget source reset --force; winget source update` and re-run the script.

### Laptop's internet dies the moment Tailscale comes on
DNS hijack from a previous Tailscale session on this box. The script already uses `--accept-dns=false --accept-routes=false --reset` to prevent this on fresh joins, but if the laptop was on a different tailnet earlier, run `tailscale logout` first then re-run the script.

### Green dot stays red after Network settings applied
- `tailscale ping 100.78.88.63` from the laptop must succeed. If it doesn't, the ACL grant `tag:client → tag:rustdesk` isn't matching. Check the admin console → **Machines** → laptop's row shows `tag:client` in the Tags column, and the relay (`saiftrw`) shows `tag:rustdesk`.
- Verify the relay's containers are actually running: `ssh msa@100.78.88.63 'docker compose -f ~/rustdesk-server/docker-compose.yml ps'`.

### Tailscale Machines list shows the laptop owned by an email, not `tag:client`
The auth key wasn't tagged. Revoke it, generate a new one with the `tag:client` tag ticked, `tailscale logout` on the laptop, re-run the script with the new key.

## Relay recovery

If `saiftrw` dies, you're rebuilding from scratch only if `~/rustdesk-server/data/` was lost. As long as that directory's contents (especially `id_ed25519` and `id_ed25519.pub`) are backed up, restoring the relay is:

```bash
mkdir -p ~/rustdesk-server/data
# restore data/ contents from backup
cd ~/rustdesk-server
# (copy the docker-compose.yml from this repo's runbook/ or rewrite it)
docker compose up -d
```

The pubkey doesn't change, so every existing client keeps working with zero re-bootstrapping. **Back up `~/rustdesk-server/data/` regularly on saiftrw.**

If `data/` is lost, hbbs generates a new keypair on first start and **every existing client breaks** — they'd all need re-bootstrapping with the new key. Avoid this by snapshotting `data/`.

## Repo layout

```
rustdesk-client-bootstrap/
├── README.md               # this file
└── bootstrap-client.ps1    # Windows install script
```

No Linux variant yet — add one if/when a Linux client needs onboarding.
