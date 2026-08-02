TASK: coverage. You are ADDING tests. This is the one task that writes inside `tests/**`, and the
only files you may WRITE are the test files in the theme (the harness rejects any other write,
including to the source file the gap is in -- read it all you like, do not touch it).

- Never weaken an existing test. The gate rejects any diff that reduces the assert count or the
  test count of a test file that already existed, whatever else the diff does. Refactoring three
  asserts into one parametrised case will be rejected: add, do not restructure.
- A test that cannot fail is worse than no test. Before you finish, break the code under test in
  your head and confirm your assertion would catch it. If it would not, the assertion is wrong.
- Ponytail mode is `lite` here on purpose: do not YAGNI your own test away.
- Run the new test and paste what you saw into `summary`. A test you did not run is not a finding,
  it is a hope.
