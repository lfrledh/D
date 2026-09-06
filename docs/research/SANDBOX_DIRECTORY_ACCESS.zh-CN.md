# 工作台目录权限与搜索式遍历

日期：2026-09-07。起因是正常签名沙箱应用通过保存面板选择外盘项目后，仍然无法创建项目；不应通过扩大权限解决这一实现错误。

## 原因与修复

原来的文件描述符遍历对 `/`、`/Volumes` 和每一级祖先都使用 `O_RDONLY`。用户选择项目／模型目录，只授予该位置的访问，不授予所有祖先的目录枚举权。旧的核心和命令行验证不运行在同一应用沙箱内，因此没有暴露这个问题。

修复使用 `O_SEARCH | O_NOFOLLOW | O_CLOEXEC` 逐级打开祖先，只请求目录搜索。模型和图片产物的最终已授权根目录继续使用 `O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC`，实际枚举、内容校验和保存仍需要相应权限。每级 `openat`、不跟随符号链接、文件身份检查、不覆盖发布和目录刷新保留。

`O_SEARCH` 是独立的访问模式；`O_EVTONLY` 仅用于事件观察，不能代替搜索模式。Apple 的 [open/openat 手册源码](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/man/man2/open.2)区分了这些选项，本机 SDK 的 `sys/fcntl.h` 提供相应定义。

## 独立对照

本机使用自有临时目录、一个可读子目录及祖先符号链接对照。Seatbelt 配置只对测试祖先精确路径拒绝 `file-read-data`；保留正常子目录访问，不修改系统或应用权限。结果如下：

| 操作 | 原 `O_RDONLY` | 尝试 `O_EVTONLY` | 最终 `O_SEARCH` |
| --- | --- | --- | --- |
| Seatbelt 拒绝祖先数据读取时打开祖先 | EPERM | EPERM | 成功 |
| 用祖先描述符 `openat` 打开可读子目录 | 不可到达 | 不可到达 | 成功 |
| 对祖先搜索描述符执行 `fsync` | 不适用 | 不适用 | 成功 |
| `O_NOFOLLOW` 打开祖先符号链接 | 拒绝 | 拒绝 | 拒绝 |
| 普通 POSIX 0100 祖先（仅搜索权限） | EACCES | EACCES | 成功 |

控制记录保存在外盘开发目录的 `Logs/directory-sandbox-probe.json`、`directory-search-probe.json` 和 `directory-search-fsync-probe.json`。控制程序是 `TestTemporary/directory-{sandbox,search,search-fsync}-probe.c`。O_EVTONLY 的失败记录保留，避免把未经证实的候选方案描述成有效修复。

上述对照验证系统调用和受控 Seatbelt 行为，不能替代真实保存面板、安全作用域书签和重新启动后的 UI 验证。Xcode 宿主测试会注入额外测试权限，正常应用的最终验收必须先普通构建、核验签名权限，再启动。

## 回归要求

`SandboxDirectoryTests` 增加生产图片发布与完整模型目录校验在不可枚举祖先之下成功、最终图片根目录仍要求读取权限、祖先符号链接仍被拒绝四个场景。它们不加载真实权重、不运行 GPU。

上述新场景与现有 `ImageArtifactStoreTests`、`LocalImageModelInventoryTests` 已在独立 Xcode 测试进程实际通过 **31 项声明／62 个展开场景，0 失败、0 跳过**，保留文件替换、错误大小／类型、缺失和损坏内容、写入失败、发布后保留及清理所有权的覆盖。结果包为外盘开发目录 `Logs/WorkbenchBackendCPU-20260907-0123.xcresult`，原始日志 `workbench-backend-cpu-tests.log`，同名 `.summary.json` 保存执行计数。

这是针对文件系统修改的 CPU 回归，没有重新执行整套 GPU 生命周期测试。真实正常沙箱 UI 结果和其他回归以工作台检查点验收报告为准。
