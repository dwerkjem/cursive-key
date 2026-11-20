# Test toolchain for the eight test layers

_Researched 2026-11-12 for [#4](https://github.com/dwerkjem/cursive-key/issues/4) (map: [#1](https://github.com/dwerkjem/cursive-key/issues/1)). Package versions are from `npm view` on 2026-11-12. Page quotes are from the linked docs on that date. **Runtimes are estimates**, not measurements: nothing has been built yet. Re-check them once the first workflow runs._

## Answer in one line

Use **Vitest** for unit tests, content validation and Workers integration (through **`@cloudflare/vitest-plugin`**, the renamed `vitest-pool-workers`). Use **Playwright** for end-to-end tests on all three browsers, for axe checks (`@axe-core/playwright`) and for warn-only visual regression with baselines stored in the repo. Use **Lighthouse CI** for performance budgets and **Docker Buildx plus curl** for the container smoke test. Everything runs on free `ubuntu-latest` runners. The full suite runs against a local `workerd` build on every PR, including PRs from forks. A small smoke suite runs against the Access-gated preview URL, using a **service token** sent as headers.

## Per-layer summary

| # | Layer | Tool | How it runs in CI | Rough runtime | Caveats |
|---|---|---|---|---|---|
| 1 | Unit | Vitest 5 (`node` project) | `vitest run --project unit` | under 30 s | None |
| 2 | Integration in Workers runtime + D1 | Vitest + `@cloudflare/vitest-plugin` 1.x (`workers` project) | Same `vitest run`; Miniflare/`workerd` run locally with no Cloudflare account and no network | 30–90 s | Use Istanbul coverage, not V8. Storage is isolated per test file. Await every storage call. |
| 3 | End-to-end, Chromium / Firefox / WebKit | Playwright 1.65 | Job matrix (one browser per job) in the pinned `mcr.microsoft.com/playwright:v1.65.0-noble` container, against a local `workerd` server | 2–5 min per browser | WebKit on Linux is not Safari. Use 1 worker on CI. |
| 4 | Accessibility | `@axe-core/playwright` 4.14 | Part of the Chromium E2E job, using a shared `makeAxeBuilder` fixture with WCAG A/AA tags | +1–3 s per page | Catches only some WCAG issues. Manual checks are still needed. |
| 5 | Content validation | Vitest (`content` project) + the Snippet Zod schema shared with Astro's content collection | `vitest run --project content` before `astro build`; a second leak check scans `dist/` after the build | under 30 s | "No answer-key leaks" is ambiguous if grading happens in the browser. See [open questions](#questions-this-raised). |
| 6 | Visual regression (warn-only) | Playwright `toHaveScreenshot`, baselines committed to the repo | Separate job in the same pinned container, Chromium only, `continue-on-error: true`, not a required check | 1–3 min | Baselines are tied to OS, fonts and browser build. They must be created in the container. They add PNGs to git. |
| 7 | Performance budgets | Lighthouse CI (`@lhci/cli` 0.16) | `lhci autorun` against the local build, 3 runs per URL, assertions start as `warn` | 1–3 min for about 5 URLs | Chrome only. Scores vary between runs, so use the median. Temporary public storage deletes reports after a few days. |
| 8 | Container smoke test | Docker Buildx (`docker/build-push-action@v7`, `push: false`, `type=gha` cache) + `docker run` + `curl` | Build the Node image, start it, hit a health route, one page and one API round trip, then stop it. Never push. | 1–3 min cold, under 1 min cached | What the smoke test calls depends on #6 |

The toolchain needs **Node 22.12 or later** (Vitest 5, Wrangler 4, `@axe-core/playwright`), and Astro 7 declares `node >=22.23.4`. Pin **Node 24** in CI.

## Layer details

### 1. Unit: Vitest

- Vitest 5.1.0 is current. Its engines field is `node ^22.12.0 || ^24.0.0 || >=26.0.0`.
- One `vitest.config.ts` with **projects** keeps all Vitest layers in one process. The docs say "Vitest provides a way to define multiple project configurations within a single Vitest process". Each inline project can set its own `environment` and `include`, and since Vitest 5.0 inline projects inherit root plugins unless `extends: false` ([Vitest projects](https://vitest.dev/guide/projects)). The `workers` project should set `extends: false` so the Cloudflare plugin applies only there.
- Unit tests cover pure TypeScript: answer normalisation, FSRS scheduling wrappers and Snippet selection. Astro components can be rendered with Astro's Container API (`AstroContainer.create()` / `renderToString`) if needed, and `getViteConfig()` loads the Astro config into Vitest ([Astro testing guide](https://docs.astro.build/en/guides/testing/)).

### 2. Integration in the real Workers runtime, with D1

- **Package name changed.** On 2026-08-19 Cloudflare released "Version 1 of the Workers Vitest integration", which moved it from `@cloudflare/vitest-pool-workers` to **`@cloudflare/vitest-plugin`**. "The Vitest configuration API is unchanged", and a codemod is available: `npx @cloudflare/codemods vitest:pool-workers-to-vitest-plugin` ([changelog](https://developers.cloudflare.com/changelog/post/2026-08-19-vitest-plugin/), [migration guide](https://developers.cloudflare.com/workers/testing/vitest-integration/migration-guides/migrate-to-vitest-plugin/)). Start on the new name.
- Versions: `@cloudflare/vitest-plugin` 1.8.1 has peer `vitest ^4.1.0 || ^5.0.0`. The old `@cloudflare/vitest-pool-workers` 0.23.0 supports only `vitest ^4.1.0`, so it does not work with Vitest 5 (npm, 2026-11-12). The "Write your first test" page still shows `npm i -D vitest@^4.1.0 @cloudflare/vitest-plugin`. Either version works.
- Config: add `cloudflareTest({ wrangler: { configPath: "./wrangler.jsonc" } })` to `plugins`. Bindings come from `env` in `cloudflare:workers`. Integration tests call the Worker through `exports.default.fetch(url)`, and `createExecutionContext()` / `waitOnExecutionContext()` come from `cloudflare:test`. It needs an ES-modules Worker with a compatibility date of 2022-10-31 or later ([write your first test](https://developers.cloudflare.com/workers/testing/vitest-integration/write-your-first-test/)).
- **D1:** call `readD1Migrations()` from `@cloudflare/vitest-plugin/config` in Node (in the config), then call `applyD1Migrations(db, migrations)` inside the runtime. It "applies all un-applied D1 migrations … recording migrations state in the `migrationsTableName` table" (default `d1_migrations`) ([Test APIs](https://developers.cloudflare.com/workers/testing/vitest-integration/test-apis/)). The same migration files that `wrangler d1 migrations apply` uses therefore build the test database.
- It runs entirely locally: "Runs fully locally using Miniflare" ([overview](https://developers.cloudflare.com/workers/testing/vitest-integration/)). It needs no Cloudflare credentials, so it works on fork PRs.
- Known issues ([page updated 2026-11-12](https://developers.cloudflare.com/workers/testing/vitest-integration/known-issues/)):
  - "Native code coverage via V8 is not supported", so use Istanbul.
  - Storage isolation is per test file, and writes are undone at the end of each file. Await every storage call and consume every response body, or tests fail intermittently.
  - Dynamic `import()` doesn't work inside handlers called through `exports.default.fetch()`.
  - The global setup file runs in Node, not `workerd`.
- Outbound `fetch` mocking now goes through `@msw/cloudflare` (changelog above).
- **Portability:** the same Hono routes should also get a Node-side integration run against the SQLite storage implementation. Otherwise only layer 8 tests the Node build. Whether to do this depends on the storage interface (#6).

### 3. End-to-end on Chromium, Firefox and WebKit: Playwright

- Playwright 1.65.0 (npm, 2026-11-12). It supports "Debian 12 / 13, Ubuntu 22.04 / 24.04 / 26.04 (x86-64 or arm64)" ([system requirements](https://playwright.dev/docs/intro)). `ubuntu-latest` is Ubuntu 24.04 with 4 vCPU, 16 GB RAM and 14 GB SSD on public repos, and "Use of the standard GitHub-hosted runners is free and unlimited on public repositories" ([GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)).
- **WebKit on Linux runners works**, but it is not Safari. Playwright's WebKit is "derived from the latest WebKit main branch sources, often before these updates are incorporated into Apple Safari". The docs also say "While running WebKit on Linux CI is usually the most affordable option, for the closest-to-Safari experience you should run WebKit on mac" ([browsers](https://playwright.dev/docs/browsers)). Recommendation: run WebKit on Linux for every PR. A weekly scheduled `macos-latest` WebKit job can be added later if Safari-only bugs appear. That job would also be free, because macOS standard runners are free on public repos too.
- **How it runs:**
  - Use a job matrix `browser: [chromium, firefox, webkit]`. Each job runs in the container `mcr.microsoft.com/playwright:v1.65.0-noble`, pinned to the exact `@playwright/test` version. The docs say "always pin your Docker image", and a version mismatch means browsers aren't found ([Docker](https://playwright.dev/docs/docker)).
  - The container avoids `npx playwright install --with-deps` on every run. Playwright advises against caching browser binaries: "Caching browser binaries is not recommended, since the amount of time it takes to restore the cache" is about the same as downloading them ([CI](https://playwright.dev/docs/ci)).
  - Set `workers: 1` on CI: "We recommend setting workers to "1" in CI environments to prioritize stability and reproducibility" (same page). Parallelism comes from the browser matrix and, later, sharding.
- **Target:** the built site served locally by `workerd`, either through `wrangler dev` or through `astro preview`, which "uses `workerd`, so it mirrors production" ([Astro Cloudflare adapter](https://docs.astro.build/en/guides/integrations-guide/cloudflare/)). Playwright's `webServer` config starts the server, and the local D1 database is migrated and seeded first. No Cloudflare Access sits in front of it, so the Worker needs a test identity seam. #2 already asks how to test that without real logins.
- **Flakiness:** use `retries: 2` on CI with `trace: 'on-first-retry'`, and treat any test that needed a retry as something to fix. Set a global timeout so a hung run fails rather than burning time (CI page).

### 4. Accessibility: axe

- Use `@axe-core/playwright` 4.14.0: `new AxeBuilder({ page }).withTags(['wcag2a','wcag2aa','wcag21a','wcag21aa']).analyze()`, then assert that `violations` is empty. A shared `makeAxeBuilder` fixture holds the tags and excludes ([Playwright accessibility testing](https://playwright.dev/docs/accessibility-testing)).
- Run it in the **Chromium** E2E job only. Axe rules check the DOM, so repeating them in every engine adds time and finds little. Scan every Learner-facing route, plus the quiz in each state (unanswered, wrong, right).
- Caveat from the same page: "automated testing cannot detect all types of WCAG violations." Keyboard-only and screen-reader passes stay manual. Those could be among the Public Launch criteria (#8).

### 5. Content validation

There is no off-the-shelf tool for this layer. It is a Vitest `content` project plus one shared schema module.

- **Snippet schema:** define the Snippet record (see `doc/architecture.md`) once with Zod from `astro/zod`. Astro's content collections use the same schema through the `file()` loader, which reads "a single array of objects from JSON and YAML files" and requires a unique `id` on each entry ([content collections](https://docs.astro.build/en/guides/content-collections/)). The docs say only that Astro "will provide a helpful error" on a schema violation; they don't promise a failing build. The content test therefore calls `schema.parse()` on `content/snippets.json` itself, so a bad record fails CI for certain.
- **Images exist:** for each Snippet, check that `image` resolves to a file under `public/` (or `src/assets/`), is non-empty, and has an allowed extension. Optionally also check dimensions and size (the architecture doc expects 10–30 KB).
- **Provenance and rights present:** the schema makes `source.url`, `source.collection`, `source.rights` and `source.transcriptionBy` required non-empty strings. The test also checks that `source.url` / `source.iiif` use an allowed host (`loc.gov`, `tile.loc.gov`).
- **Uniqueness and sanity:** IDs are unique, `difficulty` is in range, and `text` is non-empty and trimmed.
- **No answer-key leaks on Learner-facing pages:** a post-build test parses the HTML in `dist/` for Learner-facing routes and fails if any Snippet's `text` or `alternates` appears in visible text, `alt`, `title`, `aria-*` or inline JSON on a page where that Snippet is a question. A Playwright check confirms the answer isn't in the DOM before the Learner submits. See the open question below: if grading happens in the browser, the answer has to reach the browser somehow.
- Runtime: well under 30 s for hundreds of Snippets.

### 6. Visual regression, warn-only: baselines in the repo or a hosted service

**Recommendation: in-repo baselines with Playwright `toHaveScreenshot`, Chromium only, in a non-blocking job.**

- **How it works:** baselines live "next to the test file, in a separate directory", named with "the browser name and the platform" (for example `landing-chromium-linux.png`). Pixel tolerance is controlled by `threshold` (default `0.2`) and `maxDiffPixels`. Running `npx playwright test --update-snapshots` rewrites the baselines ([snapshots](https://playwright.dev/docs/test-snapshots)).
- **Environment pinning is the main flakiness risk.** "Browser rendering can vary based on the host OS, version, settings, hardware…" and "For consistent screenshots, run tests in the same environment where the baseline screenshots were generated" (same page). Generate and compare **only inside the pinned Playwright container**, never on a laptop. A `workflow_dispatch` job ("update visual baselines") can run `--update-snapshots` in that container and upload the PNGs as an artifact, or commit them to the PR branch.
- **Warn-only:** Playwright has no "warn" mode for screenshots, so use GitHub's job-level `continue-on-error: true` and leave the job out of the required checks (#13). The HTML report artifact shows the expected, actual and diff images.
- **Cost of keeping baselines in the repo:** every accepted UI change adds new PNGs to git history. For about 20 pages × 1 browser × 2 viewports, that is roughly 40 files of 50–300 KB per accepted change (estimate). Use Chromium only to start, mask volatile regions, and keep the page count small.

**Hosted alternatives (checked 2026-11-12):**

| Service | Free tier | Fits? |
|---|---|---|
| [Argos](https://argos-ci.com/pricing) | Hobby: free, 5,000 screenshots/month. "Screenshots for open-source projects are public." | Yes, if in-repo review becomes painful. Its GitHub Actions **tokenless** auth is "the only method that works on pull requests from forks" and must be enabled per project ([Argos GitHub Actions auth](https://argos-ci.com/docs/learn/integrations/github-actions-authentication.md)). Integration uses `@argos-ci/playwright` 7.8.0. |
| [Chromatic](https://www.chromatic.com/pricing) | Free: 5,000 snapshots/month, **Chrome only**. Safari, Firefox and Edge start at $179/month. | Worse fit. It is built around Storybook and its free tier has fewer browsers. |

A hosted service gives a review UI and keeps PNGs out of git. It costs a third-party account, a monthly quota (about 40 screenshots per PR run means about 125 runs a month), and a dependency during CI. Moving later is cheap, because the Argos reporter wraps the same Playwright tests.

### 7. Performance budgets: Lighthouse CI

- `@lhci/cli` 0.16.1 (npm, 2026-11-12). `lhci autorun` runs collect, assert and upload. The GitHub Actions example in the docs runs `npm install -g @lhci/cli@0.16.x && lhci autorun` with no browser install step ([getting started](https://github.com/GoogleChrome/lighthouse-ci/blob/main/docs/getting-started.md)). Use `startServerCommand` with a `url` list, or `staticDistDir` for a static-only build.
- `numberOfRuns` defaults to 3. Assertion levels are `off`, `warn` (prints but doesn't fail) and `error` (non-zero exit). Without options, the aggregation is `optimistic`; use `median` or `median-run` for budgets. The presets are `lighthouse:recommended`, `lighthouse:no-pwa` and `lighthouse:all`. A `budgetsFile` "cannot be used in conjunction with any other assert option" ([configuration](https://github.com/GoogleChrome/lighthouse-ci/blob/main/docs/configuration.md)).
- **Target:** the local build on the runner, not the preview URL. Runner-local numbers are more repeatable, and fork PRs work. The budget numbers are deferred (map: "Numbers for later"). Start every assertion at `warn` and switch to `error` once a few weeks of numbers exist.
- **Reports:** `temporary-public-storage` is free, but reports are "automatically deleted after a few days". Uploading the `.lighthouseci/` folder as an Actions artifact keeps them private. A self-hosted LHCI server is not worth running under the budget.
- Lighthouse is **Chrome only**. Performance on Firefox and WebKit is not measured.
- For authenticated pages, `collect.settings.extraHeaders` takes a JSON header map, so the same service token could be used against the preview URL if that is ever needed.

### 8. Container smoke test

- Build with `docker/setup-buildx-action@v4` and `docker/build-push-action@v7` (`push: false`, `load: true`, `cache-from: type=gha`, `cache-to: type=gha,mode=max`) ([Docker GHA cache](https://docs.docker.com/build/ci/github-actions/cache/)). `ubuntu-latest` has Docker.
- Run the image with `docker run -d -p 8080:8080`. Poll a health route until it answers, then:
  1. `GET /` returns 200 HTML.
  2. A static Snippet image returns 200 with an image content type.
  3. One API write and read round trip goes through the SQLite storage implementation.
- Then `docker logs` and `docker stop`. Never push, as the map requires.
- The Node side is `@hono/node-server` 2.1.8 (`serve()`, plus `serveStatic` from `@hono/node-server/serve-static`). Hono's guide includes a multi-stage Node Alpine Dockerfile with a non-root user ([Hono on Node.js](https://hono.dev/docs/getting-started/nodejs)). What else the smoke test must prove depends on the layering chosen in #6.

## Getting past Cloudflare Access on preview URLs

- **Mechanism:**
  1. Create a service token, for example `ci-preview`.
  2. On the Access application that covers the preview hostnames, add a policy with action **Service Auth** that selects that token. An Allow policy for Beta Testers sits alongside it. "Bypass and Service Auth policies are evaluated first" ([Access policies](https://developers.cloudflare.com/cloudflare-one/access-controls/policies/)).
  3. Every request then sends `CF-Access-Client-Id` and `CF-Access-Client-Secret` ([service tokens](https://developers.cloudflare.com/cloudflare-one/identity/service-tokens/)).
- **Strict mode:** "Organizations created on or after 2026-10-05" have strict service-token mode **on by default and cannot turn it off**. In strict mode Access "does not return a `CF_Authorization` cookie", ignores any such cookie sent with a request, and returns 401/403 instead of redirecting to login (same page). The headers must therefore go on **every** request, not just the first.
- **In Playwright:** `use.extraHTTPHeaders` sends headers "with every request" ([TestOptions](https://playwright.dev/docs/api/class-testoptions)). That handles strict mode, but it would also send the secret to any **third-party** host the page loads. Either guarantee the site makes no third-party requests in tests, or add the headers with `context.route()` only for the preview hostname. **Prefer the route-scoped approach.**
- **In Lighthouse CI:** use `collect.settings.extraHeaders` (above). It has the same third-party exposure.
- **Secrets and forks:** "With the exception of `GITHUB_TOKEN`, secrets are not passed to the runner" for PRs from forks, the token is read-only, and first-time contributors' runs may need approval ([events that trigger workflows](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows)). Running untrusted code under `pull_request_target` "may lead to security vulnerabilities" (same page). Do not use it to give fork PRs the token. Fork PRs therefore get the full local suite but **no preview deploy and no preview smoke test**. Keep the token in a GitHub Environment secret that only the same-repo preview job can read.
- **Limits:** 50 service tokens per account by default, and 500 Access applications ([account limits](https://developers.cloudflare.com/cloudflare-one/account-limits/), updated 2026-11-05). Service tokens expire at the duration chosen when they are created and can be refreshed for a year. Set an expiry reminder.
- **Not confirmed:** whether a service token uses a Zero Trust free-plan seat. #2 owns the seat question.
- **Preview URL facts:**
  - Version URLs (formerly "preview URLs") are `<version-prefix>-<worker>.<subdomain>.workers.dev`, and `wrangler versions upload` prints the URL. `--preview-alias pr-123` gives a stable per-PR hostname.
  - Version URLs are not available on Workers that implement a Durable Object. They work only on `workers.dev`. Their logs are not in `wrangler tail` ([Version URLs](https://developers.cloudflare.com/workers/configuration/previews/)).
  - Access can gate them: it "can cover one Worker or all Workers in an account" (same page).

## Proposed workflow shape

```
pull_request (all, including forks)        push to main
├─ build            astro build → dist artifact
├─ vitest           unit + workers(D1) + content     [required]
├─ e2e (matrix ×3)  chromium(+axe) / firefox / webkit [required]
├─ visual           chromium, continue-on-error      [not required]
├─ lighthouse       warn-only at first               [required once budgets are set]
├─ container        build + smoke, no push           [required]
└─ preview (same-repo PRs only, Environment secrets)
   ├─ wrangler versions upload --preview-alias pr-N
   └─ preview-smoke  ~5 Playwright tests via service token
                                            └─ deploy (after the same checks pass)
```

All jobs except `preview` need no secrets, so a fork PR runs everything except the preview deploy.

**Estimated wall-clock time:** 6–10 minutes per PR with jobs in parallel; the longest is the WebKit E2E job. GitHub Actions minutes cost $0 on a public repo.

## Questions this raised

1. **Where does grading happen, and what does "no answer-key leaks" mean?** If the quiz island grades in the browser, each Snippet's answer must reach the client (inline JSON, a fetched JSON file, or a hash). A static check can only prove the answer isn't *visible* before submission. Hashing answers (with normalisation) or grading in the Worker changes what layer 5 asserts. This needs a decision, probably in a product or quiz ticket, before the leak check is written.
2. **Preview deploys and D1 data.** Cloudflare says D1 state is "not tracked with versions" ([versions and deployments](https://developers.cloudflare.com/workers/configuration/versions-and-deployments/)). A Version URL "uses that Worker version's existing configuration and resources" ([Version URLs](https://developers.cloudflare.com/workers/configuration/previews/)). So unless a preview binds a different database, **a PR preview reads and writes the production D1 database**, and a PR's migrations can't be tried safely there. #5 should treat this as its central constraint. A separate preview Worker with its own D1 database may be required.
3. **How a service-token request maps to a Person.** A service-token request has no email. The preview smoke suite needs to act as a Beta Tester, and perhaps as an Admin. The Worker needs an explicit mapping (token → test Person with Roles, preview only) that must never be honoured in production. This fits #2, or the test identity seam it already asks about.
4. **Strict service-token mode** applies to Access organizations created on or after 2026-10-05. A new Cursive Key org will have it, which also changes how Beta Tester sessions and service tokens coexist. #2 should check what strict mode does to policies that mix Allow and Service Auth.
5. **Is WebKit on Linux enough?** It is a proxy for Safari, not Safari. Given the Safari storage-eviction issue in the architecture doc, decide whether a scheduled macOS WebKit job is part of the Public Launch bar (#8).

## Sources

All accessed 2026-11-12.

- Cloudflare: [Vitest integration](https://developers.cloudflare.com/workers/testing/vitest-integration/) (updated 2026-08-20) · [Write your first test](https://developers.cloudflare.com/workers/testing/vitest-integration/write-your-first-test/) · [Test APIs](https://developers.cloudflare.com/workers/testing/vitest-integration/test-apis/) · [Known issues](https://developers.cloudflare.com/workers/testing/vitest-integration/known-issues/) (updated 2026-11-12) · [Changelog: vitest-plugin](https://developers.cloudflare.com/changelog/post/2026-08-19-vitest-plugin/) (2026-08-19) · [Migrate to vitest-plugin](https://developers.cloudflare.com/workers/testing/vitest-integration/migration-guides/migrate-to-vitest-plugin/) · [Version URLs](https://developers.cloudflare.com/workers/configuration/previews/) · [Versions and deployments](https://developers.cloudflare.com/workers/configuration/versions-and-deployments/) (updated 2026-11-12) · [Service tokens](https://developers.cloudflare.com/cloudflare-one/identity/service-tokens/) · [Access policies](https://developers.cloudflare.com/cloudflare-one/access-controls/policies/) · [Zero Trust account limits](https://developers.cloudflare.com/cloudflare-one/account-limits/) (updated 2026-11-05)
- Playwright: [System requirements](https://playwright.dev/docs/intro) · [Browsers](https://playwright.dev/docs/browsers) · [CI](https://playwright.dev/docs/ci) · [Docker](https://playwright.dev/docs/docker) · [Visual comparisons](https://playwright.dev/docs/test-snapshots) · [Accessibility testing](https://playwright.dev/docs/accessibility-testing) · [TestOptions](https://playwright.dev/docs/api/class-testoptions)
- Vitest: [Projects](https://vitest.dev/guide/projects) (v5.1.0)
- Astro: [Testing](https://docs.astro.build/en/guides/testing/) · [Content collections](https://docs.astro.build/en/guides/content-collections/) · [Cloudflare adapter](https://docs.astro.build/en/guides/integrations-guide/cloudflare/) (v14.4.7)
- Lighthouse CI: [Getting started](https://github.com/GoogleChrome/lighthouse-ci/blob/main/docs/getting-started.md) · [Configuration](https://github.com/GoogleChrome/lighthouse-ci/blob/main/docs/configuration.md)
- GitHub: [GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) · [Events that trigger workflows](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows) · [Secure use](https://docs.github.com/en/actions/reference/security/secure-use)
- Docker: [GitHub Actions cache](https://docs.docker.com/build/ci/github-actions/cache/)
- Hono: [Node.js](https://hono.dev/docs/getting-started/nodejs)
- Visual services: [Argos pricing](https://argos-ci.com/pricing) · [Argos Playwright](https://argos-ci.com/docs/playwright) · [Argos GitHub Actions auth](https://argos-ci.com/docs/learn/integrations/github-actions-authentication.md) · [Chromatic pricing](https://www.chromatic.com/pricing)
- npm registry (`npm view`, 2026-11-12): vitest 5.1.0 · @cloudflare/vitest-plugin 1.8.1 · @cloudflare/vitest-pool-workers 0.23.0 · @playwright/test 1.65.0 · @axe-core/playwright 4.14.0 · @lhci/cli 0.16.1 · astro 7.4.11 · @astrojs/cloudflare 14.4.7 · wrangler 4.161.0 · hono 4.13.18 · @hono/node-server 2.1.8 · @argos-ci/playwright 7.8.0
