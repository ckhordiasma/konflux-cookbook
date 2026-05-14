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

   Even if the user selects one pipeline, scan the `prefetch-input` of the other push pipelines in the repo. Different components in the same monorepo often reveal patterns (e.g., one component uses a single npm entry while others need multiple entries for sub-project lockfiles, or some components add gomod entries for Go BFFs). These cross-component patterns inform the guide even when only one pipeline is the focus.

3. **Identify the Dockerfile pair**: The pipeline references a `Dockerfile.konflux` (or variant like `Dockerfile.konflux.mlflow`). Ask the user which file was the *original* non-hermetic Dockerfile — it may be in a different directory, use a different naming convention, or use upstream base images. Diff the two and categorize each change:
   - **Hermetic-specific**: offline install flags, prefetch mount paths, workaround scripts for hermetic builds
   - **Konflux-specific but not hermetic**: base image pinning by digest, replacing upstream images with UBI/Red Hat equivalents, hardcoding build args, adding LABEL metadata, changing CGO/linker flags
   - **Structural**: restructuring COPY patterns, changing build context, workspace-aware builds vs standalone builds

   Finding **zero hermetic-specific changes** is a valid and important result — it means the Konflux pipeline's automatic cachi2.env injection and volume mounts were sufficient without any manual Dockerfile modifications. Report this explicitly, since it indicates the guide may overstate the amount of Dockerfile work needed for simple cases.

   Note: Categorize "Konflux-specific but not hermetic" findings separately. These belong in a Dockerfile.konflux best practices guide, not in the hermeto prefetch guide. Track them as TODO items rather than proposing edits to `guides/hermeto-prefetch.md`.

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

   **Verify claims against upstream docs.** Before asserting how a package manager or hermeto feature works, check the [hermeto docs](https://hermetoproject.github.io/hermeto/latest/) to confirm. Do not assume behavior from a single repo's pipeline config — the config may be incorrect, outdated, or cargo-culted. The guide should reflect how hermeto actually works, not just how one team configured it.

6. **Present findings**: Summarize in three categories:
   - **Guide got right**: Areas where the implementation matches guide instructions — a reader would arrive at the same result.
   - **Guide missed**: Things the developer had to figure out that the guide doesn't cover — a reader would get stuck.
   - **Better approaches**: Things the developer did differently that the guide could adopt — improvements to recommend.

   Separate hermeto-specific findings (belong in `guides/hermeto-prefetch.md`) from Konflux-general findings (base image pinning, build-arg patterns, labels, Renovate config). Propose Konflux-general items as TODO entries rather than guide edits.

7. **Apply improvements incrementally**: Work through findings one at a time rather than presenting all edits upfront. For each finding:
   - Present the finding and propose a concrete edit (section name, what to add/change, and why)
   - Let the user review and refine the wording
   - Apply the edit and commit before moving to the next finding

   This avoids large batches of changes that are harder to review and allows the user to redirect the conversation as findings surface new questions. If changes affect the workflow described in `skills/hermeto-prefetch/SKILL.md`, update that skill too.
