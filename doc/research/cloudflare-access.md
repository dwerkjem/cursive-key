# Cloudflare Access as the identity layer

_Researched 2026-11-12 for [issue #2](https://github.com/dwerkjem/cursive-key/issues/2). Sources are Cloudflare's own docs and pricing pages. Each one's "last updated" date is given where the page shows it. Claims marked **unverified** are not stated in any primary source and need a prototype on a real account to confirm._

## Answer

| Use | Viable? | Why |
|---|---|---|
| **Closed Beta gate** | **Yes**, as long as Admins, Curators and Beta Testers together stay under 50 people | The Zero Trust Free plan is $0 for 50 users. One-time PIN sign-in needs no identity provider account. An Admin's approval can update the allowlist through the API. |
| **Optional sign-in after Public Launch** | **No** | It works technically, but every Person who signs in takes one of the 50 free seats. When the seats run out, logins are blocked. The paid plan is $7 per user per month, so the $20 budget covers 2 users. |
| **Gating preview deploys** | **Yes** | Worker-level Access can protect a Worker's previews only, or all of its traffic. |

**Recommended setup:** use Cloudflare Access for the Closed Beta gate, the Admin and Curator areas, and preview URLs. Don't use it for Learner sign-in after Public Launch. Build that sign-in in the Worker (Hono + D1) instead. [Alternatives](#cheapest-alternative-for-optional-sign-in) lists the options.

## 1. Seats, limits and cost

| Fact | Value | Source |
|---|---|---|
| Free plan | "$0 … forever", **50 users**, logs kept up to 24 hours | [SASE / Zero Trust pricing](https://www.cloudflare.com/plans/sase-zero-trust.md) (fetched 2026-11-12) |
| Pay-as-you-go | **$7 /user/month**, no user limit, logs kept up to 30 days | same |
| What uses a seat | "any Cloudflare Access authentication event, such as a login to the App Launcher or an application". A user takes one seat however many applications they open. | [Seat management](https://developers.cloudflare.com/cloudflare-one/team-and-resources/users/seat-management/) (updated 2026-05-01) |
| When a seat is freed | Only when the user is **removed** from the organization. Revoking a user's session does not free the seat. Seats are not counted per month. | same |
| Automatic removal | "Remove inactive users from seats" removes users after 1 month to 1 year of inactivity. It runs once a day. | same |
| When seats run out | "additional users who attempt to log in are blocked" | same |
| Avoiding seat use | Service tokens give access "without consuming seats" | same |
| Access app limits | 500 applications, 500 reusable policies, 1,000 emails per rule, 50 domains per application, 50 identity providers | [Account limits](https://developers.cloudflare.com/cloudflare-one/account-limits/) (updated 2026-11-05) |

**Staying within $20/month.** The Free plan costs $0 up to 50 seats. The paid plan doesn't fit the budget: $20 ÷ $7 = 2 users. Forum posts say that leaving Free makes *every* seat billable (51 × $7 ≈ $357/month). No official page confirms or denies this (**unverified**). Either way, more than 50 Persons don't fit the budget.

**Unverified:** what Free does at the 51st user. The seat page says logins are blocked, and no page says Free bills for overage. A November 2026 forum post says the Free checkout asks for card authorization "for usage exceeding free limits". The forum page couldn't be fetched (HTTP 403) to check it. Test this before relying on Free as a hard cap.

## 2. Login methods on Free

- **One-time PIN (OTP) by email** is offered "as an alternative to integrating an identity provider". The PIN expires after 10 minutes and works once. "Cloudflare only sends the email if the user is allowed by an Access policy", but the login page always says a code was sent. Mail scanners can use up the PIN by following the link, and the fix is to request a new code. ([One-time PIN](https://developers.cloudflare.com/cloudflare-one/integrations/identity-providers/one-time-pin/))
- **Several identity providers at once:** Cloudflare "supports all SAML and OIDC providers" (Google and GitHub included), and also offers built-in **Passkeys** and a **Cloudflare identity provider**. Several can be enabled together and the Person picks one. The page lists no limits by plan. ([Identity providers](https://developers.cloudflare.com/cloudflare-one/integrations/identity-providers/), updated 2026-11-10)
- **So Beta Testers don't need a Google or GitHub account.** OTP to any email address works.
- **Pitfall:** Access matches the policy against the *email* the Person signs in with. Never use an "Everyone" or "Login Methods: One-time PIN" include rule on a gated app, because then anyone with an email address gets in. ([Policies](https://developers.cloudflare.com/cloudflare-one/access-controls/policies/), updated 2026-11-02)

## 3. Closed Beta: public Landing Page and Access Request form, everything else gated

### How Access decides which rule applies

- The **most specific rule wins**. Hostname or path applications apply first, then Worker-level Access, then account-level Access. ([Workers: Cloudflare Access](https://developers.cloudflare.com/workers/configuration/cloudflare-access/), updated 2026-11-02)
- Within one hostname, "the more specific rule takes precedence" for paths that share a root. A path with no rule of its own inherits its parent's rule. ([Application paths](https://developers.cloudflare.com/cloudflare-one/access-controls/policies/app-paths/), updated 2026-04-17)
- A **Bypass** policy "does not enforce any Access security controls and requests are not logged". It can't use identity selectors. Bypass and Service Auth policies are evaluated before Allow and Block. ([Policies](https://developers.cloudflare.com/cloudflare-one/access-controls/policies/))
- Path matching: `example.com/*` and an empty path both cover the apex and every path under it. `example.com/alpha/*` does **not** cover `example.com/alpha` itself. Query strings aren't supported. ([Application paths](https://developers.cloudflare.com/cloudflare-one/access-controls/policies/app-paths/))

### Recommended configuration (gated unless a path is explicitly public)

1. **Gate:** turn on Worker-level Access for the site's Worker with "All traffic" (`worker` destination). This covers routes, the Custom Domain, `workers.dev` and previews. The Allow policy includes an Access group called `beta-testers`, plus the Admin and Curator emails.
2. **Public holes:** add self-hosted applications on the custom hostname with **Bypass / Everyone** for the Access Request form (for example `/request-access` and `/request-access/*`) and for the static assets those pages need (for example the Astro bundle prefix and a dedicated `/public-assets/*` prefix). Snippet images stay gated. Because hostname and path apps beat Worker-level Access, these holes take precedence.
3. **Landing Page at `/`: unverified, needs a prototype.** No documented path pattern matches the root alone. An empty path and `/*` both cover everything. If a path app for exactly `/` doesn't work, there are two fallbacks. (a) Put the Landing Page at a public path such as `/welcome` and make that the link people share. Visitors to `/` then see the Access login page, which can be branded and can link to `/welcome`. (b) Do the opposite: gate only a few prefixes (`/learn/*`, `/snippets/*`, `/api/*`), which leaves `/` public. The risk is that any route added outside those prefixes is public by mistake.
4. **Admin and Curator areas:** add separate path apps (`/admin/*`, `/curate/*`) whose Allow policies list only those Persons. Keep them after Public Launch.

### Approving an Access Request through the API

Yes, this can be automated.

- **Access group (recommended):** `PUT /accounts/{account_id}/access/groups/{group_id}`. `include` and `name` are required. The token needs **"Access: Organizations, Identity Providers, and Groups Write"**. ([API: update group](https://developers.cloudflare.com/api/resources/zero_trust/subresources/access/subresources/groups/methods/update/)) This is a narrower permission than editing apps and policies. The Admin page's approve action reads the group, adds `{ "email": { "email": "…" } }` to `include`, and PUTs it back. One rule holds at most 1,000 emails, which is far more than 50 seats need.
- **Reusable policy (alternative):** `PUT /accounts/{account_id}/access/policies/{policy_id}`. `decision`, `include` and `name` are required, with "Access: Apps and Policies Write". ([API: update policy](https://developers.cloudflare.com/api/resources/zero_trust/subresources/access/subresources/policies/methods/update/)) That permission can rewrite every app's policy, so it's a worse token to keep as a Worker secret.
- **External Evaluation (alternative):** an Access rule calls a Worker, which answers yes or no in a signed JWT. That Worker could check a D1 table of Beta Testers, so no Access API token is needed at all. The docs don't say whether it runs on Free, how long it may take, or how it interacts with OTP sending (**unverified**). ([External Evaluation](https://developers.cloudflare.com/cloudflare-one/access-controls/policies/external-evaluation/), updated 2026-10-12)
- **Unverified:** whether the `PUT` replaces `include` entirely, as is likely. Assume it does and always send the full list. Removing a seat through the API isn't documented on the seat page. Only the dashboard and SCIM are mentioned.
- **Seat budget:** Admins + Curators + Beta Testers ≤ 50. Turn on seat expiration (minimum 1 month) so Beta Testers who drift away free their seats.

## 4. Public Launch: public site with optional sign-in

**It works technically**, as follows:

- Remove the Worker-level "All traffic" gate. Keep a path app on `/signin` (and the `/admin/*` and `/curate/*` apps) with an Allow policy for anyone who signs in.
- `CF_Authorization` is scoped to the domain unless cookie path scoping is turned on: "When disabled, the `CF_Authorization` cookie is only scoped to the domain and subdomain." It is HttpOnly by default. ([Authorization cookie](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/authorization-cookie/), updated 2026-11-02) After signing in at `/signin`, the browser therefore sends the cookie to public paths too. There, Access adds no header, so the Worker verifies the cookie itself (see §6). Pages are static assets, so the page would ask the Worker who is signed in with a call like `GET /api/me`.
- **Unverified:** whether Access strips or rewrites `CF_Authorization` on paths with no Access app or with Bypass.

**It isn't viable, for these reasons:**

1. **Seats.** Every Person who signs in takes a seat until they're removed. Even with seat expiration at its 1-month minimum, the free ceiling is about 50 *monthly active signed-in Persons*. That ceiling is far too low for a public site, and the paid plan costs $7 per user.
2. **Seat exhaustion locks everyone out.** An Allow policy that lets anyone with an email in means anyone, a bot included, can use up the 50 seats with throwaway addresses. From then on "additional users who attempt to log in are blocked", Admins included unless they still hold a seat. During the Closed Beta this can't happen, because OTP only sends codes to allowlisted emails.
3. **Portability.** Identity tied to Access only works behind Cloudflare's edge. This conflicts with keeping the app portable to a Node container ([#6](https://github.com/dwerkjem/cursive-key/issues/6)).

### Cheapest alternative for optional sign-in

Build sign-in in the Worker (Hono routes, sessions in D1, an HttpOnly session cookie). Hosting and data stay on Cloudflare.

| Option | Monthly cost | Notes |
|---|---|---|
| **Email magic link or code**, sent with Cloudflare Email Service | **$5** (Workers Paid minimum), which includes 3,000 emails a month, then $0.35 per 1,000 | Email Sending is "Not available" on Workers Free ([Email pricing](https://developers.cloudflare.com/email-service/platform/pricing/), updated 2026-06-09). Workers Paid has a "minimum charge of $5 USD per month" ([Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/), updated 2026-10-02). This works for every Person, but it conflicts with the "stay on Workers Free" guardrail in `architecture.md`. |
| **Passkeys (WebAuthn)** in the Worker | $0 | No email needed. Recovering a lost device is hard, and some genealogists may find passkeys unfamiliar. |
| **Google / GitHub OAuth** in the Worker | $0 | Free and familiar, but Google or GitHub becomes the identity provider. |

A reasonable mix is OAuth plus passkeys at $0, with magic links added if Workers Paid is accepted. Which to choose is a new question (see below).

## 5. Preview deploys and `*.workers.dev`

- "Access can protect one Worker's production workers.dev URL, preview URLs, or both", and it can also protect "all Workers or all Worker previews in an account". ([workers.dev](https://developers.cloudflare.com/workers/configuration/routing/workers-dev/), updated 2026-11-06)
- API destination types: `worker`, `preview_worker`, `all_workers`, `all_preview_workers`. ([Workers: Cloudflare Access](https://developers.cloudflare.com/workers/configuration/cloudflare-access/))
- Preview URLs are **public by default**. Cloudflare adds `X-Robots-Tag: noindex` on `workers.dev` previews but not on custom-domain previews. Worker Previews need Wrangler 4.135.0 or later. ([Previews](https://developers.cloudflare.com/workers/previews/), [changelog 2026-09-22](https://developers.cloudflare.com/changelog/post/2026-09-22-worker-previews/))
- Worker-level Access **can't exclude paths**, so public paths need hostname apps (see §3). WebSocket upgrades through Worker-level Access fail with a 403.
- **Setup:** during the Closed Beta, "All traffic" covers previews automatically. After Public Launch, switch to "Previews only" (`preview_worker`). The production `workers.dev` hostname is then public. Either turn it off (`workers_dev = false`) or protect it. On the older Version URLs page, "If workers_dev is disabled, Version URLs are disabled by default" ([Version URLs](https://developers.cloudflare.com/workers/configuration/previews/), updated 2026-09-22). Whether the newer Previews are affected the same way is **unverified**.
- Preview sign-ins use seats too. Use the same staff policy, or a service token for CI smoke tests, since service tokens use no seats.

## 6. Verifying identity in the Worker

- **Token:** Access sends a JWT in the `Cf-Access-Jwt-Assertion` header, and also as the `CF_Authorization` cookie for browsers. Cloudflare recommends the header because "the cookie is not guaranteed to be passed". ([Validate JWTs](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/authorization-cookie/validating-json/), updated 2026-11-02)
- **Checks:** verify the signature with keys from `https://<team>.cloudflareaccess.com/cdn-cgi/access/certs`, matching the token's `kid`. `iss` must equal the team domain and `aud` must equal the application's AUD tag. The AUD tag "will never change unless you delete or recreate the Access application". Signing keys rotate every 6 weeks, and old keys stay valid for 7 days, so fetch keys from the endpoint and never hard-code them. Cloudflare's example uses `jose` `jwtVerify` with `issuer: env.TEAM_DOMAIN` and `audience: env.POLICY_AUD`. (same page)
- **Several apps mean several AUD tags.** The gate, `/signin`, `/admin/*` and the Worker-level app each have their own AUD tag, so the verifier should accept a configured list.
- **`ctx.access` isn't available to this project.** "Workers with Static Assets execute behind an internal router Worker" and "the router does not pass `ctx.access` to the user Worker". ([Workers: Cloudflare Access](https://developers.cloudflare.com/workers/configuration/cloudflare-access/)) Verify the JWT by hand. **Unverified:** that the `Cf-Access-Jwt-Assertion` header itself does reach a Worker with static assets. Test this in the first prototype.
- **Claims** ([Application token](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/authorization-cookie/application-token/), updated 2026-06-25): `email` (verified by the identity provider), `sub`, `iss`, `aud`, `exp`, `iat`, `nbf`, `type`, `identity_nonce` and `country`. Service tokens have an empty `sub`.

### Testing locally and in CI without real logins

- `wrangler dev` can simulate Access with an `[access.dev]` block (`aud` is required, `identity` is optional). It only fills in `ctx.access`, though, which this project can't use (see above). So it doesn't help here.
- Instead, make the verifier a small module that takes `{ issuer, audiences, keySet }`:
  - In production, `keySet` is `createRemoteJWKSet(new URL(TEAM_DOMAIN + "/cdn-cgi/access/certs"))`.
  - In tests (Vitest, including `@cloudflare/vitest-pool-workers`), create a key pair with `jose` `generateKeyPair`, build `createLocalJWKSet`, and sign tokens with `SignJWT`. Write cases for valid, expired, wrong `aud`, wrong `iss`, unknown `kid` and missing token. No network or real login is needed, so it runs the same way in GitHub Actions.
  - For local development, a dev-only route can sign a token with the test key. Enable it only when a dev-only binding is present, and assert in a test that the production config lacks that binding.
- Run one manual smoke test against a preview URL with a real OTP login before turning the gate on.

## 7. What to store per Person in D1

- **Key on an internal id, and look Persons up by normalized email.** `sub` is "unique to an email address per account", but it **changes if the user is removed and re-added** to the organization ([Application token](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/authorization-cookie/application-token/)). Seat expiration removes users, so `sub` isn't stable for this project. It is also tied to Access, which won't be used for Learner sign-in after launch.
- Suggested shape:

  ```sql
  person(id TEXT PRIMARY KEY,          -- our own random id
         email TEXT NOT NULL UNIQUE,   -- lower-cased, from the verified `email` claim
         access_sub TEXT,              -- last seen Access sub; a hint, never a key
         created_at INTEGER NOT NULL)
  person_role(person_id TEXT, role TEXT, PRIMARY KEY (person_id, role))
  ```

- Email is personal data, which brings in [#11](https://github.com/dwerkjem/cursive-key/issues/11) (privacy and retention). It is also the field that carries a Beta Tester across to whatever sign-in replaces Access at Public Launch.

## Blockers and open risks

1. **Seats rule out Access for public sign-in** (§4). This is a blocker for the "optional sign-in" half of the ticket.
2. **Unverified:** whether the Landing Page can be at `/` while every other path is gated (§3). There are fallbacks.
3. **Unverified:** that `Cf-Access-Jwt-Assertion` reaches a Worker with static assets, and that `CF_Authorization` reaches Bypass or uncovered paths (§4, §6).
4. **Unverified:** what Zero Trust Free does at the 51st seat: blocks or bills (§1).
5. Email magic links need Workers Paid ($5/month), which conflicts with the Workers-Free guardrail in `architecture.md`.
6. `architecture.md` still says "User accounts / auth: rejected". The Closed Beta and the optional sign-in described in the glossary replace that decision. Update the doc when this lands.
