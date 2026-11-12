# Portability: Hono, a storage interface and Astro on Workers and in a Node container

_Researched 2026-11-12 for [issue #6](https://github.com/dwerkjem/cursive-key/issues/6). Sources are first-party docs, npm registry metadata and package source, read on that date. Versions below are the npm `latest` tags on that date._

## The question

What does "able to move to a Node container (and so Kubernetes) without a rewrite" need concretely? The ticket asks about five things:

1. Hono on Workers and Node: what differs?
2. A thin storage interface over D1 that also runs on SQLite or Postgres, whether an ORM or query builder is worth it, and how migrations stay shared.
3. Astro: a static build served by both, or the Cloudflare adapter plus the Node adapter?
4. How Access identity and Turnstile are abstracted so the container can run without them.
5. The smallest container smoke test that proves portability in CI.

## Recommendation in one paragraph

Build Astro as a **static site with no adapter**. Write all server code as **one Hono app** that never touches a Cloudflare or Node API directly. It gets four ports from outside: `Storage`, `Identity`, `HumanCheck` and `Config`. Add **two small entry files**. `worker.ts` builds those ports from Worker bindings and lets Workers Static Assets serve `dist/`. `node.ts` builds them from `process.env` and a SQLite file, serves `dist/` with `@hono/node-server`'s `serveStatic`, and runs migrations at startup. Storage is **Drizzle with the SQLite dialect**, so **one schema and one folder of plain-SQL migrations** serve both D1 (applied by `wrangler d1 migrations apply`) and SQLite in the container (applied by Drizzle's `migrate()`). Postgres is not a target now. Identity means **validating the Cloudflare Access JWT with `jose`**, which works the same on both runtimes. Do not use `ctx.access`. Turnstile needs no abstraction, because siteverify is a plain HTTPS call, and CI uses Cloudflare's published test keys. The CI smoke test builds the image, runs it against an empty volume, and checks a few HTTP requests with `curl`.

## Layering

```
                ┌──────────────────────────────────────────────┐
  dist/ (Astro  │  src/server/app.ts  — createApp(ports)       │  no imports from
  static build) │  Hono routes + middleware (Closed Beta gate,  │  cloudflare:*, node:*,
                │  Roles, Access Request, Feedback, progress)   │  process.env, c.env
                └──────────────┬───────────────────────────────┘
                               │ ports (TypeScript interfaces)
     ┌──────────────┬──────────┴───────┬───────────────┐
     │ Storage      │ Identity         │ HumanCheck    │ Config
     │ (domain ops) │ whoIs(req)       │ verify(token) │ (plain object)
     └──────┬───────┴────────┬─────────┴───────┬───────┘
            │                │                 │
  src/server/adapters/       │                 │
  storage-drizzle.ts  ◄── one implementation, two Drizzle drivers
     ├─ drizzle-orm/d1               (Workers)
     └─ drizzle-orm/better-sqlite3   (Node)   [or node-sqlite on Drizzle v1]
  identity-access-jwt.ts (jose, both runtimes) · identity-dev.ts (non-prod only)
  turnstile.ts (fetch, both runtimes)

  Entry points (the only runtime-specific code):
    src/entry/worker.ts  export default { fetch(req, env, ctx) } — ports from env bindings
    src/entry/node.ts    serve({ fetch }) + serveStatic('dist') + migrate() + SIGTERM
```

Rules that keep it portable:

- `app.ts` and everything it imports must not import `cloudflare:workers`, `node:*`, or read `process.env` or `c.env`. Enforce this with a lint rule such as `no-restricted-imports` scoped to `src/server/**`. The two entry files are the only exceptions.
- Ports are passed in, not looked up. Hono's [testing guide](https://hono.dev/docs/guides/testing) already uses this pattern by passing a mock env as the third argument to `app.request`, so unit tests use in-memory fakes.
- The Workers integration-test layer from the map still runs the real Worker entry in `workerd`, so the Cloudflare side is covered too.

### Sketch

```ts
// src/server/ports.ts
export interface Storage {            // domain operations, not a db handle
  createAccessRequest(r: NewAccessRequest): Promise<void>;
  findPersonByEmail(email: string): Promise<Person | null>;
  grantRole(personId: string, role: Role): Promise<void>;
  saveProgress(personId: string, blob: ProgressBlob): Promise<void>;
  // …
}
export interface Identity  { whoIs(req: Request): Promise<{ email: string; sub: string } | null> }
export interface HumanCheck { verify(token: string, ip?: string): Promise<boolean> }

// src/server/app.ts
export function createApp(getPorts: (c: Context) => Ports) {
  const app = new Hono<{ Variables: { ports: Ports } }>();
  app.use('*', async (c, next) => { c.set('ports', getPorts(c)); await next(); });
  // routes use c.var.ports.storage, never c.env
  return app;
}

// src/entry/worker.ts
const app = createApp((c) => workerPorts(c.env as CloudflareBindings)); // drizzle(env.DB) is cheap per request
export default app;

// src/entry/node.ts
const ports = nodePorts(process.env);   // opens SQLite once, runs migrate()
const app = createApp(() => ports);
app.use('*', serveStatic({ root: distDir }));
app.notFound(/* serve dist/404.html */);
const server = serve({ fetch: app.fetch, port: Number(process.env.PORT ?? 8080) });
process.on('SIGTERM', () => server.close(() => process.exit(0)));
```

## 1. Hono on Workers and Node: what differs

| Concern | Workers | Node container | Source |
|---|---|---|---|
| Entry | `export default app` (or `{ fetch }`) | `serve({ fetch: app.fetch, port })` from `@hono/node-server` (v2.1.8, Node ≥ 20) | [hono.dev Workers](https://hono.dev/docs/getting-started/cloudflare-workers), [hono.dev Node](https://hono.dev/docs/getting-started/nodejs) |
| Bindings and secrets | `c.env.DB`, `c.env.SECRET`; types from `wrangler types --env-interface CloudflareBindings`. `process.env` is absent unless a compat flag is set | `c.env` is `{ incoming, outgoing }` (the raw Node request and response); config comes from `process.env` | same pages |
| Env strings, runtime-neutral | `env(c)` from `hono/adapter` reads Wrangler vars | the same `env(c)` reads `process.env` | [hono.dev adapter helper](https://hono.dev/docs/helpers/adapter) |
| Static files | Workers Static Assets, configured in `wrangler.jsonc` under `assets`. Asset-first by default, and the Worker runs only on a miss or for `run_worker_first` routes | `serveStatic` from `@hono/node-server/serve-static`. `root` is relative to the cwd (build it from `import.meta.url`). A directory request serves `index.html` ([source](https://github.com/honojs/node-server/blob/main/src/serve-static.ts)). Only GET and HEAD are handled | [CF routing](https://developers.cloudflare.com/workers/static-assets/routing/worker-script/), [node-server README](https://github.com/honojs/node-server) |
| Shutdown | n/a | handle `SIGTERM` with `server.close()` | hono.dev Node |
| Container | n/a | hono.dev gives a multi-stage Dockerfile (`node:22-alpine`, non-root user, `npm prune --production`) | hono.dev Node |

**Takeaway:** the only real difference is where bindings come from. `c.env` means different things on each runtime, so the app must never read it. Only the entry file reads it, to build the ports. `hono/adapter`'s `env()` covers config strings, but not D1 handles, so it does not replace the ports.

**Static-asset parity:** the Node entry has to copy three Workers behaviours. The smoke test checks them.

- **404 page.** On Workers, set `not_found_handling: "404-page"` ([Astro deploy guide](https://docs.astro.build/en/guides/deploy/cloudflare/)). On Node, use `app.notFound` to serve `dist/404.html`.
- **Trailing slashes.** On Workers the default `html_handling` is `auto-trailing-slash` ([docs](https://developers.cloudflare.com/workers/static-assets/routing/advanced/html-handling/)). Set Astro's `trailingSlash` and `build.format` so both runtimes give the same answer.
- **Immutable caching.** Serve `/_astro/*` with an immutable `Cache-Control` header via the `onFound` option of `serveStatic`.

## 2. Storage interface, ORM and migrations

### D1 facts that shape the interface

- D1 runs in auto-commit mode. `batch()` is the transaction primitive: the statements in a batch run in one transaction and are rolled back together if one fails ([D1 Database API](https://developers.cloudflare.com/d1/worker-api/d1-database/)).
- D1 rejects explicit `BEGIN TRANSACTION`/`COMMIT`. The import guide tells you to strip them from SQL dumps ([import/export](https://developers.cloudflare.com/d1/best-practices/import-export-data/)). Drizzle's D1 `transaction()` sends a raw `begin` ([source](https://github.com/drizzle-team/drizzle-orm/blob/main/drizzle-orm/src/d1/session.ts)), so **interactive transactions are not portable**.
- Drizzle's D1 driver has `db.batch()`, but its better-sqlite3 driver does not ([d1/driver.ts](https://github.com/drizzle-team/drizzle-orm/blob/main/drizzle-orm/src/d1/driver.ts)). On Node, use `db.transaction()` instead. better-sqlite3 transactions are synchronous, so keep the callback free of `await`.

**So the interface is made of domain operations, not a query builder or a db handle.** Each method that writes more than one row owns its atomicity. Inside the single Drizzle implementation, one private helper `atomic(statements)` calls `batch` on D1 and `transaction` on SQLite. Everything else is shared.

### ORM or query builder?

| Option | D1 driver | Node SQLite driver | Migrations | Verdict |
|---|---|---|---|---|
| **Drizzle** | First-party `drizzle-orm/d1` ([docs](https://orm.drizzle.team/docs/connect-cloudflare-d1)) | First-party `better-sqlite3` (0.45.x) and `node-sqlite` (v1 RC) ([docs](https://orm.drizzle.team/docs/get-started-sqlite)) | `drizzle-kit generate` writes **plain SQL** files that other tools may apply ([docs](https://orm.drizzle.team/docs/drizzle-kit-generate), [migrations](https://orm.drizzle.team/docs/migrations)) | **Recommended** |
| Kysely 0.29.9 | Community only: `kysely-d1` 0.4.0, last published 2025-04-19 ([dialects list](https://kysely.dev/docs/dialects)) | Built-in `SqliteDialect` | TypeScript `up`/`down` functions run by `Migrator`, recorded in `kysely_migration`. They are not plain SQL, so `wrangler d1 migrations apply` cannot run them ([docs](https://kysely.dev/docs/migrations)) | Workable, but the D1 dialect is a single-maintainer package and migrations would have to run from inside a Worker or a script |
| Raw SQL behind the interface | `env.DB.prepare().bind()` | `node:sqlite` `DatabaseSync` | Hand-written `.sql` files | Viable for a schema this small, but you write row mapping and types yourself |

Drizzle wins on one point: **one sqlite-core schema, one SQL migration folder, and first-party drivers for both runtimes**. On Cloudflare, `wrangler d1 migrations apply` runs any folder of `.sql` files and records them in `d1_migrations`. Set `migrations_dir` in the D1 binding ([D1 migrations](https://developers.cloudflare.com/d1/reference/migrations/)).

**Version choice:**

- **Drizzle 0.45.4** (stable, published 2026-10-08) writes flat `NNNN_name.sql` files, which wrangler reads directly. Its Node driver is `better-sqlite3`, a native module, so the image needs build tools or a prebuilt binary.
- **Drizzle v1 (`1.0.0-rc.5`**, published 2026-10-21) writes one folder per migration (`<ts>_name/migration.sql`). Wrangler then needs the `migrations_pattern` option, which Cloudflare's docs name for Drizzle's nested layout. v1 also adds a `node-sqlite` driver and migrator on Node's built-in `node:sqlite`. That module is "Stability 1.2, Release candidate" since Node 25.7 ([Node docs](https://nodejs.org/api/sqlite.html)), so it is a release candidate in Node 26 LTS (LTS since 2026-10-28, [schedule](https://github.com/nodejs/Release/blob/main/schedule.json)), and the image needs no native module.

**Recommendation:** start on 0.45.x with `better-sqlite3`. Move to v1 with `node-sqlite` when v1 is stable, since that is a driver swap inside the adapter. The ports keep the move contained either way.

### How migrations stay shared

- `drizzle/` (or `migrations/`) is the single source. Only `drizzle-kit generate` writes to it, and it is committed.
- **Cloudflare:** `wrangler d1 migrations apply <db> --remote` in the deploy job, and `--local` for dev and integration tests. Issue #5 owns how this runs for preview deploys.
- **Node:** `migrate(db, { migrationsFolder })` from `drizzle-orm/better-sqlite3/migrator` at process start. This is safe because the container runs **one replica**: SQLite on a ReadWriteOnce volume, with a `Recreate` deployment strategy. For more replicas, move migration to a Kubernetes Job, which by then means Postgres anyway.
- **Caveat for moving data:** the two runners record applied migrations in different tables (`d1_migrations` vs Drizzle's own table). When real data moves from D1 into the container (`wrangler d1 export` → SQLite, see [import/export](https://developers.cloudflare.com/d1/best-practices/import-export-data/)), seed Drizzle's table, or start the container on a fresh database and import data only. Write this as a one-off script on the day of the move, not now.

### What about Postgres?

The ticket names "SQLite or Postgres". Drizzle schemas are per dialect (`sqliteTable` vs `pgTable`), and so is the generated SQL. Kysely's own migration examples also differ between SQLite and Postgres. **No tool gives one schema and one migration set across D1 and Postgres.** The honest portability target is therefore **SQLite in the container**: the same dialect, schema and migrations. That runs one replica in Kubernetes, which matches "portability only, never deployed". Postgres becomes a **second implementation of `Storage`** with its own `pgTable` schema and migrations, written only if multi-replica Kubernetes ever becomes real. Domain-shaped methods keep that cost bounded, and the shared contract tests (below) make it safe.

**Contract tests:** one test suite runs against every `Storage` implementation, with the in-memory fake, D1 (via the Workers integration layer) and SQLite on Node. This is what keeps "thin interface" honest.

## 3. Astro: static build, not two adapters

- **No adapter is needed for a static build:** "If you're using Astro as a static site builder, you don't need an adapter" ([Cloudflare adapter docs](https://docs.astro.build/en/guides/integrations-guide/cloudflare/)). The Workers deploy is just `assets.directory: "./dist"` ([deploy guide](https://docs.astro.build/en/guides/deploy/cloudflare/)).
- **The adapters diverge at the runtime boundary.** `@astrojs/cloudflare` 14.4.7 (for Astro 7.4) runs `astro dev` in `workerd`. Its bindings come from `import { env } from 'cloudflare:workers'`, and `Astro.locals.runtime` was removed. Sessions default to KV. `@astrojs/node` 11.1.12 uses a filesystem session driver and runs standalone or as Express/Fastify middleware ([Node adapter docs](https://docs.astro.build/en/guides/integrations-guide/node/)). Any server-rendered page that reads a binding therefore imports a module that does not exist on Node. Supporting both would mean two builds, two session stores and two code paths: the rewrite that portability is meant to avoid.
- **This product does not need SSR.** Content is static. Progress, Personal Settings, the Access Request form, Feedback and the Admin page can all be static Astro pages with client-side islands that call the Hono `/api/*` routes.

**Recommendation:** `output: 'static'`, no adapter. If a page ever truly needs server rendering, render it in Hono (with `hono/jsx` or a template), not with an Astro adapter.

## 4. Cloudflare-only features

### Access identity

- **Validate the JWT and do not use `ctx.access`.** Cloudflare says that with Static Assets "the router does not pass `ctx.access` to the user Worker" ([Workers + Access](https://developers.cloudflare.com/workers/configuration/cloudflare-access/)), and `ctx.access` does not exist on Node anyway. Read the `Cf-Access-Jwt-Assertion` header, preferred over the `CF_Authorization` cookie, which "is not guaranteed to be passed". Verify it with `jose` against `https://<team>.cloudflareaccess.com/cdn-cgi/access/certs`, checking `iss` (team domain) and `aud` (application AUD tag) ([validate JWTs](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/authorization-cookie/validating-json/)). `jose` 6.2.17 uses Web Crypto and `fetch`, so the same `identity-access-jwt.ts` runs on both runtimes.
- **The container can keep Access.** Run `cloudflared` as a separate Deployment next to the app, with the app behind a ClusterIP service and not exposed otherwise ([Tunnel on Kubernetes](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/deployment-guides/kubernetes/)). Put the Access application on that hostname, and the same JWT arrives. A signed JWT cannot be forged on another network path, so the check is safe even when the origin is reachable some other way. Never trust a plain identity header.
- **Without Access** (CI and local), use `identity-dev.ts`. It returns a fixed Person from `DEV_IDENTITY_EMAIL`, or nobody. The Node entry **refuses to start** if `APP_ENV=production` and the dev identity is selected. Wrangler offers the same for `ctx.access` via an `access.dev` block, which is moot here.
- **Roles never come from Access.** Access answers "who is this email". Roles (Beta Tester, Curator, Admin) live in `Storage`, so the gate logic is the same on both runtimes.

### Turnstile

- **Siteverify is runtime-neutral:** `POST https://challenges.cloudflare.com/turnstile/v0/siteverify` with `secret`, `response` and optionally `remoteip`/`idempotency_key`. Tokens last 300 s and are single-use ([server-side validation](https://developers.cloudflare.com/turnstile/get-started/server-side-validation/)). The widget is client-side JavaScript loaded from Cloudflare. Neither part needs a Cloudflare runtime.
- **Test keys** ([testing](https://developers.cloudflare.com/turnstile/troubleshooting/testing/)): sitekey `1x00000000000000000000AA` (always passes), secret `1x0000000000000000000000000000000AA` (always passes), `2x…AA` (always fails), `3x…AA` (`timeout-or-duplicate`). The dummy token is `XXXX.DUMMY.TOKEN.XXXX`. Production secrets reject dummy tokens.
- **Abstraction:** a `HumanCheck` port with one real implementation (Turnstile via `fetch`). CI and the container smoke test use the test keys, so the real code path runs. A `disabled` implementation exists only for offline local dev, and the same production guard applies.

## 5. Smallest container smoke test

**Goal:** prove the image starts on Node, serves the Astro build, applies migrations to an empty SQLite file, and runs one real write through the shared app. Everything runs in one GitHub Actions step after `docker build`:

```sh
docker build -t cursive-key:ci .
docker run -d --name ck -p 8080:8080 \
  -e APP_ENV=ci -e DATABASE_PATH=/data/app.db \
  -e TURNSTILE_SECRET=1x0000000000000000000000000000000AA \
  -e IDENTITY=dev \
  --tmpfs /data cursive-key:ci
# wait for readiness (≤30 s)
for i in $(seq 30); do curl -fs localhost:8080/healthz && break; sleep 1; done
curl -fs localhost:8080/ | grep -q 'data-page="landing"'          # static HTML served
curl -fs -o /dev/null localhost:8080/$(curl -s localhost:8080/ | grep -o '_astro/[^"]*\.css' | head -1)  # hashed asset
test "$(curl -s -o /dev/null -w '%{http_code}' localhost:8080/no-such-page)" = 404   # 404 page parity
test "$(curl -s -o /dev/null -w '%{http_code}' localhost:8080/practice)" != 200      # Closed Beta gate fails closed
curl -fs -X POST localhost:8080/api/access-requests \
  -H 'content-type: application/json' \
  -d '{"email":"ci@example.org","turnstileToken":"XXXX.DUMMY.TOKEN.XXXX"}'  # migrations + Turnstile + write
docker stop -t 10 ck && test "$(docker inspect -f '{{.State.ExitCode}}' ck)" = 0   # clean SIGTERM
```

- `/healthz` should run `SELECT 1` against storage, so readiness also proves the database opened.
- The Access Request POST is the one request that crosses every port. It hits HumanCheck (real siteverify with the test secret, which needs outbound network; GitHub-hosted runners have it), Storage (the table exists only if migrations ran) and the app's routing.
- Page and route names are placeholders until issues #2, #9 and #13 settle them.
- The run takes seconds, needs no registry push, and never deploys.

## Interactions with other tickets

- **Closed Beta gate vs. free static assets (#2, #7).** Workers Static Assets serve matching files **without running the Worker** unless `run_worker_first` matches. Requests that do invoke the Worker are billed as Worker requests, and on Free a request over the limit gets a 429 ([billing](https://developers.cloudflare.com/workers/static-assets/billing-and-limitations/), [binding config](https://developers.cloudflare.com/workers/static-assets/binding/)). On Node, `serveStatic` sits behind Hono middleware, so the gate covers files naturally. There are two portable ways to keep the gate identical:
  - (a) During the Closed Beta, set `run_worker_first: true` (or a pattern list with `!` exclusions for public assets) so the Hono gate sees every page. At Public Launch, narrow it to `["/api/*"]`.
  - (b) Gate at the edge with Access path policies. This is not identical on Node unless the container also sits behind Tunnel and Access.

  Option (a) keeps one gate in code. #7 should count those requests against the 100k/day Free limit.
- **Repo layout (#13).** The `src/server`, `src/entry/{worker,node}.ts` and `drizzle/` split above is a proposal for #13 to confirm.
- **Test toolchain (#4).** The container smoke test is the script above. Storage contract tests add one suite run against three implementations.

## Open points to verify in a prototype

- That the `Cf-Access-Jwt-Assertion` header reaches a Worker that uses Static Assets with `run_worker_first`. The docs confirm only that `ctx.access` is withheld. The JWT validation page is written for any origin.
- That Drizzle's `--> statement-breakpoint` comments in generated SQL are harmless to `wrangler d1 migrations apply`. They are SQL comments, but run one migration through both runners to confirm.
