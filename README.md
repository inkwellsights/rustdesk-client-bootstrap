# rustdesk-client-bootstrap

One PowerShell script that turns a fresh Windows laptop into an unattended-access endpoint on a self-hosted, Tailscale-only RustDesk relay. No router ports, no public internet exposure, no per-client server config.

The relay, the ACL cage, and the controlling-side config are already done. **This repo is only for adding new clients.**

---

## TL;DR — install on a new client laptop

In admin PowerShell on the laptop, paste these three lines (after putting your auth key into line 3):

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
iwr https://raw.githubusercontent.com/inkwellsights/rustdesk-client-bootstrap/main/bootstrap-client.ps1 -OutFile bootstrap-client.ps1
.\bootstrap-client.ps1 -AuthKey tskey-auth-PASTE-YOURS-HERE
```

Then in the RustDesk window that opens automatically:

1. Wait for the **green status dot** at the bottom.
2. **≡ menu → Security → Use permanent password ON** → set one.
3. **≡ menu → General → Start RustDesk on boot ON**.
4. Note the **9-digit ID** on the main window.

Send the **9-digit ID + the permanent password** to whoever's controlling. Done.

---

## Who runs what

There are two people in this loop, even if they're the same person:

| Role | Where they sit | What they do |
|---|---|---|
| **Operator** | Your own PC | Generates an auth key, sends instructions, tests the connection, revokes the key. |
| **Client** | The laptop being onboarded | Pastes three commands into PowerShell, finishes 4 GUI clicks, sends back the ID + password. |

If both are you, just follow the operator section then the client section yourself.

---

## Operator playbook (do this once per new laptop)

### 1. Generate a one-shot auth key

Tailscale admin console → **Settings → Keys → Generate auth key**:

- **Description:** `rustdesk-bootstrap <client name>`
- **Reusable:** OFF
- **Ephemeral:** OFF
- **Tags:** tick **`tag:client`**
- **Expiration:** 7 days (you'll use it once and revoke after)

Copy the `tskey-auth-...` string — it's only shown once.

### 2. Send this message to the client

Copy-paste, drop the auth key into the marked spot, send to the client over whatever channel you use:

> Hey — here's the install for unattended remote access. You'll need to run this on the laptop as **Administrator**.
>
> 1. Right-click the Windows Start button → **Terminal (Administrator)** → click Yes on the UAC prompt.
> 2. Paste these three lines and press Enter after each:
>
> ```powershell
> Set-ExecutionPolicy -Scope Process Bypass -Force
> iwr https://raw.githubusercontent.com/inkwellsights/rustdesk-client-bootstrap/main/bootstrap-client.ps1 -OutFile bootstrap-client.ps1
> .\bootstrap-client.ps1 -AuthKey tskey-auth-XXXXXXXXXXXX
> ```
>
> 3. A RustDesk window will open. Wait for the small status dot at the bottom to turn **green**.
> 4. Click the **≡ menu (top-right) → Security → Use permanent password ON** → set a password you'll remember and write it down.
> 5. Click the **≡ menu → General → Start RustDesk on boot ON**.
> 6. On the main window, you'll see a **9-digit ID number**. Send me that number + the password you just set.

### 3. Test from your own machine

Open RustDesk on your end → paste the 9-digit ID → Connect → enter the permanent password. You should land on their desktop within seconds.

If the connection stalls, see [Troubleshooting](#troubleshooting).

### 4. Revoke the auth key

Tailscale admin console → **Settings → Keys** → find the key you used → **Revoke**.

The client's tailnet membership stays intact. Revoking just prevents that key from being reused if it leaks.

---

## What the script actually does

Walks the laptop through six steps, in order. Each is idempotent — safe to re-run if any step fails partway through.

1. **Install Tailscale** if missing (winget).
2. **Join the tailnet** as `tag:client` using the one-shot auth key, with DNS and subnet route acceptance **disabled** so the laptop's normal internet keeps working.
3. **Verify reachability** to the relay over Tailscale (`tailscale ping`).
4. **Install RustDesk** if missing (winget; falls back to GitHub release direct download if winget's source cache is broken).
5. **Write the RustDesk config** so its Network settings point at the self-hosted relay + pubkey.
6. **Launch RustDesk** and print the four remaining manual GUI steps.

---

## Constants (already burned into the script — no editing needed)

| Field | Value |
|---|---|
| Relay IP (ID Server + Relay Server) | `100.78.88.63` |
| Relay pubkey | `yIABL36cWQnguBPXRQZcUwyYsyRSZD++vhjQyh7Ctu8=` |
| Tailscale tag | `tag:client` |

All three are safe to commit publicly:

- The relay IP is a Tailscale `100.x` address — only reachable from inside the tailnet.
- The relay key is a *public* key (asymmetric crypto). It lets clients verify the relay's identity; it grants no access on its own.
- The tag is just an ACL label.

The only per-install secret is the Tailscale auth key, passed as a script parameter. It's never committed, and it's rotated per install.

---

## Troubleshooting

### Script error: "Run this script in PowerShell as Administrator"
The PowerShell window isn't elevated. Close it. Right-click the Windows Start button → **Terminal (Administrator)** → click Yes on the UAC prompt → try again.

### Script error: "tailscale up failed"
The auth key is wrong, expired, or wasn't tagged. Generate a new one in the admin console, ticking `tag:client` this time, and re-run with the new key.

### Script error: "Relay unreachable"
The laptop joined the tailnet but the ACL grant `tag:client → tag:rustdesk` isn't matching. Check the admin console → **Machines** — the laptop's row should show `tag:client` in the Tags column. If it shows your email instead, the auth key wasn't tagged. Revoke, regenerate with the tag, `tailscale logout` on the laptop, re-run the script.

### "Failed when opening source(s)" during winget install
winget's source cache is stale. Run:
```powershell
winget source reset --force
winget source update
```
Then re-run the bootstrap script. (RustDesk install will fall back automatically; this matters mainly for Tailscale.)

### Laptop's internet dies the moment Tailscale comes on
DNS hijack from a previous Tailscale session that joined a different tailnet. The script uses `--accept-dns=false --accept-routes=false --reset` to prevent this on fresh joins, but if the laptop was already on a different tailnet, do `tailscale logout` first then re-run.

### Green dot stays red after the script finishes
- Run `& "C:\Program Files\Tailscale\tailscale.exe" ping 100.78.88.63` on the laptop. Must succeed within a few packets.
- If ping fails: see "Relay unreachable" above.
- If ping succeeds but the dot is still red: relay's containers may be down. Operator should SSH to the relay and check `docker compose ps`.

### Tailscale Machines list shows the laptop owned by an email, not `tag:client`
Auth key wasn't tagged. Revoke, regenerate with `tag:client` ticked, `tailscale logout` on the laptop, re-run.

### Connect stalls on "Connecting…"
- Most likely: the controlling end is using a different key or relay IP than the client. Check `≡ → Network` on both ends; the three values must match exactly.
- Less likely: the laptop isn't actually on the tailnet anymore. Run `tailscale status` on the laptop.

---

## Relay recovery (for the operator, when saiftrw dies)

The relay itself isn't in this repo — only the client-side bootstrap is. But here's the survival note:

The pubkey `yIABL36c...` is generated by `hbbs` on first startup and written to `~/rustdesk-server/data/id_ed25519.pub`. **As long as `~/rustdesk-server/data/` is backed up**, restoring the relay is:

```bash
# on the replacement box
mkdir -p ~/rustdesk-server
# restore docker-compose.yml + data/ from backup
cd ~/rustdesk-server
docker compose up -d
```

Pubkey stays the same. **Every existing client keeps working with zero re-bootstrapping.**

If `data/` is lost, `hbbs` generates a new keypair on first start. Every client's saved key is now wrong. They all need re-bootstrapping with the new pubkey — and you have to ship them an updated script. **So: snapshot `~/rustdesk-server/data/` regularly.**

---

## Repo layout

```
rustdesk-client-bootstrap/
├── README.md               # this file
└── bootstrap-client.ps1    # Windows install script (parameterized)
```

No Linux variant yet — add one if/when a Linux client needs onboarding.
