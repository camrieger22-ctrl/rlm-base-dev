@IsTest
private class RLM_ConstraintRuleIndexTest {

    @IsTest
    static void indexesServer2DualGoldAndX16Messages() {
        RLM_ConstraintRuleIndex.Rule gold = RLM_ConstraintRuleIndex.byMatch('dualGold');
        System.assertNotEquals(null, gold);
        System.assertEquals(
            'Dual cannot use a Gold CPU. Pick a Platinum, or switch Socket to Single.',
            gold.ruleText
        );
        System.assert(gold.flips.contains('platinum'), String.valueOf(gold.flips));
        System.assert(gold.flips.contains('socketSingle'), String.valueOf(gold.flips));

        RLM_ConstraintRuleIndex.Rule fromCre = RLM_ConstraintRuleIndex.matchText(
            'constraint: Dual CPUs are only available for Platinum CPUs.'
        );
        System.assertEquals(gold.ruleText, fromCre.ruleText);

        RLM_ConstraintRuleIndex.Rule lanes = RLM_ConstraintRuleIndex.matchText(
            'Calculated value int 1 is not in domain of x16Lanes in Server_0'
        );
        System.assertEquals(
            'Do not edit x16 Lanes. Dual with this Performance Tier adds a GPU. Set Performance Tier to Entry, or set Socket to Single.',
            lanes.ruleText
        );
        System.assertEquals(false, lanes.ruleText.contains('A Dual GPU is selected'));
    }
}
