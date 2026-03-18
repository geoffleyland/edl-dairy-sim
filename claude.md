# Production Planning Tool — Claude Code Briefing

**Before doing anything, read `docs/architecture.md` and `docs/domain.md`.**

This project is a livestock allocation planning tool replacing a GAMS-based
legacy stack. The plan editor is the primary deliverable. Phase 1 of the solver
(LP transportation problem: supply limits + shift capacity) is implemented and
tested.

The architecture and code conventions are in `docs/architecture.md`. They are
deliberately reusable across planning tool projects — carry that file forward.

The domain, the data model, and what we're actually building are in `docs/domain.md`.

## Working style

- **Push back on bad ideas.** Don't be agreeable. Say when something is wrong
  or when there's a better way.
- **Naming matters.** Think hard about names. Don't abbreviate unless you're
  abbreviating everywhere. Raise bad names in review — good names come from
  discussion, not from one side alone.
