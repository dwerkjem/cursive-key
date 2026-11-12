# Per-PR preview deploys with D1, migrations and secrets

_Researched 2026-11-12 for [#5](https://github.com/dwerkjem/cursive-key/issues/5). Sources are Cloudflare and GitHub first-party docs; each citation gives the page's "last updated" date as shown on 2026-11-12. Cloudflare's Worker Previews feature launched on 2026-09-22, so recheck it before building._

## Answer in brief

Use **Worker Previews** (`wrangler preview`), not Version URLs and not separate per-PR Workers. Each PR gets a Preview named `pr-<number>` under the one production Worker, with its own bindings, secrets and URL. Previews sit behind Cloudflare Access ("Previews only" scope). They bind to a **shared preview D1 database** that follows `main`'s schema. A PR that adds a migration gets its **own throwaway D1 database**, created, migrated and seeded in CI, then deleted when the PR closes. Migrations are **forward-only and expand-then-contract**, applied **before** the code deploys. Fork PRs get **no secrets and no Preview**: they run build and test only, under plain `pull_request` (never `pull_request_target`). Production deploys on push to `main` from a GitHub `production` environment that only `main` can use. Recovery is `wrangler rollback` for code and D1 Time Travel for data (7 days on Free).

## 1. Previews vs Version URLs vs separate Workers

| Option | What it is | Fit for per-PR |
|---|---|---|
| **Worker Previews** (`wrangler preview`) | "An isolated, production-like environment under the same Worker", with its own variables, secrets, bindings, URL and observability ([Previews](https://developers.cloudflare.com/workers/previews/), 2026-09-24) | **Yes.** Cloudflare calls it "the recommended way to test changes before production" ([Compare workflows](https://developers.cloudflare.com/workers/previews/compare-workflows/), 2026-09-22) |
| Version URLs (`wrangler versions upload --preview-alias`) | An uploaded version that "uses that Worker version's existing configuration and resources instead of creating a separate environment" ([Version URLs](https://developers.cloudflare.com/workers/configuration/previews/), 2026-09-22) | **No.** They run against **production bindings**, so a PR would write to the production D1. Cloudflare says not to use them for branch or PR testing. They were called "preview URLs" until recently, which makes older guides misleading. |
| Separate Workers (`wrangler deploy --env pr-123`) | A separately named Worker per environment ([Compare workflows](https://developers.cloudflare.com/workers/previews/compare-workflows/)) | Works, but it is the pre-Previews workaround. You manage Worker lifecycle, Access and secrets per Worker. Not needed now. |

**Mechanics** ([Previews](https://developers.cloudflare.com/workers/previews/), [Configuration](https://developers.cloudflare.com/workers/previews/configuration/), [Get started](https://developers.cloudflare.com/workers/previews/get-started/), [Wrangler commands](https://developers.cloudflare.com/workers/wrangler/commands/workers/), 2026-09-22 to 2026-10-26):

- Needs **Wrangler 4.135.0 or later** as a project dependency; a newer global install isn't used.
- `npx wrangler preview --name pr-123 --json` creates or updates a Preview. `--name` defaults to the git branch. The production Worker doesn't need to be deployed first.
- Each Preview has a stable **Preview URL** (`pr-123-<worker>.<subdomain>.workers.dev`) that always serves the latest deploy. Each deploy also gets an immutable **Deployment URL**. Previews on `workers.dev` automatically send `X-Robots-Tag: noindex`; Previews on a custom domain need a wildcard certificate and don't get that header ([Custom domains](https://developers.cloudflare.com/workers/previews/custom-domains/), 2026-11-08). **Use `workers.dev` for Previews** until a domain is chosen.
- Previews **don't inherit production settings**. Bindings and `vars` go in a `previews` block of the Wrangler config. `assets` and `compatibility_date` stay at top level, and `wrangler preview` uploads the branch's own static assets.
- Previews don't support Cron Triggers, Queue consumers or production routes. Service bindings from a Preview call the **production** deployment of the other Worker. `wrangler tail` doesn't work on Previews; use Workers Observability, which you configure in `previews` ([Resources and isolation](https://developers.cloudflare.com/workers/previews/resources/), 2026-11-09; [Test and debug](https://developers.cloudflare.com/workers/previews/test-and-debug/), 2026-10-10).

**Free plan limits** ([Previews](https://developers.cloudflare.com/workers/previews/)):

| Limit | Free | Paid |
|---|---|---|
| Previews per Worker | 100 | 500 |
| Deployments per Preview | 100 | 100 |

When the limit is reached, Cloudflare deletes the least recently deployed Preview (or the oldest deployment in a Preview). The docs don't say whether Preview requests count toward the 100,000 Worker requests per day on Free, and they don't price Previews. Ticket #7 should cover that.

**Workers Builds** (Cloudflare's own CI) also runs `wrangler preview` per PR and comments the URL. Free plan: 3,000 build minutes per month, 1 concurrent build, 20-minute timeout ([Limits](https://developers.cloudflare.com/workers/ci-cd/builds/limits-and-pricing/), 2026-10-28). It's **not recommended here** for three reasons. The map already chose GitHub Actions. The eight test layers have to run in Actions anyway. And I found no Workers Builds doc saying how it treats fork PRs or secrets ([GitHub integration](https://developers.cloudflare.com/workers/ci-cd/builds/git-integration/github-integration/), 2026-11-10). That gap matters for a public repo.

## 2. D1 per Preview

### What Cloudflare provides

- D1 is **not** isolated automatically. Previews bound to the same `database_id` share data, so isolation means binding a different database ([Resources and isolation](https://developers.cloudflare.com/workers/previews/resources/), 2026-11-09).
- Cloudflare's documented pattern has four parts. First, a **shared staging database** under `previews.d1_databases` on the base branch. Second, a separate `wrangler.preview-migrations.jsonc` that names the same database at top level, so `wrangler d1 migrations apply PREVIEW_DB --remote --config wrangler.preview-migrations.jsonc` targets it. Third, optionally, a branch can point both files at its own database. Fourth, "apply migrations to the branch's database before deploying its Preview" (same page; [Configuration](https://developers.cloudflare.com/workers/previews/configuration/), 2026-09-22).
- Seeding isn't covered by the Previews docs. `wrangler d1 execute <db> --remote --file seed.sql -y` runs a SQL file ([D1 commands](https://developers.cloudflare.com/workers/wrangler/commands/d1/), 2026-04-23).

### Free-plan constraints that shape the choice

([D1 limits](https://developers.cloudflare.com/d1/platform/limits/), [D1 pricing](https://developers.cloudflare.com/d1/platform/pricing/), both 2026-10-30)

- **10 databases per account** on Free. Production and the shared preview database use 2, which leaves **8** for per-PR databases.
- 500 MB per database and 5 GB per account. Storage is "the sum of all databases in your account".
- 5M rows read and 100K rows written per day. Once the limit is hit, queries fail until 00:00 UTC. The docs don't say whether this budget is per account. If it is, Previews and production share it. Ticket #7 should confirm.

### The three options

| Option | Good | Bad |
|---|---|---|
| **One shared preview DB** | Cloudflare's default; 1 database; nothing to clean up | Two PRs with migrations collide. If PR B's migration is renumbered after PR A merges, it is re-applied under a new name and fails with "table exists". The shared database drifts from `main` and needs manual resets. |
| **DB per PR, always** | Full isolation | Hard cap of 8 open PRs. Every PR pays for a create, migrate and seed. Leaked databases (from failed cleanups) quickly hit the cap. |
| **Hybrid (recommended)** | Most PRs reuse the shared database at zero cost; only PRs that change `migrations/` get their own | One more CI branch in the workflow |

### Recommended: hybrid

1. **Shared preview database** `cursive-key-preview`, bound under `previews.d1_databases` in the committed config. **Only the `main` workflow migrates it**, right after production, so its schema always equals `main`'s. A PR without migrations matches it exactly.
2. **A PR that changes `migrations/`** gets `cursive-key-pr-<n>`. CI runs `wrangler d1 create` the first time, rewrites the D1 `database_id` in the **checked-out** config before running `wrangler preview`, applies all migrations, then seeds. The rewrite is a small script and is **never committed**: Cloudflare's per-branch override edits the committed file, which would then merge into `main`. A CI step counts existing databases and fails clearly at the cap instead of silently.
3. **Seed data is synthetic only**: `seed/preview.sql` with fake Persons, Access Requests and Feedback. Previews **never get a copy of production data**. Production D1 holds personal data (Access Request emails, Personal Settings, Feedback; see #11), and every Beta Tester allowed through the Preview Access policy could see it.
4. **Reset** is a manual `workflow_dispatch` job. It drops every table in the shared preview database, re-applies `main`'s migrations and re-seeds. Use it if the database ever drifts.

## 3. Migrations: applying and "rolling back" safely

**Facts** ([D1 commands](https://developers.cloudflare.com/workers/wrangler/commands/d1/), 2026-04-23; [D1 migrations](https://developers.cloudflare.com/d1/reference/migrations/), 2026-06-08):

- Migrations are numbered `.sql` files in `migrations/`. Applied ones are recorded in a `d1_migrations` table.
- `wrangler d1 migrations apply <db> --remote` skips its confirmation prompt in CI, and "after applying, a backup will be captured."
- On failure, "this migration will be rolled back, and the previous successful migration will remain applied". Each file is its own unit, not one transaction for the whole run.
- There are **no down migrations**.
- Rolling back a Worker leaves resources alone: "Resources connected to your Worker will not be changed during a rollback," and "errors could occur if using code for a prior version if the structure of data has changed" ([Rollbacks](https://developers.cloudflare.com/workers/configuration/versions-and-deployments/rollbacks/), 2026-11-12).

**Rules that follow:**

1. **Forward-only.** Undo a migration with a new migration, never by editing an applied file.
2. **Expand, then contract.** A migration in a PR may only **add**: new tables, nullable columns, indexes. Drops and renames ship in a **later** PR, after no deployed code (including the version you might roll back to) still reads the old shape. Then two things are always true: the running code works against the migrated schema, and `wrangler rollback` to the previous version is safe.
3. **Migrate, then deploy.** In the production job, `migrations apply` runs before `wrangler deploy`. If a migration fails, the job stops and the old code keeps running against a schema that is at worst partly expanded. By rule 2 that is still compatible.
4. **Test migrations in every PR, including forks, with no secrets.** Run `wrangler d1 migrations apply <db> --local` against the local D1 in the test job, then run the integration tests (#4) against it.
5. **Record a Time Travel bookmark before migrating production.** `wrangler d1 time-travel info cursive-key --json` goes into the job log, so a data restore has a known target (§6).

## 4. Secrets, Access service tokens and fork PRs

### GitHub's rules ([Events that trigger workflows](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows); [Secure use reference](https://docs.github.com/en/actions/reference/security/secure-use); [Deployments and environments](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments); no dates shown, read 2026-11-12)

- On `pull_request` from a fork, "secrets are not passed to the runner" and "the `GITHUB_TOKEN` has read-only permissions." Dependabot PRs are treated the same way.
- `pull_request_target` runs with secrets in the base repo's context. GitHub says "avoid using this event if you need to build or run code from the pull request" and that such workflows "must not explicitly check out untrusted code." Building a Preview means running the PR's code, so **`pull_request_target` is ruled out**.
- First-time contributors to a public repo may need a maintainer's approval before workflows run. GitHub warns to be "especially alert to any proposed changes in the `.github/workflows/` directory" ([Approve runs from forks](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/approve-runs-from-forks)).
- **Environments**: environment secrets are "only available to workflow jobs that reference the environment". "Selected branches and tags" limits which refs can deploy to it. Required reviewers are available on public repos on GitHub Free.

### Cloudflare's rules

- CI needs `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`. Create the token from the "Edit Cloudflare Workers" template and limit it to one account ([GitHub Actions](https://developers.cloudflare.com/workers/ci-cd/external-cicd/github-actions/), 2026-10-18). The preview workflow also needs **D1 Edit**.
- **API token permissions are account-scoped.** Workers Scripts Edit and D1 Edit can't be limited to one Worker or one database, and there's no preview-only permission ([API token permissions](https://developers.cloudflare.com/fundamentals/api/reference/permissions/), 2026-10-30). So **any token that can deploy a Preview can also deploy production and write to the production D1**. Splitting the token between GitHub environments gives a cleaner audit trail but **not** a hard security boundary.
- Cloudflare's own example guards credentials with `github.event.pull_request.head.repo.full_name == github.repository` ([Automation examples](https://developers.cloudflare.com/workers/previews/automation-examples/), 2026-10-01).
- **Worker runtime secrets** for Previews are set once by an Admin from a laptop, not by CI. Use `wrangler preview base-config secret put NAME` for all new Previews, or `wrangler preview secret put NAME --name pr-123` for one. Base changes reach **new** Previews only ([Configuration](https://developers.cloudflare.com/workers/previews/configuration/)). Production uses `wrangler secret put`.

### Cloudflare Access on Previews

- On the Worker's **Access** tab, choose **"Previews only"** or "All traffic". Worker-level Access covers routes, custom domains, `workers.dev` and Previews ([Workers: Cloudflare Access](https://developers.cloudflare.com/workers/configuration/cloudflare-access/), 2026-11-02). One-click Access on Preview URLs creates one account-wide "Cloudflare Workers Preview URLs" policy ([changelog, 2025-12-03](https://developers.cloudflare.com/changelog/post/2025-12-03-reusable-access-policies/)).
- **"All traffic" can't be used for production during the Closed Beta.** The Landing Page and the Access Request form must stay public, so production needs hostname- or path-based Access applications instead. That design belongs to #2. Previews can use "Previews only", since nobody outside the team needs them.
- **CI reaching an Access-protected Preview** (end-to-end tests, smoke probes) uses an **Access service token**. Send the `CF-Access-Client-Id` and `CF-Access-Client-Secret` headers, and add a policy with action **Service Auth** to the Preview Access application. The token expires on the duration set at creation (one year in the API example) and has to be refreshed ([Service tokens](https://developers.cloudflare.com/cloudflare-one/identity/service-tokens/), 2026-11-11).
- Zero Trust Free covers up to 50 users ([Access product page](https://www.cloudflare.com/sase/products/access/)). Recent community threads say the Free checkout asks for overage billing consent. Ticket #2 should confirm that before enrolling, given the $20 cap.

### Where each secret lives

| GitHub location | Secret | Used by |
|---|---|---|
| Environment `preview` (no branch restriction) | `CLOUDFLARE_API_TOKEN` (Workers Scripts Edit + D1 Edit), `CLOUDFLARE_ACCOUNT_ID`, `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET` | Preview deploy, cleanup, E2E against the Preview |
| Environment `production` (deployment branch: `main` only) | A **separate** `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`, the Access service token | Production deploy and smoke test |
| Repository secrets | none | |

The two tokens have the same powers (see above), but separate tokens can be revoked separately and show up separately in Cloudflare's audit log.

### How the fork-PR risk is actually contained

- Fork PRs **never receive secrets**. Every job that needs one checks `head.repo.full_name == github.repository`. Fork PRs still run all test layers that need no secrets: unit, integration in the Workers runtime (local D1), E2E against `wrangler dev`, accessibility, content validation and the container smoke test.
- **Set the repo's fork-PR approval to the strictest option**, so no workflow runs until a maintainer has read the diff, `.github/workflows/` especially.
- **To preview a fork PR**, a maintainer reviews it and pushes its head to a branch in this repo, which runs the same-repo pipeline. Do this only after reading the diff, because that push gives the code the Cloudflare token.
- **Same-repo PRs are trusted by construction.** Only people with write access can open them, and anyone with write access "has read access to all secrets configured in your repository" anyway ([Secure use reference](https://docs.github.com/en/actions/reference/security/secure-use)). Keep write access to the Admins. Protect `.github/workflows/` with CODEOWNERS and branch protection (#13).
- Set the workflow default to `permissions: contents: read`, and grant `pull-requests: write` only to the job that comments the Preview URL.
- Pin third-party actions to a full commit SHA.

## 5. Cleanup when a PR closes

- The preview workflow also listens for `closed`. The cleanup job runs `npx wrangler preview delete --name pr-<n> --skip-confirmation`, and if a PR database exists, `npx wrangler d1 delete cursive-key-pr-<n> -y` ([Automation examples](https://developers.cloudflare.com/workers/previews/automation-examples/); [D1 commands](https://developers.cloudflare.com/workers/wrangler/commands/d1/)). It runs for both merged and unmerged closes and uses the same same-repo guard; fork PRs never got a Preview.
- **A weekly scheduled sweeper** catches cleanups that failed. It runs `wrangler d1 list`, deletes any `cursive-key-pr-<n>` whose PR is closed, and deletes Previews for closed PRs by name. The Wrangler docs list no `preview list` command, so the sweeper derives names from closed PRs. This matters because a leaked database permanently uses one of the 8 free slots, while leaked Previews are evicted anyway once there are more than 100.
- Per-Preview **secrets** need no separate cleanup; they go with the Preview. Base-config secrets are shared and stay.

## 6. Rolling back a bad production deploy

**Code and static assets**: `wrangler rollback [VERSION_ID] --message "…"`. Without an ID it goes to the version before the latest, and `--message` skips the prompts, so it works in CI. The dashboard has the same action under Deployments. You can roll back to any of the **100 most recent versions**, and a version includes its static assets ([Wrangler commands](https://developers.cloudflare.com/workers/wrangler/commands/workers/), 2026-10-26; [Rollbacks](https://developers.cloudflare.com/workers/configuration/versions-and-deployments/rollbacks/); [Versions and deployments](https://developers.cloudflare.com/workers/configuration/versions-and-deployments/), 2026-11-12). Caveats:

- The change takes time to reach every location. Pages loaded before the rollback may still request the newer version's assets (version skew).
- D1 is untouched. That is safe only under the expand-then-contract rule (§3).

**Data**: D1 **Time Travel** restores any minute in the last **7 days on Free** (30 on Paid). It is always on and free. `wrangler d1 time-travel restore cursive-key --bookmark=<b>` is **destructive**: it overwrites in place, cancels in-flight queries, and returns a bookmark that undoes the restore ([Time Travel](https://developers.cloudflare.com/d1/reference/time-travel/), 2026-11-06; [D1 limits](https://developers.cloudflare.com/d1/platform/limits/)). It also throws away every write since the bookmark, such as new Access Requests and Feedback. **Keep it a manual Admin action, never automatic.** Prefer a fix-forward migration when data is intact and only the schema is wrong.

**Automatic rollback in CI**: if the post-deploy smoke test against production fails (it reaches production through the Access service token), the job runs `wrangler rollback --message "smoke test failed: <sha>"` and fails loudly. Data is never restored automatically.

## Recommended pipeline shape

```
.github/workflows/
  ci.yml          on: pull_request (all, forks included)   no secrets
  preview.yml     on: pull_request [opened, synchronize, reopened, closed]
                  if: head.repo.full_name == github.repository
                  environment: preview
  production.yml  on: push to main                          environment: production (main only)
  maintenance.yml on: schedule (weekly) + workflow_dispatch  environment: preview
```

**ci.yml** (every PR, forks too; `permissions: contents: read`):
build → unit → `wrangler d1 migrations apply DB --local` → integration in the Workers runtime → E2E, axe and visual tests against `wrangler dev` → content validation → container smoke test → `wrangler deploy --dry-run`.

**preview.yml** (same-repo PRs; `concurrency: preview-pr-<n>`, cancel in progress):

1. If the PR changes `migrations/`: create `cursive-key-pr-<n>` if missing, rewrite the D1 `database_id` in the checked-out config, apply migrations `--remote`, then seed. Otherwise use the shared `cursive-key-preview` and don't migrate it.
2. `npx wrangler preview --name pr-<n> --json`, then comment the Preview URL on the PR.
3. Probe and E2E against the Preview URL with the Access service token headers.
4. On `closed`: `wrangler preview delete` and `wrangler d1 delete` for the PR's database if it exists.

**production.yml** (push to `main`; `concurrency: production`, never cancel in progress):

1. Build and the fast test layers.
2. Log the Time Travel bookmark.
3. `wrangler d1 migrations apply cursive-key --remote`.
4. `wrangler deploy`.
5. Smoke-test production with the Access service token. On failure, `wrangler rollback` and fail the job.
6. `wrangler d1 migrations apply cursive-key-preview --remote`, so the shared preview database follows `main`.

**maintenance.yml**: a weekly sweeper for leaked Previews and PR databases, plus a manual "reset shared preview database" job.

**Cost**: everything above fits Workers Free, D1 Free (2 to 10 databases) and GitHub Actions on a public repo. Nothing in the pipeline needs Workers Paid.

## Open points for other tickets

- **#7**: whether Preview traffic and Preview D1 reads and writes count against the same Free daily budgets as production. The docs don't say.
- **#2**: production can't use Worker-level "All traffic" Access during the Closed Beta (the Landing Page and Access Request form are public), so it needs path- or hostname-based Access applications. Also confirm the Zero Trust Free checkout's billing consent fits the $20 cap.
- **#4**: E2E against Previews needs the Access service token, so fork PRs can only run E2E against `wrangler dev`. A Preview's `scheduled()` is never called, so cron logic needs a test-only route ([Resources and isolation](https://developers.cloudflare.com/workers/previews/resources/)).
- **#13**: CODEOWNERS on `.github/workflows/`, branch protection, and keeping write access to the Admins are what contain the account-wide API token.
- **#11**: confirms the "no production data in Previews" rule, and makes the 7-day Time Travel window a de facto backup-retention period.
