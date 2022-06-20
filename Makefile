PYODIDE_ROOT=$(abspath .)

include Makefile.envs

.PHONY=check

CC=emcc
CXX=em++


all: check \
	dist/pyodide.asm.js \
	dist/pyodide.js \
	dist/pyodide.d.ts \
	dist/package.json \
	dist/console.html \
	dist/distutils.tar \
	dist/test.tar \
	dist/packages.json \
	dist/pyodide_py.tar \
	dist/test.html \
	dist/module_test.html \
	dist/webworker.js \
	dist/webworker_dev.js \
	dist/module_webworker_dev.js
	echo -e "\nSUCCESS!"

dist/pyodide_py.tar: $(wildcard src/py/pyodide/*.py)  $(wildcard src/py/_pyodide/*.py)
	cd src/py && tar --exclude '*__pycache__*' -cf ../../dist/pyodide_py.tar pyodide _pyodide

dist/pyodide.asm.js: \
	src/core/docstring.o \
	src/core/error_handling.o \
	src/core/error_handling_cpp.o \
	src/core/hiwire.o \
	src/core/js2python.o \
	src/core/jsproxy.o \
	src/core/main.o  \
	src/core/pyproxy.o \
	src/core/python2js_buffer.o \
	src/core/python2js.o \
	src/js/_pyodide.out.js \
	$(wildcard src/py/lib/*.py) \
	$(CPYTHONLIB)
	date +"[%F %T] Building pyodide.asm.js..."
	[ -d dist ] || mkdir dist
	$(CXX) -o dist/pyodide.asm.js $(filter %.o,$^) \
		$(MAIN_MODULE_LDFLAGS)

	if [[ -n $${PYODIDE_SOURCEMAP+x} ]] || [[ -n $${PYODIDE_SYMBOLS+x} ]]; then \
		cd dist && npx prettier -w pyodide.asm.js ; \
	fi

   # Strip out C++ symbols which all start __Z.
   # There are 4821 of these and they have VERY VERY long names.
   # To show some stats on the symbols you can use the following:
   # cat dist/pyodide.asm.js | grep -ohE 'var _{0,5}.' | sort | uniq -c | sort -nr | head -n 20
	sed -i -E 's/var __Z[^;]*;//g' dist/pyodide.asm.js
	sed -i '1i "use strict";' dist/pyodide.asm.js
	# Remove last 6 lines of pyodide.asm.js, see issue #2282
	# Hopefully we will remove this after emscripten fixes it, upstream issue
	# emscripten-core/emscripten#16518
	# Sed nonsense from https://stackoverflow.com/a/13383331
	sed -i -n -e :a -e '1,6!{P;N;D;};N;ba' dist/pyodide.asm.js
	echo "globalThis._createPyodideModule = _createPyodideModule;" >> dist/pyodide.asm.js
	date +"[%F %T] done building pyodide.asm.js."


env:
	env


node_modules/.installed : src/js/package.json src/js/package-lock.json
	cd src/js && npm ci
	ln -sfn src/js/node_modules/ node_modules
	touch node_modules/.installed

dist/pyodide.js src/js/_pyodide.out.js: src/js/*.ts src/js/pyproxy.gen.ts src/js/error_handling.gen.ts node_modules/.installed
	npx rollup -c src/js/rollup.config.js

dist/package.json : src/js/package.json
	cp $< $@

.PHONY: npm-link
npm-link: dist/package.json
	cd src/test-js && npm ci && npm link ../../dist

dist/pyodide.d.ts: src/js/*.ts src/js/pyproxy.gen.ts src/js/error_handling.gen.ts
	npx dts-bundle-generator src/js/pyodide.ts --export-referenced-types false
	mv src/js/pyodide.d.ts dist

src/js/error_handling.gen.ts : src/core/error_handling.ts
	cp $< $@

src/js/pyproxy.gen.ts : src/core/pyproxy.* src/core/*.h
	# We can't input pyproxy.js directly because CC will be unhappy about the file
	# extension. Instead cat it and have CC read from stdin.
	# -E : Only apply prepreocessor
	# -C : Leave comments alone (this allows them to be preserved in typescript
	#      definition files, rollup will strip them out)
	# -P : Don't put in macro debug info
	# -imacros pyproxy.c : include all of the macros definitions from pyproxy.c
	#
	# First we use sed to delete the segments of the file between
	# "// pyodide-skip" and "// end-pyodide-skip". This allows us to give
	# typescript type declarations for the macros which we need for intellisense
	# and documentation generation. The result of processing the type
	# declarations with the macro processor is a type error, so we snip them
	# out.
	rm -f $@
	echo "// This file is generated by applying the C preprocessor to core/pyproxy.ts" >> $@
	echo "// It uses the macros defined in core/pyproxy.c" >> $@
	echo "// Do not edit it directly!" >> $@
	cat src/core/pyproxy.ts | \
		sed '/^\/\/\s*pyodide-skip/,/^\/\/\s*end-pyodide-skip/d' | \
		$(CC) -E -C -P -imacros src/core/pyproxy.c $(MAIN_MODULE_CFLAGS) - \
		>> $@

dist/test.html: src/templates/test.html
	cp $< $@

dist/module_test.html: src/templates/module_test.html
	cp $< $@

.PHONY: dist/console.html
dist/console.html: src/templates/console.html
	cp $< $@
	sed -i -e 's#{{ PYODIDE_BASE_URL }}#$(PYODIDE_BASE_URL)#g' $@


.PHONY: docs/_build/html/console.html
docs/_build/html/console.html: src/templates/console.html
	mkdir -p docs/_build/html
	cp $< $@
	sed -i -e 's#{{ PYODIDE_BASE_URL }}#$(PYODIDE_BASE_URL)#g' $@


.PHONY: dist/webworker.js
dist/webworker.js: src/templates/webworker.js
	cp $< $@

.PHONY: dist/module_webworker_dev.js
dist/module_webworker_dev.js: src/templates/module_webworker.js
	cp $< $@

.PHONY: dist/webworker_dev.js
dist/webworker_dev.js: src/templates/webworker.js
	cp $< $@


update_base_url: \
	dist/console.html



.PHONY: lint
lint:
	pre-commit run -a --show-diff-on-failure

benchmark: all
	$(HOSTPYTHON) benchmark/benchmark.py all --output dist/benchmarks.json
	$(HOSTPYTHON) benchmark/plot_benchmark.py dist/benchmarks.json dist/benchmarks.png


clean:
	rm -fr dist/*
	rm -fr src/*/*.o
	rm -fr node_modules
	make -C packages clean
	echo "The Emsdk, CPython are not cleaned. cd into those directories to do so."

clean-python: clean
	make -C cpython clean

clean-all: clean
	make -C emsdk clean
	make -C cpython clean-all

src/core/error_handling_cpp.o: src/core/error_handling_cpp.cpp
	$(CXX) -o $@ -c $< $(MAIN_MODULE_CFLAGS) -Isrc/core/

%.o: %.c $(CPYTHONLIB) $(wildcard src/core/*.h src/core/*.js)
	$(CC) -o $@ -c $< $(MAIN_MODULE_CFLAGS) -Isrc/core/


# Stdlib modules that we repackage as standalone packages

TEST_EXTENSIONS= \
		_testinternalcapi.so \
		_testcapi.so \
		_testbuffer.so \
		_testimportmultiple.so \
		_testmultiphase.so \
		_ctypes_test.so
TEST_MODULE_CFLAGS= $(SIDE_MODULE_CFLAGS) -I Include/ -I .

# TODO: also include test directories included in other stdlib modules
dist/test.tar: $(CPYTHONLIB) node_modules/.installed
	cd $(CPYTHONBUILD) && emcc $(TEST_MODULE_CFLAGS) -c Modules/_testinternalcapi.c -o Modules/_testinternalcapi.o \
							   -I Include/internal/ -DPy_BUILD_CORE_MODULE
	cd $(CPYTHONBUILD) && emcc $(TEST_MODULE_CFLAGS) -c Modules/_testcapimodule.c -o Modules/_testcapi.o
	cd $(CPYTHONBUILD) && emcc $(TEST_MODULE_CFLAGS) -c Modules/_testbuffer.c -o Modules/_testbuffer.o
	cd $(CPYTHONBUILD) && emcc $(TEST_MODULE_CFLAGS) -c Modules/_testimportmultiple.c -o Modules/_testimportmultiple.o
	cd $(CPYTHONBUILD) && emcc $(TEST_MODULE_CFLAGS) -c Modules/_testmultiphase.c -o Modules/_testmultiphase.o
	cd $(CPYTHONBUILD) && emcc $(TEST_MODULE_CFLAGS) -c Modules/_ctypes/_ctypes_test.c -o Modules/_ctypes_test.o

	for testname in $(TEST_EXTENSIONS); do \
		cd $(CPYTHONBUILD) && \
		emcc Modules/$${testname%.*}.o -o $$testname $(SIDE_MODULE_LDFLAGS) && \
		rm -f $(CPYTHONLIB)/$$testname && \
		ln -s $(CPYTHONBUILD)/$$testname $(CPYTHONLIB)/$$testname ; \
	done

	cd $(CPYTHONLIB) && tar -h --exclude=__pycache__ -cf $(PYODIDE_ROOT)/dist/test.tar \
		test $(TEST_EXTENSIONS) unittest/test sqlite3/test ctypes/test

	cd $(CPYTHONLIB) && rm $(TEST_EXTENSIONS)


dist/distutils.tar: $(CPYTHONLIB) node_modules/.installed
	cd $(CPYTHONLIB) && tar --exclude=__pycache__ -cf $(PYODIDE_ROOT)/dist/distutils.tar distutils


$(CPYTHONLIB): emsdk/emsdk/.complete
	date +"[%F %T] Building cpython..."
	make -C $(CPYTHONROOT)
	date +"[%F %T] done building cpython..."


dist/packages.json: FORCE
	date +"[%F %T] Building packages..."
	make -C packages
	date +"[%F %T] done building packages..."


emsdk/emsdk/.complete:
	date +"[%F %T] Building emsdk..."
	make -C emsdk
	date +"[%F %T] done building emsdk."


SETUPTOOLS_RUST_COMMIT=5e8c380429aba1e5df5815dcf921025c599cecec
rust:
	wget https://sh.rustup.rs -O /rustup.sh
	sh /rustup.sh -y
	source $(HOME)/.cargo/env && rustup toolchain install nightly-2022-06-14 && rustup default nightly-2022-06-14
	source $(HOME)/.cargo/env && rustup target add wasm32-unknown-emscripten --toolchain nightly-2022-06-14
	# Install setuptools-rust with a fix for Wasm targets
	# TODO: Remove this when they release the next version.
	pip install -t $(HOSTSITEPACKAGES) git+https://github.com/PyO3/setuptools-rust.git@$(SETUPTOOLS_RUST_COMMIT)


FORCE:


check:
	./tools/dependency-check.sh


debug :
	EXTRA_CFLAGS+=" -D DEBUG_F" \
	make
