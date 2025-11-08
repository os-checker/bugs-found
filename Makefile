ROOT := $(realpath .)
ARCH := $(shell uname -m)
MIRI_DIR := $(ROOT)/$(ARCH)/miri

TARGETS := arceos-hypervisor/axaddrspace \
					 Starry-OS/starry-process \
					 arceos-hypervisor/x86_vcpu

# Run miri and save results.
define run_miri_test
$(1):
	OUT_DIR=$(MIRI_DIR)/$(1); \
	echo "OUT_DIR=$$$$OUT_DIR Building and testing $(1)..." && \
	cd repos/$(1) && \
	cargo clean && \
	rustup component add miri && \
	mkdir -p $$$$OUT_DIR && \
	cargo miri test 2>&1 | tee $$$$OUT_DIR/output.txt
endef

# Dynamically generate targets.
$(foreach target,$(TARGETS),$(eval $(call run_miri_test,$(target))))

all: $(TARGETS)

add_submodule:
	@$(foreach target,$(TARGETS), \
		git clone https://github.com/$(target) repos/$(target) || echo "$(target) has been added.";)

.PHONY: all $(TARGETS)
