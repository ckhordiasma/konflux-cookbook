# Konflux Build Context

This file provides context for AI agents working in repos that build on Konflux.

## Key Concepts

- **Konflux** uses Tekton Pipelines-as-Code. PipelineRuns live in `.tekton/` directories and are triggered by GitHub events (push, pull_request) or PR comments.
- **Push pipelines** run after code is merged. **Pull request pipelines** run on PRs.

## PipelineRun Conventions

- Push PipelineRuns for release branches are named `<component>-<release-branch>-push.yaml`.
- Pull request PipelineRuns are named `<component>-pull-request.yaml`.
- `{{repo_url}}` and `{{target_branch}}` are used in push pipelines.
- `{{source_url}}` and `{{revision}}` are used in pull request pipelines (to support forks and build PR commits).

## RHOAI-Specific

- **konflux-central** is the central repo that defines shared pipelines and maintains PipelineRuns for all RHOAI components. PipelineRuns in `pipelineruns/<component>/.tekton/` get synced to component repos. konflux-central is the source of truth -- changes made directly in component repos must be synced back, or they will be overwritten on the next sync.
- Release branches follow the pattern `rhoai-X.Y` (e.g., `rhoai-2.19`).
- Production images go to component-specific quay repos under `quay.io/redhat-user-workloads/`.
- Pull request pipeline images must go to `quay.io/redhat-user-workloads/rhoai-tenant/pull-request-pipelines/<component>`.
- Pull request pipelines must use the service account `build-pipeline-pull-request-pipelines`, not the component's push service account.
- Never push test images to a production quay repo -- this can overwrite released images.
- If you modify a push pipeline in a component repo, the same change needs to go into `pipelineruns/<component>/.tekton/` in konflux-central after merging.
