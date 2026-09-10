# D-AW-VIEW-01 / AW1-V1

有限任务：AI 音频创作视图，来自用户批准第一阶段。Astra冻结接口；Terra/medium实现纯展示与交互，不能碰ProjectSession/ProjectStore/模型/工程配置。源633150477de90d30c1f44c915b1f10e13acd246d，实际准备基线见request。AW1-V1；初交+2修复，随后一次有界Lead接管；每执行900秒；不得递归。

只允许新增 Packages/UI/Sources/UI/Views/AudioCreationView.swift、Packages/UI/Sources/UI/State/AudioCreationActions.swift、Packages/UI/Tests/UITests/AudioCreationViewTests.swift。不得改AudioCreationDraft、其他视图/测试/文档。读取本任务、AudioCreationDraft、AudioTypes和现有 AudioWorkbenchView/AudioWorkbenchViewTests 的布局/检查惯例，按需AGENTS边界即可，不通读历史。

冻结public接口（Lead负责生产装配）：
- @MainActor public struct AudioCreationActions，public var闭包，public init显式参数：generate:()->Void, cancel:()->Void, save:()->Void, select:(UUID?)->Void, play:(UUID)->Void, stop:()->Void, adopt:(UUID?)->Void, reject:(UUID,Bool)->Void, export:(UUID)->Void, createFrom:(UUID)->Void, chooseModel:()->Void。
- public struct AudioCreationView: View；public init(draft: Binding<AudioCreationDraft>, source: ProjectAsset?, candidates: [ProjectAsset], selectedAssetID: UUID?, adoptedAssetID: UUID?, modelStatus: String, canGenerate: Bool, isBusy: Bool, progress: Double?, status: String?, transport: AudioTransport, actions: AudioCreationActions)。这些全是DWorkbench的public既有值/服务。可私有抽取view辅助，不增加公共接口。不要在视图做持久化或推理。
- draft Binding编辑保留未完成输入，revision由宿主更新；rejectedAssetIDs只读展示，不由binding编辑。

行为：提示词和生成/参考变体/区间重绘三操作；无source时禁用变体/重绘并解释，不悄悄改操作。duration/seed/steps/guidance/strength按真实支持显示，默认6秒/8步等来自draft，不把这些硬写成产品上限。source操作时显示来源时长固定而不开放矛盾duration；重绘区间以秒的数值输入/滑动选区表达，换算44.1kHz半开frame边界，显示区间；坏输入不可悄悄夹紧或覆盖原值，不使用字节/latent位置。非44.1k stereo WAV源明确不能当前模型编辑，原件仍能保留/试听/导出。不要声称精确乐谱/歌声控制。

候选列表含名字/时长/采用/已拒绝状态，选择和生成不自动采用；原声试听和候选试听共用transport，视图只调play/stop；采用、回到原声(adopt nil)、拒绝/恢复(reject bool)、保存、导出与基于候选新建均为显式动作。拒绝说明“不删原件/候选”；忙时禁改变持久引用/重启生成，取消保留。status显示保存/错误来源文字，不吞掉。无资产时能填提示生成。显示模型状态与chooseModel入口，无内部脚本/环境变量等实现细节。

macOS26原生Liquid Glass控件/工具栏语汇、减弱动态透明尊重系统设置；可用现有原生组件，不额外造炫光。宽窄可滚动重排，长中文/组合emoji提示和资产名不在窄窗截断；按钮可访问性标识稳定audio-create-*。不要为测试启动GUI/应用/麦克风/音频播放。

验收：纯回调路由且无隐式adopt；空source/非法范围可见状态且不发generate；seed完整大整数文本和Unicode保留；busy取消/按钮状态正确；宽窄离屏布局/控件存在；已拒绝候选可恢复；不声称离屏等于真人GUI。测试必须直接针对new view/handler，真实播放不在Worker范围。

受限CLI只own worktree +run/worker-output,tmp；网络关闭，无GPU/构建完整app/安装。尽量只swift CPU；SwiftPM内部沙箱拒绝暂停交Lead，不禁沙箱。其他权限异常停报。不要commit或编辑任务记录。开始只预检，Lead核验运行上下文后IMPLEMENT。
