# ArceOS Miri UB 报告

## 总览

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

## linked_list_r4l

### Unsoundness of `CursorMut`

展示这个数据结构的 safe API 具有未定义行为的测例：

```rust
#[test]
fn cursor_mut_unsoundness() {
    let data = Arc::new(Node::new(String::new()));

    let task = |id: usize| {
        let data = data.clone();
        const N: usize = 100;
        let f = move || {
            let mut list = List::<Arc<Node>>::new();
            list.push_back(data);
            let mut cursor = list.cursor_front_mut();
            let buf = &mut cursor.current().expect("No current corsor").inner;
            for i in N * id..N * (id + 1) {
                *buf = i.to_string();
            }
        };
        thread::Builder::new()
            .name(id.to_string())
            .spawn(f)
            .unwrap()
    };

    let mut tasks = Vec::new();
    for id in 0..10 {
        tasks.push(task(id));
        println!("id={id} buf={}", data.inner());
    }

    for t in tasks {
        t.join().unwrap();
    }
}
```

运行测试，可以看到不仅出现数据损坏，而且在一个线程上，全新的链表在前一行插入数据，下一行构造的 cursor 中没有节点：

```text
$ cargo test cursor_mut_unsoundness
id=5 buf=399
id=6 buf=�
id=7 buf=599
id=8 buf=699
id=9 buf=799

thread '9' (2605626) panicked at tests/cursor_mut.rs:40:45:
No current corsor
note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace

thread 'cursor_mut_unsoundness' (2605616) panicked at tests/cursor_mut.rs:58:18:
called `Result::unwrap()` on an `Err` value: Any { .. }
test cursor_mut_unsoundness ... FAILED
```

Miri 的 stack borrows 检查报告存在 UB，因为
* `let new_ptr = Some(NonNull::from(new))` 从共享引用 `new` 中构造 NonNull
* 在 `&mut *cur.as_ptr()` 中创建了 `&mut`，这违反了 [`NonNull`] 的安全要求

[`NonNull`]: https://doc.rust-lang.org/stable/std/ptr/struct.NonNull.html

> Notice that `NonNull<T>` has a From instance for &T. However, this does not
> change the fact that mutating through a (pointer derived from a) shared
> reference is undefined behavior unless the mutation happens inside an
> `UnsafeCell<T>`. The same goes for creating a mutable reference from a shared
> reference. When using this From instance without an `UnsafeCell<T>`, it is your
> responsibility to ensure that as_mut is never called, and as_ptr is never
> used for mutation.

```rust
$ cargo miri test cursor_mut_unsoundness
error: Undefined Behavior: trying to retag from <141872> for Unique permission at alloc42393[0x10], but that tag only grants SharedReadOnly permission for this location
   --> /home/gh-zjp-CN/bugs-found/repos/arceos-org/linked_list_r4l/src/raw_list.rs:393:23
    |
393 |         Some(unsafe { &mut *cur.as_ptr() })
    |                       ^^^^^^^^^^^^^^^^^^ this error occurs as part of retag at alloc42393[0x10..0x40]
    |
    = help: this indicates a potential bug in the program: it performed an invalid operation, but the Stacked Borrows rules it violated are still experimental
    = help: see https://github.com/rust-lang/unsafe-code-guidelines/blob/master/wip/stacked-borrows.md for further information
help: <141872> was created by a SharedReadOnly retag at offsets [0x10..0x38]
   --> /home/gh-zjp-CN/bugs-found/repos/arceos-org/linked_list_r4l/src/raw_list.rs:162:28
    |
162 |         let new_ptr = Some(NonNull::from(new));
    |                            ^^^^^^^^^^^^^^^^^^
    = note: BACKTRACE (of the first span) on thread `0`:
    = note: inside `linked_list_r4l::raw_list::CursorMut::<'_, std::sync::Arc<Node>>::current` at /home/gh-zjp-CN/bugs-found/repos/arceos-org/linked_list_r4l/src/raw_list.rs:393:23: 393:41
note: inside `linked_list_r4l::linked_list::CursorMut::<'_, std::sync::Arc<Node>>::current`
   --> /home/gh-zjp-CN/bugs-found/repos/arceos-org/linked_list_r4l/src/linked_list.rs:249:9
    |
249 |         self.cursor.current()
    |         ^^^^^^^^^^^^^^^^^^^^^
note: inside closure
   --> tests/cursor_mut.rs:40:28
    |
 40 |             let buf = &mut cursor.current().expect("No current corsor").inner;
    |                            ^^^^^^^^^^^^^^^^
```

而 Miri 的 tree borrows 检测到例子中进一步利用可变引用造成的数据竞争问题：

```rust
$ MIRIFLAGS=-Zmiri-tree-borrows cargo miri test cursor_mut_unsoundness
error: Undefined Behavior: Data race detected between (1) retag read on thread `cursor_mut_unso` and (2) non-atomic write on thread `0` at alloc42393+0x10
  --> tests/cursor_mut.rs:42:17
   |
42 |                 *buf = i.to_string();
   |                 ^^^^ (2) just happened here
   |
help: and (1) occurred earlier here
  --> tests/cursor_mut.rs:54:36
   |
54 |         println!("id={id} buf={}", data.inner());
   |                                    ^^^^^^^^^^^^
   = help: retags occur on all (re)borrows and as well as when references are copied or moved
   = help: retags permit optimizations that insert speculative reads or writes
   = help: therefore from the perspective of data races, a retag has the same implications as a read or write
   = help: this indicates a bug in the program: it performed an invalid operation, and caused Undefined Behavior
   = help: see https://doc.rust-lang.org/nightly/reference/behavior-considered-undefined.html for further information
   = note: BACKTRACE (of the first span) on thread `0`:
   = note: inside closure at tests/cursor_mut.rs:42:17: 42:21
```

### Aliasing Violation

```rust
$ cargo miri pop_front_unsoundness
error: Undefined Behavior: deallocation through <133683> at alloc42029[0x11] is forbidden
    --> /home/gh-zjp-CN/.rustup/toolchains/nightly-aarch64-unknown-linux-gnu/lib/rustlib/src/rust/library/alloc/src/boxed.rs:1686:17
     |
1686 |                 self.1.deallocate(From::from(ptr.cast()), layout);
     |                 ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ Undefined Behavior occurred here
     |
     = help: this indicates a potential bug in the program: it performed an invalid operation, but the Tree Borrows rules it violated are still experimental
     = help: see https://github.com/rust-lang/unsafe-code-guidelines/blob/master/wip/tree-borrows.md for further information
     = help: the accessed tag <133683> is a child of the conflicting tag <133604>
     = help: the conflicting tag <133604> has state Frozen which forbids this deallocation (acting as a child write access)
help: the accessed tag <133683> was created here
    --> tests/pop_front.rs:11:5
     |
  11 |     list.pop_front().unwrap();
     |     ^^^^^^^^^^^^^^^^^^^^^^^^^
help: the conflicting tag <133604> was created here, in the initial state Cell
    --> /home/gh-zjp-CN/bugs-found/repos/arceos-org/linked_list_r4l/src/raw_list.rs:162:28
     |
 162 |         let new_ptr = Some(NonNull::from(new));
     |                            ^^^^^^^^^^^^^^^^^^
     = note: BACKTRACE (of the first span) on thread `pop_front_unsou`:
     = note: inside `<std::boxed::Box<Node> as std::ops::Drop>::drop` at /home/gh-zjp-CN/.rustup/toolchains/nightly-aarch64-unknown-linux-gnu/lib/rustlib/src/rust/library/alloc/src/boxed.rs:1686:17: 1686:66
     = note: inside `std::ptr::drop_in_place::<std::boxed::Box<Node>> - shim(Some(std::boxed::Box<Node>))` at /home/gh-zjp-CN/.rustup/toolchains/nightly-aarch64-unknown-linux-gnu/lib/rustlib/src/rust/library/core/src/ptr/mod.rs:805:1: 807:25
note: inside `pop_front_unsoundness`
    --> tests/pop_front.rs:11:30
     |
  11 |     list.pop_front().unwrap();
     |                              ^
note: inside closure
    --> tests/pop_front.rs:8:27
     |
   7 | #[test]
     | ------- in this attribute macro expansion
   8 | fn pop_front_unsoundness() {
     |                           ^
```

### 修复 linked_list_r4l 和 axsched

axsched 的 `fifo::{bench_remove,test_sched}` 测例 UB 是上游 linked_list_r4l 导致的，因此修复集中在 linked_list_r4l。

对 linked_list_r4l 的修复有两种思路：
1. 尽可能保留现有代码
2. 重新将 Rust for Linux 的链表代码抽取出来

这里聚焦于第一种思路。

对于 `CursorMut` 暴露 `&mut T` 问题，我们可以把涉及的函数改为 unsafe，或者保持 safe fn 但返回 `*mut T`。

对于 aliasing 问题，首先修复的地方是在推入节点的时候，传递 `NonNull` ptr 而不是共享引用：

```diff
pub fn push_back(&mut self, data: G::Wrapped) {
    let ptr = data.into_pointer();

    // SAFETY: We took ownership of the entry, so it is safe to insert it.
-    if !unsafe { self.list.push_back(ptr.as_ref()) } {
+    if !unsafe { self.list.push_back(ptr) } {
```

这意味着 `RawList::push_back` 应该采用 `NonNull` 而不是 `&`：

```diff
-pub unsafe fn push_back(&mut self, new: &G::EntryType) -> bool {
+pub unsafe fn push_back(&mut self, new: NonNull<G::EntryType>) -> bool {
```

还需要类似的的函数改动指针类型。


## 对比 Rust for Linux 的链表实现

把链表的代码抽取成单独的库 [linked_list_r4l-upstream]，并作为正常的 Cargo 项目

```text
linked_list_r4l-upstream v0.1.0
├── bindings v0.1.0 (./bindings)
│   ├── ffi v0.1.0 (./ffi)
│   └── pin-init v0.1.0 (./pin-init)
│       ├── paste v1.0.15 (proc-macro)
│       └── pin-init-internal v0.1.0 (proc-macro) (./pin-init-internal)
│           ├── proc-macro2 v1.0.103
│           │   └── unicode-ident v1.0.22
│           └── quote v1.0.42
│               └── proc-macro2 v1.0.103 (*)
├── ffi v0.1.0 (./ffi)
├── paste v1.0.15 (proc-macro)
└── pin-init v0.1.0 (./pin-init) (*)
```

[linked_list_r4l-upstream]: https://github.com/os-checker/linked_list_r4l-upstream

bindings 只是 C 的接口，没有链接到内核的实现。这意味着无法以正常的方式调用内核的 C 代码。内核测试需要 KUnit。

> KUnit 内核测试框架
> 
> KUnit之所以能够对内核模块的代码进行单元测试，并且能够无缝处理Linux内核源码的库，其核心在于它的架构设计——**KUnit测试本身就是内核代码，并在内核空间中运行**。
> 
> 
> 这使得它与被测试的代码处于相同的执行环境，从而获得了直接访问和测试内核内部组件的能力。
> 
> 1. KUnit如何测试内核模块代码？
> 
> KUnit通过一种“白盒测试”的方法来测试内核模块，这意味着测试代码可以访问被测模块的内部函数和数据结构，而不仅仅是暴露给用户空间的接口。它主要通过以下几种方式实现：
> 
> *   **作为可加载模块运行**：KUnit测试本身可以被编译成一个独立的内核模块。当您通过 `modprobe` 加载这个测试模块时，它会自动执行其中定义的所有测试用例。这些测试用例可以直接调用您想要测试的内核模块中的函数（只要这些函数不是 `static` 的）。
> 
> *   **与被测代码一起编译**：测试代码可以和被测的模块代码一起编译。通过在编译时使用特定的宏（如 `KUNIT_TEST`），可以控制是编译生成一个包含测试用例的模块，还是一个不含测试的生产环境模块。
> 
> *   **利用用户模式Linux (UML)**：为了方便和快速测试，KUnit通常与用户模式Linux（UML）结合使用。UML可以将整个Linux内核编译成一个普通的用户空间程序。开发者可以在自己的主机上直接运行这个程序来启动一个功能完整的内核，而无需虚拟机或物理硬件。`kunit_tool` 脚本会自动处理这个过程：它会构建一个包含被测模块和KUnit测试的UML内核，运行它，然后解析内核日志中的测试结果。
> 
> *   **隔离的测试上下文**：每个KUnit测试用例都在一个单独的线程上下文中执行。这种设计提供了隔离性，确保一个测试用例的失败或崩溃不会影响到其他测试用例或整个内核的稳定性。
> 
> 2. KUnit如何处理Linux内核源码的库？
> 
> KUnit处理内核库的方式非常直接和自然，因为它本身就是内核的一部分。
> 
> *   **无缝集成构建系统**：KUnit测试代码通过内核的构建系统（Kbuild/Makefiles）进行编译。这意味着在编译时，它可以像任何其他内核代码一样，直接 `#include` 内核的头文件（例如 `<linux/list.h>`、`<linux/slab.h>` 等）。
> 
> *   **直接链接和访问**：由于测试代码和内核库最终都被链接到同一个内核镜像中（或在模块加载时解析符号），KUnit测试可以直接调用任何内核提供的非 `static` 函数，访问全局变量和数据结构。它不需要任何特殊的“模拟”（mocking）或存根（stubbing）机制来处理内核内部的库函数，除非开发者为了隔离测试单元而主动创建这些机制。
> 
> *   **测试内核核心库的理想工具**：正是因为这种紧密的集成，KUnit不仅能测试设备驱动等模块，也非常适合用来测试内核的核心库代码。对于那些没有用户空间接口的内部库（例如链表操作、内存分配器等），从用户空间进行测试极其困难，而KUnit提供了一种在内核内部直接测试这些基础组件的有效方法。
> 
> 总结来说，KUnit的强大之处在于它将测试框架完全融入了内核的开发和运行环境。它不是一个外部工具，而是内核原生的测试解决方案，这使得它能够轻松地测试内核模块的内部实现，并像使用标准C库一样自然地使用内核的所有内部函数和库。


# Asterinas

Existent issues:
* [assert_eq!() hangs on failure/panic in ktest](https://github.com/asterinas/asterinas/issues/1584)
