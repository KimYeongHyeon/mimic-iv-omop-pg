# Related work — other MIMIC-to-OMOP implementations

This project is not the first attempt to bring MIMIC-IV into the OMOP CDM
outside the official BigQuery pipeline. Several community efforts predate
or run in parallel with `mimic-iv-omop-pg`, each with a different design
choice. This document records them honestly so that researchers choosing
a tool have full context.

## At a glance

| Project | Target engine | Source MIMIC | Approach | Status |
|---|---|---|---|---|
| [OHDSI/MIMIC](https://github.com/OHDSI/MIMIC) | BigQuery | MIMIC-IV v2.2 | Official ETL, BQ-native | Upstream reference |
| [kole-geeta/MIMICiv-to-OMOP-in-PostgreSQL](https://github.com/kole-geeta/MIMICiv-to-OMOP-in-PostgreSQL) | PostgreSQL | MIMIC-IV | Hand-converted static SQL fork of OHDSI/MIMIC | Available |
| [CogStack/dbt_mimic_omop](https://github.com/CogStack/dbt_mimic_omop) | DuckDB (dbt) | MIMIC-IV v3.1 (+ CXR) | Modern dbt models, medallion architecture | Available |
| [MIT-LCP/mimic-omop](https://github.com/MIT-LCP/mimic-omop) | PostgreSQL | MIMIC-III | Historical CDM v5 effort | Predecessor |
| **mimic-iv-omop-pg (this repo)** | PostgreSQL | MIMIC-IV v2.2 | Live-converted from OHDSI/MIMIC via `bq_to_pg.py` + 5 patches; full DQD + clinical replication validation | Available |

## Design-choice comparison

| Dimension | mimic-iv-omop-pg | kole-geeta | CogStack/dbt |
|---|---|---|---|
| Conversion strategy | Programmatic (`bq_to_pg.py` 430 LOC + 5 small patches against upstream OHDSI/MIMIC) | Hand-converted static SQL files committed to the repo | dbt models authored fresh against DuckDB |
| Upstream sync | Tracks OHDSI/MIMIC via the bundled submodule; re-runs the converter on upstream changes | Static fork; manual re-convert needed on upstream changes | Independent codebase; does not track OHDSI/MIMIC |
| Orchestration | Single command `./run.sh`, idempotent phases m0–m10, `.done` markers | Run SQL scripts in documented order manually | `dbt run` |
| Broadsea integration | Drops into an existing `broadsea-atlasdb` container; no rebuild | Operates on a separate PostgreSQL database | Local DuckDB; not a multi-user OHDSI deployment |
| Vocabulary loading | Reuses an already-loaded Athena schema via views (no re-download) | Loads Athena into a dedicated schema | dbt seeds |
| Custom MIMIC vocab | 1,670 entries from OHDSI/MIMIC `gcpt_*` CSVs | `tmp_custom_mapping.csv` | dbt seeds |
| OMOP CDM version | v5.3.1 | v5.3.3.1 | OMOP + MI-CDM imaging |
| Validation reported | DQD full sweep (1,990 checks) + 6 clinical cohort replications | Not reported in repo README | Not reported in repo README |
| Documentation | README + VERIFICATION.md + DQD_RESULTS.md + CONVERSION_PATTERNS.md + REPORT.md | README | README |
| License | MIT | (see repo) | (see repo) |

## Output-size observations

For information only — different person filters and different MIMIC
versions produce different cohort sizes. Numbers below come from each
repo's published output (kole-geeta's README table; ours from our run
report).

| Table | mimic-iv-omop-pg | kole-geeta |
|---|---:|---:|
| person | 259,770 | 337,942 |
| visit_occurrence | 2,344,230 | 2,435,481 |
| condition_occurrence | 10,123,189 | 10,816,850 |
| measurement | 220,589,620 | 208,106,453 |
| drug_exposure | 15,453,515 | 17,045,781 |

The ~30 % person-count difference reflects different ETL choices about
which patients to retain (e.g., persons with zero clinical events). A
comparative validation study analyzing the impact of this choice on
downstream cohort definitions is on our roadmap.

## Where each project fits best

- **OHDSI/MIMIC (BigQuery)** — when an organization already runs on GCP
  and wants the most upstream-aligned implementation.
- **kole-geeta/MIMICiv-to-OMOP-in-PostgreSQL** — when a researcher
  wants a hand-readable static PostgreSQL SQL set they can audit
  end-to-end without a converter step.
- **CogStack/dbt_mimic_omop** — when the analytic environment is
  DuckDB-based or when MIMIC-CXR imaging is in scope.
- **MIT-LCP/mimic-omop** — when working with MIMIC-III (predecessor
  dataset; the current project does not cover v2.2/v3.x).
- **mimic-iv-omop-pg (this project)** — when an existing OHDSI Broadsea
  stack should host MIMIC-IV with the lowest deployment friction,
  upstream-tracking behavior, and reported validation against DQD
  and clinical literature.

## What we explicitly do not claim

- We are not the first PostgreSQL implementation of MIMIC-IV → OMOP.
- Output of this project is not bit-identical to OHDSI/MIMIC's
  BigQuery output (different ID hash function; see VERIFICATION.md).
- DQD failure breakdown shows we inherit the same limitations as the
  upstream OHDSI/MIMIC ETL (date shift, 64-bit `person_id`, custom-vocab
  long-tail) plus one re-runnable step we documented and resolved.

## Future comparative work

The validation framework in this repo (DQD + six clinical cohorts)
can be applied to any OMOP CDM build of MIMIC-IV. A natural next
step is a side-by-side validation across the available implementations
listed above. Pull requests that run the same DQD + cohort suite
against alternative CDM builds are welcome.

---

Last updated: 2026-05-21
