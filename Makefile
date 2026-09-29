.PHONY: all extract analyze forecast detect report test

all: analyze forecast detect report test

extract:
	Rscript R/extract.R

analyze:
	Rscript R/analyze.R

forecast:
	Rscript R/forecast.R

detect:
	Rscript R/detect.R

report:
	Rscript R/size_opportunity.R
	Rscript R/charts.R
	quarto render reports/decision_memo.qmd

test:
	Rscript -e 'testthat::test_dir("tests/testthat", reporter = "summary")'
