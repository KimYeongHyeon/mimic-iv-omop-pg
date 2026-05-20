# Manual SQL patches

Three issues in the OHDSI/MIMIC ETL aren't suitable for regex-based BQ→PG
conversion. They're applied by `./run.sh m2` (the m2_port_sql phase) after the
automatic conversion.

| File | Patch reason |
|---|---|
| `01_st_hosp_dead_code.patch`           | Dead-code `CREATE TABLE … AS` without SELECT body |
| `02_lk_meas_chartevents_groupby.patch` | GROUP BY alias collides with real column name |
| `03_lk_procedure_char5.patch`          | CTAS inherits CHAR(5) constraint causing later INSERT overflow |
| `04_offset_reserved_word.patch`        | `offset` column needs double-quoting in cdm_note_nlp |
| `05_current_date_parens.patch`         | `CURRENT_DATE()` → `CURRENT_DATE` in cdm_cdm_source |

See `docs/CONVERSION_PATTERNS.md` for full details.
