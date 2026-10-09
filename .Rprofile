# Fall back to a CRAN mirror when none is configured (some R installs, e.g. the
# R 4.6 build used by r-lib/actions on CI, leave repos at "@CRAN@").
local({
  repos <- getOption("repos")
  if (is.null(repos) || identical(unname(repos["CRAN"]), "@CRAN@")) {
    rspm <- Sys.getenv("RSPM")
    repos["CRAN"] <- if (nzchar(rspm)) rspm else "https://cloud.r-project.org"
    options(repos = repos)
  }
})

# Activate the renv project library.
# renv/activate.R is generated the first time renv::init() runs; until then,
# fall back to renv::load() so scripts work right after `renv::restore()`.
if (file.exists("renv/activate.R")) {
  source("renv/activate.R")
} else if (requireNamespace("renv", quietly = TRUE) && file.exists("renv.lock")) {
  suppressPackageStartupMessages(renv::load())
}
