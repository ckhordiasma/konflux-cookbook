# konflux-cookbook

A collection of recipes and tools for getting builds working on Konflux.

## Structure

```
konflux-cookbook/
├── recipes/          # Human-readable how-to guides (standalone documentation)
├── skills/           # Claude Code skills (agent automation, references recipes/)
└── .claude-plugin/   # Plugin manifest
```

- **`recipes/`** -- step-by-step guides you can follow manually. Each recipe covers a specific build task.
- **`skills/`** -- Claude Code plugin skills that automate the recipes. These are used by Claude, not directly by humans.

## Recipes

| Recipe | Description |
|--------|-------------|
| [create-pr-pipeline](recipes/create-pr-pipeline.md) | Create a temporary pull request PipelineRun from a push PipelineRun to test build changes on an RHOAI release branch |

## Using as a Claude Code plugin

Install locally for testing:

```
claude --plugin-dir /path/to/konflux-cookbook
```

Once installed, the skills are available as slash commands (e.g., `/konflux-cookbook:create-pr-pipeline`).
