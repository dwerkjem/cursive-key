# Architecture

_Researched 2026-11-12. Free-tier numbers are mostly from 2026 third-party summaries that cite official pages; verify on Cloudflare's pricing pages before relying on any specific limit._

## Constraints

- **Free for users, forever.**
- **Near-zero running cost.** The project has very little money, so no part of the system may produce a surprise bill.
- **Cloudflare ecosystem.**

## Key decision: most of the data needs no database

| Data | Example | Where it lives | Cost |
|---|---|---|---|
| **Lesson content** | Snippet images, crop boxes, transcriptions, galleries | JSON and image files in this repo, deployed as static assets | $0 |
| **Learner progress** | FSRS review state, history | Learner's browser (IndexedDB) + export/import file | $0 |
| **Shared state** (later) | Cross-device sync, community submissions | Cloudflare D1 via a Worker | $0 within free tier |

Lesson content only changes when a curator publishes, so it ships with the site. Hosting cost doesn't grow with the number of learners.

## Stack

| Layer | Choice | Notes |
|---|---|---|
| Hosting | **Cloudflare Workers with static assets** | Cloudflare now recommends this over Pages for new projects ([migration guide](https://developers.cloudflare.com/workers/static-assets/migrate-from-pages/)). Static asset requests are **free and unlimited**. Free plan allows about 20,000 files and 25 MiB per file. |
| Site framework | **Astro**, static output | Content pages (galleries, guides) stay static; the quiz runs as an interactive island. Deploys well to Workers. |
| Spaced repetition | [**ts-fsrs**](https://github.com/open-spaced-repetition/ts-fsrs) (MIT) | FSRS v6, the algorithm used by Anki; runs fully in the browser. |
| Learner storage | IndexedDB (e.g. via `idb`) | Plus "Export / Import progress" (JSON file). |
| Snippet images | Static assets bundled with the site | About 10–30 KB WebP or JPEG each; 1,000 snippets ≈ 20 MB. |
| Optional sync API | **Worker + D1** | Added in a later phase only. |
| Overflow images | **R2** (only if we pass the asset file limit) | 10 GB-month storage, 1M Class A / 10M Class B ops per month, zero egress ([pricing](https://developers.cloudflare.com/r2/pricing)). |

## Content pipeline

```
LOC BTP CSV ──► pick pages ──► curator cropping tool ──► snippets.json + crop JPEGs ──► git ──► deploy
  (CC0 text)                    (Annotorious +             (provenance, transcription,
                                 OpenSeadragon on LOC IIIF)  tags, difficulty)
```

1. **Select:** filter BTP datasets for Completed, legible, public-domain pages.
2. **Crop:** a local, curator-only web tool using [Annotorious + OpenSeadragon](https://annotorious.dev/guides/openseadragon-iiif/) loads the LOC IIIF image. The curator draws boxes around words or lines and confirms the transcription text from the page transcript.
3. **Export:** a script downloads each region once from `tile.loc.gov` (throttled under 150 req/min), saves it as a static image, and writes metadata to `content/snippets.json`.
4. **Publish:** commit and deploy. There is no admin backend and no server-side CMS; git is the CMS.

Later: suggest boxes automatically (Kraken line segmentation, or a vision model) so the curator only corrects them.

### Snippet record (draft)

```json
{
  "id": "btp-sba-000123-w04",
  "image": "snippets/btp-sba-000123-w04.webp",
  "text": "Rochester",
  "alternates": [],
  "kind": "word",
  "tags": ["place", "capital-R"],
  "era": "1870s",
  "recordType": "letter",
  "difficulty": 2,
  "source": {
    "collection": "Susan B. Anthony Papers",
    "itemId": "mss11049...",
    "asset": "...",
    "url": "https://www.loc.gov/item/...",
    "iiif": "https://tile.loc.gov/image-services/iiif/.../1222,3511,1303,413/full/0/default.jpg",
    "rights": "No known restrictions on publication.",
    "transcriptionBy": "By the People volunteers (CC0)"
  }
}
```

## Learner progress and the Safari problem

Safari deletes script-writable storage (IndexedDB, localStorage) for a site **after 7 days of Safari use without visiting it** ([web.dev](https://web.dev/articles/storage-for-the-web)). Home-screen web apps are reportedly exempt. Mitigations, in build order:

1. **Export / Import progress** as a JSON file (Phase 1).
2. **Installable PWA** with a manifest and service worker, so users can add it to the home screen (Phase 2).
3. **Optional sync code** (Phase 3): no accounts and no personal data.
   - The learner gets a random code (e.g. `maple-ink-4821`) and the browser `PUT`s its compressed progress blob to a Worker.
   - The Worker stores it in D1, keyed by a hash of the code.
   - Save at most once per study session. The blob is a few KB.

## Free-tier budget (Workers Free plan)

| Resource | Free limit | Our expected use |
|---|---|---|
| Static asset requests | Unlimited | All page and image traffic |
| Worker requests | 100,000/day | Sync API calls only |
| D1 rows read / written | 5M / 100K per day, 5 GB storage | One write per sync; about 100K syncs/day |
| R2 (if needed) | 10 GB, zero egress | Only if images outgrow static-asset limits |

Since **2026-09-01**, D1 queries on the free plan [**fail** once the daily limit is hit](https://developers.cloudflare.com/changelog/post/2026-09-01-d1-free-tier-limit-enforcement/) until the 00:00 UTC reset, instead of billing. That is the desired behaviour here: the worst case is "sync paused until tomorrow," never a bill. The app must treat sync failures as non-fatal because local progress is the primary copy.

## Cost

| Item | Cost |
|---|---|
| Hosting, bandwidth, images, D1 | $0 |
| Domain (optional; `*.workers.dev` works) | about $10–15/year |

**Guardrail:** stay on the Workers Free plan. Don't upgrade to Workers Paid unless the project has funding, because the free plan hard-caps usage rather than billing for it.

## Rejected alternatives

| Option | Why not |
|---|---|
| Hotlinking LOC IIIF at runtime | 150 req/min limit with 1-hour blocks; dependency on a third-party server |
| Supabase | Free projects pause after 7 days inactive; next tier $25/mo |
| A server-side database for lesson content | Unneeded cost and complexity for read-only data |
| User accounts / auth | Personal data to protect, more cost; a sync code is enough |
