# Platform GitOps

Desired Kubernetes state for the Formula Insights Platform, reconciled by Argo CD.

## Purpose

This repository is the source of truth for what is deployed to each Kubernetes environment. It contains declarative workload configuration, environment-specific values, Argo CD application definitions, and platform policies that belong at the cluster layer.

Argo CD, not a CI pipeline, applies these changes to Kubernetes.

## Scope

- Argo CD \`Application\` definitions.
- Namespace configuration and Kubernetes policies.
- Helm values or Kustomize overlays by environment.
- Approved container image versions.
- Kubernetes resource requests, limits, probes, and scheduled-job configuration.

## Out of scope

- Application business logic.
- Building container images.
- Terraform-managed cloud resources.
- Plaintext secrets.

## Intended structure

\`\`\`text
bootstrap/             # Argo CD bootstrap and root applications
applications/
  formula-insights/    # workload deployment configuration
environments/
  dev/
  prod/
policies/              # namespace, network, or admission policies
\`\`\`

## Delivery flow

\`\`\`text
formula-insights-api pull request
        ↓
GitHub Actions tests and builds an image
        ↓
reviewed image-version update in this repository
        ↓
Argo CD reconciles desired state to Kubernetes
\`\`\`

## Change rules

- Every production-facing change is made through a pull request.
- Pin container images to immutable versions; do not deploy \`latest\`.
- Define CPU and memory requests/limits for every workload.
- Define readiness and liveness probes for the API.
- Define a clear retry and failure policy for the ingestion CronJob.
- Store secret references only; use a dedicated secret-management mechanism for values.

## Verification

After a merge, verify that Argo CD reports the application as \`Synced\` and \`Healthy\`. The deployed version and relevant dashboard links should be included in the pull request.

## Related documents

See ADR-003 in the \`formula-docs\` repository for the GitOps decision, and use \`formula-docs/runbooks\` for rollback and incident procedures.
