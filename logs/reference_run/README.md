# Reference run logs

Captured from an actual end-to-end execution against MIMIC-IV 2.2 on
PostgreSQL 16 (Broadsea container). Passwords have been sanitized
(`mypass` → `<REDACTED>`). Use these as a baseline when troubleshooting your
own run.

## Run profile
- Start: 2026-05-19 19:29
- ETL chain complete: 2026-05-20 10:06 (after one re-run for custom vocab fix)
- Wall clock: ~14 h (includes debug + idle); pure compute ~5 h
- Final DB size: ~280 GB

## What's here

```
phase/                     One file per top-level phase
  01_create.log              mimiciv_hosp/icu/note schema DDL
  02a_stage.log              Small table COPY load (24 tables, ~80 s total)
  02b_stage.log              Large table COPY load (11 tables, chartevents 320 s)
  03_etl_schemas.log         mimiciv_voc/etl/cdm schema + views
  04_custom_vocab.log        Custom MIMIC vocab (1,670 mappings)
  04_ddl.log                 CDM v5.3.1 DDL applied
  06_publish.log             mimiciv_cdm views published
  convert.log                bq_to_pg.py converter output
  etl_run.log                Initial ETL chain run
  etl_rerun.log              ETL re-run after custom vocab fix
  unzip.log                  MIMIC-IV-2.2.zip extraction

etl/                       Per-script ETL logs
  _summary.log               One line per script: time | OK/FAIL | duration
  cdm_*.log                  Each CDM table population step
  lk_*.log                   Each lookup/code-mapping step
  ext_*.log                  Extension tables

load/                      Per-table raw COPY logs
  mimiciv_*_*.log            Each .csv.gz load (timing, row count)
  mimiciv_*_*.done           Marker files indicating successful completion
```

## Key timings observed

| Step | Duration | Notes |
|---|---:|---|
| MIMIC-IV unzip | 5 min | 9.6 GB zip → ~9 GB extracted |
| Small table COPY (24 tables) | 80 s | Includes diagnoses_icd 4.7M, omr 7.7M |
| Large table COPY (11 tables) | 16 min | chartevents 313M rows in 320 s |
| st_hosp.sql (src_* CTAS) | 6.3 min | 22 src_* tables incl src_labevents 118M |
| st_icu.sql | 17 min | src_chartevents 313M with json+uuid |
| lk_meas_chartevents.sql | 31 min | Heaviest; 312M code mapping |
| cdm_measurement.sql | 5.5 min | 220M rows from 4 lk_* tables |
| Total ETL chain | ~3 h | 36 SQL steps |

## How to use these for debugging

1. **First failure?** Check `phase/etl_run.log` for the first FAIL line, then read the corresponding `etl/<script>.log` for the SQL error.
2. **Cardinality off?** Compare `load/<table>.log` row counts against PhysioNet's published v2.2 numbers (in repo README).
3. **Mapping low?** Look at `etl/lk_*_concept.log` — these are where source codes meet vocabulary JOINs.

## ETL chain summary (from etl/_summary.log)

The summary log captures every step. Failures from the first pass appear with `FAIL`,
followed by re-runs with `OK`. This is normal; `.done` markers prevent re-execution
of successful steps, so re-running picks up exactly where it stopped.

A clean run from scratch (no prior `.done` markers) would show only `OK` lines.
