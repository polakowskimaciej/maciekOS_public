# aikiq

AI-assisted QA CLI that turns Jira tickets and code diffs into structured, validated test artifacts — with file-based sessions, drift-aware snapshots, and a pluggable checks framework that halts runs on schema violations.

---

## What it does

aikiq replaces ad-hoc LLM usage with structured, controlled workflows.

* Parses Jira tickets into factual summaries
* Reviews tickets for gaps and ambiguity
* Analyzes code diffs without guessing intent
* Runs rule-based + schema-validated checks (halt-on-fail)
* Compares Jira vs implementation (no bias)
* Generates Gherkin scenarios
* Exports test cases (Testmo)
* Produces clean, unambiguous Jira comments
* Tracks work in file-based sessions with state machine, drift detection, and standup aggregation

---

## Why it matters

LLMs are inconsistent for QA when used directly.

aikiq enforces:

* Controlled, repeatable outputs
* No hidden assumptions
* Explicit gaps instead of "best guesses"
* Full reproducibility via sessions
* Deterministic drift detection (snapshot SHA over normalized `jira view` output)
* Hard schema gates that halt runs producing structurally invalid artifacts

LLM = semantic compression
System = source of truth

---

## Example usage

```bash
# Pipeline (auto-feed: snapshot-enabled jira_* workflows pull
# `jira view XX-1234` for you when stdin is empty)
aikiq jira_summary --session 1234_x_y
aikiq jira_review  --session 1234_x_y
aikiq jira_clarify --session 1234_x_y

# Code-side
hg diff -r default:my_branch | aikiq code_review     --session 1234_x_y
aikiq code_summary       --session 1234_x_y
aikiq jira_code_review   --session 1234_x_y

# Test artifacts
aikiq gherkin_write   --session 1234_x_y
aikiq testmo_import   --session 1234_x_y

# Jira comment with hard schema gate (halts on structural failure;
# forensic artifact still written to disk)
aikiq jira_comment    --session 1234_x_y

# Re-run schema validation against an existing artifact (no LLM call)
aikiq verify --session 1234_x_y --workflow jira_comment
```

---

## Sessions + state machine

A "session" is a file-based workspace under `sessions/<id>/` capturing every run, output, and metadata around a single Jira ticket.

States:

* `open` — actively working
* `closed` — work is done
* `reassigned` — handed off to someone else, expected to bounce back (`→` glyph in `aikiq daily`)
* `archived` — historical

Reopen does not require `--force` for `reassigned`; closed/archived do — the rewind needs to be deliberate.

```bash
aikiq sessions                          # list active sessions
aikiq status   --session 1234_x_y       # full session state
aikiq close    --session 1234_x_y       # work is done
aikiq reassign --session 1234_x_y --to "PM Lead"
aikiq reopen   --session 1234_x_y       # natural bounce-back, no --force needed
aikiq daily                             # standup roll-up: ✓ closed, → reassigned, blank open
aikiq sync-status                       # bidirectional sweep against Jira state
```

`aikiq sync-status` reconciles every session against `jira view <key>` and applies the state-machine rules:

| Rule | Source | → Desired |
|---|---|---|
| 1 | `status ∈ {Done, Ready For Staging, Ready For Production}` | `closed` |
| 2 | `assignee != self` (and not shipped) | `reassigned` |
| 3 | otherwise | `open` |

Cancelled tickets are deliberately NOT auto-closed by status alone.

---

## Drift detection (snapshot gates)

Snapshot-enabled workflows fingerprint `jira view <key>` at every run and store the SHA in `session_log.json`. Three gates:

* `requires_jira_change` — skip the run when the ticket hasn't changed since the last snapshot (saves the LLM call). Used by `jira_summary` / `jira_review` / `jira_clarify`.
* `skip_if_self_authored` — skip when the only change since last snapshot is your own comment.
* `requires_jira_unchanged` — halt the run when the ticket has moved on since the snapshot a draft was started against. Used by `jira_comment` so in-flight drafts can't quietly post against a stale baseline.

The fingerprint is hashed over a normalized form of the output (relative timestamps like "27 days ago" collapsed) so day-rollover doesn't trigger spurious drift.

```bash
aikiq snapshot --session 1234_x_y           # capture; no LLM call
aikiq snapshot --session 1234_x_y --check   # exit 0 unchanged / 1 changed / 2 no prior
```

---

## Pluggable checks framework

The `Checks::Base` registry collects every subclass via Ruby's `inherited` hook. `Schema` is the first formal Check; new ones (regex disallow-lists, AST validity, ticket-title exact-match) plug in via `class < Checks::Base`. Workflows opt in via `vars.gates: [...]`.

Failures halt the run and persist a `check_results[]` row in `session_log.json` with `passed`, `tier`, `messages_truncated`, `forced`, `force_reason`. Bypass with `--force-gate <id> --force-reason "<why>"` — auditable.

`aikiq verify` replays gates against an existing artifact (no LLM call) — useful when you've manually edited an output or added a new gate retroactively.

---

## Note content linter

Session notes (the one-paragraph "where am I" log) are validated at write time:

* Length 30–1000 chars
* No tooling-meta phrases (`via aikiq`, `_workflow`, "first run", "<shape>", ...)
* At least one outcome verb (closed / verified / approved / asked / awaiting / ...)
* No `[auto` prefix (reserved for backfill sweeps)

Bypass with `aikiq note --force --force-reason "<why>"`. Bypassed notes are recorded in `note_force_reason` and skipped by `aikiq daily` (consistent with the `[auto` skip).

---

## Integrations

```bash
# Live JQL search via /rest/api/3/search/jql (replaces dead /search/2)
aikiq scrum --status "In Progress" "Testing" --priority High Highest
aikiq scrum --unassigned --status "In Refinement"  # refinement queue
aikiq scrum --watched --recent 7d

# Fix versions
aikiq fixversion-list XX                          # current-year unreleased
aikiq fixversion-add XX-1234 "2026/05/XX Staging"

# User search → mention syntax
aikiq userid Smith
# → "Jane Smith  [~accountid:5b4...]"

# Sentry capture
aikiq sentry-list --since 24h --limit 10
aikiq sentry-pull BACKEND-AB --session 1234_x_y
```

---

## How it works

* YAML workflows (one responsibility per step)
* Strict schemas (JSON / CSV validation)
* Pluggable Check classes (`vars.gates: [schema]` halts the run)
* Rule-based content linters (not AI guessing)
* File-based sessions with state machine + drift detection
* Auto-feed: workflows that own ticket fetch don't require piping `jira view`
* Deterministic SHA fingerprints (relative-timestamp normalization)

Each step is isolated and constrained by schemas, rules, and gates.

---

## Design principles

* Control over implicit behavior
* Explicit > inferred
* No mixed responsibilities
* Audit trail for every gate bypass
* QA invariants always enforced:

  * authorization
  * nil safety
  * external API failures
  * permission layering

---

## Configuration

Most behavior is environment-driven so the public CLI works without any embedded personal data:

| env | default | purpose |
|---|---|---|
| `AIKIQ_JIRA_PROJECT_KEY` | `XX` | ticket-key prefix used for snapshot derivation and sync-status |
| `AIKIQ_JIRA_ASSIGNEE_SELF` | `Your Name` | display name treated as "me" by sync-status |
| `AIKIQ_JIRA_EMAIL` / `AIKIQ_JIRA_API_TOKEN` / `AIKIQ_JIRA_ENDPOINT` | reads `~/.jira.d/config.yml` | REST v3 auth (Basic email:token) |
| `AIKIQ_STANDUP_DAYS` | `2,4` (Tue/Thu) | wday integers for `aikiq daily` cutoff |
| `AIKIQ_STANDUP_HOUR` / `_MIN` | `10:00` | standup-time anchor |
| `OPENROUTER_API_KEY` | — | LLM calls |
| `SENTRY_AUTH_TOKEN` / `SENTRY_ORG` / `SENTRY_PROJECT` | — | sentry subcommands |

---

## Tech

CLI (Thor) • YAML workflows • OpenRouter (LLMs) • Atlassian REST v3 • Sentry API • JSON schema validation • pluggable Check framework • Gherkin / BDD • file-based session metadata

---

## Who it's for

QA engineers, backend teams, and anyone who wants **reliable AI-assisted testing without guesswork**, with proper drift detection and an audit trail for every override.

---

## Status

Working CLI. Active development on regex-based content checks (disallowed phrases, class-path anchors), Gherkin AST validity check, and ticket-title exact-match check — slotting into the same `Checks::Base` framework that the schema gate already uses.

---

## License

TBD
