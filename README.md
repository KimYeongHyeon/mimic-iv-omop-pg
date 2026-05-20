# mimic-iv-omop-pg

End-to-end MIMIC-IV → OMOP CDM v5.3.1 conversion on PostgreSQL,
without BigQuery, without R, without restarting your existing OHDSI stack.

Single command: `./run.sh`

---

## What this is

- A working Postgres port of the OHDSI/MIMIC ETL (which is officially BigQuery-only).
- Lives on top of an **existing** OHDSI Broadsea stack — no rebuild required.
- Reuses your already-loaded Athena vocabulary (6.3M concepts) via views — no re-download.
- Idempotent: every step has a `.done` marker, safe to re-run.

## What you get

A new schema `mimiciv_cdm` in your Broadsea Postgres that ATLAS can register as
a source. Contents (260K patient subset of MIMIC-IV 2.2):

| Table | Rows | % concept_id > 0 |
|---|---:|---:|
| person | 259,770 | — |
| visit_occurrence | 2,344,230 | — |
| condition_occurrence | 10,123,189 | 100% |
| procedure_occurrence | 7,052,156 | 100% |
| drug_exposure | 15,453,515 | 96.77% |
| measurement | 220,589,620 | 94.15% |
| observation | 11,114,883 | 100% |
| device_exposure | 1,749,219 | 100% |
| death | 8,592 | — |
| concept (vocab view) | 6,328,777 + 5,093 custom | — |

---

## Requirements

- An **already-running OHDSI Broadsea** stack (`broadsea-atlasdb` + `ohdsi-webapi` + `ohdsi-atlas` containers).
- Athena vocabulary (Standardized Vocabularies bundle from athena.ohdsi.org) already loaded into a Postgres schema in the same `broadsea-atlasdb` database. The script reads it through the `VOCAB_SOURCE_SCHEMA` env var; the placeholder default `omop_vocab` is rarely correct for your install — point it at whatever schema you actually loaded into.
- PhysioNet credentialed access to MIMIC-IV 2.2 (you download `MIMIC-IV-2.2.zip` yourself).
- Disk: ~250 GB free.
- ~5 hours total ETL time.

No host psql client needed — we use a sidecar `postgres:16-alpine` container.

---

## Quick start

```bash
# 1. Download MIMIC-IV 2.2 from PhysioNet (requires credentialed access)
#    https://physionet.org/content/mimiciv/2.2/
#    Place MIMIC-IV-2.2.zip in this directory.

# 2. (optional) override defaults
export ATLASDB_CONTAINER=broadsea-atlasdb     # default
export ATLASDB_USER=postgres
export ATLASDB_PASS=mypass
export ATLASDB_DB=ohdsi
export VOCAB_SOURCE_SCHEMA=omop_vocab    # REQUIRED: replace with the actual schema name where you loaded Athena vocab

# 3. Run everything (idempotent; ~5 hours)
./run.sh

# 4. After m6 finishes, register the source in WebAPI
#    (see docs/WEBAPI_REGISTER.md). One-time, ~30 seconds.
```

## Phase-by-phase

```bash
./run.sh m0    # prerequisite check
./run.sh m1    # ~30 min, load raw MIMIC-IV into mimiciv_hosp/icu/note
./run.sh m2    # ~30 sec, port BQ SQL → Postgres
./run.sh m3    # ~10 sec, create mimiciv_voc/etl/cdm schemas + DDL
./run.sh m4    # ~30 sec, load custom MIMIC vocabulary (gcpt_*)
./run.sh m5    # ~3 h, run full ETL chain
./run.sh m6    # ~5 sec, publish mimiciv_cdm views
./run.sh m7    # ~30 sec, verification report
./run.sh m8    # ~10 sec, init results schema (ATLAS cohort/profile tables)
./run.sh m9    # ~1.5-3 h, run Achilles → enables ATLAS Data Source dashboard
./run.sh m10   # ~2 h, run DataQualityDashboard → ~3,500 quality checks
```

Phases are independent and idempotent. To re-run any single step in m5,
delete its `logs/etl/<step>.done` marker and re-run.

---

## Architecture in one diagram

```
   PhysioNet           Broadsea Postgres
                       ┌────────────────────────────────────────────────┐
   MIMIC-IV-2.2.zip────▶ mimiciv_hosp / icu / note  (raw, 35 tables)    │
                       │                                                │
                       │ $VOCAB_SOURCE_SCHEMA.concept (6.3M Athena)      │
                       │       ↑   (read-only view)                     │
                       │ mimiciv_voc.concept    (view)                  │
                       │                                                │
                       │ mimiciv_custom.concept (5K from gcpt_*.csv)    │
                       │                                                │
                       │ mimiciv_etl.voc_concept (UNION of above)       │
                       │       │                                        │
                       │       ▼                                        │
                       │ mimiciv_etl.src_*, lk_*, cdm_*                 │
                       │       │                                        │
                       │       ▼                                        │
                       │ mimiciv_cdm.* (38 views — what ATLAS sees)     │
                       │ mimiciv_cdm_results (empty, for cohort gen)    │
                       └────────────────────────────────────────────────┘

   ATLAS / WebAPI ◀── source_key=MIMICIV ──── mimiciv_cdm
```

---

## Why PostgreSQL instead of BigQuery

PhysioNet permits BigQuery deployment of MIMIC-IV, and the official OHDSI/MIMIC
pipeline targets BQ. So why a Postgres port?

**Three concrete advantages over BigQuery for OHDSI/MIMIC workloads:**

1. **Zero-shim integration with the Broadsea/ATLAS/WebAPI stack.**
   Broadsea — the de-facto OHDSI deployment — is PostgreSQL-native.
   ATLAS, WebAPI, Achilles, DataQualityDashboard, ARES Indexer all consume
   `mimiciv_cdm` as a first-class data source with no JDBC driver
   installation, no IAM setup, no datasource adapter configuration.

2. **Bit-level reproducibility.**
   Pinned Docker image + Postgres patch version + git commit hash =
   identical results 5 years from now. BigQuery silently upgrades its SQL
   engine; queries that worked yesterday can return different results today
   (BQ Standard SQL semantics have changed multiple times since 2020).
   Important for FAIR-aligned journals (Scientific Data, GigaScience) and
   any reproducibility-conscious research.

3. **Operational fit with existing institutional infrastructure.**
   Local development without internet · pgAdmin/DBeaver/psql tooling ·
   user-controlled indexing (btree/gin/gist) · PITR via WAL · pgaudit for
   compliance logging · `postgres_fdw` to federate with existing hospital
   PG systems (REDCap, i2b2, OMOP from other source EHRs) without data
   movement. None of these are easy on BigQuery.

**A note on data governance:** MIMIC-IV is already de-identified by
PhysioNet via HIPAA Safe Harbor (date shifting, geographic generalization,
free-text scrubbing). Strictly speaking, MIMIC-IV is no longer PHI, so the
HIPAA/PhysioNet rules permit cloud deployment. The governance argument for
on-prem PostgreSQL becomes substantive only when adapting this pipeline to
**your institution's own EHR data** — at which point PHI rules return in
full force and on-prem operation matters.

**When BigQuery is genuinely better:** at TB-PB scale (multi-million-patient
networks like the US VA), for in-database ML via BigQuery ML, or when tight
integration with other GCP services (Looker, Vertex AI) is required. For
MIMIC-IV's 260K patients (~200 GB) and the OHDSI analytic stack, PostgreSQL
is the better fit.

---

## What was hard

The official [OHDSI/MIMIC](https://github.com/OHDSI/MIMIC) ETL is **BigQuery-only**.
Porting required:

- **BQ→PG SQL converter** ([`scripts/bq_to_pg.py`](scripts/bq_to_pg.py)) — 16 mechanical
  patterns (CREATE OR REPLACE TABLE, FARM_FINGERPRINT, TO_JSON_STRING, IF→CASE,
  DATE_ADD, INT64/STRING types, etc.). 92% of the 39 SQL files convert
  automatically.
- **5 manual patches** ([`patches/`](patches/)) for non-mechanical issues
  (dead-code CTAS, GROUP BY alias collision, CHAR(5) inference, reserved
  words). Each is a small `.patch` file applied automatically by `m2`.
- **Custom vocabulary load** — chartevents itemids and other MIMIC-specific codes
  live in `custom_mapping_csv/` (1,670 entries). `m4` loads them so measurement
  mapping reaches 100%.
- **Worktree-friendly orchestration** — sidecar `postgres:16-alpine`
  containers (no host psql, no Broadsea downtime), per-script `.done` markers
  for safe interrupt+resume, no host filesystem mounts into broadsea-atlasdb.

Full details: [docs/CONVERSION_PATTERNS.md](docs/CONVERSION_PATTERNS.md).

---

## Verification

Full reports:
- **[docs/VERIFICATION.md](docs/VERIFICATION.md)** — what we tested, how, what we did **not** test.
- **[docs/DQD_RESULTS.md](docs/DQD_RESULTS.md)** — DataQualityDashboard demo (100 pts, 85 failures) **and** full (260K pts, 93 failures, 92 post-Group-E-fix) runs with root-cause analysis. Zero failures originate in our port code.

Short version: ran `./run.sh m7` plus a separate demo-subset run, then ran
[OHDSI's own unit-test suite](https://github.com/MIT-LCP/mimic-iv-demo-omop/tree/master/test/ut)
against our output:

| Check | Pass criterion | Result |
|---|---|---|
| Structural | 38 views in mimiciv_cdm | **38 / 38** |
| Source row counts | match PhysioNet published values | **all match** |
| Cardinality | person ≥ 250K, measurement ≥ 100M | **PASS** |
| Mapping quality | ≥ 50 % concept_id > 0 per domain | **94-100 %** all domains |
| Referential integrity | 0 FK orphans | **0** |
| Date sanity | 0 visit_end < visit_start | **0** |
| OHDSI unit tests | extracted from MIT-LCP/mimic-iv-demo-omop | **24 / 24** PASS on valid SQL |
| Source → CDM conservation | type_concept_id provenance check | **6 / 6** plausible |

### What this does NOT prove

- **Row-identical to BigQuery output is NOT verified**. That requires GCP
  execution; see [docs/VERIFICATION.md §L1](docs/VERIFICATION.md). Some
  fields (`*_id` from FARM_FINGERPRINT vs md5, `trace_id` JSON key order)
  will inherently differ even with bit-perfect logic.
- **DataQualityDashboard full sweep (1,990 checks)** — both runs complete:
  demo (100 pts, 17 min) at 93.5 % pass on applicable checks; full
  (260K pts, 6 h 38 min) at 93.77 % pre-fix / **93.84 % after Group E ETL gap
  resolved**. Of 93 full-run failures, 92 are inherited limitations (MIMIC
  date shift, OHDSI 64-bit IDs, custom-vocab long tail, MIMIC source coding
  artifacts) and 1 was a re-runnable ETL step — all detailed in
  [docs/DQD_RESULTS.md](docs/DQD_RESULTS.md).
- **MIMIC-IV v3.1 NOT supported** (only v2.2).
- **Waveform module stubbed empty**.

The claim is *functional equivalence* to the BigQuery output (same domain
assignments, same conservation laws, passes the same unit tests), not
*bit-identical equivalence*.

---

## Configuration

All knobs are env vars; defaults are for the stock Broadsea deployment:

| Variable | Default | Meaning |
|---|---|---|
| `ATLASDB_CONTAINER` | `broadsea-atlasdb` | Docker name of the Postgres container |
| `ATLASDB_NETWORK` | `broadsea_default` | Docker network for sidecar |
| `ATLASDB_USER` / `_PASS` / `_DB` | `postgres` / `mypass` / `ohdsi` | DB credentials |
| `VOCAB_SOURCE_SCHEMA` | `omop_vocab` (placeholder) | Schema in `ATLASDB_DB` that already contains the 6.3M Athena Standardized Vocabularies. **Must be overridden** to the actual schema name on your install. |
| `MIMIC_DATA_DIR` | `./data/MIMIC-IV-2.2` | Extracted CSVs (after unzip) |

---

## Limitations / Known issues

- **MIMIC-IV 2.2 only** — the SQL is written against v2.2 schemas. v3.1 has
  different column names (e.g., emar) and would need DDL updates.
- **CDM v5.3.1** — not v5.4. The OHDSI/MIMIC team has not updated to v5.4 yet.
  v5.3.1 is fully supported by ATLAS.
- **Waveform skipped** — we stub `lk_meas_waveform_mapped` as empty. If you
  have MIMIC waveform data, supply the staging tables and remove the stub.
- **person count = 259,770**, ~40K below the 299K in patients.csv. Driven by
  `cdm_finalize_person.sql` which drops persons with zero clinical events
  (typical EHR cleaning).

---

## License & attributions

This repository wraps and adapts several upstream projects. Each component
keeps its original license; the wrapper code in this repo is MIT.

| Component | Origin | License | What we use it for |
|---|---|---|---|
| This wrapper (`run.sh`, `scripts/*`, `bq_to_pg.py`, patches, docs) | this repo | [MIT](LICENSE) | E2E orchestration + BQ→PG conversion |
| ETL SQL & custom mapping CSVs | [OHDSI/MIMIC](https://github.com/OHDSI/MIMIC) (Odysseus Data Services, Inc.) | [Apache 2.0](https://github.com/OHDSI/MIMIC/blob/master/LICENSE) | Source of the BigQuery ETL we port to Postgres |
| MIMIC-IV source schema DDL | [MIT-LCP/mimic-code](https://github.com/MIT-LCP/mimic-code) | [MIT](https://github.com/MIT-LCP/mimic-code/blob/main/LICENSE) | Canonical `mimiciv_hosp`/`icu`/`note` DDL |
| OMOP Common Data Model v5.3.1 | [OHDSI/CommonDataModel](https://github.com/OHDSI/CommonDataModel) | [Apache 2.0](https://github.com/OHDSI/CommonDataModel/blob/main/LICENSE) | Target schema standard |
| Athena standard vocabulary | [athena.ohdsi.org](https://athena.ohdsi.org) | [OHDSI Vocabulary License](https://athena.ohdsi.org/vocabulary/list) | 6.3M standard concepts (loaded separately) |
| OHDSI Broadsea stack | [OHDSI/Broadsea](https://github.com/OHDSI/Broadsea) | [Apache 2.0](https://github.com/OHDSI/Broadsea/blob/main/LICENSE) | Postgres + WebAPI + ATLAS host environment |
| ATLAS UI | [OHDSI/Atlas](https://github.com/OHDSI/Atlas) | [Apache 2.0](https://github.com/OHDSI/Atlas/blob/main/LICENSE) | Cohort/analytics interface for the published CDM |
| WebAPI | [OHDSI/WebAPI](https://github.com/OHDSI/WebAPI) | [Apache 2.0](https://github.com/OHDSI/WebAPI/blob/master/LICENSE) | Source registration backend |
| DataQualityDashboard (suggested) | [OHDSI/DataQualityDashboard](https://github.com/OHDSI/DataQualityDashboard) | [Apache 2.0](https://github.com/OHDSI/DataQualityDashboard/blob/main/LICENSE) | Exhaustive CDM validation (3,500+ checks) |
| Achilles (suggested) | [OHDSI/Achilles](https://github.com/OHDSI/Achilles) | [Apache 2.0](https://github.com/OHDSI/Achilles/blob/main/LICENSE) | Characterization for the ATLAS data-source dashboard |
| PostgreSQL | [postgresql.org](https://www.postgresql.org/) | [PostgreSQL License](https://www.postgresql.org/about/licence/) | Runtime database (Postgres 16) |
| Docker | [docker.com](https://www.docker.com/) | [Apache 2.0](https://github.com/moby/moby/blob/master/LICENSE) | Sidecar containers + Broadsea hosting |

### Data — important

The **MIMIC-IV** dataset itself is **NOT redistributed** here.
It is available only via PhysioNet credentialed access:
[https://physionet.org/content/mimiciv/2.2/](https://physionet.org/content/mimiciv/2.2/)

Loading and analyzing MIMIC-IV requires:
1. Completion of the [CITI Data or Specimens Only Research course](https://physionet.org/about/citi-course/)
2. Signed [PhysioNet Credentialed Health Data Use Agreement](https://physionet.org/content/mimiciv/view-dua/2.2/)
3. Acceptance of the MIMIC-IV Data Use Agreement specifically

If you publish work using MIMIC-IV, cite:
> Johnson, A., Bulgarelli, L., Pollard, T., Horng, S., Celi, L. A., & Mark, R. (2023). MIMIC-IV (version 2.2). PhysioNet. https://doi.org/10.13026/6mm1-ek67
