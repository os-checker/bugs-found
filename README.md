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

