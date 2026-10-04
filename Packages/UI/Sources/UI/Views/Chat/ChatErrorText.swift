import Foundation

/// Display text only. Callers keep the original reason for storage and execution.
@MainActor
enum ChatErrorText {
    struct Entry {
        let original: String
        let key: String
        let english: String
    }

    // Exact product-owned literals. Do not infer a cause from a substring of a
    // backend diagnostic or from user/model content.
    static let entries: [Entry] = [
        .init(original: "上下文选择含未知、重复或无效的消息身份。", key: "chat.error.invalidContextSelection", english: "The context selection contains an unknown, duplicate, or invalid message ID."),
        .init(original: "Imported text has conflicting execution provenance.", key: "chat.error.importProvenance", english: "Imported text has conflicting execution provenance."),
        .init(original: "所选路径含未完成或待处理工具调用。", key: "chat.error.unfinishedPath", english: "The selected path contains an unfinished answer or pending tool call. Finish it or choose another path."),
        .init(original: "部分回答须显式采用后才能进入上下文。", key: "chat.error.adoptPartial", english: "Use the partial answer explicitly before continuing with it in the context."),
        .init(original: "完整聊天消息超过1MiB；请显式开启新会话或分叉较短路径。", key: "chat.error.contextTooLarge", english: "The complete chat messages exceed 1 MiB. Start a new conversation or fork a shorter path explicitly."),
        .init(original: "文字附件缺少冻结快照。", key: "chat.error.missingTextSnapshot", english: "The text attachment has no frozen snapshot."),
        .init(original: "附件类型不能用于文字聊天。", key: "chat.error.unsupportedContextAttachment", english: "This attachment type cannot be used in text chat."),
        .init(original: "聊天记录保存失败，请先重试保存。", key: "chat.error.retryChatSave", english: "Saving the chat record failed. Retry the save before continuing."),
        .init(original: "聊天回答尚未写入项目，请先在文字页重试保存；原记录和生成结果仍保留。", key: "chat.error.backupPendingSave", english: "The chat answer has not been saved to the project. Retry saving on the text page before backing up. The original record and generated result remain."),
        .init(original: "聊天仍在生成、语音处理或停止中，请待资源释放后再备份。", key: "chat.error.backupBusy", english: "Chat is generating, processing speech, or stopping. Wait for resources to be released before backing up."),
        .init(original: "对话不存在。", key: "chat.error.missingConversation", english: "The conversation no longer exists."),
        .init(original: "会话正在关闭。", key: "chat.error.sessionClosing", english: "The session is closing."),
        .init(original: "当前会话仍在运行，请等待其停止后归档。", key: "chat.error.archiveBusy", english: "The current conversation is still running. Wait for it to stop before archiving."),
        .init(original: "草稿超过1MiB。", key: "chat.error.draftTooLarge", english: "The draft exceeds 1 MiB."),
        .init(original: "消息为空或超过1MiB。", key: "chat.error.invalidMessageSize", english: "The message is empty or exceeds 1 MiB."),
        .init(original: "请等待回答结束或停止后再选择引用。", key: "chat.error.quoteBusy", english: "Wait for the answer to finish or stop before selecting a quotation."),
        .init(original: "草稿或来源已改变；选段已保存在素材中，没有覆盖新输入。", key: "chat.error.quoteDraftChanged", english: "The draft or source changed. The quotation was saved as an asset without replacing the new input."),
        .init(original: "项目已关闭或正在离开；未添加迟到的附件。", key: "chat.error.projectClosingAttachment", english: "The project is closed or closing. The late attachment was not added."),
        .init(original: "一次最多32个附件。", key: "chat.error.attachmentLimit", english: "A message can have at most 32 attachments."),
        .init(original: "这条路径仍在生成，请等待停止后再分叉。", key: "chat.error.forkBusy", english: "This path is still generating. Wait for it to stop before forking."),
        .init(original: "请等待当前会话停止。", key: "chat.error.waitForStop", english: "Wait for the current conversation to stop."),
        .init(original: "运行中或待处理工具的回答不能作为人工正文采用。", key: "chat.error.cannotAdoptRunning", english: "A running answer or one with pending tool calls cannot be adopted as edited text."),
        .init(original: "请等待当前生成或辅助任务结束／保存。", key: "chat.error.assistanceBusy", english: "Wait for the current generation or assistance task to finish and save."),
        .init(original: "辅助任务预算超过当前模型请求上限；请明确调整预算。", key: "chat.error.assistanceBudget", english: "The assistance budget exceeds the current model request limit. Adjust the budget explicitly."),
        .init(original: "辅助任务预算超过所选请求上限，没有自动降低或提交。", key: "chat.error.assistanceBudgetSubmit", english: "The assistance budget exceeds the selected request limit. It was not lowered or submitted automatically."),
        .init(original: "辅助输出未完整结束；原文保留，未采用截断／工具内容。", key: "chat.error.incompleteAssistance", english: "Assistance output did not finish. The original remains; truncated or tool content was not adopted."),
        .init(original: "待发送引用的来源已移除或更新，请重新选择。", key: "chat.error.quoteSourceChanged", english: "The source of a pending quotation was removed or updated. Select it again."),
        .init(original: "请等待当前操作结束后预览模板。", key: "chat.error.templatePreviewBusy", english: "Wait for the current operation to finish before previewing the template."),
        .init(original: "请选择可用会话和模型。", key: "chat.error.chooseSessionModel", english: "Choose an available conversation and model."),
        .init(original: "回答参数仍有未完成或无效输入，请先修正。", key: "chat.error.invalidAnswerSettings", english: "Some answer settings are incomplete or invalid. Correct them before continuing."),
        .init(original: "已有聊天推理或待保存结果；请等待或重试保存。其他会话可以继续编辑。", key: "chat.error.chatBusyRetrySave", english: "Chat is generating or has a result awaiting save. Wait or retry saving. You can still edit other conversations."),
        .init(original: "已有聊天推理或待保存结果。", key: "chat.error.chatBusy", english: "Chat is generating or has a result awaiting save."),
        .init(original: "请填写消息并选择模型。", key: "chat.error.enterMessageModel", english: "Enter a message and choose a model."),
        .init(original: "所选路径已有待回复用户消息，请重试该消息或选择已完成路径。", key: "chat.error.pendingUserReply", english: "The selected path already ends with a user message awaiting a reply. Retry that message or choose a completed path."),
        .init(original: "另一次聊天推理已开始；请等待资源释放后重试。", key: "chat.error.generationStarted", english: "Another chat generation has started. Wait for resources to be released, then retry."),
        .init(original: "会话在准备期间已归档或删除；没有提交新的生成。", key: "chat.error.sessionChangedBeforeRun", english: "The conversation was archived or deleted during preparation. No new generation was submitted."),
        .init(original: "文字输出缺少已发布原文。", key: "chat.error.missingPublishedText", english: "The text output has no published original."),
        .init(original: "尝试记录已丢失。", key: "chat.error.missingAttempt", english: "The attempt record is missing."),
        .init(original: "待保存聊天结果已失去原始保存上下文。", key: "chat.error.saveContextLost", english: "The pending chat result lost its original save context."),
        .init(original: "保存恢复未返回已发布文字结果。", key: "chat.error.saveRecoveryMissingText", english: "Save recovery did not return a published text result."),
        .init(original: "聊天仍在运行、播放或有待保存结果。", key: "chat.error.chatStillBusy", english: "Chat is still running, playing, or has a result awaiting save."),
        .init(original: "请先允许本会话联网；没有发送查询。", key: "chat.error.networkPermission", english: "Allow network access for this conversation first. No query was sent."),
        .init(original: "请先选择或采用回答。", key: "chat.error.chooseOrAdoptAnswer", english: "Choose or adopt an answer first."),
        .init(original: "成果正在保存，或项目已离开。", key: "chat.error.artifactSaveBusy", english: "The artifact is being saved or the project has closed."),
        .init(original: "完整聊天及成果超过16MiB；未更改现有版本，请在新的独立项目中保存。", key: "chat.error.projectChatTooLarge", english: "The complete chat and artifacts exceed 16 MiB. The existing version was not changed; save in a new independent project."),
        .init(original: "请先采用部分回答，或选择已完成的回答后保存。", key: "chat.error.adoptBeforeSave", english: "Adopt the partial answer or choose a completed answer before saving."),
        .init(original: "对话已删除或不存在。", key: "chat.error.deletedConversation", english: "The conversation was deleted or no longer exists."),
        .init(original: "请返回原对话后再采用此回答。", key: "chat.error.returnToAdopt", english: "Return to the original conversation before adopting this answer."),
        .init(original: "回答仍在运行、待保存或等待工具完成，不能采用。", key: "chat.error.answerNotReadyToAdopt", english: "The answer is running, awaiting save, or waiting for tools. It cannot be adopted yet."),
        .init(original: "请等待回答完成并返回原对话后再选择版本。", key: "chat.error.versionNotReady", english: "Wait for the answer to finish, then return to its conversation before choosing a version."),
        .init(original: "请返回原对话后再修改消息。", key: "chat.error.returnToEdit", english: "Return to the original conversation before changing the message."),
        .init(original: "请先恢复已删除的对话。", key: "chat.error.restoreConversation", english: "Restore the deleted conversation first."),
        .init(original: "请返回原对话后再编辑消息。", key: "chat.error.returnToEditMessage", english: "Return to the original conversation before editing the message."),
        .init(original: "长期保存入口不可用。", key: "chat.error.retainUnavailable", english: "Long term saving is unavailable."),
        .init(original: "长期保存入口不可用；成果仍在临时会话。", key: "chat.error.retainTemporary", english: "Long term saving is unavailable. The artifact remains in the temporary conversation."),
        .init(original: "消息不存在。", key: "chat.error.missingMessage", english: "The message no longer exists."),
        .init(original: "回答不存在。", key: "chat.error.missingAnswer", english: "The answer no longer exists."),
        .init(original: "Measured output metadata is unavailable. / 找不到该输出的实际记录。", key: "chat.error.outputMetadata", english: "Measured output metadata is unavailable."),
        .init(original: "仅可丢弃临时会话。", key: "chat.error.discardTemporaryOnly", english: "Only a temporary conversation can be discarded."),
        .init(original: "请选择独立的长期保存位置。", key: "chat.error.independentSaveLocation", english: "Choose an independent location for long term saving."),
        .init(original: "保存操作已结束。", key: "chat.error.saveOperationEnded", english: "The save operation has ended."),
        .init(original: "成果不是UTF-8文字。", key: "chat.error.artifactNotUTF8", english: "The artifact is not UTF-8 text."),
        .init(original: "发现多个待恢复的辅助保存，请保留原件检查。", key: "chat.error.multipleAssistanceSaves", english: "Multiple assistance saves await recovery. Keep the originals and inspect them."),
        .init(original: "聊天记录版本已达上限。", key: "chat.error.chatRevisionLimit", english: "The chat record has reached its version limit."),
        .init(original: "临时会话不进入常规备份，请显式保存成果。", key: "chat.error.temporaryBackup", english: "Temporary conversations are not included in regular backups. Save the artifact explicitly."),
        .init(original: "聊天已改变，请重新导出会话包。", key: "chat.error.exportChanged", english: "Chat changed. Export the conversation archive again."),
        .init(original: "会话标题无效或数量已达上限。", key: "chat.error.invalidTitleOrLimit", english: "The conversation title is invalid or the conversation limit has been reached."),
        .init(original: "会话标题无效。", key: "chat.error.invalidTitle", english: "The conversation title is invalid."),
        .init(original: "资料已移除，请重新选择。", key: "chat.error.knowledgeRemoved", english: "The source was removed. Select it again."),
        .init(original: "原消息不属于此会话。", key: "chat.error.messageWrongConversation", english: "The original message does not belong to this conversation."),
        .init(original: "请在可用会话中保存选段。", key: "chat.error.quoteUnavailableConversation", english: "Save the quotation in an available conversation."),
        .init(original: "引用超过草稿或附件容量；原文未改。", key: "chat.error.quoteCapacity", english: "The quotation exceeds the draft or attachment capacity. The original text was not changed."),
        .init(original: "请选择支持有序消息的明确文字模型。", key: "chat.error.orderedMessageModel", english: "Choose an explicit text model that supports ordered messages."),
        .init(original: "系统提示超过64KiB。", key: "chat.error.systemPromptLimit", english: "The system prompt exceeds 64 KiB."),
        .init(original: "提示预设无效。", key: "chat.error.invalidPreset", english: "The prompt preset is invalid."),
        .init(original: "预设不存在。", key: "chat.error.missingPreset", english: "The preset no longer exists."),
        .init(original: "附件类型或名称无效。", key: "chat.error.invalidAttachment", english: "The attachment type or name is invalid."),
        .init(original: "TXT/MD 来源必须是不超过512KiB的 UTF-8。", key: "chat.error.textSourceLimit", english: "A TXT or MD source must be UTF-8 and no larger than 512 KiB."),
        .init(original: "文档原件不存在。", key: "chat.error.missingDocument", english: "The original document no longer exists."),
        .init(original: "This attachment needs an explicit conversion first. / 此素材需要先显式转换。", key: "chat.error.attachmentNeedsConversion", english: "This attachment needs an explicit conversion first."),
        .init(original: "Attachment position is no longer available. / 附件位置已经变化。", key: "chat.error.attachmentPositionChanged", english: "The attachment position is no longer available."),
        .init(original: "This conversation cannot accept attachments. / 此会话目前不能修改附件。", key: "chat.error.attachmentsUnavailable", english: "This conversation cannot accept attachments."),
        .init(original: "资料检索接受文字或已解释的文档。", key: "chat.error.knowledgeSourceType", english: "Knowledge search accepts text or an interpreted document."),
        .init(original: "临时会话不连接长期资料集合，或项目正在关闭。", key: "chat.error.knowledgeCollectionUnavailable", english: "A temporary conversation cannot connect to a long term knowledge collection, or the project is closing."),
        .init(original: "个人资料库尚未就绪。", key: "chat.error.personalLibraryNotReady", english: "The personal library is not ready."),
        .init(original: "所选资料已移除。", key: "chat.error.selectedKnowledgeRemoved", english: "The selected source was removed."),
        .init(original: "复制期间来源或目标已改变；没有登记迟到资料。", key: "chat.error.knowledgeCopyChanged", english: "The source or destination changed during copying. The late source was not registered."),
        .init(original: "请等待资料重排完成，或检查输出预算。", key: "chat.error.rerankBusyOrBudget", english: "Wait for knowledge reranking to finish, or check the output budget."),
        .init(original: "请选择模型及其允许范围内的重排预算。", key: "chat.error.rerankBudget", english: "Choose a model and a reranking budget within its allowed range."),
        .init(original: "重排没有完整输出。", key: "chat.error.rerankMissingOutput", english: "Reranking produced no complete output."),
        .init(original: "重排未完整结束；原文保留，未采用。", key: "chat.error.rerankIncomplete", english: "Reranking did not finish. The original was retained and no result was adopted."),
        .init(original: "重排期间会话或资料范围改变；未采用旧结果。", key: "chat.error.rerankScopeChanged", english: "The conversation or knowledge scope changed during reranking. The old result was not adopted."),
        .init(original: "重排保存没有返回原文。", key: "chat.error.rerankSaveMissingText", english: "The reranking save returned no original text."),
        .init(original: "重排引用已失效；请重新检索。", key: "chat.error.rerankQuoteStale", english: "A reranking quotation is stale. Search again."),
        .init(original: "引用对应的资料版本已改变或不在本资料库；请重新检索。", key: "chat.error.quoteKnowledgeChanged", english: "The quoted source version changed or is no longer in this library. Search again."),
        .init(original: "请先选择检索资料范围。", key: "chat.error.selectKnowledgeScope", english: "Select a knowledge search scope first."),
        .init(original: "检索期间项目或资料范围已改变，请重新检索。", key: "chat.error.searchScopeChanged", english: "The project or knowledge scope changed during search. Search again."),
        .init(original: "附件不存在。", key: "chat.error.missingAttachment", english: "The attachment no longer exists."),
        .init(original: "只能编辑已有用户消息。", key: "chat.error.editUserOnly", english: "Only an existing user message can be edited."),
        .init(original: "会话数量已达上限。", key: "chat.error.conversationLimit", english: "The conversation limit has been reached."),
        .init(original: "助手消息不存在。", key: "chat.error.missingAssistantMessage", english: "The assistant message no longer exists."),
        .init(original: "人工版本不属于该消息。", key: "chat.error.revisionWrongMessage", english: "The edited version does not belong to that message."),
        .init(original: "已启用摘要覆盖范围重叠，请仅保留一个版本。", key: "chat.error.overlappingSummaries", english: "Enabled summaries cover overlapping messages. Keep only one version."),
        .init(original: "本次上下文的记忆来源超过预算，请减少启用条目。", key: "chat.error.memorySourceBudget", english: "Memory sources for this context exceed the budget. Enable fewer entries."),
        .init(original: "这份旧请求或摘要使用的记忆已修改、关闭或忘记，不能按原请求重现；请生成新候选。", key: "chat.error.memoryReplayChanged", english: "Memory used by the old request or summary changed, was disabled, or was forgotten. It cannot be replayed as the original request; generate a new candidate."),
        .init(original: "临时会话不读取长期记忆。", key: "chat.error.temporaryMemoryRead", english: "Temporary conversations do not read long term memory."),
        .init(original: "记忆范围不属于当前项目。", key: "chat.error.memoryScopeWrongProject", english: "The memory scope does not belong to this project."),
        .init(original: "临时会话不写入长期记忆。", key: "chat.error.temporaryMemoryWrite", english: "Temporary conversations do not write long term memory."),
        .init(original: "个人记忆所有者尚未就绪；项目记忆仍可用。", key: "chat.error.personalMemoryOwnerNotReady", english: "The personal memory owner is not ready. Project memory remains available."),
        .init(original: "记忆不属于当前项目。", key: "chat.error.memoryWrongProject", english: "The memory does not belong to this project."),
        .init(original: "记忆版本已过期或已忘记。", key: "chat.error.memoryVersionStale", english: "The memory version is stale or was forgotten."),
        .init(original: "缺少记忆初始版本。", key: "chat.error.memoryInitialVersion", english: "The initial memory version is missing."),
        .init(original: "要编辑的摘要已不存在。", key: "chat.error.summaryToEditMissing", english: "The summary to edit no longer exists."),
        .init(original: "摘要不存在。", key: "chat.error.missingSummary", english: "The summary no longer exists."),
        .init(original: "建议已不属于此会话。", key: "chat.error.suggestionWrongConversation", english: "The suggestion no longer belongs to this conversation."),
        .init(original: "临时会话不提取长期记忆。", key: "chat.error.temporaryMemoryExtraction", english: "Temporary conversations do not extract long term memory."),
        .init(original: "辅助记忆范围不属于当前项目。", key: "chat.error.assistanceMemoryScope", english: "The assistance memory scope does not belong to this project."),
        .init(original: "辅助任务授权或会话状态已改变；原结果保留但不自动采用。", key: "chat.error.assistanceAuthorizationChanged", english: "Assistance authorization or conversation state changed. The original result remains and was not adopted automatically."),
        .init(original: "辅助任务没有发布完整原文。", key: "chat.error.assistanceMissingText", english: "The assistance task did not publish complete original text."),
        .init(original: "辅助记录不存在。", key: "chat.error.missingAssistanceRecord", english: "The assistance record no longer exists."),
        .init(original: "记忆在提取期间改变；没有重新创建已忘记内容。", key: "chat.error.memoryChangedDuringExtraction", english: "Memory changed during extraction. Forgotten content was not recreated."),
        .init(original: "个人记忆尚未就绪。", key: "chat.error.personalMemoryNotReady", english: "Personal memory is not ready."),
        .init(original: "辅助任务回执缺失。", key: "chat.error.missingAssistanceReceipt", english: "The assistance task receipt is missing."),
        .init(original: "个人记忆所有者尚未就绪；保存续作已保留。", key: "chat.error.personalMemorySaveOwner", english: "The personal memory owner is not ready. The pending save continuation was retained."),
        .init(original: "个人记忆尚未读取。", key: "chat.error.personalMemoryNotLoaded", english: "Personal memory has not been loaded."),
        .init(original: "记忆在保存续作前改变；未重新创建可能已忘记的内容。", key: "chat.error.memoryChangedBeforeSave", english: "Memory changed before save recovery. Potentially forgotten content was not recreated."),
        .init(original: "个人记忆存在不同来源的同名身份；原件保持。", key: "chat.error.personalMemoryIdentityConflict", english: "Personal memory has the same identity from a different source. The original remains."),
        .init(original: "辅助保存回执已改变。", key: "chat.error.assistanceSaveReceiptChanged", english: "The assistance save receipt changed."),
        .init(original: "待保存原文的所有者不存在；不会重推理。", key: "chat.error.pendingTextOwnerMissing", english: "The owner of pending original text is missing. Inference will not be repeated."),
        .init(original: "辅助保存没有返回原文。", key: "chat.error.assistanceSaveMissingText", english: "The assistance save returned no original text."),
        .init(original: "会话在预览期间已改变，请重新预览；旧结果没有应用。", key: "chat.error.previewChanged", english: "The conversation changed during preview. Preview again; the old result was not applied."),
        .init(original: "需要已有用户消息和模型。", key: "chat.error.needUserMessageModel", english: "An existing user message and model are required."),
        .init(original: "比较需要已有固定问题与明确的文字模型配置。", key: "chat.error.compareNeedsFixedQuestion", english: "Comparison requires an existing fixed question and explicit text model settings."),
        .init(original: "固定比较输入超过所选上下文预算；没有删减原始问题。", key: "chat.error.compareContextBudget", english: "The fixed comparison input exceeds the selected context budget. The original question was not shortened."),
        .init(original: "旧尝试缺少可重现的冻结参数或种子，不能按当前设置冒充重现。", key: "chat.error.replayMissingParameters", english: "The old attempt has no reproducible frozen settings or seed. Current settings cannot be presented as a replay."),
        .init(original: "摘要在准备期间已改变，请重新发送。", key: "chat.error.summaryChanged", english: "The summary changed during preparation. Send again."),
        .init(original: "当前不能开始本地转写。", key: "chat.error.transcriptionUnavailable", english: "Local transcription cannot start now."),
        .init(original: "会话已关闭；转写没有写入其他会话。", key: "chat.error.transcriptionSessionClosed", english: "The conversation closed. The transcription was not written to another conversation."),
        .init(original: "会话已关闭，原件与转写资产仍保留。", key: "chat.error.transcriptionAssetsRetained", english: "The conversation closed. The original and transcription assets remain."),
        .init(original: "没有可采用的语音转写。", key: "chat.error.noTranscriptionToAdopt", english: "No speech transcription is available to adopt."),
        .init(original: "草稿或来源数量已达上限；原转写仍保留。", key: "chat.error.transcriptionDraftLimit", english: "The draft or source count reached its limit. The original transcription remains."),
        .init(original: "搜索缺少结果。", key: "chat.error.searchMissingResults", english: "The search has no results."),
        .init(original: "搜索没有结果；未凭空添加引用。可以关闭自动搜索后发送。", key: "chat.error.searchEmpty", english: "Search returned no results. No citation was invented. You can turn off automatic search and send again."),
        .init(original: "自动搜索需要先允许联网。", key: "chat.error.automaticSearchPermission", english: "Automatic search requires network permission first."),
        .init(original: "请等待当前工具结束，并选择可用会话。", key: "chat.error.toolBusy", english: "Wait for the current tool to finish and choose an available conversation."),
        .init(original: "工具历史没有足够空间保存完整结果，请新建会话。", key: "chat.error.toolHistoryBudget", english: "Tool history has insufficient space for the complete result. Start a new conversation."),
        .init(original: "工具记录不存在。", key: "chat.error.missingToolRecord", english: "The tool record no longer exists."),
        .init(original: "工具结果尚未完成。", key: "chat.error.toolResultPending", english: "The tool result is not complete yet."),
        .init(original: "完整工具正文超过附件预算，请显式选取材料；没有截断。", key: "chat.error.toolAttachmentBudget", english: "The complete tool body exceeds the attachment budget. Select material explicitly; nothing was truncated."),
        .init(original: "会话已关闭；已保存工具结果未自动加入草稿。", key: "chat.error.savedToolSessionClosed", english: "The conversation closed. The saved tool result was not added to the draft automatically."),
        .init(original: "附件数量已达上限。", key: "chat.error.attachmentCountLimit", english: "The attachment count has reached its limit."),
        .init(original: "搜索列表不是网页正文，请先选择并读取一个结果。", key: "chat.error.searchListNotPage", english: "The search list is not page content. Select and read a result first."),
        .init(original: "Import identity conflicts with an existing conversation.", key: "chat.error.importIdentityConflict", english: "Import identity conflicts with an existing conversation."),
        .init(original: "此成果版本已有不同内容；请重新打开最新版本。", key: "chat.error.artifactVersionConflict", english: "This artifact version already has different content. Reopen the latest version."),
        .init(original: "成果版本或来源已变化；未覆盖已有版本。", key: "chat.error.artifactVersionChanged", english: "The artifact version or source changed. The existing version was not overwritten."),
        .init(original: "成果版本已达保存上限。", key: "chat.error.artifactVersionLimit", english: "The artifact version limit has been reached."),
        .init(original: "请在可用会话中保存字段。", key: "chat.error.fieldConversationUnavailable", english: "Save the field in an available conversation."),
        .init(original: "字段超出文字资产容量。", key: "chat.error.fieldCapacity", english: "The field exceeds the text asset capacity."),
        .init(original: "请等待回答和保存完成，并在原对话中选择。", key: "chat.error.configurationBusy", english: "Wait for the answer and save to finish, then choose in the original conversation."),
        .init(original: "当前对话或模型参数尚不能提交比较。", key: "chat.error.compareUnavailable", english: "The current conversation or model settings are not ready for comparison."),
        .init(original: "请先完成参数输入并选择模型，再保存当前配置。", key: "chat.error.saveConfiguration", english: "Complete the settings and choose a model before saving this configuration."),
        .init(original: "项目尚未准备。", key: "chat.error.projectNotReady", english: "The project is not ready."),
        .init(original: "工作流交接入口不可用；选段已保留。", key: "chat.error.workflowHandoffUnavailable", english: "Workflow handoff is unavailable. The quotation was retained."),
        .init(original: "原会话已离开。", key: "chat.error.originalSessionClosed", english: "The original conversation has closed."),
        .init(original: "Conversation import must be a regular file up to 2 MiB. / 会话导入限2MiB普通文件。", key: "chat.error.importFileLimit", english: "Conversation import requires a regular file no larger than 2 MiB."),
        .init(original: "Preset file must be at most 2 MiB. / 预设文件不能超过2MiB。", key: "chat.error.presetFileLimit", english: "A preset file must be no larger than 2 MiB."),
        .init(original: "No selected conversation path. / 尚无所选会话路径。", key: "chat.error.noSelectedPath", english: "No conversation path is selected."),
        .init(original: "Schema declaration exceeds 64 KiB.", key: "chat.error.schemaLimit", english: "The schema declaration exceeds 64 KiB."),
        .init(original: "Output budgets must be positive integers / 输出预算须为正整数。", key: "chat.error.positiveOutputBudgets", english: "Output budgets must be positive integers."),
        .init(original: "The summary threshold must be positive / 摘要阈值须为正整数。", key: "chat.error.positiveSummaryThreshold", english: "The summary threshold must be a positive integer."),
        .init(original: "The saved artifact did not match the submitted version.", key: "chat.error.artifactContentMismatch", english: "The saved artifact did not match the submitted version."),
        .init(original: "The saved artifact has no published output asset.", key: "chat.error.artifactOutputMissing", english: "The saved artifact has no published output asset."),
        .init(original: "Mermaid preview is unavailable: no local renderer was provided.", key: "chat.error.mermaidRendererUnavailable", english: "Mermaid preview is unavailable: no local renderer was provided."),
        .init(original: "CSV preview: Source exceeds 1 MiB of UTF-8.", key: "chat.error.csvSourceLimit", english: "CSV preview: Source exceeds 1 MiB of UTF-8."),
        .init(original: "CSV preview: Unexpected quote in an unquoted field.", key: "chat.error.csvUnexpectedQuote", english: "CSV preview: Unexpected quote in an unquoted field."),
        .init(original: "CSV preview: Unexpected character after a quoted field.", key: "chat.error.csvUnexpectedCharacter", english: "CSV preview: Unexpected character after a quoted field."),
        .init(original: "CSV preview: Unclosed quoted field.", key: "chat.error.csvUnclosedQuote", english: "CSV preview: Unclosed quoted field."),
        .init(original: "CSV preview: Escaped table exceeds 1 MiB.", key: "chat.error.csvEscapedTableLimit", english: "CSV preview: Escaped table exceeds 1 MiB."),
    ]

    static func display(_ original: String, language: UILanguageStore?) -> String {
        if let budget = displayContextBudget(original, language: language) { return budget }
        if let csv = displayCSVLimit(original, language: language) { return csv }
        guard let entry = entries.first(where: { $0.original == original || $0.english == original }) else {
            // Keep all diagnostic bytes visible. The label describes the text; it
            // does not claim that an unknown backend cause was translated.
            return (language?.text("chat.error.originalDiagnostic", fallback: "Original diagnostic: ")
                    ?? "Original diagnostic: ") + original
        }
        return language?.text(entry.key, fallback: entry.english) ?? entry.english
    }

    private static func displayContextBudget(_ original: String, language: UILanguageStore?) -> String? {
        let prefix = "保守估计输入约"
        let separator = " token，超过所选上限"
        let suffix = "；这不是精确分词。请显式排除消息或分叉较短路径。"
        guard original.hasPrefix(prefix), original.hasSuffix(suffix) else { return nil }
        let middle = original.dropFirst(prefix.count).dropLast(suffix.count)
        let parts = String(middle).components(separatedBy: separator)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }) else { return nil }
        let fallback = "Conservative input estimate: about {estimatedTokens} tokens, above the selected limit of {limit}. This is not exact tokenization. Exclude messages explicitly or fork a shorter path."
        let arguments = ["estimatedTokens": parts[0], "limit": parts[1]]
        return language?.text("chat.error.contextBudget", fallback: fallback, arguments: arguments)
            ?? LanguagePackCodec.render(fallback, arguments: arguments)
    }

    private static func displayCSVLimit(_ original: String, language: UILanguageStore?) -> String? {
        let prefix = "CSV preview: More than "
        guard original.hasPrefix(prefix) else { return nil }
        let candidates = [
            (suffix: " columns.", key: "chat.error.csvColumnLimit", fallback: "CSV preview: More than {count} columns."),
            (suffix: " rows.", key: "chat.error.csvRowLimit", fallback: "CSV preview: More than {count} rows."),
        ]
        for candidate in candidates where original.hasSuffix(candidate.suffix) {
            let number = original.dropFirst(prefix.count).dropLast(candidate.suffix.count)
            guard !number.isEmpty, number.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            let arguments = ["count": String(number)]
            return language?.text(candidate.key, fallback: candidate.fallback, arguments: arguments)
                ?? LanguagePackCodec.render(candidate.fallback, arguments: arguments)
        }
        return nil
    }
}
