---
title: 'mimic-iv-omop-pg: A PostgreSQL implementation of the OHDSI/MIMIC ETL with reported validation against DataQualityDashboard and clinical literature'
tags:
  - PostgreSQL
  - MIMIC-IV
  - OMOP Common Data Model
  - OHDSI
  - clinical informatics
  - ETL
  - reproducibility
authors:
  - name: YeongHyeon Kim
    orcid: 0000-0000-0000-0000
    affiliation: 1
affiliations:
  - name: Seoul National University, Republic of Korea
    index: 1
date: 21 May 2026
bibliography: paper.bib
---

# Summary

`mimic-iv-omop-pg` is an end-to-end PostgreSQL implementation of the
official OHDSI/MIMIC ETL [@ohdsi_mimic], which is otherwise only
distributed as a BigQuery pipeline. It converts the MIMIC-IV v2.2
critical-care dataset [@johnson2023mimiciv] into the OMOP Common Data
Model v5.3.1 [@omop_cdm] in an existing OHDSI Broadsea PostgreSQL
container [@ohdsi_broadsea], invoked with a single command and
producing an `mimiciv_cdm` schema that ATLAS [@ohdsi_atlas] can
register as a first-class data source. The build pipeline is
idempotent (per-phase `.done` markers, safe to interrupt and resume),
reuses an already-loaded Athena Standardized Vocabularies schema
through read-only views to avoid re-downloading the 6.3 M-concept
vocabulary, and tracks the upstream OHDSI/MIMIC SQL through a
programmatic BigQuery-to-PostgreSQL converter (`bq_to_pg.py`, 430 LOC)
plus five small mechanical patches. The repository includes a
DataQualityDashboard [@blacketer2021dqd] full sweep (1,990 checks,
1,897 pass, 93 failures fully root-caused), a six-cohort clinical
replication (sepsis, acute kidney injury by KDIGO [@kdigo2012aki],
heart failure, acute myocardial infarction, atrial fibrillation, and
type 2 diabetes) whose headline metrics fall within published
MIMIC and general-ICU literature ranges, and comparative
documentation against other community MIMIC-to-OMOP implementations
[@kole_geeta;@cogstack_dbt;@mit_lcp_mimic_omop]. The project is
distributed under the MIT license; the underlying MIMIC-IV dataset
remains under PhysioNet credentialed access.

# Statement of need

The OHDSI/MIMIC project provides a thoroughly developed conversion
of MIMIC-IV into the OMOP CDM, but the official pipeline targets
Google BigQuery. Institutions and research groups that already
operate an OHDSI Broadsea stack — PostgreSQL plus the WebAPI and
ATLAS containers — face a practical barrier: to use MIMIC-IV on
their existing infrastructure they must either stand up a parallel
GCP project, port the ETL manually, or adopt one of the partial
community PostgreSQL implementations and validate it themselves.

Two PostgreSQL implementations of MIMIC-IV → OMOP exist in the open
community at the time of writing. `kole-geeta/MIMICiv-to-OMOP-in-PostgreSQL`
[@kole_geeta] is a hand-converted static SQL fork of OHDSI/MIMIC with
no reported DataQualityDashboard or clinical-replication output.
`CogStack/dbt_mimic_omop` [@cogstack_dbt] is a modern dbt-based
implementation but targets DuckDB on the analyst's workstation rather
than a multi-user PostgreSQL deployment, and includes MIMIC-CXR
imaging in scope. Neither approach drops directly into an existing
OHDSI Broadsea PostgreSQL container without configuration work, and
neither reports an end-to-end validation artifact.

`mimic-iv-omop-pg` addresses three gaps that block adoption of
MIMIC-IV by institutions on the OHDSI Broadsea stack:

1. **Deployment friction.** The pipeline drops into an existing
   `broadsea-atlasdb` container as a new schema with no rebuild,
   no JDBC driver installation, and no parallel database stack.
2. **Upstream drift.** Because conversion is programmatic
   (`bq_to_pg.py` reading the OHDSI/MIMIC submodule on each build),
   the project re-tracks upstream OHDSI/MIMIC changes by re-running
   the converter, rather than requiring a manual diff and re-edit
   of static SQL.
3. **Validation transparency.** The repository ships reported
   DataQualityDashboard results, six cohort replications matching
   published literature, and explicit documentation of the 92
   inherited limitations (MIMIC date shift, OHDSI 64-bit `person_id`,
   custom-vocabulary long-tail) plus the one re-runnable ETL step
   that the validation surfaced.

The intended users are clinical informatics researchers and
institutional operators who maintain OHDSI Broadsea installations
and need an inspectable, validated PostgreSQL path for MIMIC-IV.
The project is not a replacement for the OHDSI/MIMIC BigQuery
pipeline; it is a parallel deployment option for environments
where PostgreSQL is the operational standard. A roadmap for
side-by-side BigQuery comparison and a second-dataset port
(eICU-CRD) is published with the repository.

# Acknowledgements

This work builds directly on the OHDSI/MIMIC ETL maintained by
Odysseus Data Services, the OMOP Common Data Model maintained by the
OHDSI community, the MIMIC-IV dataset published by the MIT
Laboratory for Computational Physiology, and the Broadsea
deployment stack maintained by the OHDSI community.

# References
