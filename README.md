# D · 本地 AI 创作工作台

D面向Mac上的创作者、艺术家与学生，目标是可组合、可检查的**统一节点工作台**：用户准备和修改条件、检查中间结果，再决定后续生成。场景是能力组合例子；模态可用于类型和筛选，不强制分割工作方式。当前仍是旧模态工作台实现，新节点界面尚未实施。

## 从哪里开始

- 看当前源、最近受测App、未整合候选与下一步：[当前行动](docs/CURRENT_ACTIONS.zh-CN.md)。整理前生产快照为`b334920907de0324bf3e0146bb78433742356a6c`；文档提交不代表新应用构建。
- 看各模型实际上支持什么、在哪验证：[模型与发行状态](docs/MODEL_SUPPORT_AND_RELEASE.zh-CN.md)。图文、声音、器乐、T2V已有指定App证据；歌声/音符编辑组合和I2V仍有候选验收缺口，不是全部模态全部配置已完成。
- 看为什么这样设计：[产品原则](docs/PRODUCT_PRINCIPLES.zh-CN.md)、[目标与发布边界](docs/PRODUCT_GOALS.zh-CN.md)。首发剩余承诺未因整理取消。
- 修改代码从[实际导航](docs/REPOSITORY_MAP.zh-CN.md)选路径；代理先读[AGENTS](AGENTS.md)。旧方案及版本见[历史](docs/history/README.md)，不是当前开工授权。

## 打开与构建

在**真实开发仓库**打开`D.xcworkspace`，选`D` scheme、My Mac。不要按项目名猜目录或使用同名空仓库；本机实际根目录从Git工作树清单与当前任务的本机回执定位。当前App部署目标macOS26.2、Apple Silicon；不声称所有历史Mac可运行，16GiB只是开发验证样本。

已有Xcode、固定依赖与本机合法签名配置时，从仓库根运行：

```sh
./scripts/build-local.sh --offline
```

脚本默认将产物/日志与App依赖检出放在仓库同级`D-Development`；隔离工作树必须先显式指定`D_DEVELOPMENT_ROOT`或脚本的`--derived-data-path`、`--source-packages-path`、`--log-path`，避免共用可变输出。`--offline`不能补齐缺失依赖，也不等于系统强制断网。签名配置由本机受控文件提供，不把Team/私钥/个人目录写进仓库。

普通Swift构建**不自动封装全部Python音视频引擎**。完整开发包另见`scripts/build-development-app.py`及对应任务；不将当前开发环境依赖说成干净Mac发行已完成。正式App不附模型权重，用户显式下载/导入；现有开发包的内含模型与路径差距见支持表，本页不表示已改好。

## 开发验证

| 入口 | 用途 |
| --- | --- |
| `scripts/test-foundation.sh` | 纯契约/运行时，无模型 |
| `scripts/test-workbench.sh` | 工作台、模型管理和项目服务CPU检查 |
| `scripts/build-mlx.sh` | 固定上游校验及d-infer构建 |
| `scripts/test-mlx.sh` | 指定模型的图文真实测试，需独立资源与完整证据 |

更细的触发关系见[导航验证表](docs/REPOSITORY_MAP.zh-CN.md)；文本/图像调用见[MLX指南](docs/MLX_REFERENCE_GUIDE.zh-CN.md)、[图像指南](docs/IMAGE_RUNTIME_GUIDE.zh-CN.md)，按其版本范围使用。构建、夹具、CLI、普通签名App、真人、发布分别验收；旧通过、条件跳过和当前文档检查不互相替代。

项目采用单仓模块化组织；DInference定义值契约，DRuntime调度，DMLXBackend执行，DWorkbench拥有应用服务，UI展示，App装配。旧公共Packages与研究/参考代码保留并分类，不属于当前App依赖图的部分也不据此删除。来源与许可证保留在Vendor和历史记录。
