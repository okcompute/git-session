---
name: git-session-review
description: >
  Project-specific code review checklist for this Zig codebase (git-session).
  Focuses on idiomatic Zig patterns and test coverage expectations.
  Use this skill whenever reviewing Zig code changes in this repository --
  including during PR reviews, deep reviews, or when the user asks to
  review, check, or critique Zig code. This skill supplements deep-review
  with Zig-specific and project-specific guidance.
advertise: true
---

# Zig Code Review — git-session

This skill provides project-specific review guidance for the git-session
Zig codebase. It is a supplement to the `deep-review` skill, not a
replacement. Use it to add a Zig-focused lens on top of any general review.

## Idiomatic Zig

When reviewing Zig code in this project, check for these patterns. The
goal is not rigid enforcement but catching cases where non-idiomatic code
makes things harder to read, less safe, or inconsistent with the rest of
the codebase.

### Memory management

- Every allocation should have a corresponding `defer free` at the call
  site, or clearly documented ownership transfer ("Caller owns the
  returned slice"). Look for allocations that lack both.
- Prefer `allocPrint` / `allocSentinel` over manual buffer management
  when building strings.
- Complex structures that own heap memory should provide a `free*`
  function (e.g., `freeRepoConfig`, `freeExecResult`) and callers should
  use it via `defer`.
- Arena allocators are fine for short-lived, batch-style work (like the
  main function's top-level arena). Avoid arenas for long-lived data
  that grows unboundedly.
- **Append-after-dupe leak.** `try list.append(alloc, try alloc.dupe(...))`
  leaks the duped slice if `append`'s array-grow OOMs: the slice was
  never stored, so neither the list's own `errdefer` nor a caller's
  `free*` can reclaim it. Flag this pattern and prefer:
  ```zig
  const d = try alloc.dupe(u8, x);
  errdefer alloc.free(d);
  try list.append(alloc, d);
  ```
  This is easy to miss because the happy path and `testing.allocator`
  both pass — the leak only appears on the allocation-failure branch.
  Prove error-path leak-freedom with `std.testing.FailingAllocator`:
  loop `fail_index` from 0 upward, expect `error.OutOfMemory` until the
  call succeeds, and free on the success branch. The same orphaning
  applies to any "allocate, then store into a container that may itself
  allocate" sequence.

### Error handling

- Use Zig's error unions (`!T`) for fallible operations. Avoid sentinel
  values or booleans to signal failure when an error union would be
  clearer.
- Named error values (e.g., `error.ConfigNotFound`,
  `error.GitWorktreeCreationFailed`) are preferred over generic
  `error.Unexpected`.
- The `catch` + `break :blk` pattern for fallback values is idiomatic in
  this codebase — don't flag it as unusual.
- Non-critical failures (like a git fetch warning) can be logged and
  swallowed. Critical failures should propagate.

### Naming and style

- `camelCase` for functions and variables, `PascalCase` for types,
  structs, and enums — standard Zig conventions.
- Doc comments (`///`) on **all functions** — both public and private.
  This is stricter than typical Zig convention, but it is the standard
  in this project. Every function should have a `///` comment describing
  its purpose, parameters, return value, and ownership semantics (e.g.,
  "Caller owns the returned slice"). Flag any new function, public or
  private, that is missing a doc comment.
- Section separators (`// ----` or `// ====`) to visually group code
  within a file are used throughout — keep this pattern when adding new
  sections.
- Tests go at the bottom of the file, after a `// Tests` separator.

### Concurrency

- Use `std.atomic.Value` for cross-thread signaling flags (like
  `worker_done`).
- Use `std.Io.Mutex` for protecting shared mutable data structures
  (Zig 0.16 removed `std.Thread.Mutex`). Lock with
  `lockUncancelable(io)` from raw `std.Thread.spawn` workers (they are
  not managed by Io cancellation) and pair with `unlock(io)`. Sharing
  one `io` across OS threads for mutex ops is only sound with a
  thread-safe Io implementation — `Io.Threaded`, which
  `std.process.Init` supplies — so flag any mutex/sleep call on a
  shared `io` from a raw thread that doesn't document this assumption.
- Follow the snapshot pattern: copy values on the main thread before
  spawning a worker thread, rather than sharing mutable state (e.g.,
  copying `TextField.buf` contents before the worker reads them).

### General

- Prefer `std.mem.splitScalar` / `std.mem.tokenizeScalar` over manual
  index arithmetic for string splitting.
- Use `std.fmt.allocPrint` for building paths and formatted strings.
- Use `std.fmt.bufPrint` with a stack buffer when the result is
  short-lived and bounded in size.
- Relative `@import("module.zig")` for internal modules, not package
  paths.

## TUI rendering (tui.zig)

### List rows must stay exactly one line tall

The vxfw widget framework's `vxfw.Text` **soft-wraps** when its content
exceeds the available width (with `width_basis = .parent`, that width is
the constrained content box — currently 64 columns, see
`TuiApp.draw`). But the list draw loops in `tui.zig` (e.g.
`drawWorktreeList`) advance the row cursor by **exactly one row per
item**. So a label that soft-wraps onto a second line is overdrawn by
the next item and renders as a **blank or missing row** — the item
silently disappears from the list even though its data is present.

When reviewing or editing any `tui.zig` list rendering:

- Every per-item label must be clamped to the content width so it
  occupies a single line. Use `term.truncateLabel` (ellipsis truncation on
  UTF-8 codepoint boundaries) rather than a raw `allocPrint` of
  `{indent}{name}`.
- Flag any new list loop that builds an item label with `allocPrint`
  without truncation, or that assumes a fixed one-row height while the
  label width is unbounded (session names, branch names, repo paths can
  all be long).
- This is a data-invisible bug: the listing functions return the item
  correctly; only the render drops it. Don't be misled into hunting the
  data layer.

### Debugging TUI rendering issues

TUI bugs are invisible to static analysis and to the data-layer
functions (which often test fine in isolation). To reproduce and inspect
what the TUI actually draws, drive the real binary in a detached tmux
pane and capture the screen:

```sh
tmux new-session -d -s gstest -x 200 -y 50
tmux send-keys -t gstest "zig-out/bin/git-session --repository <repo>" Enter
sleep 2
tmux send-keys -t gstest "3"   # navigate (e.g. 3 = Fix)
sleep 1
tmux capture-pane -t gstest -p        # plain text
tmux capture-pane -t gstest -p -e     # with escape codes (to inspect styling)
tmux kill-session -t gstest
```

To inspect per-item geometry (the smoking gun for the soft-wrap bug is a
surface with `height == 2`), temporarily log each drawn surface's
`size.width`/`size.height` to a file like `/tmp/gs_debug.log` from
inside the draw loop, then read it back. Remember to remove any such
scaffolding before finishing — and never leave throwaway harness files
under `src/` (they get picked up by the build and can leak into a
commit).

## Test coverage

This codebase uses Zig's built-in `test` blocks, co-located at the
bottom of each source file. When reviewing changes, apply these
guidelines:

### What should be tested

- **Pure functions and parsing logic** — always. If a new function
  transforms data, parses strings, derives values, or makes decisions
  based on input, it should have test coverage. Examples in the codebase:
  `deriveRepoName`, `sanitizeTmuxName`, `expandTilde`, `parseTomlArray`,
  `stripQuotes`, `sortByUsage`.
- **Error paths** — test that the function returns the expected error or
  handles missing/malformed input gracefully. The codebase already tests
  things like missing config files and empty inputs.
- **Edge cases** — empty strings, missing fields, unusual characters
  (dots, nested paths, `.git` suffixes). Look at existing tests for the
  pattern.

### What does not need tests

- **TUI rendering and interaction logic** (`tui.zig`) — this is hard to
  test because it depends on the vaxis/vxfw widget framework, terminal
  state, and interactive input. Don't flag missing tests for TUI code.
- **Thin wrappers around external processes** — functions that just shell
  out to `git` or `tmux` and return the result. The interesting logic
  (like deriving names from URLs) is testable and should be tested, but
  the subprocess invocation itself is not.
- **`main.zig`** — entry point glue code.
- **`cli.zig`** — CLI dispatch that delegates to other modules.
- **`build.zig`** — build configuration. Review for correctness of
  dependencies, steps, and flags, but tests and doc comments are not
  required.

### Test patterns to follow

- Use `std.testing.allocator` — it detects memory leaks, which is
  valuable for catching missing `defer free` calls.
- Use `std.testing.tmpDir()` for tests that touch the filesystem; it
  auto-cleans on scope exit. Note: this API's exact behavior may vary
  across Zig versions — verify against the project's current Zig version
  if in doubt.
- Helper functions for test setup (like `writeTmpFile`) are fine and
  encouraged when they reduce duplication.
- Use `testing.expectEqualStrings` for string comparisons and
  `testing.expectEqual` for other values.
- Each test should be self-contained and not depend on other tests.

### When to flag missing tests

If a PR adds a new pure function or parsing logic to a module that
already has tests (config.zig, git.zig, tmux.zig, term.zig, repo.zig,
process.zig, usage.zig), and the function is not tested, flag it. Frame
it as a suggestion, not a blocker — something like:

> "Consider adding a test for `newFunctionName` — the existing tests in
> this module cover similar logic and this function has testable edge
> cases (e.g., empty input, path with special characters)."

If the new code is in `tui.zig` or is purely subprocess orchestration,
don't flag missing tests.

## Presenting review findings

When presenting review findings to the user, assign each issue a unique
numeric identifier (e.g., #1, #2, #3). This lets the user unambiguously
reference specific issues when asking for fixes (e.g., "fix #2 and #5").

## Changelog

Every PR that changes application code (`src/`, `build.zig`,
`build.zig.zon`) must update `CHANGELOG.md`. The changelog follows the
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format.

- New entries go under an `[Unreleased]` section at the top of the file.
- Use the appropriate category: `Added`, `Changed`, `Fixed`, `Removed`.
- CI-only changes, agent configuration, and documentation-only changes
  do not require a changelog entry.

When reviewing, if the PR touches application code and `CHANGELOG.md`
is not updated, flag it as a required change, not a suggestion.

## Linting

This project uses [zlint](https://github.com/DonIsaac/zlint) for static
analysis. Configuration is in `zlint.json` at the repository root.

- As part of every review, run `zlint` from the repo root and verify it
  reports **zero errors and zero warnings**. If it doesn't, flag the
  issues.
- `// zlint-disable` file-level directives must **not** be used — they
  trigger a known zlint bug (hang/OOM). If a change introduces one,
  flag it and suggest disabling the rule in `zlint.json` instead.
- Do not suggest disabling rules in `zlint.json` to work around
  warnings without explicit user approval — prefer fixing the code.

## Review checklist (quick reference)

When reviewing a change, run through this list:

1. **zlint clean?** Run `zlint` — zero errors and zero warnings.
2. **Allocations paired with frees?** Look for `allocPrint`, `dupe`,
   `ArrayList` — each should have a `defer free` or documented
   ownership transfer.
3. **Errors propagated or handled?** Fallible operations should use `!T`.
   Critical errors propagate, non-critical ones can be logged.
4. **Doc comments on every function?** All new functions — public and
   private — need `///` doc comments describing behavior and ownership.
5. **Tests for new logic?** Pure functions and parsers in testable
   modules should have tests. TUI code is exempt.
6. **Naming conventions followed?** `camelCase` functions,
   `PascalCase` types, descriptive names.
7. **Thread safety?** If touching shared state across threads, verify
   proper use of atomics or mutexes.
8. **Consistent with existing patterns?** Does the new code follow the
   same patterns as the rest of the module?
8. **Changelog updated?** If the change touches application code
   (`src/`, `build.zig`, `build.zig.zon`), verify that `CHANGELOG.md`
   has a corresponding entry under `[Unreleased]`.
