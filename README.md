# ArceOS Miri UB 报告

| 类型                 | 库                            | 测例                                  |
|----------------------|-------------------------------|---------------------------------------|
| Return Type Mismatch | Starry-OS/starry-process      | [未知][os-checker#397]                |
| Stacked Borrows      | arceos-hypervisor/axaddrspace | test_addrspace_creation               |
| Stacked Borrows      | arceos-hypervisor/x86_vcpu    | [多处][x86_vcpu#tests]                |
| Stacked Borrows      | arceos-org/allocator          | tlsf_alloc                            |
| Stacked Borrows      | arceos-org/axsched            | fifo::{bench_remove,test_sched}       |
| Stacked Borrows      | arceos-org/linked_list_r4l    | test_push_back, test_one_insert_after |
| Stacked Borrows      | arceos-org/slab_allocator     | allocate_and_free_double_usize        |

[os-checker#397]: https://github.com/os-checker/os-checker/issues/397
[x86_vcpu#tests]: https://os-checker.github.io/testcases?repo=x86_vcpu&miri_pass=%25E2%259D%258C

Integer-to-pointer cast 警告（关于 provenance)
* arceos-hypervisor/axaddrspace
* arceos-hypervisor/x86_vcpu
* arceos-org/allocator
* arceos-org/slab_allocator

注：os-checker 设置 1 分钟检测时间上限，防止出现卡住，并尽可能快完成检查。
