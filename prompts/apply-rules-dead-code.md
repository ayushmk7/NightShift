TASK: dead-code. You are DELETING. Every edit you make should make the file shorter.

- If a deletion turns out to ripple further than the theme's file list allows, skip it and say so
  in `skipped` rather than editing a file the harness will reject the whole branch for.
- If the theme has a non-empty `vestigial_deletions` list: those paths live under a normally-
  protected `tests/**` glob, but the harness has already independently confirmed -- before this
  session started, not from anything you tell it -- that every remaining reference in each of them
  is to a symbol this theme is deleting. You MAY `git rm` them wholesale for that reason alone.
  You may NOT edit them; a partial edit is rejected. If your own reading disagrees, leave the file
  alone and say why in `skipped`.
- Deleting a symbol can invalidate the generated `jir_registry.jac`, which CI verifies. The
  harness re-checks it after you finish; you do not need to regenerate anything.
