# https://www.gnu.org/software/make/manual/make.html

DOCKER   = docker-compose
WORDPRESS   = $(DOCKER) exec wordpress

##
## PROJECT
## -------

start: ## start project
	$(DOCKER) up --build --remove-orphans --force-recreate --detach

stop: ## stop project
	$(DOCKER) stop

kill:
	$(DOCKER) kill
	$(DOCKER) down --volumes --remove-orphans

restart: kill start ## restart project

composer: ## install vendor packages
	$(COMPOSER) install

.PHONY: start stop restart composer
##
## CODE
## ----

plugins:
	$(WORDPRESS) wp plugin install wordpress-importer --activate --allow-root

postexport:
	$(WORDPRESS) wp export --dir=data/export/ --filename_format=test.xml --allow-root

postimport:
	$(WORDPRESS) wp import data/export/test.xml --authors=create --allow-root

style:
	#npm run lint:scss
	npm run compile:css

blocks:
	#npm run lint:scss
	npm run build

.PHONY: check php-cs-fixer phpstan phpmd lint-yaml phpunit validate

#
# HELP
# ----

help:
	@cat $(MAKEFILE_LIST) | grep -E '(^[a-zA-Z_-]+:.*?##.*$$)|(^##)' | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[32m%-24s\033[0m %s\n", $$1, $$2}' | sed -e 's/\[32m## /[33m/' && printf "\n"

.PHONY: help

.DEFAULT_GOAL := help

-include Makefile.override.mk
