# ngs-lims-postgres: everything runs through psql inside the container.
-include .env
export

COMPOSE ?= docker compose
DB_USER := $(or $(POSTGRES_USER),lims_admin)
DB_NAME := $(or $(POSTGRES_DB),ngs_lims)
PSQL    := $(COMPOSE) exec -T db psql -X -v ON_ERROR_STOP=1 -U $(DB_USER) -d $(DB_NAME)

.PHONY: up down reset psql test report analysis

.env:
	cp .env.example .env

up: .env
	$(COMPOSE) up -d --wait

down:
	$(COMPOSE) down

## drop every schema and role, then rebuild and reseed from sql/00_run_all.sql
reset: up
	$(PSQL) -q -f /sql/00_run_all.sql

psql: up
	$(COMPOSE) exec db psql -U $(DB_USER) -d $(DB_NAME)

test: up
	$(PSQL) -q -f /tests/run_tests.sql

## run every analysis query in sql/08_analysis.sql
analysis: up
	$(PSQL) -f /sql/08_analysis.sql

report: up
	@cat report/header.html > report.html.tmp
	@$(PSQL) -q -f /report/report.sql >> report.html.tmp
	@cat report/footer.html >> report.html.tmp
	@mv report.html.tmp report.html
	@echo "wrote report.html"
