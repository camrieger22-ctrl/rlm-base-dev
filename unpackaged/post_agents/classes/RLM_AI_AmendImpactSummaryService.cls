/**
 * Invocable: names-only Current / This add / Finalized summary for an amendment quote.
 * Backs Quinn AmendmentStudio → Summarize_Amend_Impact. Read-only.
 */
public with sharing class RLM_AI_AmendImpactSummaryService {

    public class SummaryInput {
        @InvocableVariable(required=true label='Quote Id'
            description='18-character Quote Id (0Q0...) of the amendment quote to summarize.')
        public String quoteId;
    }

    public class SummaryOutput {
        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;

        @InvocableVariable(label='Summary Display'
            description='Names-only amend impact for the rep (no raw Ids).')
        public String summaryDisplay;

        @InvocableVariable(label='Is Amendment Quote')
        public Boolean isAmendmentQuote;

        @InvocableVariable(label='Error Message')
        public String errorMessage;

        public SummaryOutput() {
            this.isSuccess = false;
            this.summaryDisplay = '';
            this.isAmendmentQuote = false;
        }
    }

    @InvocableMethod(
        label='Summarize Amend Impact'
        description='Builds a names-only Current / This add / Finalized contract summary for an amendment Quote, including installed products and KPI totals. Read-only.'
    )
    public static List<SummaryOutput> summarize(List<SummaryInput> inputs) {
        List<SummaryOutput> results = new List<SummaryOutput>();
        if (inputs == null || inputs.isEmpty()) {
            return results;
        }
        for (SummaryInput input : inputs) {
            results.add(build(input));
        }
        return results;
    }

    private static SummaryOutput build(SummaryInput input) {
        SummaryOutput out = new SummaryOutput();
        if (input == null || String.isBlank(input.quoteId)) {
            out.errorMessage = 'Quote Id is required.';
            return out;
        }
        Id quoteId = RLM_AI_ConfigServiceUtils.toIdOrNull(input.quoteId);
        if (quoteId == null || !RLM_AI_ConfigServiceUtils.hasPrefix(input.quoteId, RLM_AI_ConfigServiceUtils.QUOTE_PREFIX)) {
            out.errorMessage = 'Invalid quote Id.';
            return out;
        }

        List<Quote> quotes = [
            SELECT
                Id,
                Name,
                QuoteNumber,
                OriginalActionType,
                Account.Name,
                RLM_Amend_Current_ARR__c,
                RLM_Amend_Current_MRR__c,
                RLM_Amend_Current_Qty__c,
                RLM_Amend_Proposed_ARR__c,
                RLM_Amend_Proposed_MRR__c,
                RLM_Amend_Proposed_Qty__c,
                RLM_Amend_Net_Increase_ARR__c,
                RLM_Amend_Net_Increase_MRR__c,
                RLM_Amend_Net_Increase_Qty__c,
                RLM_Amend_This_Add_Prorated__c
            FROM Quote
            WHERE Id = :quoteId
            WITH USER_MODE
            LIMIT 1
        ];
        if (quotes.isEmpty()) {
            out.errorMessage = 'Quote was not found or is not readable.';
            return out;
        }
        Quote q = quotes[0];

        RLM_AmendDifferenceService.HistoryResponse history;
        try {
            history = RLM_AmendDifferenceService.getHistoryForQuote(quoteId);
        } catch (Exception e) {
            history = null;
        }

        // OriginalActionType is platform-owned (not DML-writeable in tests). Also
        // treat populated amend stamp fields as amend evidence for demos/tests.
        Boolean isAmend =
            (q.OriginalActionType == 'Amend')
            || (history != null && history.isAmendmentQuote == true)
            || q.RLM_Amend_Current_ARR__c != null
            || q.RLM_Amend_Proposed_ARR__c != null;
        out.isAmendmentQuote = isAmend;

        if (!isAmend) {
            out.isSuccess = true;
            out.summaryDisplay =
                'Quote ' + safe(q.QuoteNumber) + ' does not look like an amendment. '
                + 'Open an amendment quote (or start an amend) to see Current / This add / Finalized.';
            return out;
        }

        out.isSuccess = true;
        out.summaryDisplay = render(q, history);
        return out;
    }

    private static String render(Quote q, RLM_AmendDifferenceService.HistoryResponse history) {
        List<String> lines = new List<String>();
        String accountName = q.Account != null ? q.Account.Name : null;
        lines.add(
            '**Amendment impact** - Quote '
            + safe(q.QuoteNumber)
            + (String.isNotBlank(accountName) ? ' / ' + accountName : '')
        );

        lines.add(
            '**Current contract** - ARR ' + money(q.RLM_Amend_Current_ARR__c)
            + ' / MRR ' + money(q.RLM_Amend_Current_MRR__c)
            + ' / Qty ' + qty(q.RLM_Amend_Current_Qty__c)
        );

        lines.add(
            '**This add** (prorated this term ' + money(q.RLM_Amend_This_Add_Prorated__c) + ') - '
            + 'Δ ARR ' + money(q.RLM_Amend_Net_Increase_ARR__c)
            + ' / Δ MRR ' + money(q.RLM_Amend_Net_Increase_MRR__c)
            + ' / Δ Qty ' + qty(q.RLM_Amend_Net_Increase_Qty__c)
        );

        lines.add(
            '**Finalized if accepted** - ARR ' + money(q.RLM_Amend_Proposed_ARR__c)
            + ' / MRR ' + money(q.RLM_Amend_Proposed_MRR__c)
            + ' / Qty ' + qty(q.RLM_Amend_Proposed_Qty__c)
        );

        if (history != null && history.assets != null && !history.assets.isEmpty()) {
            lines.add('**Installed / amending products**');
            Integer shown = 0;
            for (RLM_AmendDifferenceService.AssetHistoryCard card : history.assets) {
                if (card == null || String.isBlank(card.assetName)) {
                    continue;
                }
                String tag = card.isAmending == true ? ' (amending)' : '';
                lines.add(
                    '- ' + card.assetName + tag
                    + ' - installed qty ' + qty(card.installedQuantity)
                    + ', ARR ' + money(card.summary != null ? card.summary.currentArr : null)
                );
                shown++;
                if (shown >= 12) {
                    lines.add('- ...and more in Amendment Studio');
                    break;
                }
            }
        }

        lines.add('Open Amendment Studio on this quote for the full Current / This add / Finalized tables.');
        return String.join(lines, '\n');
    }

    private static String money(Decimal value) {
        if (value == null) {
            return '-';
        }
        return '$' + value.setScale(2, RoundingMode.HALF_UP).format();
    }

    private static String qty(Decimal value) {
        if (value == null) {
            return '-';
        }
        return value.setScale(0, RoundingMode.HALF_UP).format();
    }

    private static String safe(String value) {
        return String.isBlank(value) ? '' : value;
    }
}
