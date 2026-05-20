library(Achilles)
library(DatabaseConnector)

cat("=== Starting Achilles for MIMIC-IV OMOP CDM ===\n")

cd <- createConnectionDetails(
  dbms     = "postgresql",
  server   = Sys.getenv("DB_SERVER",  "broadsea-atlasdb/ohdsi"),
  user     = Sys.getenv("DB_USER",    "postgres"),
  password = Sys.getenv("DB_PASS",    "mypass"),
  port     = as.integer(Sys.getenv("DB_PORT", "5432")),
  pathToDriver = "/opt/hades/jdbc_drivers"
)

CDM_SCHEMA <- Sys.getenv("CDM_SCHEMA", "mimiciv_cdm")
RESULTS_SCHEMA <- Sys.getenv("RESULTS_SCHEMA", "mimiciv_cdm_results")

cat(sprintf("CDM schema:     %s\n", CDM_SCHEMA))
cat(sprintf("Results schema: %s\n", RESULTS_SCHEMA))
cat("Generating Achilles SQL...\n")

Achilles::achilles(
  connectionDetails    = cd,
  cdmDatabaseSchema    = CDM_SCHEMA,
  resultsDatabaseSchema= RESULTS_SCHEMA,
  scratchDatabaseSchema= RESULTS_SCHEMA,
  vocabDatabaseSchema  = CDM_SCHEMA,
  tempEmulationSchema  = RESULTS_SCHEMA,
  sourceName           = Sys.getenv("SOURCE_NAME", "MIMIC-IV 2.2"),
  cdmVersion           = "5.3",
  createTable          = TRUE,
  smallCellCount       = 0,
  createIndices        = FALSE,
  numThreads           = 1,
  optimizeAtlasCache   = TRUE,
  defaultAnalysesOnly  = TRUE,
  sqlOnly              = TRUE,
  outputFolder         = "/tmp/achilles_sql_mimiciv"
)

cat("SQL generated. Executing...\n")
conn <- connect(cd)
executeSql(conn, sprintf("SET search_path TO %s, %s, public;", RESULTS_SCHEMA, CDM_SCHEMA))

sqlFiles <- sort(list.files("/tmp/achilles_sql_mimiciv", pattern="\\.sql$", full.names=TRUE))
cat(sprintf("Found %d SQL files\n", length(sqlFiles)))

ok <- 0; fail <- 0; t0 <- Sys.time()
for (f in sqlFiles) {
  cat(sprintf("[%s] %s ... ", format(Sys.time(), "%H:%M:%S"), basename(f)))
  tryCatch({
    sql <- readChar(f, file.info(f)$size)
    executeSql(conn, sql)
    ok <- ok + 1
    cat("OK\n")
  }, error = function(e) {
    fail <<- fail + 1
    cat(sprintf("ERROR: %s\n", substr(conditionMessage(e), 1, 200)))
  })
}

cat(sprintf("\n=== %d OK, %d FAIL, elapsed: %s ===\n",
            ok, fail, format(difftime(Sys.time(), t0))))

tryCatch({
  cnt <- querySql(conn, sprintf("SELECT count(*) AS n FROM %s.achilles_results", RESULTS_SCHEMA))
  cat(sprintf("achilles_results rows: %d\n", cnt$N))
  cnt <- querySql(conn, sprintf("SELECT count(*) AS n FROM %s.achilles_results_dist", RESULTS_SCHEMA))
  cat(sprintf("achilles_results_dist rows: %d\n", cnt$N))
}, error=function(e) cat(sprintf("count error: %s\n", conditionMessage(e))))

disconnect(conn)
cat("=== DONE ===\n")
