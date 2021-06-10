REQUIREMENTS = src/requirements.txt
SOURCES = src/associate_eip.py
PYTHON = python3.8

.PHONY: clean build dist .venv .deps .src

.builddir:
	mkdir -p build

.deps: | .venv .builddir
	.venv/bin/pip install --target build/ -r $(REQUIREMENTS)

.src: | .builddir
	cp $(SOURCES) build/

.venv:
	$(PYTHON) -mvenv $@

build: .deps .src

dist: build
	cd build && zip -r ../dist/associateEIP.zip *
