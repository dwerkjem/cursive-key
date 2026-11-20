# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

This repo keeps all documentation in `doc/` (singular); only `README.md` and `AGENTS.md` live at the root. Paths below follow that convention.

## Before exploring, read these

- **`doc/GLOSSARY.md`**: the project's domain vocabulary.
- **`doc/adr/`**: read ADRs that touch the area you're about to work in.
- The design docs in `doc/` (`feasibility.md`, `data-sources.md`, `architecture.md`, `roadmap.md`) when the task touches their area.

If the glossary or ADRs don't exist, **proceed silently**. Don't flag their absence; don't suggest creating them upfront. The `/domain-modeling` skill (reached via `/grill-with-docs` and `/improve-codebase-architecture`) creates them lazily when terms or decisions actually get resolved.

## File structure

Single-context repo:

```
/
├── AGENTS.md
├── README.md
└── doc/
    ├── GLOSSARY.md
    ├── adr/
    │   ├── 0001-static-site-on-cloudflare.md
    │   └── 0002-progress-in-browser-storage.md
    └── agents/
```

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined in `doc/GLOSSARY.md`. Don't drift to synonyms the glossary explicitly avoids.

If the concept you need isn't in the glossary yet, that's a signal: either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it for `/domain-modeling`).

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than silently overriding:

> _Contradicts ADR-0007 (event-sourced orders), but worth reopening because…_
