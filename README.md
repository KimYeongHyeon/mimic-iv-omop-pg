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
- Athena vocabulary loaded into some schema (default: `synthea_cdm_aristotle.*` — set `VOCAB_SOURCE_SCHEMA` to override).
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
export VOCAB_SOURCE_SCHEMA=synthea_cdm_aristotle

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
                       │ synthea_cdm_aristotle.concept (6.3M Athena)    │
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

After `./run.sh m7`:

| Check | Pass criterion | Result |
|---|---|---|
| Structural | 38 views in mimiciv_cdm | PASS 38/38 |
| Cardinality | person ≥ 250K, measurement ≥ 100M | PASS |
| Mapping quality | ≥ 50% concept_id > 0 per domain | PASS all domains |
| Referential integrity | 0 FK orphans | PASS |
| Date sanity | 0 visit_end < visit_start | PASS |

For exhaustive validation, point [DataQualityDashboard](https://github.com/OHDSI/DataQualityDashboard)
at `mimiciv_cdm` schema. ~3,500 checks, ~2-3 hours.

---

## Configuration

All knobs are env vars; defaults are for the stock Broadsea deployment:

| Variable | Default | Meaning |
|---|---|---|
| `ATLASDB_CONTAINER` | `broadsea-atlasdb` | Docker name of the Postgres container |
| `ATLASDB_NETWORK` | `broadsea_default` | Docker network for sidecar |
| `ATLASDB_USER` / `_PASS` / `_DB` | `postgres` / `mypass` / `ohdsi` | DB credentials |
| `VOCAB_SOURCE_SCHEMA` | `synthea_cdm_aristotle` | Where Athena vocab already lives |
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
