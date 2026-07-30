TASK: maintenance. You are fixing DRIFT: making the text match the code, or the pin match the need.

- Behaviour-preserving or rejected. Bumping a dependency to fix a bug is not this task.
- A resolved TODO gets deleted, not rewritten. A wrong comment gets corrected, not expanded.
- Include `"fragment_kind"` in your final report: which of feature | bugfix | breaking | refactor |
  docs this change belongs to. The harness writes the release-note file itself and validates your
  answer, falling back to `refactor`.
