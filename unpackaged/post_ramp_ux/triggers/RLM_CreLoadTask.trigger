trigger RLM_CreLoadTask on Task (after insert) {
    // Hosted MCP describe used to insert Subject=RLM_CRE_LOAD tasks.
    // after-insert enqueueJob ran in that same transaction and Script-threw.
    // Configure now starts from flow RLM_Enqueue_Cre_Load after commit.
}
