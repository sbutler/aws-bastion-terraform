REQUIREMENTS = src/requirements.txt
SOURCES = src/add_extra_enis.py
PYTHON = python3.12

.PHONY: clean build lint dist .builddir .deps .src .venv

.builddir:
	mkdir -p build

.deps: | .venv .builddir
	.venv/bin/pip install --target build/ -r $(REQUIREMENTS)

.src: | .builddir
	cp $(SOURCES) build/

.venv:
	[ -e "$@" ] || $(PYTHON) -mvenv $@

clean:
	rm -fr -- .venv build dist/addExtraENIs.zip

build: .deps .src

lint: build
	[ -e .venv/bin/pylint ] || .venv/bin/pip install pylint
	.venv/bin/pylint $(SOURCES)

dist: build
	cd build && zip -r ../dist/addExtraENIs.zip *
