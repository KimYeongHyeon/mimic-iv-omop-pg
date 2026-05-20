library(DataQualityDashboard)
library(DatabaseConnector)

cat("=== Starting DataQualityDashboard for MIMIC-IV OMOP CDM ===\n")

cd <- createConnectionDetails(
  dbms     = "postgresql",
  server   = Sys.getenv("DB_SERVER",  "broadsea-atlasdb/ohdsi"),
  user     = Sys.getenv("DB_USER",    "postgres"),
  password = Sys.getenv("DB_PASS",    "mypass"),
  port     = as.integer(Sys.getenv("DB_PORT", "5432")),
  pathToDriver = "/opt/hades/jdbc_drivers"
)

CDM_SCHEMA     <- Sys.getenv("CDM_SCHEMA",     "mimiciv_cdm")
RESULTS_SCHEMA <- Sys.getenv("RESULTS_SCHEMA", "mimiciv_cdm_results")
VOCAB_SCHEMA   <- Sys.getenv("VOCAB_SCHEMA",   CDM_SCHEMA)
SOURCE_NAME    <- Sys.getenv("SOURCE_NAME",    "MIMIC-IV 2.2")
NUM_THREADS    <- as.integer(Sys.getenv("DQD_THREADS", "4"))

cat(sprintf("CDM schema:     %s\n", CDM_SCHEMA))
cat(sprintf("Results schema: %s\n", RESULTS_SCHEMA))
cat(sprintf("Threads:        %d\n", NUM_THREADS))

t0 <- Sys.time()

result <- DataQualityDashboard::executeDqChecks(
  connectionDetails            = cd,
  cdmDatabaseSchema            = CDM_SCHEMA,
  resultsDatabaseSchema        = RESULTS_SCHEMA,
  vocabDatabaseSchema          = VOCAB_SCHEMA,
  cdmSourceName                = SOURCE_NAME,
  numThreads                   = NUM_THREADS,
  sqlOnly                      = FALSE,
  outputFolder                 = "/output",
  outputFile                   = "results.json",
  verboseMode                  = FALSE,
  writeToTable                 = TRUE,
  writeTableName               = "dqdashboard_results",
  cdmVersion                   = "5.3",
  tablesToExclude              = c("CONCEPT","CONCEPT_ANCESTOR","CONCEPT_CLASS",
                                   "CONCEPT_RELATIONSHIP","CONCEPT_SYNONYM","DOMAIN",
                                   "DRUG_STRENGTH","RELATIONSHIP","VOCABULARY"),
  tableCheckThresholdLoc       = "default",
  fieldCheckThresholdLoc       = "default",
  conceptCheckThresholdLoc     = "default"
)

cat(sprintf("\n=== DQD elapsed: %s ===\n", format(difftime(Sys.time(), t0))))

conn <- connect(cd)
tryCatch({
  totals <- querySql(conn, sprintf("
    SELECT
      COUNT(*) AS total_checks,
      SUM(CASE WHEN failed=1 THEN 1 ELSE 0 END) AS failed_checks,
      SUM(CASE WHEN passed=1 THEN 1 ELSE 0 END) AS passed_checks
    FROM %s.dqdashboard_results", RESULTS_SCHEMA))
  cat(sprintf("Total checks:  %d\n", totals$TOTAL_CHECKS))
  cat(sprintf("Passed:        %d (%.1f%%)\n", totals$PASSED_CHECKS,
              100*totals$PASSED_CHECKS/totals$TOTAL_CHECKS))
  cat(sprintf("Failed:        %d\n", totals$FAILED_CHECKS))
}, error = function(e) cat(sprintf("summary error: %s\n", conditionMessage(e))))
disconnect(conn)
cat("=== DONE ===\n")
