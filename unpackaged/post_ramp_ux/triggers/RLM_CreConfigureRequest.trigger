trigger RLM_CreConfigureRequest on RLM_CreConfigureRequest__e (after insert) {
    for (RLM_CreConfigureRequest__e evt : Trigger.new) {
        RLM_RampConfiguratorAction.enqueueFromEvent(evt);
    }
}
