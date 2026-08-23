# The repository's own settings

GitHub's settings for this repository are in
[`settings/repo.yml`](../settings/repo.yml): the description, the topics, which
merge buttons exist, the labels, private vulnerability reporting. The file is
the record. The live repository is meant to match it.

Change one in the browser and the file is wrong. Change the file and nothing
happens until someone applies it. So do it in this order.

```sh
$EDITOR settings/repo.yml
make repo-settings                  # dry run: prints what would change
scripts/repo-settings.sh --apply    # writes it
```

The dry run is the default everywhere. `--apply` is the only way the script
writes anything.

Needs the [`gh`](https://cli.github.com) CLI, logged in as someone with admin
on the repository. A token without admin can still read most of it — the
script prints what it cannot read as skipped and carries on.

## Why a file and not the Settings page

Two settings there are load-bearing, and both are invisible once set.

**`squash_merge_commit_title: COMMIT_OR_PR_TITLE`** is what makes
`.githooks/commit-msg` worth running. A single-commit pull request squashes to
that commit's subject, which the hook already checked. Switch it to
`PR_TITLE` and every squash takes the title instead, so the hook stops
protecting anything. The comment at the top of
[`.github/workflows/pr-title.yml`](../.github/workflows/pr-title.yml) is the
long version.

**`web_commit_signoff_required: true`** puts a `Signed-off-by` line on commits
made through the web UI. Without it, the DCO check in
`.github/workflows/dco.yml` fails any pull request that contains one.

Neither shows up in a diff when someone flips it. The weekly check is what
notices.

## The weekly check

[`.github/workflows/repo-settings.yml`](../.github/workflows/repo-settings.yml)
runs `scripts/repo-settings.sh --check` every Monday, and on demand from the
Actions tab. Drift fails the run.

It never applies. Changing settings needs the `administration` permission, and
the default `GITHUB_TOKEN` does not have it — that would take a personal access
token with admin on the repository stored as a secret. Writes stay on the
maintainer's laptop.

## What the file does not cover

| | |
|---|---|
| `homepage` | Empty on purpose. There is no site. The owner sets it in Settings → General when there is one. |
| Discussion categories | **No API can create one.** Not REST, not GraphQL — there is no mutation for it. `has_discussions: true` turns Discussions on; the categories are made by hand in Settings → Discussions. |
| Branch protection, Actions permissions, secrets | Untouched. The script only reads and writes what the file names. |
| Deleting a label | Never. A label the file no longer names is left alone and reported, because deleting one strips it from every issue that carries it. |
