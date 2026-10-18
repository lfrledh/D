# PAN：连续手掌平移

> 2026-10-19 当前状态：本次没有新的PAN采样或因果对照，G2资格未通过；不借ZOOM或NODE的诊断失败解释PAN。旧统计继续沿用原资格。

**结论：必须独立于ZOOM解释。当前证据指向原生滚动后的几何/宿主/框架与合成候选，但未证明哪层导致迟滞。** 本阶段复算旧03：全线程1518ms，主1383ms；主调度Running1.367778502s、Runnable0.018070348s，Blocked9.606351766s。Blocked等待栈未采，不能全叫空闲或GPU fence。早/中/晚1/259/1123ms，实际输入段未知。

真实源码链：本地事件monitor→`WorkflowCanvasViewportInput.ProbeView.routePointer`→空白/手形阈值→`clip.scroll`/`reflectScrolledClipView`；非Observable scrollTracking在pan期间阻止父onScrollObservation回传，结束才提交最终center。它反驳“每个pan tick显式更新父工作区”，不排除SwiftUI/AppKit后代、祖先几何观察、跟踪区域和合成工作。

主线程inclusive：layout666ms、AG/SwiftUI452ms、viewport76ms、玻璃背景宿主102ms、可读性76ms、资料库16ms、语言10ms、操作树3ms。连接绘制11ms、geometry2ms；未命中connection_hit不能宣称其永不执行。全线程self首项objc_msgSend58ms、mach_msg2_trap47ms、iokit_user_client_trap41ms、AG::Graph::propagate_dirty29ms；系统陷阱的Running样本不是GPU等待时长。高工作量bin选样落在`NSScrollView _updateTrackingAreasWithInvalidCursorRects`的提交链；另有ViewTransform/ShapeStyle/titlebar路径。这不能证明画布事件滚错目标或标题栏是主因。

每个玻璃表面监听自身/祖先bounds/frame，geometryDidChange可更新readability、needsLayout/needsDisplay和光学参数。反证：同geometry早退、离屏释放、没有消费者时readability早退、pan复用背景字段；光学host的rootView更新不等于重新创建host。只有canvas角色invalidate背景owner，不能说每个按钮广播全owner。连接viewport观察主要改原生可见区/needsDisplay，不能直接称全路径重算。

顶层update467条能在本run内精确关联swap和displayed区间；仍缺主窗口/内容版本与输入，因此没有FPS。玻璃GPU/overdraw/合成未排除；全局CPU证据也不能证明它必然是瓶颈。ZOOM的717ms Entry比较在PAN不成立，不用于解释本页。

至多两条下一候选（均待延迟资格，不是修补授权）：①原生clip滚动后几何/宿主/跟踪区传播；②同host/面积下材质与系统合成成本。需要固定轨迹、实际clip位置、每面通知/早退与呈现关联，先基线后单因素往返。现有源码保护保留，不改视野、字体或事件归属。
