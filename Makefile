.PHONY: test check

test:
	bash tests/run.bash

check:
	bash -n bin/sst
	bash -n tests/run.bash
	$(MAKE) test