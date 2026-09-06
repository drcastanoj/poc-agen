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
  because your change is wrong, fix your change.
- If a test fails for a reason unrelated to your change (a pre-existing bug,
  a broken config), you may fix the minimum needed to unblock validation —
  a config value, an import path, one line — as long as it does not change
  the behavior the test is actually asserting. Note it plainly in your final
  summary as a separate, pre-existing fix. If the fix would require touching
  business logic or you are unsure it is safe, report it and stop instead.
- Never use `test.todo`, `it.skip`, `xit`, or equivalent to sidestep a failure.

## Git

- You are already on the correct branch. Do not create, switch, or delete
  branches.
- Do not run `git commit`, `git push`, `git rebase`, or any `gh` command. The
  harness handles all of it.
- Never add `Co-Authored-By` trailers.

## Validation

The task message gives you four exact commands (lint, typecheck, test, build)
for this repo's actual package manager. Run them yourself and iterate until
all four exit zero.

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
