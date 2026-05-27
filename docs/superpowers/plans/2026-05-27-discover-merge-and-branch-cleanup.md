# Merge `discover/llm-only-cleanup` + branch cleanup — plan

**Goal:** Land Discover/Quiz feature on `main`, close all stale branches, leave the repo with a single clean trunk.

**Date:** 2026-05-27

---

## Current state (verified)

- `main` @ `0d9b81c` — clean working state, includes today's queue/chat/MediaRef/i18n improvements (~69 commits since fork from `dc2aefa` on 05-25).
- `discover/llm-only-cleanup` @ `ebe2971` — Discover/Quiz feature, daily-driver, 158 commits since the same fork. Builds and runs.
- 117 files differ between the two heads.
- `discover/tab` @ `2c6db32` — fully superseded by `discover/llm-only-cleanup` (0 unique commits). Safe to drop.
- `main-pre-discover-merge` — identical to `main` now (created during today's failed merge attempts). Safe to drop after merge.
- 19 other branches (`feature/*`, `fix/*`, `ux/*`, `claude/*`, `Preclowski/doha`, etc.) — all `ahead=0` vs main. Already integrated.

## Why this is non-trivial

The two heads modified the **same files in different directions** over the last 2 days:

| File | main did | discover did |
|---|---|---|
| `LocalToolBackend.swift` | split into `+ArrTools.swift` / `+TMDB.swift` extensions | added `discover_in_quiz` tool, stayed monolithic |
| `Queue*.swift` | dropped arr filter, dedupe rework | older version with arr filter |
| `ChatView.swift` | (unchanged) | added rotating placeholder + first-launch tip |
| `PopoverContentView.swift` | router updates | added Discover overlay + notification observers |
| `AppNotifications.swift` | added `DetailRequest.tap(_:)` router | added 2 new notification names |
| `Localizable.xcstrings` | ~33 new keys | ~207 new keys |
| `ChatViewModel.swift` | (unchanged) | added `latestDiscoverSessionMessageID` etc. |

Today's three automated-merge attempts each lost work from one side. The honest path is **commit-by-commit rebase of `discover/llm-only-cleanup` onto current `main`**, resolving conflicts at the commit where they actually arise — each conflict will be a few hunks of context, not whole-file rewrites.

---

## Priority list

| # | What | Why |
|---|---|---|
| **P0** | Rebase `discover/llm-only-cleanup` onto `main`; fast-forward `main`; verify build + tests | This is the actual goal; everything else depends on this |
| **P1** | Smoke-test the merged app: Quiz launches, queue has no arr filter, chat has new placeholder, no regressions | Catch semantic merge breakage that compiles but is wrong |
| **P2** | Delete fully-merged branches (the 19 `ahead=0` branches + `main-pre-discover-merge` + `discover/tab`) | Stop pretending the repo has 20+ active lines of work |
| **P3** | Remove stale worktrees (`discover-tab`, `discover-llm-only`, `queue-search-status-grouping`, optionally the conductor/`doha` one) | Free filesystem + git-state clutter |
| **P4** | Remove the abandoned `2026-05-27-chat-empty-state-*` spec/plan/mockup docs that landed on main from the failed chat-empty-quiz session | Repo doesn't need a plan for code that never shipped |
| **P5** | Push merged `main` to remote | Make this the source of truth elsewhere |

P0–P3 are blocking each other only in that order. P4 can run any time after P0. P5 is the last gate.

---

## Plan

### Pre-flight

- [ ] **PF-1: Confirm `main` is clean and at `0d9b81c`**

```bash
git status --porcelain   # expect: empty
git rev-parse main       # expect: 0d9b81c…
```

- [ ] **PF-2: Confirm `discover/llm-only-cleanup` builds + tests pass standalone**

```bash
git -C .worktrees/discover-llm-only rev-parse HEAD   # expect: ebe2971…
swift test --package-path .worktrees/discover-llm-only/Packages/ArrCore 2>&1 | tail -3
xcodebuild -project .worktrees/discover-llm-only/ArrBarr.xcodeproj \
  -scheme ArrBarr -configuration Debug \
  -derivedDataPath .worktrees/discover-llm-only/build build 2>&1 | tail -3
```

- [ ] **PF-3: Pin a true backup** — tag the discover tip so it survives any future branch deletion.

```bash
git tag backup/discover-llm-only-pre-rebase discover/llm-only-cleanup
git tag backup/main-pre-merge main
```

### P0 — Rebase + merge

- [ ] **P0-1: Create a working branch off discover**

```bash
git branch merge/discover discover/llm-only-cleanup
git checkout merge/discover
```

- [ ] **P0-2: Rebase onto main**

```bash
git rebase main
```

Expect conflicts. Resolve each one in the smallest context possible. Heuristic per file:

- `LocalToolBackend.swift` — pick discover's monolithic helpers; when the rebase reaches main's split refactor, manually move those helpers into the right extension file (`+ArrTools.swift` for arr tools, `+TMDB.swift` for TMDB) OR drop the extensions and keep monolithic. **Decision tag:** if main's split was non-load-bearing (just file organisation), keep discover's monolith; if main added new logic in the extensions, keep the split and port discover's `discover_in_quiz` into `+TMDB.swift`.
- `Queue*.swift` — main's removal of the arr filter is what the user wants. When discover's version pulls the filter back, take main's removal each time.
- `ChatView.swift` — keep discover's rotating placeholder + first-launch tip. main didn't touch this.
- `PopoverContentView.swift` — keep discover's overlay + observers structure; replay main's individual router tweaks (e.g. `DetailRequest.tap` callers) on top.
- `AppNotifications.swift` — keep main's `DetailRequest.tap` router; add discover's `.arrBarrOpenDiscoverQuiz` and `.arrBarrShowDiscoverPicks` names.
- `Localizable.xcstrings` — union of both. Use the Python merge script from today's failed merge (it was correct, just buried under the other regressions).
- Tests — update expected tool-catalog counts to include `discover_in_quiz`.

If a single commit has more than ~5 files in conflict at once, **stop and ask** rather than guessing.

- [ ] **P0-3: After rebase clean, fast-forward main**

```bash
git checkout main
git merge --ff-only merge/discover
```

- [ ] **P0-4: Final build + test pass on main**

```bash
swift test --package-path Packages/ArrCore 2>&1 | tail -3
xcodebuild -project ArrBarr.xcodeproj -scheme ArrBarr \
  -configuration Debug -derivedDataPath build build 2>&1 | tail -3
```

Expect: 200+ tests pass, BUILD SUCCEEDED.

### P1 — Smoke test

- [ ] **P1-1: Kill any running ArrBarr, launch the freshly-built one**

```bash
pkill -x ArrBarr 2>/dev/null
open build/Build/Products/Debug/ArrBarr.app
```

- [ ] **P1-2: Manual verification checklist** (each must pass)
  - Queue view: no arr-filter chips (main's removal)
  - Chat input: rotating placeholder cycling
  - Chat first-launch tip visible on a fresh state
  - Quiz: trigger via `discover_in_quiz` (e.g. type "quiz na sobotę wieczór") → DiscoverTabView overlay opens with cards
  - Add/skip cards work; cards land in Radarr/Sonarr
  - No console errors during normal flows

If anything fails, surface it and stop. Don't paper over a regression.

### P2 — Branch cleanup

- [ ] **P2-1: Delete the discover working branches once main has them**

```bash
git branch -d merge/discover
git branch -d discover/llm-only-cleanup
git branch -d discover/tab     # superseded by llm-only-cleanup
git branch -d main-pre-discover-merge
```

- [ ] **P2-2: Delete the 19 fully-merged historical branches**

```bash
for b in Preclowski/doha claude/romantic-brown-802e50 \
         feat/tmdb-genres-and-options-cache \
         feature/chat-mcp feature/discovery feature/welcome-screen \
         fix/hover-popover-clicks fix/movie-detail-and-search-add \
         fix/movie-detail-existing-file fix/popover-flicker-and-glass-bars \
         fix/search-focus-loading-indicator \
         queue-search-status-grouping sonarr/search-missing \
         ux/clear-chat-label-and-panel-enrichment ux/ghost-row-buttons \
         ux/icon-button-breathing-room ux/native-row-action-buttons \
         ux/plus-row-title-year-and-ratings ux/search-result-hover \
         ux/searchadd-no-divider ux/simplify-downloading-badges \
         ux/year-in-title worktree-agent-a6ba1826324f7017e; do
  git branch -D "$b"
done
```

(Force `-D` rather than `-d` because some may technically diverge in patch-id even if `ahead=0` against main — git's heuristic is conservative.)

- [ ] **P2-3: Confirm only `main` and the backup tags remain**

```bash
git branch -a
git tag -l 'backup/*'
```

### P3 — Worktree cleanup

- [ ] **P3-1: Remove the discover worktrees**

```bash
git worktree remove .worktrees/discover-llm-only
git worktree remove .claude/worktrees/discover-tab
git worktree remove .worktrees/queue-search-status-grouping
```

- [ ] **P3-2: Check conductor/doha worktree** — confirm whether it's still needed; remove if not

```bash
git worktree list
# If `/Users/konrad/conductor/workspaces/arrhelper/doha` is dead:
git worktree remove /Users/konrad/conductor/workspaces/arrhelper/doha
```

- [ ] **P3-3: `arrhelper-chat-mcp` (detached HEAD) — sibling directory, not git-managed worktree, skip unless you want to remove the whole directory manually**

### P4 — Drop abandoned plan/spec docs

- [ ] **P4-1: Remove the 3 chat-empty-quiz docs from main** (they document a path that was abandoned)

```bash
git rm docs/superpowers/specs/2026-05-27-chat-empty-state-and-quiz-design.md \
       docs/superpowers/specs/2026-05-27-chat-empty-state-mockup.svg \
       docs/superpowers/plans/2026-05-27-chat-empty-state-and-quiz.md
git commit -m "chore: drop abandoned chat-empty-quiz plan/spec/mockup (superseded by discover merge)"
```

### P5 — Push

- [ ] **P5-1: Push main to remote**

```bash
git push origin main
```

- [ ] **P5-2: Push the backup tags (one-time safety)**

```bash
git push origin backup/discover-llm-only-pre-rebase backup/main-pre-merge
```

(Tags can be deleted later via `git push origin --delete tag <name>` once you're sure the merge is good.)

- [ ] **P5-3: Delete remote-tracking dead branches** if they exist on origin

```bash
git remote prune origin
```

---

## Rollback plan

At any point before P5 completes, if the merge produces something unacceptable:

```bash
git checkout main
git reset --hard backup/main-pre-merge
```

The two backup tags survive branch deletion and remote pushes.

After P5 push, rollback is the same but additionally needs `git push --force-with-lease origin main` — only do this with conscious intent.

---

## Out of scope

- New features. This plan is integration + cleanup only.
- Re-doing the failed `chat-empty-quiz` empty-state refresh. If a leaner empty state is still wanted later, it goes through its own spec on top of the merged trunk.
- Restoring the LLM-router-bypass code (`fetchQuizDeck`, `QuizFilters`, etc.) — it's deleted with `chat-empty-quiz` branch and not part of the discover stack.

## Estimated effort

- P0 rebase: 30-90 min depending on conflict density across 158 commits
- P1 smoke: 10 min
- P2-P3 cleanup: 5 min
- P4 doc drop: 1 min
- P5 push: 1 min

Total: ~1-2 hours focused, with user review at conflict-resolution checkpoints during P0.
