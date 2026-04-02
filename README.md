# aikiq

AI-assisted QA CLI that turns Jira tickets and code diffs into structured, validated test artifacts.

---

## What it does

aikiq replaces ad-hoc LLM usage with structured, controlled workflows.

* Parses Jira tickets into factual summaries
* Reviews tickets for gaps and ambiguity
* Analyzes code diffs without guessing intent
* Runs rule-based code checks
* Compares Jira vs implementation (no bias)
* Generates Gherkin scenarios
* Exports test cases (Testmo)
* Produces clean, unambiguous Jira comments

---

## Why it matters

LLMs are inconsistent for QA when used directly.

aikiq enforces:

* Controlled, repeatable outputs
* No hidden assumptions
* Explicit gaps instead of “best guesses”
* Full reproducibility via sessions

LLM = semantic compression
System = source of truth

---

## Example usage

```bash
# Jira → structured facts
jira view XX-6544 | aikiq jira_summary --session 6544_x_improvement

# Code diff → analysis
hg diff -r default:6544_synch_status_improvement | aikiq code_review --session 6544_x_improvement

# Continue pipeline
aikiq jira_review --session 6544_x_improvement
aikiq code_summary --session 6544_x_improvement
aikiq jira_code_review --session 6544_x_improvement
aikiq gherkin_write --session 6544_x_improvement
aikiq testmo_import --session 6544_x_improvement
aikiq jira_comment --session 6544_x_improvement
```

---

## How it works

* YAML workflows (one responsibility per step)
* Strict schemas (JSON / CSV validation)
* Rule-based checks (not AI guessing)
* File-based sessions (reproducible runs)

Each step is isolated and constrained by schemas and rules.

---

## Design principles

* Control over implicit behavior
* Explicit > inferred
* No mixed responsibilities
* QA invariants always enforced:

  * authorization
  * nil safety
  * external API failures
  * permission layering

---

## Tech

CLI • YAML workflows • OpenRouter (LLMs) • JSON schema validation • rule-based analysis • Gherkin / BDD

---

## Who it’s for

QA engineers, backend teams, and anyone who wants **reliable AI-assisted testing without guesswork**.

---

## Status

Work in progress. Focused on improving validation and add AST based checks to achieve full automation.

---

## License

TBD
