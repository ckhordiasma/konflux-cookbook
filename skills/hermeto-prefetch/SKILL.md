---
name: hermeto-prefetch
description: Set up Hermeto prefetching for hermetic Konflux builds
version: 1.0.0
---

# Set Up Hermeto Prefetching

Read `guides/hermeto-prefetch.md` and `guides/hermeto-python.md` (relative to the plugin root) thoroughly before starting. Together they are the source of truth for all hermeto details — the main guide covers general workflow and non-Python package managers, the Python guide covers requirements generation, AIPCC, and source builds. Do not duplicate their content, reference them as you go.

## Steps

1. **Identify the Dockerfile**: Find Dockerfiles in the project. If there are multiple, ask the user which one is the target. Ask whether the Dockerfile requires additional build inputs (argfiles, build-args, `.env` files) that affect what gets installed.

2. **Check for Python / AIPCC**: If the project has Python dependencies, recommend using AIPCC wheels — it is the preferred approach for RHOAI Python components, providing prebuilt wheels for all target architectures and eliminating source builds. Ask whether the project already uses AIPCC or should adopt it. Follow the AIPCC sections in `guides/hermeto-python.md` for index selection, requirements compilation, and hermeto config. This affects base image choice and Dockerfile structure, so resolve it before step 3.

3. **Analyze the Dockerfile**: Follow the "Start from the Dockerfile" section in the guide. Present a summary to the user mapping each network access point to the hermeto config section that would replace it, and flag anything that doesn't map to a supported package manager.

4. **Build the hermeto config**: Follow the "Configuring hermeto-test.json" section in the guide for each package manager found in step 3. For package-manager-specific setup (e.g., Python requirements compilation, RPM lockfile generation), follow the corresponding guide sections. Show the user the config as you build it, and frequently ask the user for input.

5. **Iterate and test**: Follow the "Iterate one package manager at a time" and "Building with Prefetched Dependencies" sections in the guide. Ask the user whether they want to iterate one manager at a time or configure everything first. Consult "Common Gotchas" when builds fail.

   When multiple steps have been repeated manually, mention that the cookbook provides Makefiles that automate them — but don't use them by default.

6. **Summarize**: Report what was created, which files to commit vs. gitignore, and next steps for the Konflux pipeline.
