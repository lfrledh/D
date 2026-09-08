# D-T0-VIEW-01 文字编辑与候选视图

spec_revision=1,contract_revision=1,batch_id=D-T0-WORKBENCH-01,run_id=run-initial。源6735266933773adaee33b3a66a01b09c0b1f7d9b；执行base_sha在请求。Lead维护规格；初次只读预检，IMPLEMENT后写。必读本规格、AGENTS边界/MULTI_AGENT_WORKFLOW副作用、TextDraft.swift/TextDraftSession.swift、既有WorkbenchView/GenerationInspector样式。别读取其他任务日志/全历史。

只新增Packages/UI/Sources/UI/Views/TextWorkbenchView.swift、TextSelectionEditor.swift以及Packages/UI/Tests/UITests/TextSelectionEditorTests.swift。不得改WorkbenchView、WorkbenchModel、ProjectSession/Store、TextDraft组件、App、工程/依赖/签名、任务文档/Git/其他工作树。

接口public @MainActor TextWorkbenchView:View，init(session:TextDraftSession, selection:NSRange, instruction:Binding<String>, modelStatus:String, canGenerate:Bool, canAccept:Bool, canUndo:Bool, isSaving:Bool, saveStatus:String, onEdit:@escaping(String)->Void, onSelection:@escaping(NSRange)->Void, onGenerate:@escaping()->Void, onCancel:@escaping()->Void, onAccept:@escaping()->Void, onReject:@escaping()->Void, onUndo:@escaping()->Void, onSave:@escaping()->Void, onChooseModel:@escaping()->Void)。通过现有session观察document/partialText/candidate/isRunning/isCancelling；不调用engine或自行edit/accept/save；全部动作发给Lead协调层。给出全部参数公开init，不能依赖其他Worker类型。

界面：左/上原稿可编辑，右/下原选段与替换候选可读比较；流中内容明确正在生成，绝不写原稿；中文说明“选中文字后描述修改意图”。模型状态/选择现有模型目录按钮；修改要求；改写/取消/接受/拒绝/撤销/保存和明确保存状态。canAccept=false时显示原稿或选区已改变提示，拒绝仍可用。无候选时不误显示失败。Liquid Glass只导航控制，编辑纸面中性不透明，支持键盘、无障碍标识、文本可选复制；不暴露模型数组/协议调试信息。generation期间仍可编辑/换选区；按钮可用性来自参数与session状态，isSaving不覆盖当前文字。

原生编辑桥使用NSTextView/NSScrollView或等价可靠AppKit桥：UTF16 NSRange向上回传；允许普通输入/IME组合，不在markedText期间按异步SwiftUI旧值覆盖；只在文档id/revision或字节确有变更时更新，程序化更新禁止回声回调；同doc正常光标保持，跨doc清除错误选择；不把规范等价Unicode当同字节。回调身份必须与当前输入文档匹配（可以闭包捕获docid/revision，由Lead再验）。完整合法选择由TextRewriteSelection验证，不能按字节偏移。给标识text-draft-editor、text-instruction、text-rewrite、text-cancel、text-accept、text-reject、text-undo、text-save、text-model-select、text-candidate-output。

测试是对应局部桥行为/Unicode边界/无程序化回声，不能通过硬编码UI文本镜像凑测试；若必须真实window/AppKit系统UI交互才能验证，标待Lead GUI，不自行启动UI。测试文件可以对提取的真实转换逻辑做纯CPU检查。Swift编译/测试由Lead串行承担，Worker只git diff --check等静态检查。未执行不可声称通过。

gpt-5.6-terra/medium，已限制本工作树+本run/worker-output,tmp写根，网络关闭。初交+2修复、每轮15分钟，不递归/commit/改文档/工具默认缓存/网络/模型。Python只内存compile；未知权限事件暂停报Lead。回传修改/限制/验证或未执行项/异常/自有进程状态。

## 修订2：初次审核反例与第一次修复
Lead 已确认 implementation 结束、模型/写根不变，静态审核无权限拒绝或越界命令。初次候选45604b851574936484338ca8a28ae9711c4888c5保留。修复1/2，仅原3个文件；不改规格/Lead接线/原核心。先读本补充，不加载历史。
1. 真实比较反例：生成针对“原选段A”，随后用户选择B或改正文，候选仍可查看但不可接受。右侧“原选段”现在从当前document/selection算，误展示B。应优先使用candidate.selection.selectedText；流期间也应保留点击生成时捕获片段，生成中标签始终明确。不要改接收接口或将候选原选段改成当前值。
2. 桥update在hasMarkedText guard前换了callbacks：跨文档更新遇IME时会把旧文本送给新文档回调。冻结规则要求输入归属正确。请明确处理documentID切换，不能把旧composition交给新回调；同文档IME不能被旧SwiftUI值覆盖。Lead主视图会.id(documentID)，但桥仍需满足其已声明身份规则。
3. 程序请求collapsed selection现在validRange拒绝，正文相同但revision变化时无法清除旧选区。编辑器光标允许合法Character边界的空range，改写依旧只接受非空。分别处理这两种语义，并补测试。
4. textDidChange后、下一次SwiftUI update前 selection回调以旧currentDocument验证新的字符串，会误拒绝新Unicode输入。用当前原生文本验证选区，身份仍按当前document绑定，不能改成字节索引。
5. configure可纵向伸展的NSTextView及宽度/滚动尺寸，确保长稿可滚动；禁止启动真实窗口/GUI。补真实桥行为的离屏AppKit单元测试（无window/no activation）覆盖程序更新无回声、文档切换、空选区、IME保留。若AppKit需启动GUI才可验证，保留明确未测，不伪造helper镜像测试。Lead串行执行，Worker不运行swift。
这些是初次冻结契约的反例/实现检查，不是新增功能。允许局部设计选择，不重写整个UI。回传具体修改、异常、自检与未覆盖项。

## 修订3：编译反例与第二次修复
修订3，第二次/最后一次普通修复。Lead先审查了repair1事件，无权限拒绝/未知副作用；同一Terra/medium及写根。Lead真实swift test在64ceb4de180a799a75807eddf0a7467c9604948e编译失败：TextSelectionEditor.swift第62、66行NSSize(width:.greatestFiniteMagnitude,height:.greatestFiniteMagnitude)对CGFloat/Double歧义。请按AppKit实际类型修正。静态审核同时要求validCursorRange明确保证Character边界，不以Range(NSRange,in:)可转换就默认为组合字符边界；保留当前Unicode断言。候选长文本需要滚动查看，不让比较区长稿挤出接受/拒绝按钮。流出非空后仍明确生成中（上一修复要求）。只改原3文件，不变接口/验收/文档，不运行Swift。修复后Lead编译/离屏测试；剩余预算0，若还有明确局部问题只能按规则Lead有界接管。请回传异常、实际改动、未执行测试。

## Candidate handoff, 2026-09-08

Terra/medium initial delivery + two repairs completed; no ordinary repair budget remains. Final local worker candidate 5047fe41bfa39bce8723d1cfca74dd5f32985b02 passed 7 related CPU/offscreen methods via Lead. Combined actual tested code 62fc7b5dd568e5f53354382dd189d09e96b7e0bc passed142 workbench methods,17 core methods and isolated unsigned app compilation. Lead reviewed Worker implementation; a separate read-only reviewer checked important Lead integration. This is not real model/GUI acceptance and is not integrated into the source branch. Processes ended; worktree and evidence retained. See [batch checkpoint](D-T0-WORKBENCH-01.md) and external final-receipt.json for version/protection/recovery details.
