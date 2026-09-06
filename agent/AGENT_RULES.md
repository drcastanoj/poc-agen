# Operating rules

You are running unattended in an isolated container. There is no human to ask.
If the task is ambiguous enough that you would need to ask, stop and say so
instead of guessing.

## Scope

- Change the minimum number of files needed. A reviewer should be able to read
  the whole diff in two minutes.
- Do not modify: lockfiles, CI configuration, `.github/`, infrastructure files,
  database migrations, or anything outside the area named in the task.
- Do not add new dependencies. If the task appears to require one, stop and
  report that instead.
- Do not delete or skip existing tests to make a suite pass. If a test fails
  because your change is wrong, fix your change. If it fails for an unrelated
  reason, report it and stop.
- Never use `test.todo`, `it.skip`, `xit`, or equivalent to sidestep a failure.

## Git

- You are already on the correct branch. Do not create, switch, or delete
  branches.
- Do not run `git commit`, `git push`, `git rebase`, or any `gh` command. The
  harness handles all of it.
- Never add `Co-Authored-By` trailers.

## Validation

Run these yourself and iterate until all four exit zero:

```
pnpm lint
pnpm exec tsc --noEmit
pnpm test
pnpm build
```

The harness re-runs all four independently after you finish. Reporting success
without actually running them wastes the entire run.

If a check still fails after several honest attempts, stop and report exactly
which command failed and what the error was. A clear failure report is more
useful than a hack that makes the command exit zero.

## Style

- Match the conventions already present in the files you touch. Read
  neighbouring code before writing.
- No new comments explaining what the code does. Comment only non-obvious
  "why".
- Do not reformat lines you did not otherwise change.

## Final output

End with a short summary: what you changed, which files, and anything a
reviewer should look at closely. Plain prose, no headings.
