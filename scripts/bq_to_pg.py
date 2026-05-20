#!/usr/bin/env python3
"""BigQuery SQL -> PostgreSQL SQL converter for OHDSI/MIMIC ETL.

Handles the 7 patterns observed in the OHDSI/MIMIC repo:
  CREATE OR REPLACE TABLE   (230)  -> DROP TABLE IF EXISTS; CREATE TABLE
  FARM_FINGERPRINT(GENERATE_UUID())  (63 pairs)  -> bigint hash of gen_random_uuid()
  TO_JSON_STRING(STRUCT(...))         (35)  -> jsonb_build_object(...)::text
  REGEXP_EXTRACT                       (7)  -> substring(x from pattern)
  PARSE_DATE                           (6)  -> to_date
  DATE_DIFF                            (2)  -> (d1::date - d2::date)
  @project.@dataset.table                    -> mapped via VAR_MAP

Usage:
  ./bq_to_pg.py <input.sql> <output.sql>
"""
from __future__ import annotations
import re
import sys
from pathlib import Path

# Project/dataset variable -> Postgres schema map
# OHDSI/MIMIC uses jinja-like @var.@var.table; we map to schema.table
VAR_MAP = {
    # source MIMIC-IV raw schemas
    "@source_project.@core_dataset":  "mimiciv_hosp",   # core was merged into hosp
    "@source_project.@hosp_dataset":  "mimiciv_hosp",
    "@source_project.@icu_dataset":   "mimiciv_icu",
    "@source_project.@note_dataset":  "mimiciv_note",
    # vocabulary
    "@voc_project.@voc_dataset":      "mimiciv_voc",    # local view onto Athena
    # ETL intermediates (lk_*, src_*, tmp_*)
    "@etl_project.@etl_dataset":      "mimiciv_etl",
    # waveform (skip; we don't have waveform data)
    "@wf_project.@wf_dataset":        "mimiciv_wf",
    # metrics + atlas target (final CDM)
    "@metrics_project.@metrics_dataset": "mimiciv_cdm",
    "@atlas_project.@atlas_dataset":  "mimiciv_cdm",
}


def replace_vars(sql: str) -> str:
    """Replace @project.@dataset.table -> schema.table"""
    out = sql
    # sort by length desc so longer keys win
    for var, schema in sorted(VAR_MAP.items(), key=lambda kv: -len(kv[0])):
        out = out.replace(var, schema)
    # warn on any leftover @vars
    leftover = re.findall(r"@\w+(?:\.@\w+)?", out)
    if leftover:
        print(f"  warn: unmapped vars: {set(leftover)}", file=sys.stderr)
    return out


def convert_create_or_replace(sql: str) -> str:
    """CREATE OR REPLACE TABLE x AS / ( cols )  ->  DROP TABLE IF EXISTS; CREATE TABLE
    Handles both CTAS (... AS SELECT) and column-list DDL form.
    """
    # CTAS form: CREATE OR REPLACE TABLE x AS
    pat_ctas = re.compile(r"CREATE\s+OR\s+REPLACE\s+TABLE\s+([\w\.\"]+)\s+AS\b", re.IGNORECASE)
    sql = pat_ctas.sub(
        lambda m: f"DROP TABLE IF EXISTS {m.group(1)} CASCADE;\nCREATE TABLE {m.group(1)} AS",
        sql,
    )
    # Column-list form: CREATE OR REPLACE TABLE x (
    pat_cols = re.compile(r"CREATE\s+OR\s+REPLACE\s+TABLE\s+([\w\.\"]+)\s*\(", re.IGNORECASE)
    sql = pat_cols.sub(
        lambda m: f"DROP TABLE IF EXISTS {m.group(1)} CASCADE;\nCREATE TABLE {m.group(1)} (",
        sql,
    )
    return sql


# BigQuery -> Postgres type map (case-insensitive, word boundary)
BQ_TYPE_MAP = {
    "INT64":    "BIGINT",
    "FLOAT64":  "DOUBLE PRECISION",
    "BIGNUMERIC": "NUMERIC",
    "NUMERIC":  "NUMERIC",      # same name
    "STRING":   "TEXT",
    "BYTES":    "BYTEA",
    "BOOL":     "BOOLEAN",
    "DATE":     "DATE",         # same
    "DATETIME": "TIMESTAMP",
    "TIMESTAMP":"TIMESTAMP",    # same
    "TIME":     "TIME",         # same
    "GEOGRAPHY":"TEXT",         # no native geography w/o postgis
    "JSON":     "JSONB",
}


def convert_bq_types(sql: str) -> str:
    """Replace BigQuery type names with Postgres equivalents (word-boundary safe)."""
    out = sql
    for bq, pg in sorted(BQ_TYPE_MAP.items(), key=lambda kv: -len(kv[0])):
        out = re.sub(rf"\b{bq}\b", pg, out, flags=re.IGNORECASE)
    return out


def convert_farm_fingerprint(sql: str) -> str:
    """FARM_FINGERPRINT(GENERATE_UUID()) -> signed bigint hash of uuid

    Postgres equivalent: ('x' || substr(md5(gen_random_uuid()::text),1,16))::bit(64)::bigint
    Requires pgcrypto extension for gen_random_uuid.
    """
    pat = re.compile(
        r"FARM_FINGERPRINT\s*\(\s*GENERATE_UUID\s*\(\s*\)\s*\)",
        re.IGNORECASE,
    )
    repl = "(('x' || substr(md5(gen_random_uuid()::text),1,16))::bit(64)::bigint)"
    return pat.sub(repl, sql)


def convert_to_json_string_struct(sql: str) -> str:
    """TO_JSON_STRING(STRUCT(a AS x, b AS y))  ->  jsonb_build_object('x',a,'y',b)::text

    Parses the STRUCT(...) arglist field by field.
    """
    # Find each TO_JSON_STRING(STRUCT( ... )) block with balanced parens
    out = []
    i = 0
    while i < len(sql):
        m = re.search(r"TO_JSON_STRING\s*\(\s*STRUCT\s*\(", sql[i:], re.IGNORECASE)
        if not m:
            out.append(sql[i:])
            break
        start = i + m.start()
        out.append(sql[i:start])
        # find balanced parens for the STRUCT(...)
        paren_start = i + m.end() - 1  # position of '(' after STRUCT
        depth = 1
        j = paren_start + 1
        while j < len(sql) and depth > 0:
            if sql[j] == '(':
                depth += 1
            elif sql[j] == ')':
                depth -= 1
            j += 1
        struct_body = sql[paren_start + 1: j - 1]  # inside STRUCT(...)
        # match the closing TO_JSON_STRING )
        # skip whitespace, then expect ')'
        k = j
        while k < len(sql) and sql[k].isspace():
            k += 1
        if k >= len(sql) or sql[k] != ')':
            # malformed; emit untouched
            out.append(sql[start:k])
            i = k
            continue
        end_tojs = k + 1  # exclusive
        # parse struct_body fields: comma-separated "expr AS alias"
        fields = split_top_level_commas(struct_body)
        parts = []
        for f in fields:
            mm = re.search(r"(.+?)\s+AS\s+([\w]+)\s*$", f.strip(), re.IGNORECASE | re.DOTALL)
            if mm:
                expr, alias = mm.group(1).strip(), mm.group(2).strip()
                parts.append(f"'{alias}', {expr}")
            else:
                # fallback: use expr text as key
                expr = f.strip()
                parts.append(f"'{expr}', {expr}")
        replacement = "(jsonb_build_object(" + ", ".join(parts) + ")::text)"
        out.append(replacement)
        i = end_tojs
    return "".join(out)


def split_top_level_commas(s: str) -> list[str]:
    depth = 0
    cur = []
    parts = []
    for ch in s:
        if ch in '([':
            depth += 1
        elif ch in ')]':
            depth -= 1
        if ch == ',' and depth == 0:
            parts.append(''.join(cur))
            cur = []
        else:
            cur.append(ch)
    if cur:
        parts.append(''.join(cur))
    return parts


def convert_parse_date(sql: str) -> str:
    """PARSE_DATE('%Y-%m-%d', x) -> to_date(x, 'YYYY-MM-DD')

    Maps common BigQuery format strings to PG/Oracle-style.
    """
    fmt_map = {
        "%Y-%m-%d": "YYYY-MM-DD",
        "%Y/%m/%d": "YYYY/MM/DD",
        "%m/%d/%Y": "MM/DD/YYYY",
        "%Y-%m-%dT%H:%M:%S": "YYYY-MM-DD\"T\"HH24:MI:SS",
    }
    def sub(m):
        fmt_lit, expr = m.group(1), m.group(2).strip()
        pg_fmt = fmt_map.get(fmt_lit, fmt_lit.upper())
        return f"to_date({expr}, '{pg_fmt}')"
    pat = re.compile(r"PARSE_DATE\s*\(\s*'([^']+)'\s*,\s*([^)]+)\)", re.IGNORECASE)
    return pat.sub(sub, sql)


def convert_date_diff(sql: str) -> str:
    """DATE_DIFF(d1, d2, DAY) -> (d1::date - d2::date)
       DATE_DIFF(d1, d2, YEAR) -> EXTRACT(YEAR FROM age(d1::date, d2::date))
    """
    def sub(m):
        d1, d2, unit = [g.strip() for g in (m.group(1), m.group(2), m.group(3))]
        u = unit.upper()
        if u == 'DAY':
            return f"(({d1})::date - ({d2})::date)"
        if u == 'YEAR':
            return f"EXTRACT(YEAR FROM age(({d1})::date, ({d2})::date))::int"
        if u == 'MONTH':
            return f"(EXTRACT(YEAR FROM age(({d1})::date, ({d2})::date))*12 + EXTRACT(MONTH FROM age(({d1})::date, ({d2})::date)))::int"
        return m.group(0)
    pat = re.compile(r"DATE_DIFF\s*\(\s*([^,]+),\s*([^,]+),\s*(\w+)\s*\)", re.IGNORECASE)
    return pat.sub(sub, sql)


def convert_regexp_extract(sql: str) -> str:
    """REGEXP_EXTRACT(x, 'pat') -> substring(x from 'pat')"""
    def sub(m):
        return f"substring({m.group(1).strip()} from {m.group(2).strip()})"
    pat = re.compile(r"REGEXP_EXTRACT\s*\(\s*([^,]+),\s*([^)]+)\)", re.IGNORECASE)
    return pat.sub(sub, sql)


def convert_if_function(sql: str) -> str:
    """IF(cond, then, else) -> (CASE WHEN cond THEN then ELSE else END)

    BigQuery's IF() takes 3 args with balanced parens; commas inside subexpressions
    must not split args, so we parse with depth tracking.
    """
    out = []
    i = 0
    pat = re.compile(r"\bIF\s*\(", re.IGNORECASE)
    while i < len(sql):
        m = pat.search(sql, i)
        if not m:
            out.append(sql[i:])
            break
        # Skip if previous non-space char is a letter/digit/underscore (e.g., NOTIF, ELSIF)
        # The \b in regex already guards, but double-check what precedes
        if m.start() > 0 and sql[m.start() - 1].isalnum():
            out.append(sql[i:m.end()])
            i = m.end()
            continue
        out.append(sql[i:m.start()])
        # find balanced parens
        depth = 1
        j = m.end()
        while j < len(sql) and depth > 0:
            if sql[j] == '(':
                depth += 1
            elif sql[j] == ')':
                depth -= 1
            elif sql[j] == "'":
                # skip string literal
                k = j + 1
                while k < len(sql) and sql[k] != "'":
                    if sql[k] == '\\':
                        k += 2
                    else:
                        k += 1
                j = k
            j += 1
        inner = sql[m.end(): j - 1]
        parts = split_top_level_commas(inner)
        if len(parts) != 3:
            # Not the 3-arg IF; keep untouched
            out.append(sql[m.start(): j])
            i = j
            continue
        cond, thn, els = [p.strip() for p in parts]
        out.append(f"(CASE WHEN {cond} THEN {thn} ELSE {els} END)")
        i = j
    return "".join(out)


def convert_date_add_sub(sql: str) -> str:
    """DATE_ADD(d, INTERVAL N UNIT)  ->  (d + (N) * INTERVAL '1 UNIT')
       DATE_SUB(d, INTERVAL N UNIT)  ->  (d - (N) * INTERVAL '1 UNIT')

    Handles N being an arbitrary expression (may contain nested parens).
    """
    def find_match(sql, func_name, op):
        out = []
        i = 0
        pat = re.compile(rf"{func_name}\s*\(", re.IGNORECASE)
        while i < len(sql):
            m = pat.search(sql, i)
            if not m:
                out.append(sql[i:])
                break
            out.append(sql[i:m.start()])
            # find balanced parens
            depth = 1
            j = m.end()
            while j < len(sql) and depth > 0:
                if sql[j] == '(':
                    depth += 1
                elif sql[j] == ')':
                    depth -= 1
                j += 1
            inner = sql[m.end(): j - 1]  # between ( and )
            # split on top-level commas
            parts = split_top_level_commas(inner)
            if len(parts) != 2:
                # unexpected; emit untouched
                out.append(sql[m.start(): j])
                i = j
                continue
            d_expr = parts[0].strip()
            iv_expr = parts[1].strip()
            # iv_expr is like "INTERVAL ... UNIT"
            iv_m = re.match(r"INTERVAL\s+(.+)\s+(\w+)\s*$", iv_expr, re.IGNORECASE | re.DOTALL)
            if not iv_m:
                out.append(sql[m.start(): j])
                i = j
                continue
            n_expr, unit = iv_m.group(1).strip(), iv_m.group(2).strip().lower()
            # Strip outer parens around N if present and not part of an expression
            replacement = f"(({d_expr}) {op} ({n_expr}) * INTERVAL '1 {unit}')"
            out.append(replacement)
            i = j
        return "".join(out)
    sql = find_match(sql, "DATE_ADD",      "+")
    sql = find_match(sql, "DATE_SUB",      "-")
    sql = find_match(sql, "DATETIME_ADD",  "+")
    sql = find_match(sql, "DATETIME_SUB",  "-")
    sql = find_match(sql, "TIMESTAMP_ADD", "+")
    sql = find_match(sql, "TIMESTAMP_SUB", "-")
    return sql


def convert_safe_cast(sql: str) -> str:
    """SAFE_CAST(x AS TYPE) -> nullif(...)::TYPE-ish, using try-cast pattern.

    Postgres has no SAFE_CAST. We use a CASE-based approximation: rely on
    nullif of regex matches for common numeric/date casts.
    For now, just convert SAFE_CAST(x AS NUMERIC) -> (NULLIF(regexp_replace(x::text,'[^0-9.\-]','','g'),'')::NUMERIC)
    Other casts -> plain CAST(x AS T) with a warning comment.
    """
    pat = re.compile(r"SAFE_CAST\s*\(\s*(.+?)\s+AS\s+([\w\(\)]+)\s*\)", re.IGNORECASE | re.DOTALL)
    def sub(m):
        expr, typ = m.group(1).strip(), m.group(2).strip().upper()
        if typ in ('NUMERIC', 'FLOAT64', 'DOUBLE', 'BIGNUMERIC', 'INT64'):
            return f"NULLIF(regexp_replace(({expr})::text, '[^0-9.\\-eE]', '', 'g'), '')::numeric"
        return f"/*SAFE_CAST*/ CAST({expr} AS {typ})"
    return pat.sub(sub, sql)


PG_RESERVED = {"offset","limit","user","order","group","check","all","end"}

def quote_reserved_columns(sql: str) -> str:
    # Quote PG reserved words appearing as bare column identifiers in DDL/SELECT lists.
    def sub(m):
        word = m.group(2)
        if word.lower() in PG_RESERVED:
            return m.group(1) + chr(34) + word + chr(34) + m.group(3)
        return m.group(0)
    # Match patterns like (newline + whitespace) + (identifier) + (whitespace + type)
    return re.sub(r"(^[ \t]+)(\w+)(\s+(?:BIGINT|INT|INTEGER|TEXT|VARCHAR|TIMESTAMP|DATE|NUMERIC|BOOLEAN|DOUBLE|FLOAT|JSONB|BYTEA|TIME)\b)", sub, sql, flags=re.MULTILINE|re.IGNORECASE)

def convert_misc(sql: str) -> str:
    out = sql
    # SAFE.CAST -> SAFE_CAST shape
    out = re.sub(r"SAFE\.CAST", "SAFE_CAST", out, flags=re.IGNORECASE)
    # backticks -> remove (PG doesn't use backticks)
    out = out.replace("`", "")
    # BigQuery raw string prefix r'...' -> '...'
    out = re.sub(r"\br'([^']*)'", r"'\1'", out)
    out = re.sub(r'\br"([^"]*)"', r"'\1'", out)
    # Strip trailing comma before FROM (BQ accepts; PG rejects)
    out = re.sub(r",(\s*(?:--[^\n]*\n\s*)*)\bFROM\b", r"\1FROM", out, flags=re.IGNORECASE)
    # CURRENT_DATE() -> CURRENT_DATE (BQ uses parens; PG forbids)
    out = re.sub(r"\bCURRENT_DATE\s*\(\s*\)", "CURRENT_DATE", out, flags=re.IGNORECASE)
    out = re.sub(r"\bCURRENT_TIMESTAMP\s*\(\s*\)", "CURRENT_TIMESTAMP", out, flags=re.IGNORECASE)
    out = re.sub(r"\bCURRENT_DATETIME\s*\(\s*\)", "CURRENT_TIMESTAMP", out, flags=re.IGNORECASE)
    return out


HEADER = (
    "-- AUTO-GENERATED by bq_to_pg.py - do not edit manually; edit source then re-convert\n"
    "-- Original BigQuery SQL: ohdsi-mimic/{relpath}\n"
    "-- Variable substitution: see scripts/bq_to_pg.py VAR_MAP\n\n"
)


def convert(sql: str) -> str:
    sql = convert_misc(sql)
    sql = replace_vars(sql)
    sql = convert_create_or_replace(sql)
    sql = convert_bq_types(sql)
    sql = quote_reserved_columns(sql)
    sql = convert_farm_fingerprint(sql)
    sql = convert_to_json_string_struct(sql)
    sql = convert_safe_cast(sql)
    sql = convert_parse_date(sql)
    sql = convert_date_diff(sql)
    sql = convert_date_add_sub(sql)
    # IF may be nested; iterate to fixed point (cap at 10 to avoid runaway)
    for _ in range(10):
        new_sql = convert_if_function(sql)
        if new_sql == sql:
            break
        sql = new_sql
    sql = convert_regexp_extract(sql)
    return sql


def main():
    if len(sys.argv) != 3:
        print("usage: bq_to_pg.py <in.sql> <out.sql>", file=sys.stderr)
        sys.exit(2)
    src = Path(sys.argv[1])
    dst = Path(sys.argv[2])
    txt = src.read_text()
    out = HEADER.format(relpath=str(src)) + convert(txt)
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(out)
    print(f"converted: {src} -> {dst}  ({len(out)} bytes)")


if __name__ == "__main__":
    main()
