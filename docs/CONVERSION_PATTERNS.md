# BigQuery → PostgreSQL SQL Conversion Patterns

Detailed catalog of every pattern transformed by `scripts/bq_to_pg.py` for the
OHDSI/MIMIC ETL. Each entry shows the BigQuery original, the Postgres
replacement, and the rationale.

---

## 1. Variable substitution (Jinja-style)

OHDSI/MIMIC uses `@project.@dataset.table` template variables (substituted by
`bq_run_script.py` at runtime). We bypass the Python orchestrator and substitute
directly in Python.

```python
VAR_MAP = {
    "@source_project.@hosp_dataset":  "mimiciv_hosp",
    "@source_project.@icu_dataset":   "mimiciv_icu",
    "@source_project.@note_dataset":  "mimiciv_note",
    "@voc_project.@voc_dataset":      "mimiciv_voc",
    "@etl_project.@etl_dataset":      "mimiciv_etl",
    "@atlas_project.@atlas_dataset":  "mimiciv_cdm",
    ...
}
```

Sorted **longest-first** so longer prefixes win over substrings.

## 2. `CREATE OR REPLACE TABLE` → `DROP` + `CREATE`

PostgreSQL has `CREATE OR REPLACE VIEW`, but **not** for tables. Two forms:

**CTAS form**:
```sql
-- BigQuery
CREATE OR REPLACE TABLE etl.foo AS SELECT … FROM …;

-- Postgres
DROP TABLE IF EXISTS etl.foo CASCADE;
CREATE TABLE etl.foo AS SELECT … FROM …;
```

**Column-list DDL form**:
```sql
-- BigQuery
CREATE OR REPLACE TABLE etl.foo (a INT64, b STRING);

-- Postgres
DROP TABLE IF EXISTS etl.foo CASCADE;
CREATE TABLE etl.foo (a BIGINT, b TEXT);
```

## 3. Type names

| BigQuery | Postgres |
|---|---|
| `INT64` | `BIGINT` |
| `FLOAT64` | `DOUBLE PRECISION` |
| `BIGNUMERIC` | `NUMERIC` |
| `STRING` | `TEXT` |
| `BYTES` | `BYTEA` |
| `BOOL` | `BOOLEAN` |
| `DATETIME` | `TIMESTAMP` (without time zone) |
| `GEOGRAPHY` | `TEXT` (no PostGIS) |
| `JSON` | `JSONB` |
| `DATE`, `TIMESTAMP`, `TIME`, `NUMERIC` | same |

## 4. `FARM_FINGERPRINT(GENERATE_UUID())` — bigint hash of UUID

BigQuery's `GENERATE_UUID()` returns a string UUID, and `FARM_FINGERPRINT(x)`
returns a SIGNED int64 hash. Together they produce a unique bigint per row.

```sql
-- BigQuery
FARM_FINGERPRINT(GENERATE_UUID())

-- Postgres (requires pgcrypto extension)
(('x' || substr(md5(gen_random_uuid()::text),1,16))::bit(64)::bigint)
```

Mechanism: take first 16 hex chars of MD5 of a v4 UUID (64 bits), cast to
`bit(64)`, then cast to `bigint` (signed). Distribution properties differ from
FarmHash slightly but uniqueness for the row-id purpose is preserved.

## 5. `TO_JSON_STRING(STRUCT(...))` → `jsonb_build_object`

```sql
-- BigQuery
TO_JSON_STRING(STRUCT(
    subject_id AS subject_id,
    charttime AS charttime
))

-- Postgres
(jsonb_build_object('subject_id', subject_id, 'charttime', charttime)::text)
```

The converter parses the inner STRUCT(...) by balanced-paren tracking, splits
on top-level commas, parses each `expr AS alias` to produce key/value pairs.

## 6. `IF(cond, then, else)` → `CASE WHEN ... END`

BigQuery's `IF` is a 3-arg function. Postgres has no equivalent.

```sql
-- BigQuery
IF(src.value IS NULL, 0, src.value)

-- Postgres
(CASE WHEN src.value IS NULL THEN 0 ELSE src.value END)
```

**Nested IF is iterated to fixed point** (up to 10 passes), since each pass only
rewrites the outermost call:
```sql
IF(IF(a, b, c) IS NOT NULL, d, e)
-- Pass 1
(CASE WHEN IF(a, b, c) IS NOT NULL THEN d ELSE e END)
-- Pass 2
(CASE WHEN (CASE WHEN a THEN b ELSE c END) IS NOT NULL THEN d ELSE e END)
```

## 7. `DATE_ADD` / `DATE_SUB`

```sql
-- BigQuery
DATE_ADD(d, INTERVAL n DAY)
DATE_SUB(d, INTERVAL n MONTH)

-- Postgres
((d) + (n) * INTERVAL '1 day')
((d) - (n) * INTERVAL '1 month')
```

Also handles `DATETIME_ADD/SUB` and `TIMESTAMP_ADD/SUB` identically.

`n` may be an arbitrary expression (`days_supply * (refills + 1)`); the
converter uses balanced-paren parsing to extract it safely.

## 8. `DATE_DIFF`

```sql
-- BigQuery
DATE_DIFF(d1, d2, DAY)
DATE_DIFF(d1, d2, YEAR)
DATE_DIFF(d1, d2, MONTH)

-- Postgres
((d1)::date - (d2)::date)
EXTRACT(YEAR FROM age((d1)::date, (d2)::date))::int
(EXTRACT(YEAR FROM age(d1::date,d2::date))*12 + EXTRACT(MONTH FROM age(d1::date,d2::date)))::int
```

## 9. `PARSE_DATE` / `to_date`

BigQuery uses C-style `%Y-%m-%d` format. PG uses `YYYY-MM-DD`.

```sql
-- BigQuery
PARSE_DATE('%Y-%m-%d', x)

-- Postgres
to_date(x, 'YYYY-MM-DD')
```

Format mapping is hardcoded for the four formats actually used in OHDSI/MIMIC.

## 10. `REGEXP_EXTRACT`

```sql
-- BigQuery
REGEXP_EXTRACT(x, '[0-9]+')

-- Postgres
substring(x from '[0-9]+')
```

PostgreSQL's `substring(x FROM pattern)` uses POSIX ERE by default, which
supports Perl-style backslash classes like `\d`, `\s`, `\w` as PG extensions.

## 11. BigQuery raw string `r'...'`

```sql
-- BigQuery
REGEXP_CONTAINS(x, r'[\d]+[.]?[\d]*')

-- Postgres
substring(x from '[\d]+[.]?[\d]*')
```

The `r` prefix is stripped; `\d`, `\s` work natively in PG regex.

## 12. `CURRENT_DATE()` (parens) → `CURRENT_DATE` (no parens)

BigQuery allows `CURRENT_DATE()`. PostgreSQL requires no parentheses.

```sql
-- BigQuery
CURRENT_DATE(), CURRENT_TIMESTAMP(), CURRENT_DATETIME()

-- Postgres
CURRENT_DATE, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
```

(`CURRENT_DATETIME` doesn't exist in PG; mapped to `CURRENT_TIMESTAMP`.)

## 13. Backtick identifiers

BigQuery quotes identifiers with backticks (` `). Postgres uses double quotes
or none. Since OHDSI/MIMIC backticks are only on table names that we substitute
via VAR_MAP, we just strip them.

```sql
-- BigQuery
SELECT * FROM `project.dataset.table`

-- Postgres
SELECT * FROM mimiciv_hosp.table   -- (after VAR_MAP)
```

## 14. Trailing comma before `FROM`

BigQuery allows `SELECT a, b, c, FROM t`. PG rejects it.

```sql
-- BigQuery
SELECT
    a,
    b,
    c,                            -- trailing comma OK in BQ
FROM t

-- Postgres
SELECT
    a,
    b,
    c                             -- removed
FROM t
```

Regex: `,(\s*(?:--[^\n]*\n\s*)*)\bFROM\b` (handles intervening comments).

## 15. PG reserved word columns

PG reserves `offset`, `limit`, `user`, `order`, `group`, `check`, `all`, `end`.
When used as a column name in CDM (cdm_note_nlp has `offset`), they must be
double-quoted.

```sql
-- BigQuery / CDM DDL (works in BQ)
CREATE TABLE foo (offset TEXT)

-- Postgres
CREATE TABLE foo ("offset" TEXT)
```

The converter quotes these only when they appear at the start of a column
definition followed by a type keyword.

## 16. `SAFE_CAST` — fragile

BigQuery's `SAFE_CAST(x AS NUMERIC)` returns NULL on failure. PG has no direct
equivalent.

Heuristic for numeric SAFE_CAST: strip non-numeric chars, NULLIF empty, then cast.

```sql
-- BigQuery
SAFE_CAST(some_text AS NUMERIC)

-- Postgres (heuristic)
NULLIF(regexp_replace(some_text::text, '[^0-9.\-eE]', '', 'g'), '')::numeric
```

For non-numeric SAFE_CAST, we fall back to plain CAST with a `/*SAFE_CAST*/`
comment, which means rows with bad data will fail rather than null out.
OHDSI/MIMIC uses SAFE_CAST sparingly so this hasn't triggered yet.

---

## Non-mechanical issues (manual patches)

Three issues weren't suitable for regex/AST conversion. They are documented
inline in the affected SQL files with `-- MOAI-PATCH:` markers.

### A. Dead-code CTAS in `st_hosp.sql`

```sql
-- DROP TABLE IF EXISTS mimiciv_etl.src_d_micro CASCADE;
CREATE TABLE mimiciv_etl.src_d_micro AS
-- SELECT ... entire body commented out ...
```

In BigQuery this happens to be a no-op (CTAS without body errors silently in
some pipelines, or the CREATE TABLE just creates an empty table inheriting from
nothing). In PG it parses as `CREATE TABLE … AS DROP …`.

**Fix**: comment the `CREATE TABLE` line too.

### B. GROUP BY alias collision in `lk_meas_chartevents.sql`

```sql
SELECT value AS source_code, value AS source_label, COUNT(*)
FROM lk_chartevents_clean
GROUP BY source_code, source_label  -- "source_code" is also a real column
```

BigQuery prefers SELECT alias when resolving GROUP BY; PG prefers the
underlying column when there's a name collision.

**Fix**: `GROUP BY 2, 3` (positional ordinals).

### C. CTAS column type inheritance in `lk_procedure.sql`

```sql
CREATE TABLE mimiciv_etl.lk_procedure_mapped AS
SELECT … src.hcpcs_cd AS source_code … FROM mimiciv_etl.lk_hcpcsevents_clean src;

INSERT INTO mimiciv_etl.lk_procedure_mapped
SELECT … src.source_code … FROM mimiciv_etl.lk_procedures_icd_clean src;  -- ICD code 7 chars
```

`hcpcs_cd` is `CHAR(5)` (HCPCS codes are exactly 5 chars). PG inherits this
type for `source_code` in the new table. Then INSERT with ICD-10 codes
(`CHAR(7)`) overflows.

**Fix**: `CAST(src.hcpcs_cd AS TEXT) AS source_code` in the first CTAS, widening
the column to TEXT.

---

## Scope: what the converter doesn't do

These BigQuery features are unused in OHDSI/MIMIC and therefore not implemented:
- `ARRAY_AGG`, `UNNEST`, `STRUCT` outside `TO_JSON_STRING`
- `ARRAY<T>`, `STRUCT<T>` types in DDL
- `EXCEPT DISTINCT` (uses BQ's set-op semantics)
- `QUALIFY` clause
- Approximate aggregates (`APPROX_COUNT_DISTINCT`, etc.)
- BigQuery ML functions

If you adapt this converter for another BQ codebase, look for these.

---

## Coverage results on OHDSI/MIMIC

| File category | Files | Auto-converted | Manual patches |
|---|---:|---:|---:|
| `etl/etl/cdm_*.sql` | 21 | 21 | 0 |
| `etl/etl/lk_*.sql` | 11 | 10 | 1 (lk_procedure) |
| `etl/etl/ext_*.sql` | 1 | 1 | 0 |
| `etl/staging/st_*.sql` | 3 | 2 | 1 (st_hosp) |
| `etl/staging/voc_*.sql` | 1 | 0 | 1 (replaced with views) |
| `etl/ddl/*.sql` | 2 | 2 | 0 |
| **Total** | **39** | **36** | **3** |

**92% fully automated.** Plus 1 reserved-word quote fix for `offset` column.
