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

---

## Code-level comparison appendix (added after detailed code audit)

To inform users and reviewers more precisely, this section documents
concrete implementation differences observed when reading the actual
SQL of kole-geeta vs the live-converted SQL produced by our
`bq_to_pg.py` against OHDSI/MIMIC.

All three projects share the same fundamental shape (the OHDSI/MIMIC
ETL stages: vocabulary refresh → DDL → staging → ETL → unload). The
differences below are local implementation choices.

### A. ID generation strategy

| Property | mimic-iv-omop-pg | kole-geeta |
|---|---|---|
| `person_id` source | `('x' \|\| substr(md5(gen_random_uuid()::text),1,16))::bit(64)::bigint` | `('x' \|\| substr(md5(random()::text),1,8))::bit(32)::int` |
| Width | 64-bit signed | 32-bit signed |
| Randomness source | `gen_random_uuid()` (pgcrypto, 122-bit entropy) | `random()` (53-bit double) |
| Collision probability at 260K persons | < 1e-12 | ~6e-3 (birthday paradox on 32-bit) |
| Declared column type | `BIGINT` | `INTEGER` |
| CDM v5.3 spec column type | `INTEGER` (32-bit) | `INTEGER` (32-bit) |

Both projects depart from the CDM v5.3 spec but in opposite directions.
kole-geeta's declared type matches the spec while values can in
principle collide; this project's wider hash avoids collisions at the
cost of declaring a wider type. Either approach is documented as a
"known issue" by the upstream OHDSI/MIMIC team for the BigQuery
implementation (`FARM_FINGERPRINT(GENERATE_UUID())` produces signed
64-bit values).

### B. `year_of_birth` derivation

For each patient, MIMIC-IV provides `anchor_year` (a reference year for
the patient's clinical timeline) and `anchor_age` (the patient's age at
that anchor year). OMOP's `person.year_of_birth` is the calendar year
of actual birth.

| Project | Formula |
|---|---|
| mimic-iv-omop-pg | `p.anchor_year - p.anchor_age` (matches upstream OHDSI/MIMIC) |
| kole-geeta | `p.anchor_year` (anchor reference year) |

Worked example: a patient with `anchor_age = 80` at `anchor_year = 2125`
yields `year_of_birth = 2045` in this project (and the OHDSI/MIMIC
BigQuery reference) and `year_of_birth = 2125` in kole-geeta. Downstream
analyses that compute age from `year_of_birth` will therefore see a
~80-year offset between the two builds.

### C. `lk_visit_concept` lookup population

Both repos define the same `lk_visit_concept` lookup (admission type /
location / discharge location → standard visit concept). On our
initial full-scale ETL run this table was left empty (`mimiciv_etl.lk_visit_concept`
= 0 rows), which the DQD run surfaced as a `sourceValueCompleteness`
failure (see `DQD_RESULTS.md` Group E). We documented the issue and
fixed it by re-running the lookup-population step. kole-geeta's SQL
populates the same table by the same method, and any user re-running
both should expect the lookup to fill correctly.

### D. Conversion and maintenance strategy

| Aspect | mimic-iv-omop-pg | kole-geeta |
|---|---|---|
| BigQuery → PostgreSQL translation | Programmatic, via `scripts/bq_to_pg.py` (430 LOC) reading the upstream OHDSI/MIMIC SQL on each build | Hand-edited static SQL files committed to the repo |
| Number of mechanical PG patches required | 5 (in `patches/`) | 0 (already hand-resolved) |
| Re-sync on OHDSI/MIMIC upstream change | Re-run `m2`; converter applies known patterns + patches | Manual diff + re-edit |
| Auditability | Diff `bq_to_pg.py` and patches | Diff full SQL tree |

Both approaches are valid. The trade-off is between (a) automated
sync at the cost of trusting a converter, vs (b) hand-readable static
SQL at the cost of upstream drift over time.

### E. Header attribution and traceability

Each SQL file in this project carries a header pointing to the
upstream OHDSI/MIMIC source path it was generated from:

```
-- AUTO-GENERATED by bq_to_pg.py - do not edit manually; edit source then re-convert
-- Original BigQuery SQL: ohdsi-mimic/ohdsi-mimic/etl/etl/cdm_person.sql
```

kole-geeta's SQL files do not retain the upstream attribution
header. This is a stylistic difference but matters for downstream
auditors who want to trace any specific SQL fragment back to the
upstream OHDSI/MIMIC version.

### F. Output cohort size delta

Published in kole-geeta's README and reproduced in our REPORT.md:

| Table | mimic-iv-omop-pg | kole-geeta | Delta |
|---|---:|---:|---:|
| person | 259,770 | 337,942 | +30 % in kole-geeta |
| visit_occurrence | 2,344,230 | 2,435,481 | +4 % |
| condition_occurrence | 10,123,189 | 10,816,850 | +7 % |
| measurement | 220,589,620 | 208,106,453 | −6 % in kole-geeta |
| drug_exposure | 15,453,515 | 17,045,781 | +10 % |

Both projects run `cdm_finalize_person` (filter persons with
`observation_period`) with byte-identical logic. The remaining person
delta therefore originates earlier — in how `cdm_observation_period`
itself is populated, or in the initial `cdm_person` filter. A focused
diff of those two files would resolve the ~78 K person-count
difference; a comparative validation study is planned.

### G. Validation reported

| Validation activity | mimic-iv-omop-pg | kole-geeta |
|---|---|---|
| DQD full sweep on output CDM | reported (1,990 checks, see `DQD_RESULTS.md`) | not reported in repo |
| Clinical cohort replication | reported (6 cohorts, see `docs/REPORT.md` in companion repo) | not reported in repo |
| OHDSI unit tests | reported (24/24 in `VERIFICATION.md`) | not reported in repo |

This is the most operationally significant difference today, but it
is a reporting / artifact difference rather than a code defect in
kole-geeta — they may well have validated locally and not published
the artifacts.

---

## What this comparison is, and isn't

This section is observational. It records what we read in the public
repos as of 2026-05-21 with the goal of helping researchers choose
the right tool and helping reviewers understand our specific
contribution. It is not a benchmark or a head-to-head bake-off, and
it does not adjudicate which project is "better" — each addresses a
different design objective.

A formal side-by-side validation, running both builds on the same
Broadsea Postgres and applying the same DQD + clinical-cohort
framework to each, is the natural next step and is on our roadmap.
