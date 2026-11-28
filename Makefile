PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
DESTDIR ?=
VERSION ?= 0.3.0

.PHONY: test check install uninstall package-deb package-rpm package-arch

test:
	bash tests/run.bash

check:
	bash -n bin/sst
	bash -n install.sh
	bash -n tests/run.bash
	bash -n packaging/build-deb.sh
	bash -n packaging/build-rpm.sh
	bash -n packaging/build-arch.sh
	bash -n packaging/release-assets.sh
	$(MAKE) test

install:
	install -Dm755 bin/sst "$(DESTDIR)$(BINDIR)/sst"

uninstall:
	rm -f "$(DESTDIR)$(BINDIR)/sst"

package-deb:
	mkdir -p dist
	./packaging/build-deb.sh "$(VERSION)" dist

package-rpm:
	mkdir -p dist
	./packaging/build-rpm.sh "$(VERSION)" dist

package-arch:
	mkdir -p dist
	./packaging/build-arch.sh "$(VERSION)" dist
