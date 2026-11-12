# Roadmap

Each phase stays at $0 running cost. See [architecture.md](architecture.md).

## Phase 0: Prototype (prove the loop)

- [ ] Download one LOC By the People dataset CSV
- [ ] Hand-crop about 20 word snippets (a simple script with manual coordinates is fine)
- [ ] Astro site with a single quiz page: show snippet → type answer → compare → next
- [ ] ts-fsrs scheduling with progress in IndexedDB
- [ ] Deploy to Cloudflare Workers (static assets) on `*.workers.dev`

**Done when:** a stranger can practise 20 real snippets and come back the next day to see due reviews.

## Phase 1: Minimum viable product

- [ ] Curator cropping tool (Annotorious + OpenSeadragon on LOC IIIF), local-only
- [ ] Throttled crop-export script (under 150 req/min, back off on 429)
- [ ] About 300 snippets across several hands and decades, with full provenance
- [ ] Letterform gallery pages (A–Z, capitals and lowercase)
- [ ] Abbreviations and record-terms reference
- [ ] Export / Import progress
- [ ] Source credits and rights page
- [ ] Forgiving answer checking (case, punctuation, accepted alternate readings)

## Phase 2: Depth

- [ ] Practice sets by record type (census, deed, will, letter) and era
- [ ] Line-level and passage-level exercises
- [ ] Installable PWA (works offline; avoids Safari's 7-day storage wipe)
- [ ] Add NARA material once the licence is confirmed
- [ ] Automatic box suggestions (Kraken or a vision model), so the curator only corrects

## Phase 3: Community (only if there's demand)

- [ ] Optional sync code (Worker + D1)
- [ ] Contribution workflow for donated documents (start with GitHub PRs or a form; no accounts)
- [ ] "Report a wrong transcription" button

## Open questions

- [ ] NARA citizen-transcription licence
- [ ] George Washington dataset licence
- [ ] Which BTP campaigns best match genealogy-era hands (1780–1930)
- [ ] Domain name
