# D-T0-STORE-01 项目文字持久化

spec_revision=1, contract_revision=1, batch_id=D-T0-WORKBENCH-01, run_id=run-initial。源6735266933773adaee33b3a66a01b09c0b1f7d9b；实际base_sha在派工请求。Lead维护本文件，初次只预检，IMPLEMENT后实现。必读本规格、AGENTS数据保护/MULTI_AGENT_WORKFLOW异常与预算、ProjectModels.swift/ProjectStore.swift、相关ProjectMigrationTests、TextDraft.swift；不加载全项目历史。

允许：Packages/UI/Sources/DWorkbench/Project/ProjectModels.swift、ProjectStore.swift；新增Packages/UI/Tests/DWorkbenchTests/ProjectTextStoreTests.swift；已有ProjectStoreTests.swift和ProjectMigrationTests.swift仅将原升级后schemaVersion==2改为currentSchemaVersion（其他既有断言不改）。禁区：TextDraft组件、ProjectSession/UI、App、工程/依赖/签名/其他任务/源树/Git元数据/文档。

API：public enum ProjectDocumentKind:String,Codable,Sendable {case image,text}；ProjectDocument公开var kind:ProjectDocumentKind（init默认.image）；var textDraft:TextDraftDocument?（init默认nil）。旧JSON没有kind时默认为image，不能任意丢弃textDraft。currentSchemaVersion=3；v1/v2按原rawbytes备份project.v1.backup.json或新增public static versionTwoBackupFilename="project.v2.backup.json"，沿用锁/no-follow/fsync/checkpoint/原子发布。v1映射仍保留id、文档、图片/任务和原件；v2字段等价。升级前validate，失败可重试、冲突备份不覆盖。不触碰真实项目。

ProjectStore新增public createTextDocument(name:String="新文稿", text:String="") throws -> ProjectManifest：新doc id与TextDraftDocument.id一致，激活它，文字<=1MiB。新增public saveTextDraft(_ draft:TextDraftDocument, documentID:UUID, expectedRevision:UUID) throws -> ProjectManifest：只接受text类型、id匹配、当前text.revision==expectedRevision；字节确实改变时revision不能重复（即使Swift String规范等价也判断UTF8字节）。精确同id/revision/字节保存可无变化。拒绝stale时用ProjectStoreError.externalModification。不让image saveDraft/enqueue/adopt等写入text文档；text文档不得含图像source/adopted/selectedAsset引用或image jobs，validate检查kind/payload/ID/上限/名称。公共已有image API默认行为保留，manifest总32MiB预算不放宽。

可选择局部实现方式，不重构ProjectFiles或创造通用存储框架。已有publish fsync失败后的行为不以吞错掩盖；新增测试覆盖真实自有temp目录：v2原字节备份/失败点重开、Unicode/空稿/重开原revision、stale/错误id/错误kind、超限、外部修改/失联导致保存失败且原文件不坏、混合image/text恢复。新测试全部使用D_TEST_TEMP_DIR下唯一目录；不写系统用户默认缓存，不网络/模型/GUI。不要把测试成功说成真实App验收。

模型gpt-5.6-terra/medium；只写本工作树+run/worker-output+run/tmp；网络关闭。Lead承担所有Swift编译/测试串行槽位，本Worker仅静态检查git diff --check/读代码，不运行Swift/Xcode。Python语法只tokenize.open+compile内存，不py_compile。权限拒绝按已落地规程暂停并报Lead；不自己禁用沙箱/改缓存/提升权限。初交+2修复，每轮15分钟，禁止递归、commit、修改规则。结果回传实际文件/自检与未执行测试/异常/自有进程状态。

## 修订2：初次审核反例与第一次修复
Lead已确认implementation结束、实际Terra/medium及受限写根，事件无未知权限失败；初次候选1a98c5e19fdb4c103c3478f0520253e7577b9633保留。修复1/2，仅原允许文件。Lead已添加counterexample，禁止删除/弱化它。
冻结契约仅精确同id/revision/bytes可no-op。saveTextDraft现在只比较bytes就直接return，因此sameText/newUUID未持久化，后续expectedRevision新UUID被当外部修改。请修复该判断，保留changedbytes复用旧UUID拒绝与externalModification语义。相同bytes但新revision必须存储。
另外ProjectDocument.decode把原required draft改decodeIfPresent默认值；schema2原本没有draft即损坏，不应默默制造默认图像配方。请保持旧必需字段严格性（实际v1由独立legacy路径迁移）。新schema3你创建的text文档仍有兼容draft字段。补缺少draft的损坏v2反例，保持raw原件不改变。
新测试CPU由Lead运行，Worker只静态检查。不要修改其他行为、声明通过未执行测试。

## 修订3：Unicode外部编辑字节反例
修订3；第二次/最后一次普通修复。上一轮实际Terra/medium/受限写根、事件与保护已查，无未知权限事件；b59ceac通过40相关方法。Lead新持久反例externalCanonicalUnicodeChangeCannotBeOverwritten已在b59ceac真实失败：同id/revision外部将正文é改为e+combining acute，Swift合成Equatable认为manifest未变，后续本地save覆盖外部字节（日志run-20260908/store-unicode-counterexample.log；1方法2断言失败）。这是冻结文本字节保全和原件保护的遗漏，不降低旧契约。
限定原ProjectStore.swift和对应ProjectTextStoreTests.swift做最小修补；不改已接纳TextDraft核心，不泛化重写整个存储框架。verifyUnchangedManifest在保留现有decoded manifest equality外，需对textDraft正文的实际UTF8字节确认未变，规范等价不能掩盖外部内容改动；仅无意义JSON空白仍按已有语义允许。保留全部Lead反例。相同bytes新revision逻辑/旧v1v2迁移不退化。静态自检，Swift由Lead串行运行。禁止其他文件、网络/commit/文档修改/递归。回传实际改动/异常/未测项。

## Candidate handoff, 2026-09-08

Terra/medium initial delivery + two repairs completed; no ordinary repair budget remains. Final local worker candidate fd1bbc22bf849ca9d4c09fa6d79f001ac938df79 passed 41 related CPU/offscreen methods via Lead. Combined actual tested code 62fc7b5dd568e5f53354382dd189d09e96b7e0bc passed142 workbench methods,17 core methods and isolated unsigned app compilation. Lead reviewed Worker implementation; a separate read-only reviewer checked important Lead integration. This is not real model/GUI acceptance and is not integrated into the source branch. Processes ended; worktree and evidence retained. See [batch checkpoint](D-T0-WORKBENCH-01.md) and external final-receipt.json for version/protection/recovery details.
