# Releasing Tally

This is the complete release procedure for Tally, a statistics addon for
**WoW Forever 1.60.1** (`## Interface: 16001`).

A release is one version number, one commit, one tag, one GitHub release, one
CurseForge file and one changelog entry. All six must agree.

Section "Setting up a new addon" applies to every addon on this machine. The
rest uses Tally as the example (its project ID, webhook ID and paths).

---

## Setting up a new addon (one-time)

Do this once per addon, before its first release. It is the only part that is
not about tagging.

**This part is manual.** Creating the CurseForge project, generating the API
token and adding the GitHub webhook all happen in a browser (the CurseForge
author dashboard and the repository's GitHub settings). There is no repository
command that creates them, and a coding agent cannot do it without your
CurseForge account. Once the webhook exists, every release after that is
automatic from the tag push.

1. **Create the CurseForge project.** In the author dashboard, create a
   project for the addon (World of Warcraft -> Addons) and tick the game
   versions it should support.

2. **Find the project ID.** It is the number in the project's dashboard URL:

   ```
   https://authors.curseforge.com/#/projects/<project-id>/files
   ```

   Example: `https://authors.curseforge.com/#/projects/1791127/files` means
   the project ID is **1791127**. That number, not the project name or slug,
   goes in the webhook URL.

3. **Generate an API token.** Open
   `https://authors.curseforge.com/#/settings/api-tokens`, create a token
   (name it "Webhooks"), and copy it. It is shown once. The token is
   account-level; the project is selected by the ID in the URL, so the same
   token can serve every project you own. Treat it as a secret - never commit
   it or put it in a repository file.

4. **Add the GitHub webhook.** Open the repository's webhook settings:

   ```
   https://github.com/<owner>/<repo>/settings/hooks
   ```

   Example: `https://github.com/MikkelHauge/Tongues/settings/hooks`.
   Choose **Add webhook** and use:

   - **Payload URL:**
     `https://www.curseforge.com/api/projects/<project-id>/package?token=<api-token>`
     (for example `.../projects/1791127/package?token=...`)
   - **Content type:** leave the default
     (`application/x-www-form-urlencoded`) - CurseForge's docs say to leave
     all other settings at their defaults.
   - **Events:** just the **push** event.
   - **Secret:** empty.
   - **SSL verification:** enabled.
   - **Active:** checked.

   GitHub sends a `ping` immediately; a `200` in **Recent Deliveries** means
   the URL and token are accepted.

5. **Add `.pkgmeta`** at the repository root, next to the TOC:

   ```yaml
   package-as: <AddonFolderName>

   ignore:
     - README.md
     - LICENSE
     - CHANGELOG.md
   ```

   Without `package-as`, CurseForge names the folder after the project's URL
   slug.

6. **Make the first release** by bumping the version, committing and pushing a
   tag - the release steps below. A brand-new project cannot be approved until
   it has a file, so the first tag is what gives it one.

After that, every release is just: bump, commit, push `main`, tag, push tag.

---

## 1. Facts and paths

| Thing | Value |
| --- | --- |
| GitHub repository | `https://github.com/MikkelHauge/Tally` |
| Default branch | `main` |
| CurseForge project | Tally - Statistics Tracker, id `1780522` |
| CurseForge game version | WoW Forever 1.60.1, id `17053` |
| TOC interface | `16001` (Forever only - never add Retail or Classic) |
| Addon source | `D:\projects\Convenient\Tally` |
| Release tooling | `D:\projects\Convenient\Tally-Tools` |
| Game install used for testing | `G:\Games\World of Warcraft\_forever_\Interface\AddOns\Tally` |
| Lua checker | `D:\projects\Convenient\tools\check-lua.ps1` |
| GitHub CLI | `gh`, authenticated as `MikkelHauge` with `repo` scope |

The CurseForge webhook is attached to the GitHub repository (webhook id
`706838071`, `push` event only). Its token lives in the webhook URL on GitHub.
**Never commit the token** and never paste it into a repository file.

---

## 2. Version scheme

- `Tally.toc` carries `## Version: YYYYMMDD.N`.
- The git tag is `vYYYYMMDD.N` - a **lightweight** tag on the release commit.
- `.N` increments for every release on the same day: `20261107.1`,
  `20261107.2`, ...
- Never reuse a version or move an existing tag. If a build is bad, ship the
  next number.

The version must be identical in these places:

- `Tally/Tally.toc` (`## Version:`)
- the git tag (`v` + version)
- the GitHub release title (`v<version> - Forever`)
- the top section of `Tally/CHANGELOG.md`
- the CurseForge display name (`<version> - Forever` for manual uploads)

---

## 3. Files that matter

| File | Purpose |
| --- | --- |
| `Tally/Tally.toc` | Version and interface. |
| `Tally/CHANGELOG.md` | Every release, newest first. Updated on every release. |
| `Tally/.pkgmeta` | CurseForge packaging. `package-as: Tally`; ignores README, LICENSE, CHANGELOG, RELEASE.md, AGENTS.md. |
| `Tally-Tools/dist/release-notes-<version>.md` | Notes used for the GitHub release. |
| `Tally-Tools/dist/curseforge-metadata-<version>.json` | Only needed for a manual CurseForge upload. |
| `Tally-Tools/dist/Tally-<version>-Forever-GitHub.zip` | Release asset, includes README.md and LICENSE. |
| `Tally-Tools/dist/Tally-<version>-Forever-CurseForge.zip` | Release asset and manual-upload fallback, docs excluded. |
| `Tally-Tools/install-test.ps1` | Copies the addon to the game folder. |

`Tally-Tools` is local tooling; it is not part of the addon repository or the
addon zip. `CHANGELOG.md`, `RELEASE.md` and `AGENTS.md` live in the repository
but are **excluded from the addon zip** by `.pkgmeta`.

---

## 4. Step by step

### 4.1 Implement, then verify

1. Make the code and data changes.
2. Run the Lua checker over every file listed in the TOC:

   ```powershell
   powershell -NoProfile -File D:\projects\Convenient\tools\check-lua.ps1
   ```

   It must end with `RESULT: all checks passed`.

3. Check the exporter still parses:

   ```powershell
   cd D:\projects\Convenient\Tally-Tools
   python -m py_compile export_tally.py
   ```

4. Copy the build to the game and smoke-test it in game:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File D:\projects\Convenient\Tally-Tools\install-test.ps1
   ```

   It prints `lua match` and the TOC interface. Verify `## Version:` in the
   installed TOC.

5. In game: log in, open Tally, visit each changed tab, `/reload`, and open the
   changed tab again.

Client quirks worth remembering (they have caused "bugs" before):

- After `/reload` this client raises only `ADDON_LOADED`. `PLAYER_LOGIN` and
  `PLAYER_ENTERING_WORLD` do not arrive, so code must not depend on them alone.
- This client's Lua sandbox has **no `os` table**. Use the game's global
  `date()` and `time()`. Calling `os.date` throws and blanked Merchant's Favor.
- Protected functions cannot be called from insecure `/run` Lua. Raid markers
  need `/tm 1-8`.

### 4.2 Bump the version and the changelog

1. Edit `Tally/Tally.toc`:

   ```toc
   ## Version: 20261107.1
   ```

2. Add a new section at the **top** of `Tally/CHANGELOG.md` (after the intro,
   before the previous release). Use the date and group user-visible changes:

   ```markdown
   ## 20261107.1 - 7 November 2026

   **Fixed**

   - What was broken and what happens now.

   **Added**

   - New commands, pages or settings.
   ```

   Describe behaviour, not the debugging that found it. Mention data repairs
   or one-time migrations, because users will notice them.

### 4.3 Commit and push `main`

```powershell
cd D:\projects\Convenient\Tally
git add -A
git -c core.autocrlf=false commit -m "Short summary" -m "Longer paragraph per change."
git push origin main
```

Two known quirks:

- CRLF warnings from `git add` are normal; ignore them.
- The push can print `remote: - Changes must be made through a pull request.`
  and return exit code 1 **while still updating `main`**. Always verify:

  ```powershell
  git ls-remote origin refs/heads/main
  git rev-parse HEAD
  ```

  The two hashes must match.

### 4.4 Tag the release and push the tag

```powershell
git tag v20261107.1
git push origin v20261107.1
git ls-remote --tags origin v20261107.1
```

Use a lightweight tag (no `-a`), matching every previous release. **The pushed
tag is what makes CurseForge publish a versioned release file.** The
`main`-branch push also delivers a webhook, but without a new release tag it
does not create a release file. Creating the GitHub release does not trigger
CurseForge at all. The tag name also sets the CurseForge release type - see
below.

### 4.5 CurseForge packaging (automatic)

The pushed tag makes GitHub deliver a `push` webhook; CurseForge packages the
repository at that tag and creates a file named `Tally-v<version>.zip`.

#### Webhook configuration (one-time)

See **Setting up a new addon (one-time)** above for creating the project,
finding the project ID, generating the API token and adding the GitHub
webhook. The values below are the ones to use.

CurseForge's Automatic Packaging documentation specifies the payload URL and
says to **leave all other GitHub webhook settings at their defaults**:

- **Payload URL:**
  `https://www.curseforge.com/api/projects/<project-id>/package?token=<token>`
- **Content type:** leave the GitHub default
  (`application/x-www-form-urlencoded`). Do not switch it to
  `application/json`; CurseForge reads the form-encoded payload that the
  default sends.
- **Events:** `push` only.
- **Secret:** empty.
- **SSL verification:** enabled.
- **Active:** checked.

The token is account-level; the project is selected by `<project-id>` in the
URL. The token lives only in the webhook URL on GitHub and must never be
committed or pasted into a repository file.

`.pkgmeta` (or `pkgmeta.yaml`) must sit at the repository root, next to
`Tally.toc`. The packaged folder is named by `package-as`; without it,
CurseForge uses the project's URL slug. Other optional keys include
`manual-changelog` (a file whose contents become the file changelog),
`license-output` (includes the license in the package files) and
`move-folders`.

#### Release type comes from the tag

- Tag contains `alpha` (for example `v20261107-alpha1`) -> **Alpha** file.
- Tag contains `beta` (for example `v20261107-beta1`) -> **Beta** file.
- Any other tag (for example `v20261107.1`) -> **Release** file.

If **"package all commits"** is enabled on the CurseForge project, untagged
pushes also create **Alpha** files. Leave it off unless alpha builds from every
commit are wanted; otherwise a normal `main` push leaves an extra Alpha file
behind.

Check the delivery:

```powershell
gh api repos/MikkelHauge/Tally/hooks --jq '.[] | {id, active, events}'
gh api repos/MikkelHauge/Tally/hooks/706838071/deliveries --jq '.[0] | {at: .delivered_at, status_code, status}'
```

- `status_code: 200` and response `{"success":true}` mean **queued**, not
  published.
- CurseForge then scans the file. New files stay in **processing** for roughly
  10-20 minutes and are **hidden from the public API** until approved.
- Confirm progress in the author dashboard:
  `https://authors.curseforge.com/#/projects/1780522/files`
- The public list (only approved files) is:
  `https://www.curseforge.com/api/v1/mods/1780522/files?pageIndex=0&pageSize=5`

Do **not** redeliver the webhook while a file is processing. A redelivery can
create a second identical file for the same version; delete the duplicate in
the author dashboard if it happens.

If the webhook genuinely fails (no file in the dashboard after ~30 minutes),
upload manually from the author dashboard. Create
`Tally-Tools/dist/curseforge-metadata-<version>.json`:

```json
{
  "changelog": "<contents of the release notes file>",
  "changelogType": "markdown",
  "displayName": "20261107.1 - Forever",
  "gameVersions": [17053],
  "releaseType": "release"
}
```

Upload `Tally-<version>-Forever-CurseForge.zip` with that metadata. The webhook
token is **not** accepted by the upload API; a manual API upload needs a
personal CurseForge API token, so prefer the dashboard.

`gameVersions` must contain only `17053` (WoW Forever 1.60.1).

### 4.6 Write the release notes

Create `Tally-Tools/dist/release-notes-<version with dots replaced by dashes>.md`,
for example `release-notes-20261107-1.md`.

Start with the build line, then sections, then the build/install footer:

```markdown
Build for WoW Forever 1.60.1 (`## Interface: 16001`).

## <Area>
- What changed for the player.

## Build
- Forever only: `## Interface: 16001`.
- CurseForge game version: WoW Forever 1.60.1 only.

Install by extracting the `Tally` folder into `World of Warcraft/_forever_/Interface/AddOns`.
```

Keep it player-facing: symptoms and results, not internal function names.

### 4.7 Build the two zips

Rules:

- The archive root is a single `Tally/` folder; extracting it must produce
  `Interface/AddOns/Tally/Tally.toc`.
- Entry names must use **forward slashes** (`Tally/Core.lua`, not
  `Tally\Core.lua`). PowerShell's `Compress-Archive` and
  `[IO.Compression.ZipFile]::CreateFromDirectory` on Windows write
  backslashes; do not use them.
- The **GitHub** zip includes `README.md` and `LICENSE`.
- The **CurseForge** zip excludes them. Neither zip includes `CHANGELOG.md`,
  `RELEASE.md`, `AGENTS.md`, `.pkgmeta` or tooling.

Save this as `Tally-Tools/build-release.py` (local tooling; not committed) and
run `python build-release.py` from anywhere:

```python
import os
import re
import zipfile

ROOT = r"D:\projects\Convenient\Tally"
DIST = r"D:\projects\Convenient\Tally-Tools\dist"

toc = open(os.path.join(ROOT, "Tally.toc"), encoding="utf-8-sig").read()
version = re.search(r"^## Version:\s*(\S+)", toc, re.M).group(1)


def build(path, include_docs):
    if os.path.exists(path):
        os.remove(path)
    z = zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED)
    z.writestr(zipfile.ZipInfo("Tally/"), "")
    for name in sorted(os.listdir(ROOT)):
        p = os.path.join(ROOT, name)
        if not os.path.isfile(p):
            continue
        if name.endswith(".lua") or name == "Tally.toc":
            z.write(p, "Tally/" + name)
        elif include_docs and name in ("README.md", "LICENSE"):
            z.write(p, "Tally/" + name)
    for folder in ("Core", "UI"):
        z.writestr(zipfile.ZipInfo("Tally/" + folder + "/"), "")
        d = os.path.join(ROOT, folder)
        for name in sorted(os.listdir(d)):
            if name.endswith(".lua"):
                z.write(os.path.join(d, name), "Tally/" + folder + "/" + name)
    z.close()
    with zipfile.ZipFile(path) as check:
        names = check.namelist()
        assert not [n for n in names if "\\" in n], "backslash in entry name"
        assert "Tally/Tally.toc" in names
        assert ("Tally/README.md" in names) == include_docs
        print(os.path.basename(path), len(names), "entries")


build(os.path.join(DIST, f"Tally-{version}-Forever-GitHub.zip"), True)
build(os.path.join(DIST, f"Tally-{version}-Forever-CurseForge.zip"), False)
```

Then verify the version inside both archives:

```powershell
python -c "import zipfile; print([l for l in zipfile.ZipFile(r'D:\projects\Convenient\Tally-Tools\dist\Tally-20261107.1-Forever-CurseForge.zip').read('Tally/Tally.toc').decode('utf-8-sig').splitlines() if 'Version' in l])"
```

### 4.8 Create the GitHub release

Create it with the GitHub zip, then attach the CurseForge zip:

```powershell
cd D:\projects\Convenient\Tally
gh release create v20261107.1 `
  --title "v20261107.1 - Forever" `
  --notes-file "D:\projects\Convenient\Tally-Tools\dist\release-notes-20261107-1.md" `
  "D:\projects\Convenient\Tally-Tools\dist\Tally-20261107.1-Forever-GitHub.zip"

gh release upload v20261107.1 "D:\projects\Convenient\Tally-Tools\dist\Tally-20261107.1-Forever-CurseForge.zip"
```

Both assets must be present:

```powershell
gh release view v20261107.1 --json assets --jq '.assets[] | {name, size, state}'
```

### 4.9 Final verification

- [ ] `git ls-remote origin refs/heads/main` equals `git rev-parse HEAD`.
- [ ] `git ls-remote --tags origin v<version>` points at that commit.
- [ ] GitHub release is published (not draft), has the notes and both zips.
- [ ] Each zip contains `Tally/Tally.toc` with the new `## Version:` and uses
      `/` separators; the CurseForge zip has no README/LICENSE.
- [ ] `Tally/CHANGELOG.md` top section is this release.
- [ ] CurseForge dashboard shows the file as processing or approved, with game
      version 1.60.1 only. The public page shows it after approval.
- [ ] Installed game copy reports the new version.

---

## 5. Quick checklist

1. Checker and `py_compile` pass.
2. Install and smoke-test in game.
3. Bump `Tally.toc`; add the CHANGELOG section.
4. Commit and push `main`; verify the remote hash.
5. Tag `v<version>` and push the tag; verify it on the remote.
6. Watch the webhook delivery; wait for CurseForge processing.
7. Write release notes.
8. Build both zips with forward slashes.
9. Create the GitHub release with both assets.
10. Run the final verification list.

---

## 6. Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `remote: - Changes must be made through a pull request.` and exit code 1 | The push still updated `main`; confirm with `git ls-remote`. |
| GitHub zip extracts as one file, or entries contain `\` | The zip was built with a Windows .NET API. Rebuild with the Python script above. |
| CurseForge file missing from the public list | It is still processing. Check the author dashboard; wait 10-20 minutes. |
| Two identical CurseForge files | The webhook was redelivered. Delete one in the dashboard. |
| Favor graph blank / `attempt to index global 'os'` | This client has no `os` table. Use `date()` and `time()`. |
| Tabs empty after `/reload` | The client sends only `ADDON_LOADED`. Keep the character-selection retry. |
| `SetRaidTarget` refused, Tally named | A macro used `/run`, which is insecure Lua. Use `/tm 1-8`. |
| CurseForge upload API redirects to `/error` | A webhook token is not an upload token. Upload from the dashboard or use a personal API token. |
