.PHONY: test build-windows build-macos build-linux install-linux clean

test:
	PYTHONPATH=linux/src python3 -m unittest discover -s linux/tests -v

build-windows:
	./windows/build.sh

build-macos:
	./macos/build.sh

build-linux:
	./linux/build.sh

install-linux:
	./linux/install.sh

clean:
	rm -rf dist/ linux/.pytest_cache/ linux/src/obit_auth/__pycache__/ linux/tests/__pycache__/
