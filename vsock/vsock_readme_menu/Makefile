# SPDX-License-Identifier: BSD-3-Clause

CFLAGS = -Wall -Wextra

ifeq ($(DEBUG),1)
GRAMINE_LOG_LEVEL = debug
CFLAGS += -g
else
GRAMINE_LOG_LEVEL = error
CFLAGS += -O3
endif

.PHONY: all
all: vsock_readme_menu vsock_readme_menu.manifest
ifeq ($(SGX),1)
all: vsock_readme_menu.manifest.sgx vsock_readme_menu.sig
endif

vsock_readme_menu: vsock_readme_menu.o

vsock_readme_menu.o: vsock_readme_menu.c

vsock_readme_menu.manifest: vsock_readme_menu.manifest.template
	gramine-manifest \
		-Dlog_level=$(GRAMINE_LOG_LEVEL) \
		$< $@
	gramine-manifest-check $@

# See comment in vsock_server example for why this is written this way.
vsock_readme_menu.sig vsock_readme_menu.manifest.sgx: sgx_sign
	@:

.INTERMEDIATE: sgx_sign
sgx_sign: vsock_readme_menu.manifest vsock_readme_menu
	gramine-sgx-sign \
		--manifest $< \
		--output $<.sgx
	gramine-manifest-check $<.sgx

ifeq ($(SGX),)
GRAMINE = gramine-direct
else
GRAMINE = gramine-sgx
endif

.PHONY: clean
clean:
	$(RM) *.token *.sig *.manifest.sgx *.manifest vsock_readme_menu.o vsock_readme_menu OUTPUT

.PHONY: distclean
distclean: clean
