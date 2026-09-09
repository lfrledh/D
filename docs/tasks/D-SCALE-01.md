# D-SCALE-01

- task_id D-SCALE-01 / spec_revision 1 / contract_revision SCALE1 / batch D-AUDIO-BACKEND-01。
- source_base beaaaf82d845e672c6a3b661d928654affc00518；执行 base_sha 为包含本规格的准备提交，见派工消息/dispatch.json。
- 角色 Sol/high 实现，Lead 独立于自测做复核；隐藏服务模型解析 unknown。

## 目标
消除固定 8 GiB 应用预算及图像 512² 的内部张量硬编码，保留当前普通工作台预设和固定精度。小机预设不能变成所有 Mac 的上限。没有 GPU 实測的扩展配置只为显式调用者提供，不自动替换当前界面行为。

## 允许修改（精确文件）
- 新增 Sources/DRuntime/ResourceBudgetPolicy.swift、Tests/DRuntimeTests/ResourceBudgetPolicyTests.swift。
- Backends/MLX/Sources/DMLXBackend/MLXImageBackend.swift、LocalImageModelInventory.swift（同目录）；新增同目录 ImageExecutionProfile.swift。
- Backends/MLX/Tests/DMLXBackendTests/LocalImageModelInventoryTests.swift；新增同目录 ImageExecutionProfileTests.swift。
- D/AppSessionFactory.swift 仅 runtime memoryBudgetBytes 计算/所需局部注入，不改模型登记、状态或签名。
禁止其他代码/CLI/文档/规格/依赖/清单/Vendor/工程设置/用户 scheme。不得改源或其他树，不 Git 提交。

## 冻结行为
1. 公共 ResourceBudgetPolicy 是 DRuntime 内纯值/算术政策（Foundation）；根据调用者提供 physicalMemoryBytes 计算默认推理预算，应用传 ProcessInfo.physicalMemory。建议固定保留 max(4 GiB, total/4)，预算为剩余；16 GiB 得12 GiB，32得24，64得48，128得96。极小/零/UInt64边界安全；此值是预算，不是可用内存或 OOM 保证。支持显式保守上限，但不能超过物理预算；共享资源仍单重任务。不能读 GPU/修改全局 VM。
2. MLXImageBackendConfiguration 增加不可变 ImageExecutionProfile，默认 verified512（512×512/4步/guidance1），新显式 scalableKlein4B 支持宽高各256...2048、均为32倍数、面积<=2048²；仍4步/guidance1/512个文本token/原4Bq8固定manifest。这是同模型形状适配，不冒称9B或任意量化支持。profile含声明的支持范围，非法/超界/溢出前置拒绝。旧默认参数的拒绝与数值行为不变。
3. 尺寸贯穿准备latents、解码shape检查、PNG；不能只删guard。VAE/text层数/量化/随机种子/调度算法不变。默认512估计8GiB；扩展按像素面积计算保守workspace增长（不可overflow，>=8GiB；清晰公式/估计非实测）。删除写死10GiB allocator limit，配置可显式给上限；默认使用请求估计的安全有界换算（检查Int溢出），先完成验证后持有许可/写allocator。恢复原cache/memory限和drain/release行为保持。
4. 应用只改预算政策，image profile仍默认512，尚未验证的扩展不进入普通UI。安装/完整性/硬件预算三者分开。

## 验收（冻结预期，不为实现改标准）
- CPU:16/32/64/128GiB及零/不足/UInt64极值/显式上限；单调、不溢出、无负值。
- 默认512保持旧全部限制；扩展接受512×256、768×512、1024²、2048²元数据，拒绝非32倍/0/负/超2048/错误步数guidance/NaN；原manifest路径/完整性/符号链规则全部保留。
- 两profile同512估计相同；扩展尺寸估计不减/溢出；报告参数与实际传递吻合。必要最小内部shape helper可测但不得复制实现自证。
- Lead串行运行core/MLX CPU、已验收512数值与真实回归；资源允许时额外真实512×256，1024/2048待高配Mac实测，不改黄金样例。Worker不得运行MLX/GPU/全应用/GUI。

## 执行与停止
只读预检通过后同线程IMPLEMENT。write roots：任务工作树+派工run的worker-output/tmp；缓存固定tmp/clang-cache、tmp/pycache，网络false。必须读本任务、相关代码和AGENTS关键边界，协作规程只读错误/停止节，不通读全史。可以 installed swiftc -frontend -parse 用任务缓存；不运行SwiftPM（已知嵌套沙箱问题），由Lead在交回后测试。Python仅tokenize.open+compile(...dont_inherit=True)，不exec/import目标。未知拒绝暂停报告，无自动绕行；不扩大权限/停用户进程/递归派工。

初交+两次针对性修复；规格/身份/目录错配立即停报不消耗普通修复猜测。回传允许文件diff、检查与证据、未执行项、异常/自有进程结束状态；不自行改任务记录。
