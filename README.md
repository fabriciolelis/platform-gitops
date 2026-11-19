# Platform GitOps

Desired Kubernetes state for the Formula Insights Platform, reconciled by Argo CD.

## Purpose

This repository is the source of truth for what is deployed to each Kubernetes environment. It contains declarative workload configuration, environment-specific values, Argo CD application definitions, and platform policies that belong at the cluster layer.

Argo CD, not a CI pipeline, applies these changes to Kubernetes (ADR-003). The bootstrap, secrets, and environment decisions are in ADR-008; the design of the first environment is in [`SPEC.md`](SPEC.md).

## Scope

- Argo CD `Application` and `AppProject` definitions.
- Kustomize bases and per-environment overlays.
- Approved container image versions.
- Kubernetes resource requests, limits, probes, and scheduled-job configuration.
- Secrets, encrypted with SOPS and age; never in plaintext.

## Out of scope

- Application business logic.
- Building container images.
- Terraform-managed cloud resources.

## Structure

```text
.sops.yaml                      # age recipient for every *.enc.yaml
bootstrap/
  k3d-local.yaml                # k3d cluster for the local environment
  argocd/                       # pinned Argo CD install, KSOPS on the repo server
  root-local.yaml               # root Application -> environments/local
environments/
  local/                        # AppProject and Applications for local
applications/
  postgres/                     # database: base and overlays/<environment>
  formula-insights/             # migration hook, API, daily importer
  monitoring/                   # Prometheus, kube-state-metrics, blackbox exporter
scripts/
  validate.sh                   # what CI runs, without a cluster or the age key
  test-validate.sh              # proves each validation rule
```

Environments are `local` (k3d) now and `dev` (the AWS lab) later. A new environment adds an overlay per application and an `environments/<environment>/` directory; the bases do not change.

## Run the local environment

Prerequisites: Docker, k3d, kubectl, sops, age, and yq (all available through winget on Windows), and the age private key. `SOPS_AGE_KEY_FILE` points to the key; on Windows the default is `%AppData%\sops\age\keys.txt`.

```bash
# Create the cluster and bootstrap Argo CD with the age key
k3d cluster create --config bootstrap/k3d-local.yaml
kubectl create namespace argocd
kubectl -n argocd create secret generic sops-age --from-file=keys.txt="$SOPS_AGE_KEY_FILE"
kubectl apply --server-side -k bootstrap/argocd
kubectl -n argocd wait --for=condition=Available deployment --all --timeout=300s
kubectl apply -f bootstrap/root-local.yaml

# Verify: every Application Synced and Healthy, then the API
kubectl -n argocd get applications
kubectl -n formula-insights port-forward svc/formula-insights-api 8000:80
curl -fsS localhost:8000/ready

# Run the daily import now instead of waiting for 06:00 UTC
kubectl -n formula-insights create job --from=cronjob/formula-insights-importer import-now
kubectl -n formula-insights wait --for=condition=Complete job/import-now --timeout=1800s

# Tear down; the data is disposable and the importer refills it
k3d cluster delete formula-insights-local
```

A rebuilt cluster loads the same age key, so no secret is re-encrypted.

## Common tasks

**Promote a new image.** In a pull request, change `newTag` in `applications/formula-insights/overlays/local/kustomization.yaml` to the full commit SHA of a published image, and paste the output of:

```bash
gh attestation verify oci://ghcr.io/fabriciolelis/formula-insights-api:<commit-sha> --owner fabriciolelis
```

After the merge, Argo CD runs the migration Job first; the new API pods start only if it succeeds.

**Roll back.** Revert the promotion pull request in Git; the schema is never reverted (ADR-007). See the rollback runbook in `platform-docs`.

**Backfill past seasons.** Copy the importer's Job with other arguments and a longer deadline (ADR-006; a backfill takes hours by design):

```bash
kubectl -n formula-insights create job backfill --from=cronjob/formula-insights-importer --dry-run=client -o yaml \
  | yq '.spec.template.spec.containers[0].args = ["python", "-m", "app.cli", "1950", "<last year>"] | .spec.activeDeadlineSeconds = 14400' \
  | kubectl apply -f -
```

**Edit a secret.** `sops applications/postgres/overlays/local/secret.enc.yaml` opens it decrypted in `$EDITOR` and re-encrypts it on save. Never commit a decrypted file.

**Open the monitoring UI.** Prometheus is reachable only through a port forward; its data is disposable and starts empty after a restart (ADR-009):

```bash
kubectl -n monitoring port-forward svc/prometheus 9090:9090
```

Then open `http://localhost:9090`. For example, `kube_job_status_succeeded{namespace="formula-insights"}` shows the outcome of each import Job.

**Validate before pushing.** Install the pinned tools once (Linux or Git Bash on Windows) into a directory on your `PATH`, then run the same checks as CI:

```bash
scripts/install-tools.sh ~/.local/bin
scripts/test-validate.sh
scripts/validate.sh
```

## Change rules

- Every change is made through a pull request; `Validate manifests` is a required check.
- Pin images to a full commit SHA or a digest; never deploy `latest`.
- Define CPU and memory requests and limits for every container.
- Commit secrets only encrypted with SOPS; keep the age private key out of Git and CI.
- Never `kubectl apply` a workload that Argo CD manages; bootstrap is the only exception.

## Verification

After a merge, verify that Argo CD reports every Application as `Synced` and `Healthy`. Promotion pull requests include the attestation check for the image they deploy.

## Related documents

ADR-003 (GitOps delivery), ADR-007 (migrations), ADR-008 (bootstrap, secrets, environments), and ADR-009 (observability) in the `platform-docs` repository, which also holds the rollback runbook.
