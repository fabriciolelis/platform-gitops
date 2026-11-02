# Spec: First GitOps deployment of Formula Insights (local k3d)

- Status: Draft, awaiting approval
- Tracks: platform-gitops#2 (decisions), Sprint 3 deployment work
- Repositories touched: `platform-docs` (ADR-008), `formula-insights-api` (two small API changes), `platform-gitops` (manifests and bootstrap)

## Objective

Run Formula Insights on a local k3d cluster with all of its desired state in this
repository and reconciled by Argo CD (ADR-003). The API, its PostgreSQL database,
the migration step from ADR-007, and the daily importer from ADR-006 are deployed
from Git. No one runs `kubectl apply` for a workload, and no plaintext secret is
committed.

The user is the platform maintainer, who must be able to rebuild the environment
from nothing with the documented commands. A portfolio reviewer must be able to
read in Git exactly what runs and why. The deployment is done when a rebuilt
cluster reaches the same state without manual fixes (see Success criteria).

AWS is out of scope (Sprint 1 review, ADR-004). The structure must still let a
`dev` overlay for the AWS K3s lab be added later without restructuring.

### Decisions recorded in ADR-008 (closes platform-gitops#2)

| Question from platform-gitops#2 | Decision |
| --- | --- |
| How Argo CD is bootstrapped | Installed once per cluster with `kubectl apply --server-side -k bootstrap/argocd`, which applies the upstream install manifest pinned to an exact release plus local patches. A root Application then deploys everything else (app of apps). Argo CD does not manage itself in this iteration. |
| Secret management | SOPS with age. The encrypted files are committed, and Argo CD decrypts them while rendering through the KSOPS Kustomize plugin on its repo server. The age private key stays with the operator and is loaded into each new cluster at bootstrap, so it survives cluster rebuilds. |
| Overlays or separate environment trees | Kustomize. Each application has its own `base/` and `overlays/<env>/` directories. `environments/<env>/` holds only that environment's Argo CD Applications. |
| Environment names | `local` (k3d) now; `dev` (the AWS lab) later. `prod` is removed from the intended structure until a cost review approves it (platform-infrastructure README). |

## Tech stack

- Local cluster: k3d running K3s, the same distribution as the AWS lab design. The cluster is defined in a committed k3d config file.
- Argo CD: one pinned release, with KSOPS added to the repo server through an init container.
- Kustomize, the version built into the pinned Argo CD.
- SOPS and age for secrets, with the age public key in `.sops.yaml`.
- PostgreSQL 16 (`postgres:16-alpine`, pinned by digest), matching `compose.yaml`.
- Application image: `ghcr.io/fabriciolelis/formula-insights-api:<full commit SHA>`, published by formula-insights-api CI.
- CI for this repository: GitHub Actions, which only renders and validates the manifests and never touches a cluster (ADR-003). Validation uses `kustomize build` and kubeconform.

## Scope

### A. formula-insights-api changes (one PR, merged and published first)

1. **Current-season import:** `python -m app.cli current` imports the current
   calendar year in UTC. The existing `<first> [<last>]` forms are unchanged. A
   pre-season run, with races scheduled but no results, already succeeds:
   empty standings with none stored are not an error (verified in
   `app/importer.py`).
2. **Readiness endpoint:** `GET /ready` returns `200 {"status": "ready"}` when a
   `SELECT 1` succeeds. It returns `503 {"status": "unavailable"}` within 2 s
   when the database cannot be reached, and never hangs until the probe times
   out. `GET /health` stays a liveness check that does not touch the database.
   This is the endpoint the availability SLO probes. The probe itself belongs to
   the observability work.

### B. platform-gitops content

| Workload | Kind | Key settings |
| --- | --- | --- |
| PostgreSQL | StatefulSet with 1 replica, ClusterIP Service, 1 Gi local-path PVC | Password from the SOPS Secret; readiness probe `pg_isready`; data is disposable (no backup). |
| Migration | Job as an Argo CD `PreSync` hook | Runs `alembic upgrade head` from the release image; `hook-delete-policy: BeforeHookCreation`; `backoffLimit: 1`; `activeDeadlineSeconds: 300`. If it fails, the sync stops and the running Deployment is untouched (ADR-007). |
| API | Deployment with 1 replica, ClusterIP Service | Liveness probe `/health`, readiness probe `/ready`; reached through `kubectl port-forward` only, with no Ingress (as in the AWS lab design). |
| Importer | CronJob | `schedule: "0 6 * * *"`, `timeZone: Etc/UTC`; arguments `current`; `concurrencyPolicy: Forbid`; `backoffLimit: 2` (the "limited job-level retries" of ADR-006); `activeDeadlineSeconds: 1800` (the 30-minute refresh SLO); `restartPolicy: Never`; keeps 3 successful and 3 failed Jobs. |

Rules that apply to every workload:

- CPU and memory requests and limits are set for every container.
- Containers run with `runAsNonRoot`, a numeric UID, `allowPrivilegeEscalation: false`, all capabilities dropped, seccomp `RuntimeDefault`, a read-only root filesystem, and `PYTHONDONTWRITEBYTECODE=1`. PostgreSQL gets the subset its image supports. The image has no `USER`, so the UID is set in the pod spec.
- The image is referenced only by a full commit SHA, set once per overlay through the Kustomize `images:` field. The migration Job and the importer therefore always run the same version as the API.
- `DATABASE_URL` and `POSTGRES_PASSWORD` come from one SOPS-encrypted Secret per environment. `JOLPICA_BASE_URL` comes from a ConfigMap.

Argo CD objects:

- The `formula-insights` AppProject allows only this repository as a source and only the `formula-insights` namespace as a destination; it does not use the `default` project.
- The `root-local` Application points at `environments/local/`.
- The `formula-insights-postgres` Application is in sync wave 0, and the `formula-insights` Application in sync wave 1. Application health assessment is enabled in `argocd-cm`, so on a cold bootstrap the database is Healthy before the migration hook runs.
- Sync is automated with `prune` and `selfHeal`, and failed syncs are retried a limited number of times.

**Promotion:** a reviewed PR changes the image tag in
`applications/formula-insights/overlays/local/kustomization.yaml`. The PR
description includes the output of `gh attestation verify` for that image.
Automated image updates are out of scope.

## Commands

Prerequisites: Docker, k3d, kubectl, sops, age, and the age private key.
`SOPS_AGE_KEY_FILE` points to the key; the default on Windows is
`%AppData%\sops\age\keys.txt`.

```bash
# Create the cluster and bootstrap Argo CD with the age key
k3d cluster create --config bootstrap/k3d-local.yaml
kubectl create namespace argocd
kubectl -n argocd create secret generic sops-age --from-file=keys.txt="$SOPS_AGE_KEY_FILE"
kubectl apply --server-side -k bootstrap/argocd
kubectl -n argocd wait --for=condition=Available deployment --all --timeout=300s
kubectl apply -f bootstrap/root-local.yaml

# Verify
kubectl -n argocd get applications            # all Synced / Healthy
kubectl -n formula-insights port-forward svc/formula-insights-api 8000:80
curl -fsS localhost:8000/ready
kubectl -n formula-insights create job --from=cronjob/formula-insights-importer import-now
kubectl -n formula-insights wait --for=condition=Complete job/import-now --timeout=1800s

# Edit or create a secret (opens decrypted in $EDITOR, re-encrypts on save)
sops applications/formula-insights/overlays/local/secret.enc.yaml

# Validate manifests as CI does (no cluster, no age key)
./scripts/validate.sh

# Tear down
k3d cluster delete formula-insights-local
```

API changes, run in `formula-insights-api` as today: `uv run pytest -q`,
`uv run ruff check .`.

## Project structure

```text
.sops.yaml                         # age recipient and encrypted_regex (data, stringData)
bootstrap/
  k3d-local.yaml                   # k3d cluster config
  argocd/kustomization.yaml        # pinned upstream install + KSOPS repo-server patch + argocd-cm
  root-local.yaml                  # root Application -> environments/local
environments/
  local/                           # AppProject and child Applications for local
applications/
  formula-insights/
    base/                          # Deployment, Service, migration Job, CronJob, ConfigMap
    overlays/local/                # image tag, resources, KSOPS generator, secret.enc.yaml
  postgres/
    base/                          # StatefulSet, Service
    overlays/local/                # storage size, KSOPS generator
scripts/validate.sh                # renders every overlay and runs kubeconform (used by CI)
.github/workflows/validate.yml
```

`policies/` stays in the intended structure but is not created yet.

## Code style

The YAML has one resource per file, named `<kind>-<name>.yaml` in lowercase, and
uses 2-space indentation. Every resource carries the standard
`app.kubernetes.io/*` labels, comments explain only the why, and each comment that
records a decision cites the ADR.

```yaml
# cronjob-formula-insights-importer.yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: formula-insights-importer
  labels:
    app.kubernetes.io/name: formula-insights
    app.kubernetes.io/component: importer
spec:
  schedule: "0 6 * * *"
  timeZone: Etc/UTC
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      backoffLimit: 2              # job-level retries; the client never retries (ADR-006)
      activeDeadlineSeconds: 1800  # incremental refresh SLO: 30 minutes
      template:
        spec:
          restartPolicy: Never
          containers:
            - name: importer
              image: ghcr.io/fabriciolelis/formula-insights-api  # tag set by the overlay
              args: ["python", "-m", "app.cli", "current"]
```

The Python changes follow the existing code: Google-style docstrings, ruff, and
one-line reasons on stderr with exit code 1 for CLI failures.

## Testing strategy

| Level | What | Where |
| --- | --- | --- |
| Unit (API) | `current` resolves to the UTC year, tested with an injected or patched clock; argument errors are unchanged; `/ready` returns 200 on a healthy database and 503 quickly on an unreachable one | `formula-insights-api/tests/` (pytest), in existing CI |
| Static (GitOps) | Every overlay renders; the rendered output passes kubeconform with strict schemas for the cluster's Kubernetes version; every `Secret` in Git is SOPS-encrypted; no image uses `latest` or lacks a tag; every container has requests and limits | `scripts/validate.sh` in GitHub Actions, without the age key |
| End to end (manual) | The Success criteria below, run on a fresh k3d cluster, with the output saved as Sprint 3 review evidence | Local machine |

CI for this repository has no cluster and no age key. The KSOPS generator
therefore has to be skipped or stubbed when rendering in CI, and the plan must
show how. Running the end-to-end check on k3d in CI is out of scope.

## Boundaries

- **Always:** make every change through a PR; pin every version (Argo CD, KSOPS,
  images by full SHA or digest); keep the age private key out of Git and out of CI
  logs; verify that Argo CD shows Synced and Healthy after a merge; cite the ADR
  when a manifest encodes a decision.
- **Ask first:** adding a cluster component (Ingress controller, cert-manager,
  monitoring stack, NetworkPolicies); letting Argo CD manage itself; adding an
  environment; changing the hook model of ADR-007; adding a dependency to
  formula-insights-api; changing the Dockerfile.
- **Never:** commit a plaintext secret or a decrypted file; deploy `latest`;
  `kubectl apply` a workload that Argo CD manages (bootstrap is the only
  exception); give CI credentials for a cluster; create AWS resources.

## Success criteria

1. Starting from no cluster, the commands above bring `root-local`,
   `formula-insights-postgres`, and `formula-insights` to **Synced** and
   **Healthy** within 10 minutes, with no other manual steps.
2. `GET /ready` returns 200 through the port-forward. When PostgreSQL is scaled
   to 0, it returns 503 and the API pod becomes NotReady but is not restarted.
3. A Job created from the CronJob completes with exit code 0, and afterwards
   `GET /seasons/<current year>/races` returns that season's races.
4. Merging a PR that changes the image tag runs the migration Job before any
   new API pod starts. A migration that fails, tried once on a throwaway branch,
   leaves the previous Deployment serving and the Application in a failed sync.
5. After `k3d cluster delete` and the bootstrap again with the same age key,
   criteria 1–3 pass with no secret re-encrypted.
6. CI fails on a PR that adds an unencrypted `Secret`, an image without a tag,
   or a container without resource limits.
7. ADR-008 is merged in platform-docs, platform-gitops#2 is closed, and this
   repository's README matches the structure that was implemented.
8. The importer CronJob shows `concurrencyPolicy: Forbid`, `backoffLimit: 2`,
   `activeDeadlineSeconds: 1800`, and a daily UTC schedule in the rendered
   manifests.

## Assumptions

1. `local` is not a "persistent environment" in the sense of ADR-007, so it uses
   a single database role. The separate migration and application roles arrive
   with the first persistent environment.
2. The GHCR package is public, so the cluster pulls without credentials. I could
   not verify this, because the local `gh` token lacks `read:packages`.
3. Data loss on `k3d cluster delete` is acceptable; recovery is re-running the
   importer.
4. Pinned Argo CD, KSOPS, and kubeconform versions are chosen in the plan and
   must be at least two weeks old.

## Open questions

1. Is the GHCR package public? If it is private, the spec needs an image pull
   secret, encrypted with SOPS.
2. Does 06:00 UTC suit you for the daily run? Results from Sunday races are
   usually on Jolpica by Monday morning.
3. Do you accept assumption 1 (single database role locally)? If not, the
   PostgreSQL bootstrap has to create two roles now.
4. Should the manual backfill (`python -m app.cli 1950 <last year>`) get a
   committed, suspended Job manifest, or a documented `kubectl create job`
   command only? The spec currently assumes the command only.
