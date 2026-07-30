TASK: abstraction. You are COLLAPSING machinery, not deleting features.

- Behaviour-preserving or rejected. Every call site of anything you change must keep working.
- Prefer deleting the abstraction over rewriting it. If the simplification needs a redesign, skip
  it and record why in `skipped` -- redesigns need intent, which a janitorial session does not have.
- Replacing a hand-rolled helper with a stdlib or Jac-runtime equivalent counts as done only when
  every call site is migrated and the helper itself is gone.
