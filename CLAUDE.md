## Validating changes

Before committing manifest or script changes, run `scripts/test-validate.sh` and `scripts/validate.sh` in Bash. If kustomize, kubeconform, yq, or promtool is missing, install the pinned versions with `scripts/install-tools.sh ~/.local/bin`.

## Agent skills

### Issue tracker

Issues live in this repo's GitHub Issues, managed with the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Centralised in `platform-docs`: `GLOSSARY.md` and `adr/ADR-NNN.md` there cover the whole system. See `docs/agents/domain.md`.
