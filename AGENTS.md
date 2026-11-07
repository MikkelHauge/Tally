# AGENTS.md

Tally is a statistics addon for **WoW Forever 1.60.1** (`## Interface: 16001`),
written in Lua. The repository root is the addon root: `Tally.toc` is here.

## Releasing

**Before doing anything release-related, stop and read
[RELEASE.md](RELEASE.md) in full.** That includes version bumps, tags, GitHub
releases, CurseForge packaging and verification. It is the single source of
truth; if this file and `RELEASE.md` ever disagree, `RELEASE.md` wins and this
file should be corrected. Do not invent a release process.

## Non-negotiables

- One version everywhere: `Tally.toc`, tag `v<version>`, GitHub release title,
  the new top section of `CHANGELOG.md`, and the CurseForge display name.
- Every release gets a new section at the top of `CHANGELOG.md` (newest first).
- CurseForge is triggered by the **pushed tag**, not by the GitHub release.
- New CurseForge files stay in **processing** for 10-20 minutes and are hidden
  from the public API until approved. Do not redeliver the webhook; that can
  create duplicate files.
- CurseForge game version must be `17053` (WoW Forever 1.60.1) only.
- Zip entries must use `/` separators and live under a single `Tally/` folder.
  Do not use `Compress-Archive` or .NET `CreateFromDirectory` on Windows.
- Never commit tokens or secrets. The CurseForge webhook token belongs only in
  the GitHub webhook URL.

## Common commands

```powershell
# Lua checker (walks the TOC)
powershell -NoProfile -File D:\projects\Convenient\tools\check-lua.ps1

# Exporter syntax check
cd D:\projects\Convenient\Tally-Tools
python -m py_compile export_tally.py

# Copy the addon into the game for testing
powershell -NoProfile -ExecutionPolicy Bypass -File D:\projects\Convenient\Tally-Tools\install-test.ps1
```

## Client quirks that have caused real bugs

- This client's Lua has **no `os` table**: use the global `date()` and `time()`.
- After `/reload` only `ADDON_LOADED` fires; `PLAYER_LOGIN` and
  `PLAYER_ENTERING_WORLD` do not. Do not rely on them alone.
- Protected calls such as `SetRaidTarget` are refused from `/run` macros; use
  `/tm 1-8`.
