# Free-tier limits for server-side state, and when Workers Paid is needed

_Researched 2026-11-12 for [issue #7](https://github.com/dwerkjem/cursive-key/issues/7). Every number below comes from a Cloudflare page fetched that day. Each source lists its own "last updated" date. Usage figures are estimates built from the stated assumptions, not measurements._

## Answer in brief

- **Cloudflare Access's 50-user Free limit binds first, and Workers Paid does not raise it.** Zero Trust Free covers 50 users. Every Person who signs in takes a seat, including Admins and Curators. The next plan is $7 per user per month. A 50-tester Closed Beta plus one Admin is already 51 seats. Signed-in Learners after Public Launch (1,000 to 10,000 a day) cannot use Access at all within the $20 cap.
- **With one progress row per Person, written once per study session, Workers Free is enough for the Closed Beta and for 1,000 Learners a day.** All D1 and Worker usage stays under 10% of the daily limits.
- **At about 10,000 signed-in Learners a day, Worker requests average about 60% of the 100,000/day cap.** That leaves no room for spikes or error storms, so this is the point to move to Workers Paid. Everything still fits in Paid's included amounts, so the bill is a flat $5/month.
- **Storing progress as one D1 row per card plus a review log breaks Free at about 400 signed-in Learners a day** (D1 writes). At 10,000 a day it also breaks the $20 cap on Paid. Avoid that design.
- **Free plans fail hard. Paid plans bill.** Cloudflare has no spending cap. Budget alerts only send email (Pay-as-you-go accounts only, informational, about one day late), so any real cap has to be built into the app.

## Primary sources

| Source | Last updated |
|---|---|
| [Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/) | 2026-10-02 |
| [Workers limits](https://developers.cloudflare.com/workers/platform/limits/) | 2026-10-29 |
| [Static assets: billing and limitations](https://developers.cloudflare.com/workers/static-assets/billing-and-limitations/) | 2026-11-12 |
| [D1 pricing](https://developers.cloudflare.com/d1/platform/pricing/) | 2026-10-30 |
| [D1 limits](https://developers.cloudflare.com/d1/platform/limits/) | 2026-10-30 |
| [D1 Worker API (`batch`)](https://developers.cloudflare.com/d1/worker-api/d1-database/) | 2026-06-22 |
| [D1 best practices: indexes](https://developers.cloudflare.com/d1/best-practices/use-indexes/) | n/a |
| [Changelog: D1 enforces free tier daily query limits](https://developers.cloudflare.com/changelog/post/2026-09-01-d1-free-tier-limit-enforcement/) | 2026-09-01 |
| [Turnstile plans](https://developers.cloudflare.com/turnstile/plans/) | 2026-08-14 |
| [Turnstile hostname management](https://developers.cloudflare.com/turnstile/additional-configuration/hostname-management/) | 2026-04-27 |
| [Zero Trust (SASE) plans](https://www.cloudflare.com/plans/sase-zero-trust.md) and the [Access product page](https://www.cloudflare.com/sase/products/access/) | not dated |
| [Cloudflare One seat management](https://developers.cloudflare.com/cloudflare-one/team-and-resources/users/seat-management/) | 2026-05-01 |
| [Cloudflare One account limits](https://developers.cloudflare.com/cloudflare-one/account-limits/) | 2026-11-05 |
| [Budget alerts](https://developers.cloudflare.com/billing/manage/budget-alerts/) | 2026-05-29 |
| [Usage-based billing](https://developers.cloudflare.com/billing/understand/usage-based-billing/) | 2026-05-29 |
| [Changelog: billable usage dashboard and budget alerts](https://developers.cloudflare.com/changelog/post/2026-04-13-billable-usage-dashboard-and-budget-alerts/) | post dated 2026-04-21 |
| [Billing changelog](https://developers.cloudflare.com/changelog/product/billing/) (entry: "Budget alerts now on by default for Pay-as-you-go accounts") | entry dated 2026-07-20 |
| [Changelog: subrequest limit / lower `limits`](https://developers.cloudflare.com/changelog/post/2026-02-11-subrequests-limit/) | 2026-02-11 |
| [Workers Logs](https://developers.cloudflare.com/workers/observability/logs/workers-logs/) | 2026-10-12 |
| [Observability pricing (from 2026-12-01)](https://developers.cloudflare.com/observability/pricing/) | 2026-11-11 |
| [WHATWG Fetch standard: HTTP-network-or-cache fetch, keepalive quota](https://fetch.spec.whatwg.org/#http-network-or-cache-fetch) | living standard |

## The limits that matter

### Workers

| | Free | Paid ($5/month minimum) |
|---|---|---|
| Worker requests | 100,000/day, reset 00:00 UTC | 10M/month included, then $0.30/M |
| CPU time | 10 ms per request | 30M CPU-ms/month included, then $0.02/M CPU-ms; 30 s default, 5 min max per request |
| Subrequests per request | 50 | 10,000 |
| Static asset requests | Free and unlimited | Free and unlimited |
| Static asset files per version | 20,000 | 100,000 |
| Static asset file size | 25 MiB | 25 MiB |

Static asset requests do not count as Worker requests. A request that matches a `run_worker_first` pattern always invokes the Worker and is billed as one ([static assets billing](https://developers.cloudflare.com/workers/static-assets/billing-and-limitations/)).

### D1

| | Free | Paid |
|---|---|---|
| Rows read | 5M/day | 25B/month included, then $0.001/M |
| Rows written | 100,000/day | 50M/month included, then $1.00/M |
| Storage | 5 GB per account; **500 MB per database** | 5 GB included, then $0.75/GB-month; 10 GB per database, 1 TB per account |
| Databases | 10 | 100,000 included |
| Queries per Worker invocation | 50 | 1,000 |
| Row or BLOB size | 2 MB | 2 MB |
| Bound parameters per query | 100 | 100 |

How D1 counts rows ([D1 pricing](https://developers.cloudflare.com/d1/platform/pricing/)):

- "Rows read measure how many rows a query reads (scans), regardless of the size of each row." An unindexed filter scans the whole table.
- INSERT, UPDATE and DELETE count as writes. "Indexes will add an additional written row when writes include the indexed column."
- Row size is not billed: "A row that is 1 KB and a row that is 100 KB both count as one row." So one compressed progress blob per Person costs the same per write as one tiny card row.
- `meta.rows_read` and `meta.rows_written` on every query result show the real cost ([indexes](https://developers.cloudflare.com/d1/best-practices/use-indexes/)).
- `batch()` runs its statements as one SQL transaction. The docs don't say whether each statement counts separately toward the 50-queries-per-invocation limit ([D1 Worker API](https://developers.cloudflare.com/d1/worker-api/d1-database/)).

### Turnstile

Free: unlimited challenges and verification requests, up to 20 widgets per account, and 10 hostnames per widget ([plans](https://developers.cloudflare.com/turnstile/plans/)). A hostname entry "will work on that exact hostname and all of its subdomains" ([hostname management](https://developers.cloudflare.com/turnstile/additional-configuration/hostname-management/)). Turnstile is never the limit here. Each `siteverify` call uses one Worker subrequest, which is well within 50.

### Cloudflare Access (Zero Trust)

- The Free plan is $0 with a **50-user limit**. Pay-as-you-go is **$7 per user per month** (annual billing) ([SASE plans](https://www.cloudflare.com/plans/sase-zero-trust.md), [Access](https://www.cloudflare.com/sase/products/access/)).
- "A user consumes a seat when they perform an authentication event", which includes logging into an Access application. Removing a user frees the seat. Optional **seat expiration** removes users with no activity for one month to one year. Revoking sessions "will not remove the user's consumption of an active seat" ([seat management](https://developers.cloudflare.com/cloudflare-one/team-and-resources/users/seat-management/)).
- "Once the total amount of seats in the subscription has been consumed, additional users who attempt to log in are blocked." The page doesn't say whether this applies to the Free plan specifically. **Not confirmed by an official source:** whether a Free account blocks the 51st login or asks to start billing. A [community thread](https://community.cloudflare.com/t/zero-trust-free-hard-0-cap-or-blocked-at-50-seats/976840) asks exactly this and was not readable (HTTP 403).
- Other limits: 500 Access applications, 50 identity providers, and 50 custom application-library apps on Free ([account limits](https://developers.cloudflare.com/cloudflare-one/account-limits/)).

### Logs (relevant to Error Reports, issue #3)

- **Until 2026-11-30:** Workers Logs Free allows 200,000 events/day with 3-day retention. Paid includes 20M/month, then $0.60/M, with 7-day retention ([Workers Logs](https://developers.cloudflare.com/workers/observability/logs/workers-logs/)).
- **From 2026-12-01:** Cloudflare Observability pricing applies. Free gets 0.5 GB/day of ingestion with 7-day retention and no overage; ingestion "stops … when you reach the daily limit" and resumes at 00:00 UTC. Paid includes 50 GB per billing cycle, then $0.25/GB ([Observability pricing](https://developers.cloudflare.com/observability/pricing/)).

## What happens at a limit: Free vs Paid

| Resource | Free: limit reached | Paid: past included amount |
|---|---|---|
| Worker requests | Fails. Error 1027; on a route, fail open (Worker bypassed) or fail closed (error page) ([limits](https://developers.cloudflare.com/workers/platform/limits/)). Requests matching `run_worker_first` get **429**, and other static assets keep serving ([static assets](https://developers.cloudflare.com/workers/static-assets/billing-and-limitations/)). | Bills $0.30/M |
| CPU time | The request fails if it exceeds 10 ms | Bills $0.02/M CPU-ms; optional per-request cap with `limits.cpu_ms` |
| D1 rows read/written | Fails. Since 2026-09-01, "D1 queries on the Workers Free plan will fail" until 00:00 UTC; "Stored data is not affected"; "You will receive email alerts when the daily limit is reached" ([changelog](https://developers.cloudflare.com/changelog/post/2026-09-01-d1-free-tier-limit-enforcement/)) | Bills |
| D1 storage | Fails. Inserts are blocked until you delete data ([D1 pricing](https://developers.cloudflare.com/d1/platform/pricing/)) | Bills per GB-month; **hard cap** of 10 GB per database |
| D1 queries per invocation | Fails (50) | Fails (1,000) |
| Logs | Ingestion stops (from 2026-12-01) | Bills |
| Turnstile | No request limit | n/a |
| Access seats | Login blocked (official wording; Free-specific behaviour unconfirmed) | $7 per user per month |

**Not documented:** what an API path served by the Worker without `run_worker_first` returns once the Free daily request cap is hit (1027 or 429). A prototype should check this before the client's error handling is written.

## Alerts and spending caps

- **No spending cap exists.** Budget alerts "are informational only. They do not pause or cap usage" ([budget alerts](https://developers.cloudflare.com/billing/manage/budget-alerts/)). The [usage-based billing](https://developers.cloudflare.com/billing/understand/usage-based-billing/) page mentions no cap either, and no changelog entry adds one.
- **Budget alerts:** set a dollar threshold on account-wide usage-based spend under Manage Account > Billing > Billable Usage. They are **Pay-as-you-go accounts only**, fire once per billing cycle, and use projected spend ([changelog, 2026-04-21](https://developers.cloudflare.com/changelog/post/2026-04-13-billable-usage-dashboard-and-budget-alerts/)).
- **Default alert:** since 2026-07-20, eligible Pay-as-you-go accounts get a **$10 alert by default**. It is rolled out in cohorts and starts at the next billing cycle. It **excludes subscription fees such as the Workers Paid $5**. "Notifications are sent the day after the threshold is reached", because usage is processed daily ([billing changelog](https://developers.cloudflare.com/changelog/product/billing/)).
- **Usage notifications** (per product metric) apply to "Professional plan or higher" ([usage-based billing](https://developers.cloudflare.com/billing/understand/usage-based-billing/)).
- **On Free**, the only built-in warning is D1's email when a daily limit is reached. Other usage is visible in the dashboard (D1: Metrics > Row Metrics) and the GraphQL Analytics API.
- **Per-request guards:** `limits.cpu_ms` and `limits.subrequests` in the Wrangler config set lower caps "to protect against runaway code or unexpected costs" ([changelog, 2026-02-11](https://developers.cloudflare.com/changelog/post/2026-02-11-subrequests-limit/)). These limit one request, not the month.

**For the $20 cap:** usage-based spend excludes the $5 fee, so a usage alert at $X means a bill of about $X + $5. Set one alert at **$5 usage (about $10 bill)** to investigate and keep the default or set a second at **$12 usage (about $17 bill)** to act, which leaves a margin for the one-day lag. Back them with app-level caps (see the write pattern below), because only the app can stop spending.

## Usage estimates

### Assumptions

1. **Static stays static.** Pages and Snippet images are static assets, so they are free. The Closed Beta gate is enforced by Access at the edge, not by the Worker. `run_worker_first` covers only `/api/*`. If every page went through the Worker, each session would add 20+ requests and every figure below would rise about 5×.
2. **API calls per signed-in study session: 4.** `GET /api/me` (Roles and Personal Settings), `GET /api/progress`, `PUT /api/progress` at session end, and 1 spare (a keepalive flush or retry).
3. **Sessions per day:** Beta Testers 2, Learners 1.5. "Learners/day" means daily active Learners. As a worst case, **all of them are signed in**. Anonymous Learners make no API calls except Feedback and Error Reports.
4. **D1 cost per request:** 1 row read to load the Person (Roles). Access JWT verification needs no D1.
5. **Progress design A (recommended):** one progress row per Person holding a compressed blob. Plus 1 Personal Settings row. Session cost: about 6 rows read and 2 rows written (the end-of-session PUT plus a possible keepalive flush). The updated columns are not indexed, so no extra index write.
6. **Progress design B (for comparison):** one row per (Person, Snippet) with FSRS state, plus one review-log row per review, each with one index. At 40 reviews per session: 40 × 2 + 40 × 2 = **160 rows written**. Loading all card state at Phase 1 size (300 Snippets) reads **300 rows**.
7. **Other traffic:** Feedback from 1% of daily Learners (Beta: 10/day); Error Reports from 2% of sessions after client dedup (Beta: 10/day); Access Requests ≤ 20/day during the Closed Beta only. Each is 1 Worker request, 1 Turnstile `siteverify` (Feedback and Access Requests only) and about 2 rows written.
8. **Admin pages:** about 10,000 rows read/day (inbox lists over a few thousand rows, a few views a day).
9. **Blob size:** FSRS card state in a compact array of about 50 bytes per Snippet. 300 Snippets is about 15 KB raw, or roughly 5–8 KB gzipped. This is an estimate and should be measured in the prototype. A review history would add to it.

### Daily figures (Free daily limit in brackets)

| | 50 Beta Testers | 1,000 Learners/day | 10,000 Learners/day |
|---|---|---|---|
| Study sessions | 100 | 1,500 | 15,000 |
| Worker requests [100,000] | ~450 (0.5%) | ~6,100 (6%) | **~60,400 (60%)** |
| D1 rows written, design A [100,000] | ~280 (0.3%) | ~3,100 (3%) | ~31,000 (31%) |
| D1 rows read, design A [5M] | ~11,000 (0.2%) | ~19,000 (0.4%) | ~100,000 (2%) |
| D1 rows written, design B [100,000] | ~16,000 (16%) | **~240,000 (240%: fails daily)** | **~2.4M (24×)** |
| D1 rows read, design B [5M] | ~40,000 (0.8%) | ~470,000 (9%) | **~4.6M (92%)** |
| Turnstile challenges [unlimited] | ~30 | ~10 | ~100 |
| Access seats [50 on Free] | **51+ (over)** | **1,000+** | **10,000+** |

Design B's write cost rises with reviews per session, so it reaches the 100,000/day write limit at about **400 signed-in Learners/day** (100,000 ÷ (1.5 × 160)).

### Storage (design A)

Assuming 3 registered Persons per daily active Learner at 10,000/day (30,000 Persons):

- At 15 KB raw, that is about 450 MB, which is close to the **500 MB per-database limit on Free**.
- Gzipped (5–8 KB), it is 150–240 MB.

Compress the blob, and keep long review history out of it or cap it. On Paid, the per-database cap is 10 GB.

### Monthly cost on Paid

- **At 10,000/day with design A:** about 1.8M Worker requests (10M included), about 0.9M rows written (50M included) and about 3M rows read (25B included). CPU: if each API call uses about 2 ms (an estimate; the Worker passes the blob through without parsing it), that is about 4M CPU-ms (30M included). **Total: $5/month.**
- **At 10,000/day with design B:** about 72M rows written per month, so 22M over the included amount × $1/M = $22, plus $5 = **$27/month, over the $20 cap.**
- **Where design A leaves the $5 flat rate:** included Worker requests run out at about 10M ÷ (30 × 1.5 × 4) ≈ **55,000 signed-in Learners/day**. Beyond that, each extra 1M requests costs $0.30.

## When Workers Paid is needed

1. **Closed Beta (50):** not needed. Everything is under 1% of Free except Access seats, which Workers Paid doesn't affect. Either cap the cohort so Beta Testers plus Admins and Curators who sign in stay at **50 or fewer**, or turn on seat expiration and remove inactive testers.
2. **1,000 Learners/day:** not needed with design A. With design B, D1 writes would fail every day, which rules out design B on Free.
3. **About 10,000 Learners/day:** upgrade. Average Worker load is about 60% of the daily cap, so one busy day or a bug that floods Error Reports would take the API offline until 00:00 UTC. Paid still costs only $5 here.
4. **Rule for "forced" (Free until then):** upgrade when either of these happens:
   - the 7-day average of Worker requests passes **50,000/day**;
   - any Free limit actually fires: D1 sends an email, or the API returns 1027/429.

   Check the dashboard weekly once Public Launch nears. When you upgrade, set the budget alerts above on the same day.
5. **Workers Paid does not solve Learner sign-in.** At Public Launch, Learner accounts on Access would cost $7 per user per month past 50 users. Sign-in for Learners has to use something other than Access seats (see the follow-ups).

## Safest write pattern for progress sync

1. **Local-first.** IndexedDB is the working copy during a session. The server copy is a backup and sync point, so a failed sync is never fatal. This matches the D1 hard-fail behaviour on Free.
2. **One row per Person, one write per session.** Use a table such as `progress(person_id INTEGER PRIMARY KEY, version INTEGER, updated_at INTEGER, blob BLOB)`. Use an `INTEGER PRIMARY KEY` so the key is the rowid and no separate key index is written, and add no indexes on `blob`, `version` or `updated_at`. Each sync is then exactly 1 row written, whatever its size (D1 bills rows, not bytes).
3. **Write at session end, flush once on leave.**
   - `PUT` when the session ends: the daily goal is met or the Learner presses Done.
   - If the page is hidden with unsynced changes, send one `fetch(..., {keepalive: true})`, then mark the session synced.
   - The Fetch standard rejects keepalive requests whose body would push in-flight keepalive bytes past **64 KiB** ([HTTP-network-or-cache fetch](https://fetch.spec.whatwg.org/#http-network-or-cache-fetch)). So the compressed blob must stay under that size, or the flush must fall back to the next visit.
   - Never write per answer.
4. **Read once per session.** `GET` progress on app start or sign-in, with the `version` as an ETag, so an unchanged blob costs one row read and no transfer.
5. **Optimistic concurrency.**
   - Write with `UPDATE progress SET blob = ?, version = version + 1, updated_at = ? WHERE person_id = ? AND version = ?`.
   - On a version conflict, return 409. The client pulls, merges per card (latest `last_review` wins; issue #12 owns the merge rules) and retries once.
   - The server never parses the blob. This keeps CPU far under 10 ms and keeps merge logic in one place.
6. **Keep the Worker strict and cheap.**
   - Reject bodies over a fixed size, such as 48 KB compressed.
   - Ignore a second progress `PUT` from the same Person within a few minutes.
   - Write Personal Settings only when they change.
7. **Cap the noisy writers.**
   - Error Reports are the most likely way to burn a daily quota: one bug on every page × 10,000 Learners. Dedupe and limit them in the browser (for example, one report per error signature per session).
   - Apply a server-side daily cap and sampling to Error Reports, and apply the issue #10 limits to Feedback and Access Requests.
   - An app-level cap is the only spending cap available on Paid.
8. **Keep review history out of the hot path.** If FSRS parameter optimisation needs review logs later, add one compressed batch per session to the same row, or one row per session. Never one row per review.

## Checking `doc/architecture.md`'s free-tier table

| Claim in `doc/architecture.md` | Verdict |
|---|---|
| Worker requests 100,000/day; static asset requests unlimited | Correct |
| Static assets about 20,000 files and 25 MiB per file on Free | Correct. Paid allows 100,000 files. |
| D1 5M rows read / 100K rows written per day, 5 GB storage | Correct, but **missing the 500 MB per-database limit** on Free |
| D1 Free fails at the daily limit since 2026-09-01, resets 00:00 UTC | Correct, and email alerts are sent |
| "One write per sync; about 100K syncs/day" | 100K is the write limit itself, not headroom. Any indexed column on the progress row halves it. |
| "Don't upgrade to Workers Paid unless the project has funding" | Superseded by the map: Workers Paid at $5 is the first allowed spend |
| Header note: numbers "mostly from 2026 third-party summaries" | Now checked against official pages (this file) |
| R2 free-tier numbers | Not checked here; out of scope |
| (missing) Cloudflare Access 50-user Free limit | **Missing, and it is the limit that binds first** |
| (missing) No spending cap on Paid; budget alerts are email only | Missing |
