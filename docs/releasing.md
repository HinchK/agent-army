# Releasing

`VERSION` is the only release string. `army version` prints it. A release is
an annotated tag `vX.Y.Z` on the merge commit that lands `develop` on `main`.
The changelog date is the tag date.

## Freeze

1. Fetch `origin` and fast-forward local `main` to `origin/main`.
2. Branch or update `develop` from that tip.
3. Land the release commits on `develop`: the version bump, `CHANGELOG.md`,
   and any fix the release gate actually requires.
4. After the freeze, product work waits for the tag.

## Prove the branch

```bash
make check
git push -u origin develop
```

Push `develop` only. Do not push `origin/main` from this repo's tools, and do
not run `gh pr merge`.

## Canary

Run [the canary mission](superpowers/plans/2026-11-08-canary-mission.md) on the `develop`
SHA you intend to release. Commander auth has to be ready before the run. A
pass is:

- `bin/army run` exits 0
- the canary repo has `.agent-army/COMPLETE.md`
- canary `main` has moved past the seed commit and `make test` passes there
- `git remote` in the canary repo prints nothing

A failure is fixed on `develop`. Run `make check` again, then repeat the
canary on the new SHA. Record the SHA and the result in the release pull
request.

## Merge and tag

Open a pull request from `develop` into `main`. Merge it with a merge commit.
After the merge, the two branches have the same tree:

```bash
git fetch origin
git diff --stat origin/develop origin/main
```

That diff is empty before the tag. On the merge commit:

```bash
git checkout main
git pull --ff-only origin main
git tag -a vX.Y.Z -m "Agent Army X.Y.Z"
git push origin vX.Y.Z
gh release create vX.Y.Z --title "vX.Y.Z" --notes-file <the changelog section>
git checkout develop
git merge main
git push origin develop
```

The tag stays where it was created. The next fix is the next patch version.

## GitHub settings

`main` requires a pull request, requires the `check` workflow, and rejects
force-pushes. `develop` requires the same check.
