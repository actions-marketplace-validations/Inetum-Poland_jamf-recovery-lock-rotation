# Jamf Recovery Lock Rotation

[![License: Apache 2.0](https://img.shields.io/github/license/Inetum-Poland/jamf-recovery-lock-rotation?logo=apache&color=purple)](https://github.com/Inetum-Poland/jamf-recovery-lock-rotation?tab=Apache-2.0-1-ov-file#)
[![GitHub Marketplace](https://img.shields.io/badge/Marketplace-Jamf%20Recovery%20Lock%20Rotation-blue?logo=github&colorA=2a313c&colorB=2f81f7)](https://github.com/marketplace/actions/jamf-recovery-lock-rotation)
[![Platform](https://img.shields.io/badge/platform-Ubuntu%20runner-orange)](#)
[![MDM: Jamf Pro](https://img.shields.io/badge/MDM-Jamf%20Pro-blue)](#)
[![Lint](https://github.com/Inetum-Poland/jamf-recovery-lock-rotation/actions/workflows/lint.yml/badge.svg)](https://github.com/Inetum-Poland/jamf-recovery-lock-rotation/actions/workflows/lint.yml)
[![ShellCheck](https://img.shields.io/badge/ShellCheck-passing-brightgreen)](#)
[![Security](https://img.shields.io/badge/secrets-no--logging-critical)](#)
[![Dry Run](https://img.shields.io/badge/dry%20run-supported-success)](https://github.com/Inetum-Poland/jamf-recovery-lock-rotation?tab=readme-ov-file#dry-run-rotate-recovery-lock-dry-run)
[![GitHub Release](https://img.shields.io/github/v/release/Inetum-Poland/jamf-recovery-lock-rotation)](https://github.com/Inetum-Poland/jamf-recovery-lock-rotation/releases)

**Composite GitHub Action for rotating Recovery Lock passphrases on Jamf Pro–managed Apple Silicon Mac computers via the Jamf Pro API.**  
Passphrases are generated from bundled or custom wordlists. Credentials are never logged.

## About

**Recovery Lock** secures the macOS Recovery environment on Apple Silicon devices. Regular rotation of these passphrases reduces exposure risk if a credential is compromised.

This action:

- authenticates to Jamf Pro using **OAuth client credentials** (`JAMF_CLIENT_ID` / `JAMF_CLIENT_SECRET`),
- retrieves device Management IDs from Jamf Pro inventory, with optional scoping via a **Smart Computer Group**,
- issues the **`SET_RECOVERY_LOCK`** MDM command,
- exposes **`rotated_count`** and **`failed_count`** outputs for downstream workflow steps or reporting.

The runner executes **`recovery-lock-rotation.sh`** with **zsh** (installed automatically on `ubuntu-latest` if needed), enabling consistent execution and local testing on macOS.

### Potential use cases

- Scheduled rotation (e.g. monthly or quarterly) across all enrolled Mac computers with valid Jamf Pro Management IDs  
- Targeted rotation for a specific Smart Computer Group (e.g. “All Managed Computers” or “Recovery Lock Rotation Group”)  
- **Dry-run workflows** to validate API roles, group scoping, and inventory without sending MDM commands  
- Conditional pipelines that branch on **`failed_count`** (e.g. trigger alerts if any device fails)

### Jamf Pro requirements

- **API client / role** with the following privileges:
  - Read Computers  
  - Read Smart Computer Groups  
  - View MDM command information in Jamf Pro API
- **Jamf Pro instance URL** (trailing slash optional, normalized internally)

> [!IMPORTANT]  
> Secrets **`JAMF_CLIENT_ID`** and **`JAMF_CLIENT_SECRET`** are **not** Action inputs: set them on the **job** or **step** `env` (typically sourced from repository secrets).

## Usage

Add a workflow job that sets the Jamf API Client environment variables, then invoke this Action with at least **`jamf_url`**.
> [!NOTE]  
> No `actions/checkout` is required **unless** you use **`wordlist_path`** to point at a file in your own repository.

```yaml
jobs:
  rotate-recovery-lock:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    env:
      JAMF_CLIENT_ID: ${{ secrets.JAMF_CLIENT_ID }}
      JAMF_CLIENT_SECRET: ${{ secrets.JAMF_CLIENT_SECRET }}
    steps:
      - uses: Inetum-Poland/jamf-recovery-lock-rotation@v1
        id: jamf_recovery_lock_rotation
        with:
          jamf_url: ${{ vars.JAMF_URL }}
```
> Where `v1` or `vX.X.X` is the tag or SHA you pin to.

## Inputs

| Input | Description | Required | Default |
| ----- | ----------- | -------- | ------- |
| `jamf_url` | Jamf Pro base URL (e.g. `https://example.jamfcloud.com`). | **yes** | — |
| `rotation_scope` | `all` = every computer with a **managementId** in inventory, or the **exact** smart computer group **name** for a scoped run. | no | `all` |
| `dry_run` | If `true`, logs intended work but does **not** call the MDM commands API. | no | `false` |
| `show_passwords_in_dry_run` | With `dry_run: true`, logs generated passphrases at WARN (sensitive). Ignored when `dry_run` is not `true`. | no | `false` |
| `log_level` | One of: `debug`, `info`, `warn`, `error`. | no | `info` |
| `wordlist` | Bundled list **relative to the action root**, e.g. `wordlists/eff_short_wordlist_1.txt`. Ignored if `wordlist_path` is set. | no | *(empty)* |
| `wordlist_path` | **Absolute** path on the runner (use after `actions/checkout`, e.g. `${{ github.workspace }}/path/to/list.txt`). Overrides `wordlist`. | no | *(empty)* |
| `word_count` | Number of random words per passphrase. | no | `4` |
| `delimiter` | Joins words in the passphrase. | no | `-` |
| `inventory_id_batch_size` | Batch size for `id=in=(…)` when resolving smart-group members against v3 inventory. | no | `80` |

### About secrets and `jamf_url`

- **`JAMF_CLIENT_ID`** and **`JAMF_CLIENT_SECRET`**: define on **`env`** at job or step level (for example `secrets.JAMF_CLIENT_ID`). They are intentionally **not** Action inputs.
- **`jamf_url`**: often stored as a repository **variable** (`vars.JAMF_URL`) since it is usually non-secret.

### About `wordlist` vs `wordlist_path`

- **`github.action_path`** exists only **inside** the composite Action. Callers cannot build paths to bundled files from `with:` alone. Use **`wordlist`** for any file shipped with this Action (e.g. `wordlists/eff_large_wordlist.txt`).
- Use **`wordlist_path`** with **`${{ github.workspace }}/…`** after **`actions/checkout`** for a list stored in **your** repo.

If both `wordlist` and `wordlist_path` are empty, the script default applies (**bundled** `wordlists/eff_large_wordlist.txt` next to the script).

## Outputs

| Output | Description |
| ------ | ----------- |
| `rotated_count` | Devices for which rotation succeeded (or would succeed in dry run). |
| `failed_count` | Devices skipped or failed (partial failures still produce a non-zero count). |

The underlying script exits with **`1`** (configuration), **`2`** (hard API/auth failure), or **`3`** (partial failure: some devices failed, some succeeded).

## Examples

These mirror the repository workflows [`examples/workflows/rotate-recovery-lock-scheduled.yml`](examples/workflows/rotate-recovery-lock-scheduled.yml), [`examples/workflows/rotate-recovery-lock-manual.yml`](examples/workflows/rotate-recovery-lock-manual.yml) and [`examples/workflows/rotate-recovery-lock-dry-run.yml`](examples/workflows/rotate-recovery-lock-dry-run.yml).

### Scheduled rotation + manual run (`Rotate Recovery Lock`)

```yaml
name: Rotate Recovery Lock

on:
  schedule:
    - cron: '0 2 1 * *'   # 02:00 UTC on the 1st of each month
  workflow_dispatch:

jobs:
  rotate-recovery-lock:
    name: Rotate Recovery Lock
    runs-on: ubuntu-latest
    timeout-minutes: 30
    env:
      JAMF_CLIENT_ID: ${{ secrets.JAMF_CLIENT_ID }}
      JAMF_CLIENT_SECRET: ${{ secrets.JAMF_CLIENT_SECRET }}
    steps:
      - name: Run Jamf Recovery Lock Rotation
        id: jamf_recovery_lock_rotation
        uses: Inetum-Poland/jamf-recovery-lock-rotation@v1
        with:
          jamf_url: ${{ vars.JAMF_URL }}
          rotation_scope: ${{ vars.ROTATION_SCOPE }}
          # dry_run: 'true'

      - name: Report counts
        shell: bash
        run: |
          echo "rotated_count=${{ steps.jamf_recovery_lock_rotation.outputs.rotated_count }}"
          echo "failed_count=${{ steps.jamf_recovery_lock_rotation.outputs.failed_count }}"
```

### Last day of each quarter (alternative `cron`)

GitHub Actions `schedule` uses **UTC**. The last calendar day of each quarter is Mar 31, Jun 30, Sep 30, and Dec 31. Standard five-field cron cannot express “last day of month” in one line, so use **two** entries: one for months that end on the 30th, one for months that end on the 31st.

```yaml
on:
  schedule:
    # 02:00 UTC on the last day of each quarter
    - cron: '0 2 30 6,9 *'   # Jun 30, Sep 30
    - cron: '0 2 31 3,12 *'  # Mar 31, Dec 31
  workflow_dispatch:
```

Combine with the same `jobs:` block as in the example above (`rotate-recovery-lock` job and steps).

### Dry run (`Rotate Recovery Lock (Dry Run)`)

Same job and step **`id`** as above; workflow file: `rotate-recovery-lock-dry-run.yml`. Uses repository variables for toggles:

```yaml
name: Rotate Recovery Lock (Dry Run)

on:
  workflow_dispatch:

jobs:
  rotate-recovery-lock:
    name: Rotate Recovery Lock (Dry Run)
    runs-on: ubuntu-latest
    timeout-minutes: 30
    env:
      JAMF_CLIENT_ID: ${{ secrets.JAMF_CLIENT_ID }}
      JAMF_CLIENT_SECRET: ${{ secrets.JAMF_CLIENT_SECRET }}
    steps:
      - name: Run Jamf Recovery Lock Rotation
        id: jamf_recovery_lock_rotation
        uses: Inetum-Poland/jamf-recovery-lock-rotation@v1
        with:
          jamf_url: ${{ vars.JAMF_URL }}
          rotation_scope: ${{ vars.ROTATION_SCOPE }}
          dry_run: 'true'
          show_passwords_in_dry_run: ${{ vars.SHOW_PASSWORDS_IN_DRY_RUN }}
          log_level: ${{ vars.LOG_LEVEL }}

      - name: Report counts
        shell: bash
        run: |
          echo "rotated_count=${{ steps.jamf_recovery_lock_rotation.outputs.rotated_count }}"
          echo "failed_count=${{ steps.jamf_recovery_lock_rotation.outputs.failed_count }}"
```

### Smart computer group scope

Use `rotation_scope` with the exact smart group name (or drive it from `vars.ROTATION_SCOPE` as in the workflows above).

### Bundled wordlist other than the default

```yaml
        with:
          jamf_url: ${{ vars.JAMF_URL }}
          wordlist: wordlists/eff_short_wordlist_1.txt
```

### Custom wordlist from the caller repository

```yaml
    steps:
      - uses: actions/checkout@v6

      - name: Run Jamf Recovery Lock Rotation
        id: jamf_recovery_lock_rotation
        uses: Inetum-Poland/jamf-recovery-lock-rotation@v1
        with:
          jamf_url: ${{ vars.JAMF_URL }}
          wordlist_path: ${{ github.workspace }}/security/recovery-lock-wordlist.txt
```

---

## Contribution

Contributions are welcome! To contribute, [create a fork](https://github.com/Inetum-Poland/jamf-recovery-lock-rotation/fork) of this repository, commit and push changes to a branch of your fork, and then submit a [pull request](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/proposing-changes-to-your-work-with-pull-requests/creating-a-pull-request). Your changes will be reviewed by a project maintainer.

Contributions don’t have to be code; we appreciate any help in answering [issues](https://github.com/Inetum-Poland/jamf-recovery-lock-rotation/issues).

---

## Credits

Jamf Recovery Lock Rotation was created by the **Apple Business Unit** at **Inetum Polska Sp. z o.o.**

Jamf Recovery Lock Rotation is licensed under the [Apache License, version 2.0](https://www.apache.org/licenses/LICENSE-2.0).
