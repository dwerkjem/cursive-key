# Undocumented Cloudflare behaviours, checked on a real account

_Checked 2026-11-20 for [issue #16](https://github.com/dwerkjem/cursive-key/issues/16). A throwaway Worker (static assets, D1, a Preview) ran on a spare custom domain. Access apps were created through the API on an existing Zero Trust **Free** org. Everything was deleted afterwards. The wizard and Worker are in `spike/cloudflare-checks/`. Times are UTC._

## Answer in brief

| # | Question | Answer |
|---|---|---|
| 1 | Can `/` alone be public while every other path is gated? | **No.** An Access app on `host/` is accepted and stored, but it does not make `/` public. Two layouts that do work: gate the whole host and make `/welcome` (plus assets and the form) public, or gate only chosen prefixes and leave everything else public. |
| 2 | Does `Cf-Access-Jwt-Assertion` reach a Worker that uses static assets? | **Yes.** It arrives on Worker routes and on asset paths routed through the Worker with `run_worker_first`, for both browser sign-ins and service tokens. |
| 3 | Is the Access cookie or JWT sent on bypassed or uncovered paths? | **The cookie is, the JWT header isn't.** `CF_Authorization` reaches the Worker on Bypass and uncovered paths. Access adds `Cf-Access-Jwt-Assertion` only on paths it gates. |
| 4 | At the 51st seat on Free, are logins blocked or billed? | **Not answered.** The test was stopped after the first login. See [4](#4-the-51st-seat). |
| 5 | Does strict service-token mode break apps that mix Allow and Service Auth? | **Mixed apps work on this org, but this org predates strict mode** (created 2025-07-17; strict is the default for orgs created after 2026-10-05). Still open for a new org. |
| 6 | What does a Worker-only API path return once the Free daily cap is hit? | **Not run.** It would have stopped every Worker on the real account until 00:00 UTC. |
| 7 | Do Preview URL requests count toward the daily Worker request limit? | **Treat them as counting.** 300 Preview requests showed up as 301 Worker invocations in account analytics, the same as 300 production requests (300). |
| 8 | Does each statement in a D1 `batch()` count toward the per-invocation query limit? | **No limit was hit at all.** On Workers Free, `batch()` with 1,001 statements and 1,001 separate queries both succeeded. The documented Free limit of 50 wasn't enforced in either mode. |

## 1. Public `/` with everything else gated

Each layout was applied through the API, then probed without credentials. "Gated" means a 302 redirect to the team's `cloudflareaccess.com` login. "Open" means the Worker or an asset answered.

### Layout A: whole host gated, Bypass app on exactly `/`

- The API accepted `domain: "host/"` and stored it unchanged as a separate app from the whole-host one.
- **`/` stayed gated**, and so did every other path, for 2½ minutes after the Bypass app was created. Bypass apps in layout B opened within that same wait, so this isn't slow propagation.
- Conclusion: a path app for `/` doesn't isolate the root. This rules out a Landing Page at `/` with Access path rules alone.

### Layout B: whole host gated, Bypass on `/welcome`, assets and the form

Bypass apps: `host/welcome`, `host/welcome/*`, `host/_astro/*`, `host/api/access-requests`.

| Path | Result |
|---|---|
| `/` | Gated |
| `/welcome` | Passed Access; the asset server redirected (307) to `/welcome/` |
| `/welcome/` | Open |
| `/_astro/app.css` | Open |
| `/api/access-requests` (GET and POST) | Open |
| `/secret/`, `/learn/`, `/api/echo` | Gated |

This is fallback (a) from the [Access research](cloudflare-access.md#3-closed-beta-public-landing-page-and-access-request-form-everything-else-gated). It works, but anyone who visits `/` sees the Access login page. They only reach the Landing Page through a shared `/welcome` link, or a link on a branded login page.

### Layout C: only `/learn` and `/api/*` gated

Gated apps: `host/learn`, `host/learn/*`, `host/api/*`. Bypass app: `host/api/access-requests`.

| Path | Result |
|---|---|
| `/`, `/welcome/`, `/_astro/app.css` | Open |
| `/secret/` (no app covers it) | **Open** |
| `/learn`, `/learn/`, `/api/echo` | Gated |
| `/api/access-requests` (GET and POST) | Open: the more specific Bypass app beats `/api/*` |
| `/uncovered/echo` | Open |

This is fallback (b). The Landing Page can sit at `/`, but `/secret/` shows the risk: **any route added outside the gated prefixes is public by default.**

## 2. The JWT header reaches a Worker with static assets

| Request | Header reached the Worker? |
|---|---|
| Service token → `/api/echo` (Worker route), layouts A, B, C | Yes (`type: app`) |
| Service token → `/secret/` (asset via `run_worker_first`), layouts A, B | Yes |
| Browser sign-in (one-time PIN) → `/secret/` and `/api/echo` | Yes (`type: app`, email present) |

The [portability research](portability.md)'s plan to verify the header with `jose` holds, and `ctx.access` isn't needed.

## 3. Cookie and JWT on Bypass and uncovered paths

| Request | `CF_Authorization` cookie at the Worker | JWT header |
|---|---|---|
| curl with the service token's cookie → Bypass path (B, C) | Yes | No |
| curl with that cookie → uncovered path (C) | Yes | No |
| Browser after sign-in → Bypass path (B, C) | Yes | No |
| Browser after sign-in → uncovered path (C) | Yes | No |

- Access doesn't strip `CF_Authorization` on paths it doesn't gate. On those paths the Worker has to verify the cookie itself (same `jose` check, same JWKS).
- A service token login also sets `CF_Authorization`.
- Browsers also carried `CF_AppSession` and `cf_clearance` on every path once Access had served the hostname.
- Each browser visit was logged twice, once with only `CF_AppSession` and once with all three cookies. That's most likely a second browser context or a prefetch, and it doesn't change the result.

## 4. The 51st seat

The org started with 2 seats in use. The first plus-addressed login (`you+ck16-1@…`) didn't add a seat: the count stayed at 2, and no user for that address appeared. The test was stopped at login 2. The 49 more logins needed to reach the limit made it impractical. The question is still open:

- What Free does at the 51st login is still only what [Seat management](https://developers.cloudflare.com/cloudflare-one/team-and-resources/users/seat-management/) says: "additional users who attempt to log in are blocked".
- Whether a plus-addressed email counts as a separate seat wasn't confirmed either.

## 5. Strict service-token mode

On this org, an app whose policies are Allow (one email) plus Service Auth (one service token) let the service token through on every layout (`/learn/` → 200). The org was created on 2025-07-17, so it doesn't have the strict mode that's the default for orgs created after 2026-10-05. Whether that mode changes the result needs a new org.

## 6. The daily request cap

Not run. Hitting the 100,000/day cap on the real account would have stopped every Worker on it until 00:00 UTC. It's still undocumented what a Worker-only path returns at the cap (1027 or 429).

## 7. Preview requests and the daily limit

| Window | Sent | Worker invocations in GraphQL analytics |
|---|---|---|
| 01:54:58–01:55:00, Preview URL only | 300 | 301 |
| 01:56:00–01:56:02, production `workers.dev` only | 300 | 300 |

Preview requests are recorded as ordinary Worker invocations on the account, one for one. Analytics reported the script name as `__unknown__` in both windows, so this doesn't show whether Previews are attributed to the production script. The analytics aren't the limit counter itself, but it's the safe reading: **budget Preview and CI traffic inside the 100,000/day**, as [free-tier limits](free-tier-limits.md) already assumed (5,000/day bucket).

## 8. D1 `batch()` and the per-invocation query limit

The account is on **Workers Free**. Requests went to the deployed Worker's `workers.dev` URL, each in its own invocation.

| Mode | 49 | 50 | 51 | 60 | 1,000 | 1,001 |
|---|---|---|---|---|---|---|
| Separate queries (`.first()` in a loop) | ok | ok | ok | ok | ok | ok |
| One `batch()` of N statements | ok | ok | ok | ok | ok | ok |

- The documented Free limit of 50 wasn't enforced, in either mode. Even 1,001, past the Paid limit, went through.
- So "does `batch()` count per statement?" doesn't matter at these sizes.
- Don't rely on this. The documented limit may be enforced later or elsewhere, so keep designs within 50 queries per invocation on Free. The [free-tier limits](free-tier-limits.md) design (one progress row written once per session) already does.

## What this changes

- **#17 (how the gate is enforced):** "Landing Page at `/` with Access path rules only" is ruled out. The options are now:
  - layout B (`/welcome` public, everything else gated by Access)
  - layout C (prefix gates, with a lint or test that fails when a route is added outside them)
  - `run_worker_first` with the gate in the Hono app, which keeps `/` and works the same on Node
- **#15 and the identity port:** after sign-in, the Worker will see `CF_Authorization` on public paths with no JWT header. Anything that shows "signed in" on a public page has to validate the cookie.
- **#9 (running the Closed Beta):** the 50-seat limit is still known only from the docs. Keep the plan to enable seat expiration and stay well under 50.
- **#5 and #7:** Preview traffic counts as Worker requests. Keep the Preview and CI budget.
- **Still open:**
  - check 6 (a throwaway account is needed)
  - check 4 (needs about 50 logins, or a support answer)
  - check 5 on a post-2026-10-05 org
