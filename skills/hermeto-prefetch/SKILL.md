---
name: hermeto-prefetch
description: Set up Hermeto prefetching for hermetic Konflux builds
version: 1.0.0
---

# Set Up Hermeto Prefetching

Read `guides/hermeto-prefetch.md` (relative to the plugin root) thoroughly before starting. It is the source of truth for all hermeto details — do not duplicate its content, reference it as you go.

## Steps

1. **Identify the Dockerfile**: Find Dockerfiles in the project. If there are multiple, ask the user which one is the target. Ask whether the Dockerfile requires additional build inputs (argfiles, build-args, `.env` files) that affect what gets installed.

2. **Check for AIPCC usage**: If the project has Python dependencies, ask whether the project uses or should use AIPCC wheels. If yes, follow the "Using AIPCC Wheels" section in `guides/hermeto-python.md` — check the `red-hat-data-services/notebooks` repo as a reference for working AIPCC base image and index URL combinations. If adopting AIPCC, consider starting from a simpler Dockerfile that uses the AIPCC base image rather than adapting an existing Dockerfile with `microdnf install` and source builds.

3. **Analyze the Dockerfile**: Follow the "Start from the Dockerfile" section in the guide. Present a summary to the user mapping each network access point to the hermeto config section that would replace it, and flag anything that doesn't map to a supported package manager.

4. **Build the hermeto config**: Follow the "Configuring hermeto.json" section in the guide for each package manager found in step 3. For package-manager-specific setup (e.g., Python requirements compilation, RPM lockfile generation), follow the corresponding guide sections. Show the user the config as you build it, and frequently ask the user for input.

5. **Iterate and test**: Follow the "Iterate one package manager at a time" and "Building with Prefetched Dependencies" sections in the guide. Ask the user whether they want to iterate one manager at a time or configure everything first. Consult "Common Gotchas" when builds fail.

   When multiple steps have been repeated manually, you can mention that the cookbook provides Makefiles that automate those steps — but don't use them by default.

6. **Summarize**: Report what was created, which files to commit vs. gitignore, and next steps for the Konflux pipeline.
