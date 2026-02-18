# reMarkable 2 Language Mod

This project patches the reMarkable 2 **xochitl** binary to replace the **German** keyboard with a custom font and language.
The patch is designed to **persistent across reboots and OS updates** — **without needing a PC to re-patch after updates**.
Currently, the code is configured to install the Hebrew language, however it's possible to install any language with minimal changes.

This patch was succesfully tested on the **reMarkable 2** and may brick other devices like the **reMarkable pro**.

**Simple & easy install instructions:**
1. Connect your **reMarkable 2** to your PC and make sure it's powered on.
2. Download/fork this repo.
3. Navigate to the **dist** folder.
4. **Right click** on **install.ps1**.
5. Enter your ssh password and hit enter.

Your tablet will restart a few times and now your **German** keyboard will display with **Hebrew**.

---
This repo is intentionally narrow, because narrow is how you ship something that doesn’t explode:

- Replaces the **German language slot** (`de_DE`) with your **custom keyboard layout** (example: Hebrew).
- Installs a **custom font** (swap `hebrew.ttf` for whatever you want).
- Survives **reboots**, **hard power loss**, and **A/B OS updates** using systemd persistence.

> ⚠️ You are modifying `/usr/bin/xochitl`. That’s the UI binary.  
> This project is for educational purposes only.  
> This is powerful, sharp, and a little bit cursed in the best way.  
> The deploy flow makes backups and includes rollback, but **use at your own risk**.


## What it does

**What:**  
It patches a compressed JSON keyboard layout embedded inside `xochitl` and makes sure the patch sticks around after reMarkable updates.

**How:**  
It finds the relevant keyboard blob inside `xochitl`, rewrites only the keys we intend to rewrite, recompresses the blob to the **exact same size**, and writes it back **without shifting bytes**.

**Why:**  
Because the OSK layout is **not a file** on disk. It’s a Qt resource embedded inside `xochitl`. So “copy a new JSON to `/usr/share/...`” will not work.

---

# User Friendly Guide (a.k.a. “just give me the magic button”)

This assumes you’re connected over **USB** (default reMarkable USB networking IP `10.11.99.1`).

## 1) Open the `dist/` folder

Inside `dist/` you’ll see:

- `Install.ps1` → install / re-install
- `Rollback.ps1` → undo everything

## 2) Install (the easy way)

1. **Right-click** `Install.ps1`
2. Click **Run with PowerShell**
3. Follow the prompts

### Password prompt (only once)
The first run may ask for the tablet password **one time** while it installs an SSH key for future runs. After that, it should be key-based and non-annoying.

## 3) Use the new keyboard

This project replaces the **German** slot (`de_DE`).  
So on the tablet, choose **German** as the keyboard language and enjoy your custom layout.

> Only `de_DE` is shipped and tested end-to-end in this repo.  
> Extending the same approach to other locales is very doable, but requires adding locale support in the Rust patcher (see Developer Guide).

---

## If “Run with PowerShell” is blocked (Windows)

If your machine blocks scripts via execution policy, open PowerShell in the `dist/` folder and run:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install.ps1
```

Wi‑Fi example (if you’re not on USB):

```powershell
powershell -ExecutionPolicy Bypass -File .\Install.ps1 -RmIp 192.168.1.123
```

---

## If you prefer running the deploy script directly (advanced user options)

From `dist/scripts/`:

```powershell
# install/reinstall
powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -Mode install

# re-apply safely (great after changing keyboard_layout.json or after an OS update)
powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -Mode repair

# show status + log tails
powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -Mode status

# rollback
powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -Mode rollback
```

Useful parameters:

- `-RmIp <ip>` (default USB is `10.11.99.1`)
- `-RmPort <port>` (default `22`)
- `-Locale de_DE` (this repo’s tested slot)
- `-SkipFontInstall` (if you truly only want the keyboard patch)

---

# Customizing font & layout

You can customize two files and rerun `Install.ps1` (or `deploy.ps1 -Mode repair`).

## Replace the font

The installer ships `hebrew.ttf` by default. Replace it with any font you want:

- Replace: `dist/scripts/hebrew.ttf`

Non‑Latin layouts (Hebrew/Arabic/etc.) **need a font** with those glyphs, or you’ll get tofu/boxes.

## Replace the keyboard layout

Replace:

- `dist/scripts/keyboard_layout.json`

This JSON is the **override/template** the patcher uses to map keys.

A reference copy of the decoded German layout is included:

- `static/de_DE.keyboard_layout.decoded.json`

Use that as your “ground truth” for structure and key positions.

### Hebrew final letters on Shift (default → shift)

If you want Shift to produce final letters, define them explicitly in your layout JSON:

- `נ` (default) → `ן` (shift)
- `מ` (default) → `ם` (shift)
- `כ` (default) → `ך` (shift)
- `פ` (default) → `ף` (shift)
- `צ` (default) → `ץ` (shift)

The patcher applies `default[0]` and `shifted[0]` exactly.

### “I changed the layout but nothing changed on the device”
Use **repair**. It re-uploads and re-applies cleanly:

```powershell
powershell -ExecutionPolicy Bypass -File .\dist\scripts\deploy.ps1 -Mode repair
```

Internally, the boot-time service uses the patcher’s `--check` mode to detect when the **JSON changed** and re-patches when needed.

---

# Rollback (undo)

## Easy way

1. **Right-click** `Rollback.ps1`
2. Click **Run with PowerShell**

## Manual way

```powershell
powershell -ExecutionPolicy Bypass -File .\Rollback.ps1
```

Rollback stops/disables persistence services, restores the last known backup of `xochitl` (if present), removes drop-ins, and restarts the UI.

---

# Developer Friendly Guide (bring snacks)

This section is for people who read `main.rs` for fun. You know who you are. 😄

## Repo layout

- `build.ps1` — builds the ARMv7 Rust patcher and assembles a shareable `dist/` package
- `rm-xochitl-kbdpatch/` — Rust source (the patcher that runs on the tablet)
- `static/`
  - `config/` — systemd drop-in for xochitl environment + font paths
  - `scripts/` — boot-time customization, slot sync, update watch, ssh ensure, rollback script
  - `services/` — systemd units
  - `de_DE.keyboard_layout.decoded.json` — decoded German layout (reference)
- `dist/` — what you hand to users:
  - `Install.ps1`
  - `Rollback.ps1`
  - `scripts/`
    - `deploy.ps1`
    - `rm-xochitl-kbdpatch`
    - `keyboard_layout.json`
    - `hebrew.ttf`
    - `static/…`

---

## Architecture overview

There are three moving parts:

1. **Windows build system** (`build.ps1`)  
   Cross-compiles the Rust patcher for `armv7-unknown-linux-musleabihf` and packages the deploy payload into `dist/`.

2. **Windows deploy/installer** (`dist/scripts/deploy.ps1`)  
   Handles SSH connectivity, one-time key provisioning, payload upload, and kicking off the on-device runner scripts.

3. **On-device persistence** (`static/scripts/*.sh` + `static/services/*.service`)  
   Ensures the patch and font setup survive reboots, power loss, and the reMarkable A/B update mechanism.

---

## How the patch works (the fun part)

### Where the keyboard JSON really lives
The OSK layout isn’t stored as a plain JSON file on disk. It’s embedded inside `xochitl` as Qt resource data, and the keyboard layouts appear as **Zstandard-compressed JSON blobs**.

Zstd frames are detectable by magic bytes:

- `28 B5 2F FD`

So the patcher:

1. Scans `xochitl` for Zstd frame signatures.
2. Attempts to decompress candidates.
3. JSON-parses decoded payloads.
4. Filters for “keyboard-shaped” JSON (`alphabetic`, `special`, etc.).
5. Picks the best match for the target locale using a **signature + scoring** heuristic.

### In-place constraint: no shifting bytes
`xochitl` is a single ELF binary. If you make embedded resources longer/shorter, you shift everything after it and the binary dies.

So patching must be **in-place**:

- Decompress → modify JSON → recompress → **must fit original capacity**
- If compressed output is smaller than capacity, pad using a **Zstd skippable frame**
- Write back at the same offset

That’s the whole “surgery” metaphor: precise edits without disturbing surrounding tissue.

---

## How the patcher finds the German layout (dynamic, update-resilient)

Offsets change across OS releases, so we don’t hardcode offsets.

For `de_DE`, the patcher looks for a keyboard whose rows resemble:

- Row 1 contains `qwertzuiop` and `ü`
- Row 2 contains `asdfghjkl` and `öä`
- Row 3 contains `yxcvbnm`

Highest score wins. This keeps the patch resilient even when resource order changes.

### German “extra keys” (`ü`, `ö`, `ä`)
German has three “extra” keys beyond the base `q..p`, `a..l`, `y..m` set:

- Row 1 extra: `ü`
- Row 2 extras: `ö`, `ä`

This repo supports overriding those too, so your custom layout can replace them with Hebrew-typist punctuation (gershayim/geresh, maqaf/dash, etc.).

---

## How overrides are applied

A keyboard layout key isn’t just `"x"` — it’s typically an object like:

- `"default": ["e", "è", "é", ...]`
- `"shifted": ["E", "È", "É", ...]`
- or `"special": "shift"`

Early “rip and replace the whole JSON” attempts can produce JSON that parses fine but doesn’t satisfy renderer expectations → **blank OSK**.

This repo is conservative:

- `keyboard_layout.json` is used as a **mapping template**.
- The patcher identifies keys in the base layout by their base Latin letter (`q`, `w`, `e`, …) and also handles the German extras (`ü/ö/ä`).
- It replaces only keys it understands how to replace.
- Special keys remain untouched.

Think: controlled mutation, not a full organ transplant.

---

## Persistence across OS updates (A/B slots)

reMarkable updates use an A/B root filesystem scheme:

- The active slot is mounted as `/`
- Updates get written to the inactive slot
- On reboot, the device switches slots

Anything under `/etc` and `/usr` can vanish when the slot flips.  
`/home/root` survives.

So persistence is achieved by:

- Keeping patcher + layout JSON + logs/state under `/home/root/...`
- Installing systemd units and a xochitl drop-in under `/etc/systemd/system/...`
- Copying those unit files into the inactive slot on shutdown/reboot (slot sync)

### Persistence components
- **rm-customizations.service**  
  Boot-time oneshot that:
  - ensures fontconfig paths
  - rebuilds font caches (fixes “boxes after hard power off”)
  - applies patch if needed (uses patcher `--check`)
  - restarts xochitl  
  Logs: `/home/root/.cache/rm-custom/customizations.log`

- **rm-slot-sync.service**  
  Shutdown/reboot hook that copies unit files + drop-ins (and font mirror) to the inactive slot.  
  Logs: `/home/root/.cache/rm-custom/slot-sync.log`

- **rm-update-watch.service**  
  Watches update state and triggers slot sync when an update is staged.  
  Logs: `/home/root/.cache/rm-custom/update-watch.log`

- **rm-ssh-ensure.service**  
  Tries to keep SSH reachable (especially over USB networking).  
  Logs: `/home/root/.cache/rm-custom/ssh-ensure.log`

---

## Adding another locale (beyond German)

Conceptually, it’s straightforward:

1. Decode the target locale’s keyboard layout JSON (or scan candidates via verbose logs)
2. Add a signature + scoring rule for that locale
3. Add a mapping builder for that locale’s key positions

Practically, it’s still real work because “keyboard layouts” often have variants and special keys.

In Rust, the core touchpoints are:

- `locale_full_sig(locale)` — expected signature rows
- `score_candidate(locale, ...)` — scoring rules
- `build_letter_mapping(locale, over)` — mapping extraction from your override JSON

**German (`de_DE`) is the only locale currently shipped and tested in this repo.**

---

## Debugging + logs (fast)

On-device logs:

```sh
tail -n 200 /home/root/.cache/rm-custom/deploy.log
tail -n 200 /home/root/.cache/rm-custom/customizations.log
tail -n 200 /home/root/.cache/rm-custom/slot-sync.log
tail -n 200 /home/root/.cache/rm-custom/update-watch.log
tail -n 200 /home/root/.cache/rm-custom/ssh-ensure.log
```

If OSK goes blank:
- rollback first
- validate your override JSON structure against `static/de_DE.keyboard_layout.decoded.json`

---

## Disclaimer

Not an official reMarkable project. No warranty. No promises.  
Just meticulous patching, persistence engineering, and a gentle respect for how easily an e‑ink slab can be annoyed.

Have fun, be careful, and keep backups — because the universe is strange and your firmware is stranger.
