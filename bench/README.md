# Twenty bench infrastructure

The fork's `main` is upstream `twenty/v2.55.0` (`b46d9e25`) plus this directory and the
`.github/workflows/bench-*.yml` files. Nothing under `packages/` differs from the release.

## Workflows

| Workflow | Trigger | What it does |
|---|---|---|
| `bench-preview.yml` | push to `baseline/**`, `phase-1/**`; dispatch `pr_branch` | Creates a GitHub deployment (`environment=preview-<slug>`, `ref=<sha>`), posts `in_progress`, deploys on the box, posts `success` with `environment_url=https://<slug>.<ip-dashed>.sslip.io` once `/healthz`, `/client-config` and `/` answer, else `failure` with `log_url`. |
| `bench-preview-action.yml` | dispatch `pr_branch`, `action`, `request_id` | `reset-db` or `rotate-auth-secret` on an existing preview. Never posts a deployment status. |
| `bench-preview-teardown.yml` | PR closed (head `baseline/*`/`phase-1/*`); dispatch `pr_branch` | Deletes the preview (services, database, worktree), posts `inactive` on the newest deployment. Idempotent. Never deletes the branch. |
| `bench-provision.yml` | dispatch | Finds or creates the one server labelled `outqube-bench=true,role=twenty`, then runs `bench provision`. `list` and `destroy` (dry run unless `confirm_destroy` is the server name). |
| `bench-ops.yml` | dispatch | Status, logs and sign-in/record probes on the box. |

`<slug>` is the branch with `/` replaced by `-`. Secrets used: `HCLOUD_TOKEN`, `BENCH_SSH_PRIVATE_KEY`.
Every job runs on a GitHub-hosted runner and SSHes into the box; scripts are always taken from `main`.

## The box (`/opt/twenty-bench`)

- `repo/`: base checkout of the fork's `main`, dependencies installed (`yarn workspaces focus`), every package built.
- `envs/<name>/src`: a git worktree per environment (`main` and one per preview). `node_modules` are hard links to the base's, build outputs are copies.
- Per environment: its own Postgres database cloned from `twenty_template`, its own Redis, and systemd units `twenty-server@<name>`, `twenty-worker@<name>`. Caddy terminates TLS for `<name>.<ip-dashed>.sslip.io`.
- `secrets/` (mode 700): `bench.env` (Postgres password, the bench-wide `ENCRYPTION_KEY`, seeded passwords), `env/<name>.env`, and `logins.env` (main URL, health URL, admin and member logins) for the Outqube bench deploy.
- `log/events.jsonl`: one line per deploy, action and teardown, with step timings.

## Build path

A push checks out the commit in the preview's worktree, diffs it against the last built commit and rebuilds
only the changed packages and their dependents, in the order of `BUILD_ORDER` in `box/lib/common.sh`.
`twenty-server` and `twenty-front` build in parallel; at most `FRONT_BUILD_SLOTS` (2) front builds run on
the box at once. Lingui catalogs are re-extracted only when the branch changes marked strings; otherwise the
catalogs extracted on the base build are reused. Commits touching the schema or standard metadata run `upgrade`.

## Seed

`workspace:seed:dev` (full), then `box/sql/template-tweaks.sql`: 2FA off, emails verified, every seeded password
replaced (admin `jane.austen@apple.dev`, member `jony.ive@apple.dev`, generated passwords), Month-first dates,
the Screening stage left empty, and three open tasks on Google (due yesterday, today and tomorrow, refreshed on
every clone by `clone-tweaks.sql`).

## Runner actions

- `reset-db`: drop the preview database, re-clone it from the template, restore storage, flush Redis, restart.
  This also signs everyone out.
- `rotate-auth-secret`: new `APP_SECRET` (the bench-wide `ENCRYPTION_KEY` is kept), revoke every
  `core."userSession"` and refresh token, retire the signing keys, flush Redis, restart. The action signs in
  before and after, and fails unless the earlier refresh token is rejected and a new one renews.
