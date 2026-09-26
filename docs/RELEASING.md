# Releasing CraftBoard

1. Bump `## Version:` in `CraftBoard/CraftBoard.toc` (semver, e.g. `0.2.0`).
2. Move `## [Unreleased]` notes into a new `## [X.Y.Z] - YYYY-MM-DD` section in `CHANGELOG.md` and update the compare links.
3. Run `tools/check.sh`, then `tools/package.sh` and test the zip from `dist/` in game.
4. Commit: `git commit -am "Release vX.Y.Z"`.
5. Tag and push: `git tag vX.Y.Z && git push && git push --tags`.
6. The tag triggers `.github/workflows/release.yml` (BigWigsMods/packager@v2).
7. Repo secrets required: `CF_API_KEY` (CurseForge API token) and `GITHUB_OAUTH` (token with `contents: write`).
8. CurseForge upload also needs the project id: `-p <id>` in the workflow args or `## X-Curse-Project-ID:` in the TOC.
9. If the workflow fails: GitHub > Actions > Release > the failed run; the packager logs game version and upload errors in its own steps.
10. Fallback: upload `dist/CraftBoard-X.Y.Z.zip` from `tools/package.sh` to CurseForge by hand, game version Forever.
