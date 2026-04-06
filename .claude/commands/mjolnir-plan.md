Help the user design a mjolnir project and build plan, then deploy it to the OCI instance.

## Step 1: Gather Requirements

Ask the user what they want to build. Clarify:
- What does the app do?
- What tech stack? (The OCI instance has Python 3.10, Node 18, Flask, Playwright+Chromium)
- How complex? (1 sprint = simple, 2-3 = moderate)

## Step 2: Enter Plan Mode

Use Claude plan mode to draft the project.toml and plan.md together with the user. Keep plans simple — 1-2 sprints for most projects.

## Step 3: Write Files

Save to `workspace/<project-name>/`:
- `project.toml` — project config
- `plan.md` — the build plan (optional — if omitted, the planner agent generates one)

### project.toml — Required Fields

See `templates/project.toml.example` for the full template with all optional fields commented.

Minimal required:

```toml
[project]
name = "my-app"           # Also becomes the work subdirectory name
description = "What to build"
goals = ["Goal 1", "Goal 2"]
tech_stack = "Python, Flask, SQLite"
# constraints = ["Optional constraints"]

[planning]
mode = "auto"             # Always "auto" when deploying remotely

[scoring.thresholds]      # Lower = easier to pass
design_quality = 6        # Architecture, separation of concerns
originality = 4           # Creative choices beyond boilerplate
craft = 6                 # Code quality, error handling, polish
functionality = 7         # Does it work? Acceptance criteria met?

[budget]
max_retries = 2           # Retries per sprint before halting
max_sprints = 1           # MUST match sprint count in plan.md (0 = planner decides)
budget_per_sprint = 10    # Cost tracking (not enforced)
```

### plan.md — Sprint Format

See `plan.md` in the repo root for a full real-world example (10-sprint todo app with offline sync).

Sprint headers MUST match `## Sprint N` — the regex `^##+ Sprint [0-9]+` is used to count them. Each sprint needs these sections:

```markdown
# Project Name

## Product Vision
Brief description — what we're building and why.

## Technical Architecture
Stack, key components, data flow.

## Sprint 1: Title

### Scope
What this sprint delivers.

### Deliverables
- app.py — Flask backend serving API and static files
- index.html — Frontend page
- start.sh — Single command to run everything

### Acceptance Criteria
Must be concrete and testable — the evaluator checks these:
- `GET /api/data` returns 200 with JSON array
- Homepage renders a chart with labeled axes
- `bash start.sh` seeds DB and starts server on port 5173

### Technical Notes
Implementation hints, patterns to use, pitfalls to avoid.
```

### Key Rules

- `max_sprints` in project.toml MUST equal the number of `## Sprint N` headers in plan.md
- Acceptance criteria must be specific and testable (not "it works")
- Web apps should serve on port 5173 (evaluator uses Playwright there)
- Generator writes to `workspace/<name>/<name>/` — all paths in plan should be relative
- If plan.md already exists when mjolnir starts, the planner phase is skipped automatically
- The evaluator scores on a 1-10 scale where 7 = "good, would ship to production"
- Set thresholds to 4-6 for smoke tests, 7+ for quality builds

### Scoring Rubric Summary

The evaluator scores on four criteria (see `prompts/rubric.md` for full details):
- **design_quality** — Architecture, separation of concerns, extensibility
- **originality** — Creative choices beyond boilerplate, novel approaches
- **craft** — Code quality, naming, error handling, polish
- **functionality** — Does it actually work? Are acceptance criteria met?

## Step 4: Deploy

With a pre-written plan:
```bash
bash mjolnir deploy <project-name> --plan=workspace/<project-name>/plan.md
```

Without a plan (planner agent creates one from project.toml goals):
```bash
bash mjolnir deploy <project-name>
```

Upload only (don't start the run):
```bash
bash mjolnir deploy <project-name> --plan=workspace/<project-name>/plan.md --no-run
```

## Step 5: Monitor

- Status: `bash mjolnir remote-status <project-name>`
- Logs: `bash mjolnir remote-logs <project-name>`
- All projects: `bash mjolnir remote-status`
