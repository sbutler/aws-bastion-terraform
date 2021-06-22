REQUIREMENTS = src/requirements.txt
SOURCES = src/associate_eip.py
PYTHON = python3.8

.PHONY: clean build lint dist .venv .deps .src

.builddir:
	mkdir -p build

.deps: | .venv .builddir
	.venv/bin/pip install --target build/ -r $(REQUIREMENTS)

.src: | .builddir
	cp $(SOURCES) build/

.venv:
	[ -e "$@" ] || $(PYTHON) -mvenv $@

build: .deps .src

lint: build
	[ -e .venv/bin/pylint ] || .venv/bin/pip install pylint
	.venv/bin/pylint $(SOURCES)

dist: build
	cd build && zip -r ../dist/associateEIP.zip *
