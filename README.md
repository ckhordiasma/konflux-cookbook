# konflux-cookbook

A collection of guides and tools for getting production-ready builds working on Konflux

## Manifesto

Give developers the local tools and knowledge to have confidence that their konflux builds will not have issues downstream.

## Things that cause issues downstream

- Hermetic Builds
- Conforma
- FIPS
- Support for PowerPC and IBM Z (power/z)

## Structure

```
konflux-cookbook/
├── guides/           # Human-readable how-to guides (standalone documentation)
├── skills/           # Claude Code skills (agent automation, references guides/)
└── .claude-plugin/   # Plugin manifest
```

- **`guides/`** -- Step-by-step guides you can follow manually. 
- **`skills/`** -- Claude Code plugin skills that reference the guides. Use the skills to have claude walk you through a guide.
- `scripts/` -- Scripts that "one-shot" the guide, given you provide it with all the correct input parameters. In other words, a deterministic automation of a given guide.

## Guides

| Guide | Description |
|-------|-------------|
| [create-pr-pipeline](guides/create-pr-pipeline.md) | Create a temporary pull request PipelineRun from a push PipelineRun to test build changes on an RHOAI release branch |
| [test-conforma](guides/test-conforma.md) | Run Conforma (Enterprise Contract) validation against a single image or Konflux snapshot to check release policy compliance |
| [beaker-vm](guides/beaker-vm.md) | Provision a VM on Beaker for multi-arch build testing |

## Using as a Claude Code plugin

Install locally for testing:

```
claude --plugin-dir /path/to/konflux-cookbook
```

Once installed, the skills are available as slash commands (e.g., `/konflux-cookbook:create-pr-pipeline`).
