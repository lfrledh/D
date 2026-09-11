# D-AE-ACCESS-01：子进程已有目录授权的有界传递

APP1/ACCESS1；batch D-AUDIO-APP-01。请求Sol/high：CoreFoundation FFI和能力生命周期风险较高。新范围为父应用已有授权的隐式书签接收，不是新增Mac权限/签名/网络能力，不刷新PACK或旧AW1预算。普通App/GPU/GUI验收仍另列。Lead在DMLXBackend/App中串行装配；本包只实现Python接收模块与CPU夹具。

允许新增且只改：`Backends/Audio/Python/d_audio_access.py`、`Backends/Audio/Tests/test_audio_access.py`。不改既有provider/contract/runtime、配置/签名/依赖/任务单/Git管理目录；无递归、网络、模型、GUI、完整构建或真实用户目录探针。独立目录D-AE-ACCESS-01、分支codex/d-ae-access-01；完整base/run/output/tmp在Lead request中，先预检后IMPLEMENT。源码检查用tokenize.open+compile(...dont_inherit=True)，行为测试另做且只在D_TEST_TEMP_DIR中的合成输入。缓存/temp唯一授权目录，PYTHONDONTWRITEBYTECODE=1。

## 冻结接口
暴露 `AudioAccessError` 和 contextmanager `acquire_file_access(manifest_path: Path, *, run_id: str, allowed_paths: Sequence[Path])`。with进入时有界读取/验证manifest、解析并启动授权，退出（包括用户代码异常）平衡stop/release。无写盘、日志、下载、子进程或提示。CLI/main入口不需要；不能借接收manifest执行任何命令/URI/模型。Lead稍后在现有provider中调用，调用时提供已冻结任务的runID及确切model目录、run目录等允许值，不把manifest声明直接当允许列表。

manifest为父应用在子进程静态可读的专属bootstrap目录所写mode0600普通文件：UTF-8 JSON，最多64KiB，重复key/NaN等拒绝。恰好字段schemaVersion=整数1（bool不是1）、runID=合法UUID字符串且与给定run_id同一UUID、grants=1..4数组。每项恰好{path:字符串,bookmark:base64字符串}；bookmark严格base64解码、非空、每项解码最多16KiB；不接受网址、非绝对路径、NUL、..或根目录。paths须规范本地POSIX、无重复，集合必须等于调用者allowed_paths规范值；allowed_paths同样验证。不能放大到父目录或拼合另一个run。manifest路径全部祖先无symlink，文件必须常规、用O_NOFOLLOW和有界读取，拒绝读取中身份/长度变化。可复用已有d_audio_contract的安全读函数但不要改它；错误转AudioAccessError，不带bookmark内容/底层CFError描述。

## macOS生命周期
仅标准库ctypes与系统CoreFoundation，不新增PyObjC等依赖。绑定CFDataCreate、CFURLCreateByResolvingBookmarkData、CFURLGetFileSystemRepresentation、CFURLStartAccessingSecurityScopedResource、CFURLStopAccessingSecurityScopedResource、CFRelease，精确argtypes/restype，管理CFData/CFURL/CFError引用和布尔/指针宽度。官方SDK CFURL.h给定：WithoutUI=1<<8、WithoutMounting=1<<9、WithoutImplicitStartAccessing=1<<15（11.2+）；采用父应用创建的隐式安全书签，不使用WithSecurityScope强行当app-scoped永久书签。关闭UI、挂载和自动开始访问；先获取解析后的本地路径并核对等于grant.path，再显式start。路径不同、过期/无法解析/无本地路径、安全格式异常则拒绝，不自动寻址或修复权限。已启动的先前grant遇后续失败必须逆序stop，所有CF引用包括error都release；正常和异常with退出同样平衡。

start返回false不自动等于权限拒绝：静态沙盒可访问路径可能无需动态扩展；必须以只读目录打开/检查确认可访问，再继续，仍不写目录测试权限。start=true时必须stop恰好一次。解析后仅尝试验证确切允许目录，不探索父级或其他位置；不声称这个检查证明后续全部写入/mmap/GPU行为。非darwin实际使用报unsupported；模块导入本身不加载框架、不调用CF、不产生副作用。

## 夹具及质量门槛
只用mock/替身CoreFoundation适配层和临时目录；不创建/解析真实私有书签、无OS权限改变。覆盖正常两grant进入/退出、with主体异常、第二项解析/路径/启动/可读性失败后第一项清理；false但可读、false且不可读；CFData/URL/Error引用在全部失败边界平衡，CFRelease不接收NULL。无目标目录写入。
JSON结构/重复key/布尔版本/错误run/未知字段/重复path/不同allowlist/Unicode路径/base64空坏超额/文件超额/符号链接与非常规文件均拒绝；错误消息不得包含能力字节或base64原文。确定性模拟能力不是本机真实授权通过，报告必须分清。可在测试中patch私有CF工厂，不加生产环境test开关或假通过分支。测试目录从显式D_TEST_TEMP_DIR取得，不硬编码本run，所有工具有界。

初交+两轮针对性修复，之后可一次有界Lead接管需非实现者审核；未知权限拒绝/身份变化/输入损坏/越界先停止并报告Lead，不私自换目录或扩权。预期失败夹具单列。Worker不commit，不改规格；回传实际文件、测试、异常、无执行/进程和未验证项。首次仅预检，等待IMPLEMENT。
