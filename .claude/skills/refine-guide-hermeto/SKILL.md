---
name: refine-guide-hermeto
description: Clone a repo with working hermetic builds and compare the implementation against the hermeto guide to identify gaps and improvements
version: 1.0.0
---

# Refine the Hermeto Guide Using a Real-World Repo

Read `guides/hermeto-prefetch.md` (relative to the plugin root) thoroughly before starting. It is the source of truth for all hermeto details. The goal of this skill is to compare a real-world hermetic build implementation against the guide and propose improvements where the guide falls short.

## Steps

1. **Get repo and branch**: If no repo is specified in the arguments, read `TODO.md` (relative to the cookbook root) and find the next unchecked repo under the "Refine Hermeto Guide Against Real Repos" section. The TODO section header specifies the branch to use. Present the repo and branch to the user for confirmation before proceeding. If the user provides a repo in the arguments, use that instead. Clone the repo at the specified branch into `.claude/repos/<repo-name>-<branch>` (relative to the cookbook root) so it doesn't pollute the project. If the directory already exists from a previous run, ask whether to re-clone or reuse it.

   **Parallel analysis:** When the user asks to analyze multiple repos (e.g., "check all AIPCC repos"), spawn background agents to analyze each repo concurrently. Each agent should perform steps 2–5 independently and return its findings. Keep the main context free for synthesis — do not duplicate the agents' analysis work in the main thread.

   Before spawning agents, read `guides/hermeto-prefetch.md` once and include its content in each agent's prompt. This eliminates redundant file reads — each agent gets the guide inline rather than reading it from disk independently. The guide is the reference for step 5 (walking through sections to compare against the implementation).

2. **Find and parse PipelineRuns**: List `.tekton/*.yaml` files in the cloned repo. If there is only one push pipeline, proceed with it directly. If there are multiple, present them to the user and ask which push pipeline(s) to analyze. For each selected pipeline, extract:
   - `hermetic` flag (true/false)
   - `prefetch-input` (the hermeto config JSON)
   - `DOCKERFILE` parameter
   - Build context path
   - Build args, argfiles, or env file references
   - `build-platforms` (multi-arch targets)
   - Pipeline reference (resolver URL, path)

   A pipeline may set `hermetic: true` with no `prefetch-input` at all. This is valid when the Dockerfile has zero network access points — there is nothing to prefetch. Note this explicitly rather than treating it as missing data.

   Even if the user selects one pipeline, scan the `prefetch-input` of the other push pipelines in the repo. Different components in the same monorepo often reveal patterns (e.g., one component uses a single npm entry while others need multiple entries for sub-project lockfiles, or some components add gomod entries for Go BFFs). These cross-component patterns inform the guide even when only one pipeline is the focus.

   Cross-repo patterns are equally valuable. When running parallel agents, a workaround seen in one repo (e.g., `--prerelease=allow` for AIPCC version suffixes) often applies to all repos using the same ecosystem. The synthesis step should surface these.

   When multiple pipelines target the same component (e.g., push + pull-request, or an older pipeline alongside a newer one), compare their `prefetch-input` for consistency. Drift between pipeline files — such as a stale pipeline missing a newly added gomod entry — is worth flagging.

3. **Identify the Dockerfile pair**: The pipeline references a `Dockerfile.konflux` (or variant like `Dockerfile.konflux.mlflow`). Identify the Dockerfile that `Dockerfile.konflux` was derived from — this is the one to diff against. The typical lineage is: upstream `Dockerfile` (which may already have a UBI/RHEL variant) → ODH/midstream Dockerfile (`Dockerfile.ODH`, `Dockerfile.rhoai`, etc.) → `Dockerfile.konflux`. The direct parent is usually the ODH or midstream variant, not the upstream. Look for `Dockerfile.ODH`, `Dockerfile.rhoai`, or similarly named files in the same directory or in a `rhoai/` subdirectory. When running as a background agent, infer the parent by comparing structure and base images; when running interactively, ask the user to confirm. Diff the two and categorize each change:
   - **Hermetic-specific**: offline install flags, prefetch mount paths, workaround scripts for hermetic builds
   - **Konflux-specific but not hermetic**: base image pinning by digest, replacing upstream images with UBI/Red Hat equivalents, hardcoding build args, adding LABEL metadata, changing CGO/linker flags
   - **Structural**: restructuring COPY patterns, changing build context, workspace-aware builds vs standalone builds

   If the Dockerfile.konflux is a complete rewrite rather than a modification (e.g., switching from a Debian base to an AIPCC UBI9 image), note this as a structural finding and compare the two builds' approaches rather than diffing line by line. A diff produces noise when the base image ecosystem, package manager, and dependency strategy are all different.

   Finding **zero hermetic-specific changes** is a valid and important result — it means the Konflux pipeline's automatic cachi2.env injection and volume mounts were sufficient without any manual Dockerfile modifications. Report this explicitly. When analyzing multiple repos, track the zero-change count (e.g., "4/6 repos needed no hermetic Dockerfile changes") — if most repos need no changes, that's a signal the guide should set that expectation upfront.

   Also look for **network-elimination strategies** — cases where the developer removed network access points from Dockerfile.konflux instead of prefetching them. Common patterns: multi-stage `COPY --from=` to extract binaries from trusted images, switching to a base image that already includes needed tools, or adding a tool's source as a git submodule and building it from source. These are alternatives to the generic fetcher that the guide should document.

   Note: Categorize "Konflux-specific but not hermetic" findings separately. These belong in a Dockerfile.konflux best practices guide, not in the hermeto prefetch guide. Track them as TODO items rather than proposing edits to `guides/hermeto-prefetch.md`.

4. **Inventory hermetic build artifacts**: Catalog all files in the repo relevant to hermetic builds:
   - Lockfiles: `package-lock.json`, `go.sum`, `Cargo.lock`, `requirements.txt`, `requirements-build.txt`, `rpms.lock.yaml`, `Gemfile.lock`, `artifacts.lock.yaml`
   - Go workspace files: `go.work`, `go.work.sum` (if present, a single gomod prefetch entry may cover multiple modules)
   - Config: `hermeto.json`, `rpms.in.yaml`, `ubi.repo`
   - Build inputs: argfiles, `.env` files, helper scripts (`hermetic_fixes.sh`, etc.)
   - Git submodules (`.gitmodules`) — submodules that replace runtime downloads (e.g., building yq from source instead of curling a binary)
   - Git LFS objects — large binaries committed via LFS that replace runtime downloads (check `.gitattributes` for LFS-tracked paths)
   - Note which files exist at the repo root vs in subdirectories (important for monorepos with multiple components)

5. **Walk through the guide**: Using the guide content (from `guides/hermeto-prefetch.md` — provided in the agent prompt during parallel runs, or read directly for single-repo runs), simulate following it step-by-step for this repo. For each section of the guide, check whether it would lead a reader to the same implementation:

   - **"Create a Dockerfile.konflux"**: Does the guide's advice to copy and modify the Dockerfile match what the developer actually did? Were there structural changes the guide doesn't mention (e.g., workspace restructuring, base image swaps)?
   - **"Start from the Dockerfile"**: Does the guide's instruction to "identify every network access point" produce the same list of package managers as the `prefetch-input`? Would a reader of the guide know how to handle this repo's specific setup (monorepo, multi-stage builds, multiple components)?
   - **Package manager config**: For each manager in the `prefetch-input`, check the guide's section for that manager. Would following it produce the same config? Flag fields, patterns, or multi-path configs not covered.
   - **Lockfile generation**: Are the committed lockfiles consistent with what the guide's instructions would produce?
   - **"Building with Prefetched Dependencies"**: Does the guide's local testing workflow (fetch-deps, generate-env, inject-files, podman build) apply to this repo without modification?
   - **"Common Gotchas"**: Are there workarounds in the implementation that aren't documented? Are there gotchas in the guide that don't apply?

   **Verify claims against upstream docs.** Before asserting how a package manager or hermeto feature works, check the [hermeto docs](https://hermetoproject.github.io/hermeto/latest/) to confirm. Do not assume behavior from a single repo's pipeline config — the config may be incorrect, outdated, or cargo-culted. The guide should reflect how hermeto actually works, not just how one team configured it.

   **Verify before asserting "required" or "essential."** When a repo uses a particular flag or pattern, confirm whether it is truly necessary or just a defensive practice. Check what environment variables hermeto actually sets (e.g., `PIP_NO_INDEX` vs `PIP_INDEX_URL`), understand flag/env-var precedence for the relevant tools, and test your reasoning against the hermeto docs. Present findings as observations from the repo until verified — "this repo uses X" is safer than "X is required for hermetic builds" until you have confirmed the mechanism.

6. **Present findings**: Summarize in three categories:
   - **Guide got right**: Areas where the implementation matches guide instructions — a reader would arrive at the same result.
   - **Guide missed**: Things the developer had to figure out that the guide doesn't cover — a reader would get stuck.
   - **Better approaches**: Things the developer did differently that the guide could adopt — improvements to recommend.

   Separate hermeto-specific findings (belong in `guides/hermeto-prefetch.md`) from Konflux-general findings (base image pinning, build-arg patterns, labels, Renovate config). Propose Konflux-general items as TODO entries rather than guide edits.

   **Synthesizing across multiple repos:** When agents analyzed multiple repos in parallel, deduplicate and merge their findings before presenting. Group findings by topic (not by repo), note how many repos exhibited each pattern, and prioritize by frequency — a pattern seen in 5/6 repos is a stronger signal than one seen in 1/6. Include repo-specific quirks if they relate to hermetic builds (e.g., a workaround for a hermeto bug in one repo), but flag them as single-repo observations rather than general patterns.

7. **Apply improvements incrementally**: Work through findings one at a time rather than presenting all edits upfront. For each finding:
   - Present the finding and propose a concrete edit (section name, what to add/change, and why)
   - Let the user review and refine the wording
   - Apply the edit and commit before moving to the next finding

   This avoids large batches of changes that are harder to review and allows the user to redirect the conversation as findings surface new questions. If changes affect the workflow described in `skills/hermeto-prefetch/SKILL.md`, update that skill too.
