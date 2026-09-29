# Activate the renv project library.
# renv/activate.R is generated the first time renv::init() runs; until then,
# fall back to renv::load() so scripts work right after `renv::restore()`.
if (file.exists("renv/activate.R")) {
  source("renv/activate.R")
} else if (requireNamespace("renv", quietly = TRUE) && file.exists("renv.lock")) {
  suppressPackageStartupMessages(renv::load())
}
