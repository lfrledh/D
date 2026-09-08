# D-T0-VIEW-01 文字编辑与候选视图

spec_revision=1,contract_revision=1,batch_id=D-T0-WORKBENCH-01,run_id=run-initial。源6735266933773adaee33b3a66a01b09c0b1f7d9b；执行base_sha在请求。Lead维护规格；初次只读预检，IMPLEMENT后写。必读本规格、AGENTS边界/MULTI_AGENT_WORKFLOW副作用、TextDraft.swift/TextDraftSession.swift、既有WorkbenchView/GenerationInspector样式。别读取其他任务日志/全历史。

只新增Packages/UI/Sources/UI/Views/TextWorkbenchView.swift、TextSelectionEditor.swift以及Packages/UI/Tests/UITests/TextSelectionEditorTests.swift。不得改WorkbenchView、WorkbenchModel、ProjectSession/Store、TextDraft组件、App、工程/依赖/签名、任务文档/Git/其他工作树。

接口public @MainActor TextWorkbenchView:View，init(session:TextDraftSession, selection:NSRange, instruction:Binding<String>, modelStatus:String, canGenerate:Bool, canAccept:Bool, canUndo:Bool, isSaving:Bool, saveStatus:String, onEdit:@escaping(String)->Void, onSelection:@escaping(NSRange)->Void, onGenerate:@escaping()->Void, onCancel:@escaping()->Void, onAccept:@escaping()->Void, onReject:@escaping()->Void, onUndo:@escaping()->Void, onSave:@escaping()->Void, onChooseModel:@escaping()->Void)。通过现有session观察document/partialText/candidate/isRunning/isCancelling；不调用engine或自行edit/accept/save；全部动作发给Lead协调层。给出全部参数公开init，不能依赖其他Worker类型。

界面：左/上原稿可编辑，右/下原选段与替换候选可读比较；流中内容明确正在生成，绝不写原稿；中文说明“选中文字后描述修改意图”。模型状态/选择现有模型目录按钮；修改要求；改写/取消/接受/拒绝/撤销/保存和明确保存状态。canAccept=false时显示原稿或选区已改变提示，拒绝仍可用。无候选时不误显示失败。Liquid Glass只导航控制，编辑纸面中性不透明，支持键盘、无障碍标识、文本可选复制；不暴露模型数组/协议调试信息。generation期间仍可编辑/换选区；按钮可用性来自参数与session状态，isSaving不覆盖当前文字。

原生编辑桥使用NSTextView/NSScrollView或等价可靠AppKit桥：UTF16 NSRange向上回传；允许普通输入/IME组合，不在markedText期间按异步SwiftUI旧值覆盖；只在文档id/revision或字节确有变更时更新，程序化更新禁止回声回调；同doc正常光标保持，跨doc清除错误选择；不把规范等价Unicode当同字节。回调身份必须与当前输入文档匹配（可以闭包捕获docid/revision，由Lead再验）。完整合法选择由TextRewriteSelection验证，不能按字节偏移。给标识text-draft-editor、text-instruction、text-rewrite、text-cancel、text-accept、text-reject、text-undo、text-save、text-model-select、text-candidate-output。

测试是对应局部桥行为/Unicode边界/无程序化回声，不能通过硬编码UI文本镜像凑测试；若必须真实window/AppKit系统UI交互才能验证，标待Lead GUI，不自行启动UI。测试文件可以对提取的真实转换逻辑做纯CPU检查。Swift编译/测试由Lead串行承担，Worker只git diff --check等静态检查。未执行不可声称通过。

gpt-5.6-terra/medium，已限制本工作树+本run/worker-output,tmp写根，网络关闭。初交+2修复、每轮15分钟，不递归/commit/改文档/工具默认缓存/网络/模型。Python只内存compile；未知权限事件暂停报Lead。回传修改/限制/验证或未执行项/异常/自有进程状态。
