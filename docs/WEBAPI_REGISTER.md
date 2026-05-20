# Registering MIMIC-IV CDM with OHDSI WebAPI / ATLAS

After running `./run.sh m6` you still need to tell WebAPI about the new data
source so ATLAS can discover it.

## Step 1 — pick a connection URL

WebAPI lives in a separate database (usually `postgres` in Broadsea) and uses
JDBC to connect to the CDM. The new source must point to the database that
hosts `mimiciv_cdm`:

```
jdbc:postgresql://broadsea-atlasdb:5432/ohdsi?user=postgres&password=<YOUR_DB_PASSWORD>
```

Adjust host/db/user/password to your environment.

## Step 2 — insert the source

```bash
docker exec -i broadsea-atlasdb psql -U postgres -d postgres -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO webapi.source (
  source_name, source_key, source_connection, source_dialect,
  username, password, is_cache_enabled, check_connection
) VALUES (
  'MIMIC-IV 2.2 OMOP CDM',
  'MIMICIV',
  'jdbc:postgresql://broadsea-atlasdb:5432/ohdsi?user=postgres&password=<YOUR_DB_PASSWORD>',
  'postgresql',
  'postgres',
  '<YOUR_DB_PASSWORD>',
  true,
  true
) RETURNING source_id;
SQL
```

Note the returned `source_id` (e.g., 9). The next step uses it.

## Step 3 — declare daimons (which schema is CDM / Vocab / Results)

```bash
docker exec -i broadsea-atlasdb psql -U postgres -d postgres -v ON_ERROR_STOP=1 <<'SQL'
-- replace 9 with the source_id from step 2
INSERT INTO webapi.source_daimon (source_id, daimon_type, table_qualifier, priority) VALUES
  (9, 0, 'mimiciv_cdm',         0),   -- 0 = CDM
  (9, 1, 'mimiciv_cdm',        10),   -- 1 = Vocabulary
  (9, 2, 'mimiciv_cdm_results', 5);   -- 2 = Results (cohort generation outputs)
SQL
```

## Step 4 — refresh WebAPI

```bash
docker restart ohdsi-webapi
sleep 30
```

## Step 5 — verify in ATLAS

Open `http://<broadsea-host>/atlas/` → "Data Sources" tab.
You should see **MIMIC-IV 2.2 OMOP CDM** with key `MIMICIV`.

## Optional — Populate Achilles results

ATLAS's data-source dashboard is empty until Achilles runs. From an R
container with the Broadsea network access:

```r
DatabaseConnector::createConnectionDetails(
  dbms      = "postgresql",
  server    = "broadsea-atlasdb/ohdsi",
  user      = "postgres",
  password  = "<YOUR_DB_PASSWORD>",
  port      = 5432
) -> cd
Achilles::achilles(
  connectionDetails  = cd,
  cdmDatabaseSchema  = "mimiciv_cdm",
  resultsDatabaseSchema = "mimiciv_cdm_results",
  sourceName = "MIMIC-IV 2.2"
)
```

Takes ~3 hours for ~260K patients.
