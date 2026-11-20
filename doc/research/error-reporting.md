# Which error-reporting tool fits the budget for browser and Worker?

_Researched 2026-11-12 for [issue #3](https://github.com/dwerkjem/cursive-key/issues/3). All pages below were read on that date. Where a vendor page shows a "last updated" date, it is given. Terms such as Error Report, Admin, and Promote are used as defined in the project glossary._

## Answer

**Build the capture into D1 ourselves.** Both the browser and the Worker send Error Reports to one Worker endpoint. The endpoint groups them by a fingerprint and stores them in D1. An Admin Promotes a report from the same Admin screen used for Feedback, and that screen calls the GitHub REST API to open a `needs-triage` issue. **Also turn on Cloudflare Workers Issues.** It costs $0 and catches Worker failures our own code cannot catch, such as CPU-limit kills.

Why the other options fall short:

- **Sentry Developer (free)** is the best tracker in this list, but on the free plan the Promote step can't be built. The plan has no API and no third-party integrations, and GitHub issue creation needs Team at $29/month, which is over the cap. The current SDK (v11) also sends IP addresses by default.
- **Cloudflare's built-in tools** (Workers Logs, Issues, Tail Workers, Analytics Engine) see only the Worker, not the browser. Tail Workers also need the Workers Paid plan.
- **The homemade D1 option** stays on the Workers Free plan and never sends a bill. It keeps personal data under our control and gives Error Reports the same Promote path as Feedback. What it costs instead: we write the grouping ourselves (about 100 lines), browser stack traces stay minified unless we map them, and its D1 writes share the account's daily write quota.

## Comparison

| | Sentry Developer (free) | Workers Logs + Issues | Tail Workers | Analytics Engine | Homemade → D1 |
|---|---|---|---|---|---|
| Browser errors | Yes (`@sentry/astro`) | No | No | Only if we forward them | Yes (we forward them) |
| Worker errors | Yes (`@sentry/cloudflare`) | Yes, with no SDK | Yes | Only if we write them | Yes (`app.onError` plus `console.error`) |
| Grouping | Best: stack-trace fingerprint, customisable | Issues groups occurrences; the method isn't documented | None (raw events) | None (we would aggregate in SQL) | Ours: hash of name, message, and top frame |
| Free quota | 5k errors | Today: 200k log events/day. From 2026-12-01: 0.5 GB/day shared | Not on Free | 100k data points/day | D1: 100k rows written/day, shared with the rest of the site |
| On overflow | Dropped, no bill | Dropped until 00:00 UTC, no bill | n/a | Not documented; not billed today | D1 query fails until 00:00 UTC, no bill |
| Retention | 30 days | Logs 3 days (7 from Dec 1); Issues occurrences 7 days | n/a | 3 months | Until we delete it |
| PII by default | IP, headers, cookies, query strings sent (SDK v11) | Request metadata captured; fields not listed | Full request incl. headers | Only what we write | Only what we write |
| Promote to GitHub | Manual copy only (no API, no integrations on free) | Manual "send to webhook" → our Worker → GitHub | n/a | n/a | One button → our Worker → GitHub |
| Monthly cost | $0 | $0 (Issues free during beta) | $5+ (Workers Paid) | $0 | $0 |

## Sentry Developer plan

**Quota and plan.** The [pricing page](https://sentry.io/pricing/) lists the Developer plan as free with "5k errors", "1 User", and a "30-day lookback". The rows for "API", "Third-party integrations", and "Alerts and notifications via integrated tools" all say **"No"**. Team costs "$29/mo monthly, $26/mo annual" for "50k errors".

**Overflow.** Events over the quota are dropped and not billed. From [Manage Your Error Quota](https://docs.sentry.io/pricing/quotas/manage-event-stream-guide/): "If you're on a Developer plan and want to increase your quota, you'll need to upgrade to a Team or Business plan. On these plans you can … purchase pay-as-you-go volume." The server returns 429 and "clients are not supposed to retry events, but instead drop events until the rate limit has expired." The [pricing docs](https://docs.sentry.io/pricing/) say: "Any data sent after you've run through your reserved volume and PAYG budget will be dropped and you won't be charged for it." The Developer plan can't buy pay-as-you-go volume, so it can't produce a bill. A browser DSN is public, though, so anyone can spend the 5k quota. Per-key rate limiting "is available only if your organization is on a Business or Enterprise plan" (same page).

**Browser and Worker coverage.** `@sentry/astro` together with `@sentry/cloudflare` covers both sides. See [Astro on Cloudflare](https://docs.sentry.io/platforms/javascript/guides/astro/cloudflare/), which requires `@astrojs/cloudflare` v13 or later. The [Cloudflare guide](https://docs.sentry.io/platforms/javascript/guides/cloudflare/) requires the `nodejs_compat` flag and a `compatibility_date` of `2024-09-23` or later. On npm, the latest version of both packages was `11.12.0` (checked 2026-11-12).

**Grouping.** [Event grouping](https://docs.sentry.io/concepts/data-management/event-grouping/) fingerprints on in-app stack frames, then on exception type and value, then on the message. Fingerprint rules can be customised. Sentry also applies source maps, so minified browser stacks become readable.

**Personal data.** In SDK v11, IP addresses are collected **by default**. The [options reference](https://docs.sentry.io/platforms/javascript/configuration/options/) explains the change: "In version 10 of the SDK, the defaults below apply only when you set the `dataCollection` option … Starting with version 11, the defaults always apply." The defaults are `userInfo: true` ("the SDK infers the IP address from an incoming HTTP request"), plus cookies, HTTP headers, and URL query parameters all `true`. [Data collected](https://docs.sentry.io/platforms/javascript/data-management/data-collected/) warns: "Even when this is disabled, IP addresses can still reach Sentry through collected HTTP headers … (for example, the `X-Forwarded-For` header)."

All of this can be turned off with `dataCollection: { userInfo: false, httpHeaders: false, cookies: false, urlQueryParams: false }`. Server-side, [data scrubbing](https://docs.sentry.io/security-legal-pii/scrubbing/server-side-scrubbing/) "is enabled by default", and you can also "prevent IP addresses from being stored". Geolocation is still derived from the IP even when that setting is on. Using Sentry also adds a third-party data processor that the privacy policy would need to name.

**Promote.** Creating GitHub issues from Sentry is a paid feature. From the [GitHub integration docs](https://docs.sentry.io/organization/integrations/source-code-mgmt/github/): "Manual issue management is available to organizations on Team, Business, or Enterprise plans", and automatic creation needs Business or Enterprise. The Developer plan also has no API, so our own Admin screen can't fetch Sentry issues to Promote them. On the free plan, Promote would mean an Admin copying text by hand from the Sentry UI.

## Cloudflare Workers Logs, Workers Issues, Tail Workers, Analytics Engine

None of these captures browser errors on its own. The browser would still have to POST each error to a Worker, which is the homemade design below.

**Workers Logs** ([docs](https://developers.cloudflare.com/workers/observability/logs/workers-logs/), last updated 2026-10-12):

- Free plan today: "200,000 per day" log events with "3 Days" retention.
- From 2026-12-01 it moves to [Cloudflare Observability pricing](https://developers.cloudflare.com/observability/pricing/): Free gets "0.5 GB per day" with "Seven days of retention". That allowance is **shared** between Workers Logs, Workers Traces, Issues, and other products. "Extra ingestion" on Free is "Not available", and "On Free, Cloudflare stops ingesting new data when you reach the daily limit." Ingestion resumes at 00:00 UTC.
- Logs are raw lines with no grouping. Invocation logs contain "details such as the Request, Response, and related metadata". The docs don't list which request fields are kept, so we couldn't confirm from the docs whether client IP or headers are stored. Check one log in the dashboard before relying on this. Invocation logs can be turned off with `invocation_logs = false`.

**Workers Issues** ([docs](https://developers.cloudflare.com/workers/observability/issues/), last updated 2026-10-12; [announced 2026-09-30](https://blog.cloudflare.com/real-time-issue-detection/)):

- **What it catches:** uncaught exceptions, failed invocations, 5xx responses, and `console.error` logs. It needs no SDK. Enable it with `observability.issues.enabled = true` (Wrangler 4.134.0 or later).
- **Grouping:** "It groups related occurrences from the same Worker into one issue". The grouping method isn't documented.
- **Cost:** "available to all Workers accounts in open beta. It is free to use during the beta period." After the beta, it falls under the shared Observability allowance.
- **Retention:** "Occurrence details are available for seven days. Issues remain listed after their occurrences expire" ([Investigate](https://developers.cloudflare.com/workers/observability/issues/investigate/)).
- **Promote:** [Automations](https://developers.cloudflare.com/workers/observability/issues/automations/) can send an issue to a "Generic webhook", and an Admin can trigger that by hand: "Open the issue and select the destination from its available actions." The payload uses the [Cloudflare Notifications webhook schema](https://developers.cloudflare.com/notifications/get-started/configure-webhooks/). Webhooks "are available on all plans". So a manual send to our own Worker endpoint could scrub the payload and open a GitHub issue, but that would be a second Promote path alongside the one in D1.
- **Personal data:** the Automations page warns that issue data "can include … request metadata, logs, and application context".

**Tail Workers** ([docs](https://developers.cloudflare.com/workers/observability/logs/tail-workers/)): "available to all customers on the Workers Paid and Enterprise tiers". They are "billed by CPU time". The Workers Paid plan has a "minimum charge of $5 USD per month" ([pricing](https://developers.cloudflare.com/workers/platform/pricing/)). That fits the $20 cap, but it breaks the architecture guardrail of staying on Workers Free, where usage is capped rather than billed. **Rejected.**

**Workers Analytics Engine** ([pricing](https://developers.cloudflare.com/analytics/analytics-engine/pricing/), [limits](https://developers.cloudflare.com/analytics/analytics-engine/limits/)):

- Free plan: "100,000 included per day" data points written and "10,000 included per day" read queries. "Currently, you will not be billed for your use of Workers Analytics Engine."
- Retention: "stored for three months". Blobs are limited to 16 KB per data point.
- It is a metrics store queried with SQL. It has no per-event detail view, status, or grouping UI, so it suits error *counts* but not Error Reports an Admin reviews and Promotes. **Not recommended as the store.**

**Cloudflare Web Analytics** ([about](https://developers.cloudflare.com/web-analytics/about/)) collects page views and Core Web Vitals through the Performance API. It doesn't document capturing JavaScript errors.

## Homemade capture into D1 (recommended)

**Capture.**

- **Browser:** `window` [`error`](https://developer.mozilla.org/en-US/docs/Web/API/Window/error_event) and [`unhandledrejection`](https://developer.mozilla.org/en-US/docs/Web/API/Window/unhandledrejection_event) listeners send a small JSON body with [`navigator.sendBeacon`](https://developer.mozilla.org/en-US/docs/Web/API/Navigator/sendBeacon) to `POST /api/error-reports`. The body holds name, message, stack, page path without the query string, release, and user-agent family.
- **Worker:** Hono's `app.onError` writes the same record directly and calls `console.error(err)`, so Workers Issues also sees the error.

**Grouping.** Fingerprint = SHA-256 of `source + name + normalised message + first in-app frame (file:function)`. Before hashing, the message is normalised by replacing numbers, UUIDs, and URLs with placeholders. Storage is one row per fingerprint: `INSERT … ON CONFLICT(fingerprint) DO UPDATE SET count = count + 1, last_seen = …`, plus the latest sample stack. Duplicates therefore cost one row write each and do not create new rows.

**Quota and overflow.** D1 on Workers Free allows "Rows read 5 million / day", "Rows written 100,000 / day", and "Storage 5 GB (total)" ([D1 pricing](https://developers.cloudflare.com/d1/platform/pricing/), last updated 2026-10-30). The same page says: "When your account hits the daily read and/or write limits, you will not be able to run queries against D1", and limits "reset at 00:00 UTC". It never bills on the Free plan.

The limit is **per account**, so an error storm could use up the writes that sync and Feedback need. The endpoint must therefore cap itself:

- the [Rate Limiting binding](https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/), which has a 10- or 60-second period and is "approximate";
- a per-fingerprint throttle, for example counting in memory and writing at most once a minute per fingerprint;
- a daily ceiling, for example 5,000 Error Report writes.

Every report POST is also a Worker request, and the Free plan allows "100,000 requests" a day before "Error 1027" ([limits](https://developers.cloudflare.com/workers/platform/limits/)). The browser should send each fingerprint at most once per page load.

**Personal data.** Nothing is captured unless we choose to send it:

- Never store `CF-Connecting-IP` or headers.
- Drop query strings.
- Before writing, regex-redact anything that looks like an email address in the message or stack.

Promote then runs the same scrub again before anything becomes public.

**Promote.** On the Admin screen, a "Promote" button calls a Worker route. That route builds a scrubbed title and body and calls [Create an issue](https://docs.github.com/en/rest/issues/issues#create-an-issue) (`POST /repos/dwerkjem/cursive-key/issues` with `labels: ["needs-triage"]`). Two requirements from that page:

- The token needs the fine-grained permission **"Issues" repository permissions (write)**.
- The token's owner must have push access, because "Only users with push access can set labels for new issues. Labels are silently dropped otherwise."

The route stores the token as a Worker secret and records the issue URL on the Error Report row. Feedback Promote uses the same path.

**Known costs of this choice.**

1. Production browser stacks are minified. Either upload nothing and map them by hand when needed (store `release` so the matching source map can be found), or later add a mapping step at Promote time.
2. The grouping is simpler than Sentry's.
3. The capture endpoint, schema, and Admin list are about a day of work.

## New questions this raises

- **Shared D1 write budget.** How should the account's 100k rows written per day be shared between sync, Feedback, Access Requests, and Error Reports, and what daily ceiling should Error Reports get?
- **Promote implementation.** How does Promote authenticate to GitHub: a fine-grained personal access token, or a GitHub App installation token? The same answer applies to Feedback Promote.
- **Source maps.** Are browser source maps published, kept private, or not generated? This decides how readable Promoted browser stack traces are.
- **Observability allowance from Dec 1.** Should Workers Logs be enabled at all, given that from 2026-12-01 it shares the 0.5 GB/day allowance with Issues? Or should we use Issues only, with `invocation_logs = false`?
