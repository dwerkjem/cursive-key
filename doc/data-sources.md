# Data Sources

_Researched 2026-11-12. Re-check rights before publishing any new collection._

## Summary

| Source | Usable? | Why |
|---|---|---|
| Library of Congress "By the People" | ✅ **Primary source** | Transcriptions are CC0; images are served openly; pages are peer-reviewed |
| National Archives (NARA) catalog | ✅ Likely | Federal records are generally public domain; about 1M citizen transcriptions; contribution licence not yet confirmed |
| George Washington HTR dataset | ⚠️ Check licence | Already segmented into words and lines with ground truth |
| Your own or donated family documents | ✅ With permission | Owner grants rights |
| **FamilySearch images** | ❌ **Do not use** | Custodian contracts forbid republishing images, even of out-of-copyright records |

## Library of Congress: By the People (BTP)

- **What:** Crowdsourced transcriptions of LOC manuscripts, published as CSV datasets. Repo: [libraryOfCongress/btp-data](https://github.com/libraryOfCongress/btp-data).
- **Licence:** Volunteer contributions are released into the public domain; the repository is CC0-1.0.
- **CSV columns:** `Campaign`, `Project`, `Item`, `ItemId`, `Asset`, `AssetStatus`, `DownloadURL`, `Transcription`, `Tags`. Dataset assets are always `Completed`, meaning they were reviewed by a second volunteer.
- **Scale:** A [2022 JOHD paper](https://doaj.org/article/f8a5a7c0f1db48bbb4781478bb3712e8) reports 23,316 transcriptions from seven campaigns. More datasets are published as item pages on loc.gov, such as the Susan B. Anthony and James A. Garfield Papers.
- **Limitation:** Transcriptions are **whole-page**, so we must find where each word or line sits on the page ourselves (see [architecture.md](architecture.md#content-pipeline)).
- **Rights caveat:** Some item pages warn that the underlying manuscripts may still be under copyright. Record each item's rights statement and use only public-domain items.

### LOC image service (IIIF)

- Base URL: `https://tile.loc.gov/image-services/iiif/{identifier}/{region}/{size}/{rotation}/{quality}.{format}`
- `region` accepts pixels (`x,y,w,h`) or percentages (`pct:x,y,w,h`), so a single word can be fetched as its own image.
- `.../info.json` returns the image dimensions.
- **Rate limits** ([source](https://www.loc.gov/apis/json-and-yaml/working-within-limits/)): image services 150 req/min, JSON API 20 req/min. Exceeding either means a **1-hour block**. Scripts must throttle and back off on HTTP 429 or CAPTCHA responses.
- **Decision:** download crops once at build time and serve them ourselves. Do not hotlink LOC from the live site.

## National Archives (NARA)

- [Catalog API](https://www.archives.gov/research/catalog/help/api) is free for civic and research use; request a key from Catalog_API@nara.gov.
- NARA asks users **not** to bulk-scrape the API. Use the [catalog dataset on the AWS Registry of Open Data](https://www.archives.gov/research/catalog/catalog-bulk-downloads) instead, which includes citizen contributions.
- Products using the API must state they are not endorsed by NARA.
- **To do:** confirm the licence on citizen transcriptions (NARA Citizen Contribution Policy) before use.

## George Washington dataset

- English continuous cursive (letters held at LOC), with word and line images plus ground-truth transcriptions ([survey](https://arxiv.org/pdf/2002.06300)).
- Useful for bootstrapping word-level snippets without manual cropping.
- **To do:** confirm licence.

## FamilySearch: excluded

FamilySearch's help centre says [contracts prohibit publishing or distributing record images](https://www.familysearch.org/en/help/helpcenter/article/do-i-have-a-legal-right-to-use-images-i-find-on-familysearch), including on the web, and its Terms of Use forbid reposting site content without permission. This applies even when the underlying record is out of copyright. We may **link** to FamilySearch for further reading, but never copy images from it.

## Per-snippet provenance (required fields)

Every snippet must carry: source collection, item ID, page/asset ID, source URL, rights statement, crop region, and transcription origin (BTP volunteer, NARA citizen, project curator).
