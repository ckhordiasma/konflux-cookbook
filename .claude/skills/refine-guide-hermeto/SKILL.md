---
name: refine-guide-hermeto
description: Clone a repo with working hermetic builds and compare the implementation against the hermeto guide to identify gaps and improvements
version: 1.0.0
---

# Refine the Hermeto Guide Using a Real-World Repo

Read `guides/hermeto-prefetch.md` (relative to the plugin root) thoroughly before starting. It is the source of truth for all hermeto details. The goal of this skill is to compare a real-world hermetic build implementation against the guide and propose improvements where the guide falls short.

## Steps

1. **Get repo and branch**: Ask the user for the repository URL and branch name. Clone the repo at the specified branch into `.claude/repos/<repo-name>-<branch>` (relative to the cookbook root) so it doesn't pollute the project. If the directory already exists from a previous run, ask whether to re-clone or reuse it.

2. **Find and parse PipelineRuns**: List `.tekton/*.yaml` files in the cloned repo. Present them to the user and ask which push pipeline(s) to analyze (there may be multiple components). For each selected pipeline, extract:
   - `hermetic` flag (true/false)
   - `prefetch-input` (the hermeto config JSON)
   - `DOCKERFILE` parameter
   - Build context path
   - Build args, argfiles, or env file references
   - `build-platforms` (multi-arch targets)
   - Pipeline reference (resolver URL, path)

3. **Identify the Dockerfile pair**: The pipeline references a `Dockerfile.konflux` (or variant like `Dockerfile.konflux.mlflow`). Ask the user which file was the *original* non-hermetic Dockerfile — it may be in a different directory, use a different naming convention, or use upstream base images. Diff the two and categorize each change:
   - **Hermetic-specific**: sourcing cachi2.env, offline install flags, prefetch mount paths
   - **Konflux-specific but not hermetic**: base image pinning by digest, replacing upstream images with UBI/Red Hat equivalents, hardcoding build args, adding LABEL metadata, changing CGO/linker flags
   - **Structural**: restructuring COPY patterns, changing build context, workspace-aware builds vs standalone builds

4. **Inventory hermetic build artifacts**: Catalog all files in the repo relevant to hermetic builds:
   - Lockfiles: `package-lock.json`, `go.sum`, `Cargo.lock`, `requirements.txt`, `requirements-build.txt`, `rpms.lock.yaml`, `Gemfile.lock`, `artifacts.lock.yaml`
   - Config: `hermeto.json`, `rpms.in.yaml`, `ubi.repo`
   - Build inputs: argfiles, `.env` files, helper scripts (`hermetic_fixes.sh`, etc.)
   - Note which files exist at the repo root vs in subdirectories (important for monorepos with multiple components)

5. **Walk through the guide**: Read `guides/hermeto-prefetch.md` and simulate following it step-by-step for this repo. For each section of the guide, check whether it would lead a reader to the same implementation:

   - **"Create a Dockerfile.konflux"**: Does the guide's advice to copy and modify the Dockerfile match what the developer actually did? Were there structural changes the guide doesn't mention (e.g., workspace restructuring, base image swaps)?
   - **"Start from the Dockerfile"**: Does the guide's instruction to "identify every network access point" produce the same list of package managers as the `prefetch-input`? Would a reader of the guide know how to handle this repo's specific setup (monorepo, multi-stage builds, multiple components)?
   - **Package manager config**: For each manager in the `prefetch-input`, check the guide's section for that manager. Would following it produce the same config? Flag fields, patterns, or multi-path configs not covered.
   - **Lockfile generation**: Are the committed lockfiles consistent with what the guide's instructions would produce?
   - **"Building with Prefetched Dependencies"**: Does the guide's local testing workflow (fetch-deps, generate-env, inject-files, podman build) apply to this repo without modification?
   - **"Common Gotchas"**: Are there workarounds in the implementation that aren't documented? Are there gotchas in the guide that don't apply?

6. **Present findings**: Summarize in three categories:
   - **Guide got right**: Areas where the implementation matches guide instructions — a reader would arrive at the same result.
   - **Guide missed**: Things the developer had to figure out that the guide doesn't cover — a reader would get stuck.
   - **Better approaches**: Things the developer did differently that the guide could adopt — improvements to recommend.

   For each finding in the "missed" or "better" categories, draft a concrete suggested edit to `guides/hermeto-prefetch.md` (section name, what to add/change, and why).

7. **Apply improvements**: After the user reviews and approves the suggested edits, apply them to `guides/hermeto-prefetch.md`. If the changes affect the workflow described in `skills/hermeto-prefetch/SKILL.md`, update that skill too.
