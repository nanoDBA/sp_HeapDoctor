# Testing sp_HeapDoctor

These rules apply to every change, whether a person or an agent makes it.
`CONTRACTS.md` says what must stay true in the procedure; this file says how a
change is proved.

## One command

```bash
bash tools/gate.sh full                          # the whole suite
bash tools/gate.sh only <test> [<test> ...]      # just these test files
bash tools/gate.sh redgreen <base> <test> [...]  # prove a test can fail
```

`<test>` is a file name in `tests/` without `.sql`.  `<base>` is any git revision.

The gate runs on SQL Server 2019, 2022 and 2025 side by side, each in a fresh
environment that it creates and destroys itself.  It prints one line per version,
then `GATE PASSED` or `GATE FAILED`, and exits 0 or 1.  The last line names a
directory outside the repo that holds the logs and a `result.json` naming the
commit that was tested.

- Take the verdict from the exit code and the last line.  Read a log only when
  the gate fails.
- `GATE_VERSIONS=2022 bash tools/gate.sh ...` limits a run to one version.  Use it
  while iterating; a final result needs all three.
- Do not create environments or run `sqlcmd` by hand to judge a change.  A result
  that the gate did not produce is not evidence.
- `full` takes about 50 minutes, `redgreen` about 10.  Think before each run; the
  gate is not for finding typos.

The gate needs a local environment configuration that is not part of this
repository.  Without it, run the suite against any instance you may freely
wreck (each test file drops and rebuilds the `HeapDoctorTest` database):

```bash
bash tests/run_suite.sh -S <server> -U <user> -P <password>
bash tests/run_suite.sh -t <test> -S <server> -U <user> -P <password>
```

## What a fix needs before it is committed

1. **A regression test that fails without the fix.**  Prove it with
   `redgreen <base> <test>`, where `<base>` is the commit before the fix.  A test
   that passes against the old procedure proves nothing.
2. **One commit per issue**, with `see #<number>` in the message.  Never a
   closing keyword: GitHub closes issues on words like "fixes", even after "not".
3. **A full run at the final commit**, green on all three versions.

Give up on a fix that is not green after three `redgreen` runs: revert it, and
do not leave its failing test in `tests/`.

## Writing a test

- **File name:** `tests/<NN>_test_<short id>.sql`.  Files run in name order.
- **Every assertion can fail.**  Each id has both a `PASS <id>:` and a
  `FAIL <id>:` literal.  The runner derives the expected count from those
  literals and fails a file that emits fewer.
- **Emit with `RAISERROR(..., 10, 1) WITH NOWAIT`**, never `PRINT`.
- **Capture the result set from the template**, never from a hand-written column
  list:

  ```sql
  SELECT * INTO #Results FROM dbo.ResultsTemplate WHERE 1 = 0;
  INSERT INTO #Results
  EXEC dbo.sp_HeapDoctor ...;
  ```

- **Never hardcode the version.**  Compare with
  `(SELECT version FROM dbo.ExpectedVersion)`.
- **The procedure is deployed in `master`.**  Read its text from
  `master.sys.sql_modules`, not from the test database.
- **Guard against passing on nothing.**  When an assertion checks that something
  is absent or zero, also assert that the work happened, for example through the
  `@TargetsFound` and `@Succeeded` output parameters.
- **Assert the reason, not only the outcome.**  A test that expects a rejection
  checks which guard rejected it.
- **Drop what you create**: tables, filegroups, logins, extra databases.
- **Low-privilege paths stay low-privilege.**  `@CheckPermissionsOnly` is tested
  as a login with no server or database state permission, so that path must not
  read views that need one.

## House rules for tracked files

- No host names, addresses, local paths, credentials or people's names.
- No em dashes.  Two spaces after a period.
- In SQL, block comments only.  See `STYLE_GUIDE.md`.
