# Feasibility

_Researched 2026-11-12._

## Verdict

**Feasible.** The software is simple and can be hosted for $0. The real work is **content curation**: choosing, cropping, and checking snippets. A legally clean source of material exists (Library of Congress "By the People", public domain), so that work is the main bottleneck, not a blocker.

## The gap

| Existing resource | What it does well | What it lacks |
|---|---|---|
| [BYU Script Tutorial](https://script.byu.edu/) | Interactive letter, word, and passage tests in 7 languages | English material centres on 1500–1800; limited volume of drills |
| [UK National Archives palaeography](https://www.legacytree.com/blog/learn-to-read-old-handwriting-in-seven-languages) | Strong tutorial with exercises | 1500–1800 British hands only |
| [FamilySearch Full-Text Search](https://familysearch.org/en/blog/ai-developments-genealogy) | AI transcriptions of deeds, wills, and more | A search tool, not a teacher; transcripts are imperfect and still need a human who can read the hand |
| Kip Sperry, *Reading Early American Handwriting* | Good reference | Paid book, not interactive |

**What's missing:** a free, high-volume, practice-focused tool for the hands US genealogists actually meet (roughly 1750–1930: round hand, Spencerian, Palmer, census enumerators, clerks of court) built from real documents.

## What makes this different

1. Hundreds to thousands of short real snippets, not a handful of sample pages.
2. Spaced repetition (FSRS), so practice concentrates on what each learner gets wrong.
3. Letterform galleries: "every way people wrote a capital S," drawn from real documents.
4. Record-type practice sets (census, deed, will, letter) plus abbreviations and terms (inst., ult., relict, do = ditto, etc.).

## Risks

| Risk | Mitigation |
|---|---|
| Curation is labour-intensive | Start with ~300 snippets; build a fast private cropping tool; later accept community contributions |
| Image rights | Use only items marked public domain; store the source URL and rights statement with every snippet ([details](data-sources.md)) |
| Crowd transcription errors | Use only reviewed ("Completed") By the People pages; check each snippet by eye when cropping |
| AI makes the skill "unnecessary" | AI transcription still needs a human who can check it; position the site as how to verify AI output |
| Running costs | Static architecture with no required database ([details](architecture.md)) |
