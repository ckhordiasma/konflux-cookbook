# konflux-cookbook

A collection of guides and tools for getting builds working on Konflux.

## Structure

```
konflux-cookbook/
├── guides/           # Human-readable how-to guides (standalone documentation)
├── skills/           # Claude Code skills (agent automation, references guides/)
└── .claude-plugin/   # Plugin manifest
```

- **`guides/`** -- step-by-step guides you can follow manually. Each guide covers a specific build task.
- **`skills/`** -- Claude Code plugin skills that automate the guides. These are used by Claude, not directly by humans.

## Guides

| Guide | Description |
|-------|-------------|
| [create-pr-pipeline](guides/create-pr-pipeline.md) | Create a temporary pull request PipelineRun from a push PipelineRun to test build changes on an RHOAI release branch |
| [test-conforma](guides/test-conforma.md) | Run Conforma (Enterprise Contract) validation against a Konflux snapshot to check release policy compliance |

## Using as a Claude Code plugin

Install locally for testing:

```
claude --plugin-dir /path/to/konflux-cookbook
```

Once installed, the skills are available as slash commands (e.g., `/konflux-cookbook:create-pr-pipeline`).
