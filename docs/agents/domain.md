# Domain Docs

How the engineering skills should consume Formula Platform's domain documentation when exploring the codebase.

Formula Platform is split across four repositories (`formula-insights-api`, `platform-infrastructure`, `platform-gitops`, `platform-docs`). The domain language and the decisions are system-wide, so they live in one place: the **`platform-docs`** repository.

## Before exploring, read these

- **`GLOSSARY.md`** at the root of `platform-docs`.
- **`adr/`** in `platform-docs`: read the ADRs that touch the area you're about to work in. They are named `ADR-NNN.md` (for example `ADR-007.md`); a new ADR takes the next number.

From another repository, find `platform-docs` as a sibling clone (`../platform-docs`). If it isn't cloned there, read it on GitHub: `fabriciolelis/platform-docs`.

If any of these files don't exist, **proceed silently**. Don't flag their absence; don't suggest creating them upfront. The `/domain-modeling` skill (reached via `/grill-with-docs` and `/improve-codebase-architecture`) creates them lazily, in `platform-docs`, when terms or decisions actually get resolved.

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined in `GLOSSARY.md`. Don't drift to synonyms the glossary explicitly avoids.

If the concept you need isn't in the glossary yet, that's a signal: either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it for `/domain-modeling`).

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than silently overriding:

> _Contradicts ADR-007 (Alembic migrations), but worth reopening because…_
