.PHONY: all extract analyze forecast report test

all: analyze forecast report test

extract:
	Rscript R/extract.R

analyze:
	Rscript R/analyze.R

forecast:
	Rscript R/forecast.R

report:
	Rscript R/report.R

test:
	Rscript -e 'testthat::test_dir("tests/testthat", reporter = "summary")'
