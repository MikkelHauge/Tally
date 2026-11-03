# Releasing Tally

CurseForge packaging runs from the GitHub webhook on `MikkelHauge/Tally`.
No GitHub Actions are required for the package itself.

## One-time setup

1. In the CurseForge project, open **About This Project** and note the numeric
   project ID.
2. Create an API token on the CurseForge API tokens page.
3. In GitHub: **Settings → Webhooks → Add webhook**.
   - Payload URL:
     `https://www.curseforge.com/api/projects/<project-id>/package?token=<token>`
   - Content type: `application/json`
   - Events: just the **push** event
   - SSL verification: on
   - Active: on

Keep the token out of the repository. If it is exposed, regenerate it on
CurseForge and update the webhook URL.

## Packaging

The repository root contains `Tally.toc`, so `.pkgmeta` only needs
`package-as: Tally`. The following are excluded from the addon zip:

- `__pycache__` and `*.pyc`
- `export_tally.py`
- the generated `Tally-Export-<date>.xlsx`
- `README.md` and this file

Update the ignored export filename in `.pkgmeta` if a differently named
workbook is committed.

## Release checklist

1. Bump `## Version:` in `Tally.toc`.
2. Run the Lua checker and the exporter syntax check:
   - `tools/check-lua.ps1` from the parent convenience repository
   - `python -m py_compile export_tally.py`
3. Commit and push `main`.
4. Tag the release:
   - Release: `vYYYYMMDD`
   - Beta: `vYYYYMMDD-beta1`
   - Alpha: `vYYYYMMDD-alpha1`
5. Push the tag:
   - `git push origin vYYYYMMDD`
6. Check GitHub **Webhooks → Recent Deliveries** and the CurseForge project's
   **Files** page.

CurseForge marks a tagged file as Alpha if the tag contains `alpha`, Beta if
it contains `beta`, and Release otherwise. Untagged pushes can also create
Alpha files if “package all commits” is enabled on the CurseForge project.

## Game versions

CurseForge may not recognise the Forever interface version (`16001`) from the
TOC automatically. If the uploaded file has the wrong game version, correct it
on the file page or use a GitHub Action with explicit game-version settings.
