# JOSS submission package

This directory contains the draft Journal of Open Source Software
(JOSS) submission for `mimic-iv-omop-pg`.

## Files

| File | Purpose |
|---|---|
| `paper.md` | Manuscript body (651 words, within JOSS 250–1,000 word target) |
| `paper.bib` | BibTeX bibliography referenced by `paper.md` |

## Before submitting

1. **ORCID** — replace the placeholder `0000-0000-0000-0000` in
   `paper.md` with your actual ORCID iD
   (https://orcid.org/register if not yet registered).
2. **Affiliation** — confirm the affiliation is current
   (Seoul National University, Republic of Korea).
3. **Date** — bump the date to the actual submission date.
4. **Local render** — confirm the paper compiles:
   ```bash
   docker run --rm -it -v $PWD/paper:/data \
     -u $(id -u):$(id -g) openjournals/inara \
     -o pdf,crossref paper.md
   ```
   Output PDF lands at `paper/paper.pdf`.

## Submission

1. Open https://joss.theoj.org/papers/new
2. Paste the GitHub repository URL:
   `https://github.com/KimYeongHyeon/mimic-iv-omop-pg`
3. Pre-review starts within ~24 h; an editor will assign reviewers
   (typically 2) and open a GitHub issue tracking the review.
4. Review iterates on the same issue thread until accepted; total
   timeline 4 weeks – 3 months in our scope.
5. On acceptance, JOSS assigns a paper DOI separate from the Zenodo
   software DOI. Update `CITATION.cff` and README to point the
   `preferred-citation` at the JOSS paper.

## JOSS reviewer checklist (self-check)

- [x] Software is on a free, public version-control host (GitHub).
- [x] OSI-approved license (MIT) committed at repository root.
- [x] Software has substantial functionality (not a toy).
- [x] Documentation describes installation, usage, and an example.
- [x] Validation reported (DQD + clinical replications + unit tests).
- [x] `paper.md` describes purpose, what the software does, who it is
      for, and what gap it fills.
- [x] Statement-of-need explicitly contrasts with related work.
- [x] Bibliography contains DOIs where possible.

## What JOSS does NOT require

- Novel scientific findings (this is a software paper)
- Peer-reviewed benchmark against alternatives
- Original methodology contribution

If the reviewer questions positioning vs. existing PostgreSQL
implementations, point them to `docs/RELATED_WORK.md` — the
"Where each fits best" section and the code-level appendix.
