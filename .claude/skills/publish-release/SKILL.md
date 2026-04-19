---
name: publish-release
description: Use after a branch of changes has been merged to main, when the user wants to ship a new zipstream release. End-to-end: picks the next semver, creates and pushes the tag, waits for the GitHub Actions release workflow, then updates the Homebrew tap and Scoop bucket and cleans up local branches. Always confirm the chosen version with the user before tagging.
---

# Publishing a zipstream release

The user runs this after merging a feature/fix branch to `main`. Do all of it in one session; don't split.

## Step 0 — Preflight

```
git fetch origin
git checkout main
git pull --ff-only
```

Abort if `main` is not fast-forwardable — something upstream is divergent and the user needs to resolve it.

Record the previous tag:

```
PREV_TAG=$(git tag --sort=-v:refname | head -1)   # e.g. v0.2.0
```

## Step 1 — Decide the next version (semver)

Inspect commits since `${PREV_TAG}`:

```
git log ${PREV_TAG}..HEAD --pretty=format:'%s%n%b%n---'
```

Apply Conventional Commits rules against the commit subjects + bodies:

| Signal | Bump |
|---|---|
| `BREAKING CHANGE:` in any body, or `!` in any subject type (e.g. `feat!:`) | **major** |
| Any `feat:` / `feat(scope):` | **minor** |
| Only `fix:` / `perf:` / `refactor:` / `docs:` / `chore:` / `test:` | **patch** |
| No user-visible changes at all | do not release — tell the user |

Pre-1.0 note: while `${PREV_TAG}` starts with `v0.`, you may still bump minor on feat and patch on fix — the project has been following that pattern (v0.1.1 → v0.2.0 for wrap-flag feats).

Compute `NEW_TAG` (e.g. `v0.3.0`) and **show the user**:

- the chosen bump (major/minor/patch) and the resulting tag
- a one-line summary of each commit since `${PREV_TAG}` that justified it

Wait for confirmation before continuing. The user can override the bump.

## Step 2 — Create and push the tag

Tag the tip of `main`:

```
git tag -a ${NEW_TAG} -m "${NEW_TAG}"
git push origin ${NEW_TAG}
```

The workflow at `.github/workflows/release.yml` fires on `v*` tags and builds five archives.

## Step 3 — Wait for the release workflow

```
gh run list --workflow=release.yml --limit 1 --json databaseId,status,conclusion,headBranch
```

If `status != completed`, poll or `gh run watch <id>`. Do not proceed until `conclusion == success`. If it fails, stop and surface the logs — do not try to paper over a broken build by publishing anyway.

Sanity check the artifacts exist:

```
gh release view ${NEW_TAG} --json assets --jq '.assets[].name'
```

Expect exactly these five names:

```
zipstream-${NEW_TAG}-aarch64-linux.tar.gz
zipstream-${NEW_TAG}-aarch64-macos.tar.gz
zipstream-${NEW_TAG}-x86_64-linux.tar.gz
zipstream-${NEW_TAG}-x86_64-macos.tar.gz
zipstream-${NEW_TAG}-x86_64-windows.zip
```

If any are missing, stop — the tap/bucket would 404.

## Step 4 — Compute artifact SHA-256s

```
mkdir -p /tmp/zs-rel && cd /tmp/zs-rel && rm -f zipstream-*
for f in \
  zipstream-${NEW_TAG}-aarch64-macos.tar.gz \
  zipstream-${NEW_TAG}-x86_64-macos.tar.gz \
  zipstream-${NEW_TAG}-aarch64-linux.tar.gz \
  zipstream-${NEW_TAG}-x86_64-linux.tar.gz \
  zipstream-${NEW_TAG}-x86_64-windows.zip; do
  curl -fsSL -O "https://github.com/refo/zipstream/releases/download/${NEW_TAG}/$f"
done
shasum -a 256 *
```

Keep the five hashes paired with their filenames.

## Step 5 — Update the Homebrew tap

Repo: `refo/homebrew-tap`. Formula: `Formula/zipstream.rb`.

```
cd /tmp && rm -rf homebrew-tap && gh repo clone refo/homebrew-tap
```

Edit `Formula/zipstream.rb`:
- `version "X.Y.Z"` — **no** `v` prefix
- Four `url` lines: replace the old tag in both the path segment and the filename (appears twice per URL)
- Four `sha256` lines: macOS-arm, macOS-x86, linux-arm, linux-x86

Commit & push:

```
cd /tmp/homebrew-tap && git add Formula/zipstream.rb && git commit -m "zipstream X.Y.Z" && git push
```

## Step 6 — Update the Scoop bucket

Repo: `refo/scoop-bucket`. Manifest: `zipstream.json`.

```
cd /tmp && rm -rf scoop-bucket && gh repo clone refo/scoop-bucket
```

Edit `zipstream.json`:
- `"version": "X.Y.Z"` — **no** `v` prefix
- `architecture.64bit.url` → `.../download/vX.Y.Z/zipstream-vX.Y.Z-x86_64-windows.zip`
- `architecture.64bit.hash` → the windows-zip SHA-256

Leave `autoupdate` alone — it templates `$version`.

Commit & push:

```
cd /tmp/scoop-bucket && git add zipstream.json && git commit -m "zipstream X.Y.Z" && git push
```

## Step 7 — Other install channels (usually untouched)

- **`install.sh`** resolves `releases/latest` via the GitHub API. No edit on release.
- **README "Download binaries"** points at the Releases page, not a tag.
- **"Build from source"** pins Zig toolchain version, not zipstream.

Only touch these if the release changes the Zig version, the OS/arch matrix, or the install contract.

## Step 8 — Clean up local branches

```
git checkout main
git branch --merged main | grep -v '^\*\| main$' | xargs -r git branch -d
git remote prune origin
```

Only delete branches already merged. Never force-delete (`-D`) without confirming with the user.

## Done

Report to the user: new tag, bump reason, tap + bucket commit URLs, and the five artifact filenames. That's the full publish.
