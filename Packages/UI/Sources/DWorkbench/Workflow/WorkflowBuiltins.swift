import Foundation

/// Static composition root; adding an operation does not change the scheduler.
enum WorkflowBuiltins {
    static let operations: [WorkflowOperation] = [
        WorkflowTextOperations.textInput,
        WorkflowAssetOperations.assetReference,
        WorkflowTextOperations.textTemplate,
        WorkflowTextOperations.textRewrite,
        WorkflowImageOperations.imageGenerate,
        WorkflowTextOperations.textConfirm,
        WorkflowAssetOperations.assetChoose,
        WorkflowImageOperations.imageResize,
        WorkflowImageOperations.imageConvert,
        WorkflowAssetOperations.assetExport,
        WorkflowRemoveBlankLines.operation,
    ]
}
