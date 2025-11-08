ROOT := $(realpath .)
ARCH := $(shell uname -m)
MIRI_DIR := $(ROOT)/$(ARCH)/miri
OUT_DIR = $(MIRI_DIR)/$(1)
OUT_FILE = $(MIRI_DIR)/$(1)/output.txt

# Github repositories:
TARGETS := arceos-hypervisor/axaddrspace \
					 Starry-OS/starry-process \
					 arceos-hypervisor/x86_vcpu \
					 arceos-org/allocator \
					 arceos-org/axconfig-gen \
					 arceos-org/axsched \
					 arceos-org/linked_list_r4l \
					 arceos-org/slab_allocator

#### Extra `cargo miri test` arguments ####
TESTCASE_arceos-org_allocator := tlsf_alloc
# The output only shows UB report of the first testcase.
TESTCASE_arceos-org_axsched := -- tests::fifo::bench_remove tests::fifo::test_sched
TESTCASE_arceos-org_linked_list_r4l := -- linked_list::tests::test_push_back raw_list::tests::test_one_insert_after

# Run miri and save results.
define run_miri_test
$(1):
	OUT_DIR=$(call OUT_DIR,$(1)) ; \
	OUT_FILE=$(call OUT_FILE,$(1)) ; \
	echo "OUT_DIR=$$$$OUT_DIR arg=$(1)" && \
	cd repos/$(1) && \
	cargo clean && \
	rustup component add miri && \
	mkdir -p $$$$OUT_DIR && \
	cargo miri test $(TESTCASE_$(subst /,_,$(1))) 2>&1 | tee $$$$OUT_FILE
endef

# Dynamically generate targets for each of $(TARGETS).
# So one exemplificative usage  is `make arceos-hypervisor/axaddrspace`.
$(foreach target,$(TARGETS),$(eval $(call run_miri_test,$(target))))

all: add_submodule $(TARGETS)

add_submodule:
	@$(foreach target,$(TARGETS), \
		git submodule add https://github.com/$(target) repos/$(target) || echo "$(target) has been added.";)

# `make remove_submodule REPO=user/repo`
remove_submodule:
	@if [ -n "$(REPO)" ]; then \
	git submodule deinit repos/$(REPO); \
	git rm repos/$(REPO) -f; \
	rm .git/modules/repos/$(REPO) -rf; \
	rm $(call OUT_DIR,$(REPO)) -rf; \
	fi

.PHONY: all
