/**
 * Agentforce Invocable: apply term and/or billing to Bamboo Revenue Suite
 * option quotes (A/B/C) via RLM_BambooSuitePlace (PST + FORCE) — preserves qty.
 *
 * Use when the AE asks to change term length or billing frequency on existing
 * suite options without rebuilding tiers or changing seat count.
 * Do NOT use RLM_BambooSuiteBuildTiers / fillTierOption for that path.
 */
public with sharing class RLM_BambooSuiteApplyCommercialTerms {
    public class Request {
        @InvocableVariable(
            required=true
            label='Opportunity Id'
            description='Opportunity that owns suite Option A/B/C quotes.'
        )
        public String opportunityId;

        @InvocableVariable(
            label='Term months'
            description='Optional. 1 (M2M), 12, 24, or 36. When set, restamps every targeted option onto the matching PBE; line Quantity is preserved.'
        )
        public Integer termMonths;

        @InvocableVariable(
            label='Billing frequency'
            description='Optional. Monthly, Quarterly, or Annual. When set with termMonths, both apply in one Place cycle per option.'
        )
        public String billingFrequency;

        @InvocableVariable(
            label='Start date'
            description='Optional subscription start YYYY-MM-DD. Defaults to each option’s current start or today.'
        )
        public String startDate;

        @InvocableVariable(
            label='Selected quote Id'
            description='Optional active option quote Id for summary refresh (LWC session quote).'
        )
        public String selectedQuoteId;

        @InvocableVariable(
            label='Quote Ids'
            description='Optional subset of suite option quote Ids. When blank, all Options A–C on the Opportunity are updated.'
        )
        public List<String> quoteIds;

        @InvocableVariable(
            label='Option label'
            description='Optional. Good, Better, Best, or Option A/B/C — updates only that option. Prefer this over quoteIds when the user names one option.'
        )
        public String optionLabel;
    }

    public class Result {
        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;

        @InvocableVariable(label='Error Message')
        public String errorMessage;

        @InvocableVariable(
            label='Summary'
            description='Human-readable result. Speak verbatim; do not invent totals.'
        )
        public String summary;

        @InvocableVariable(label='Options updated')
        public Integer optionsUpdated;
    }

    @InvocableMethod(
        label='BambooHR Suite Apply Commercial Terms'
        description='Apply term length and/or billing frequency to Bamboo Revenue Suite Option A/B/C quotes via Place + FORCE. Preserves seat/qty on every line. Updates all suite options unless quoteIds is set. Not for Good/Better/Best tier rebuilds.'
        category='BambooHR'
    )
    public static List<Result> apply(List<Request> requests) {
        List<Result> out = new List<Result>();
        if (requests == null) {
            return out;
        }
        for (Request req : requests) {
            out.add(applyOne(req));
        }
        return out;
    }

    @TestVisible
    static Result applyOne(Request req) {
        Result res = new Result();
        res.isSuccess = false;
        res.optionsUpdated = 0;
        if (req == null || String.isBlank(req.opportunityId)) {
            res.errorMessage = 'opportunityId is required';
            return res;
        }
        Boolean hasTerm = req.termMonths != null;
        Boolean hasBilling = String.isNotBlank(req.billingFrequency);
        if (!hasTerm && !hasBilling) {
            res.errorMessage = 'Provide termMonths and/or billingFrequency';
            return res;
        }

        try {
            Id oppId = Id.valueOf(req.opportunityId.trim());
            List<RLM_BambooRevenueSuite.OptionSummaryDTO> options =
                RLM_BambooRevenueSuite.listOptions(oppId, null);
            if (options.isEmpty()) {
                res.errorMessage = 'No Bamboo Revenue Suite options found on this Opportunity.';
                return res;
            }

            Set<Id> targetIds = resolveTargetQuoteIds(options, req);
            if (targetIds.isEmpty()) {
                res.errorMessage = 'No matching suite option quotes to update.';
                return res;
            }

            String selectedRaw = String.isBlank(req.selectedQuoteId)
                ? null
                : req.selectedQuoteId.trim();
            List<String> filterList = new List<String>();
            for (Id qid : targetIds) {
                filterList.add(String.valueOf(qid));
            }

            if (hasTerm && hasBilling) {
                Integer months = req.termMonths;
                String billing = req.billingFrequency;
                String startIso = String.isBlank(req.startDate)
                    ? null
                    : req.startDate.trim();
                for (RLM_BambooRevenueSuite.OptionSummaryDTO opt : options) {
                    if (!targetIds.contains(opt.quoteId)) {
                        continue;
                    }
                    String startForOption = startIso;
                    if (String.isBlank(startForOption)) {
                        RLM_BambooRevenueSuite.OptionDetailDTO cur =
                            RLM_BambooRevenueSuite.getOptionDetail(String.valueOf(opt.quoteId));
                        startForOption = String.isNotBlank(cur.startDate)
                            ? cur.startDate
                            : String.valueOf(Date.today());
                    }
                    RLM_BambooSuitePlace.applyTermToOption(
                        String.valueOf(opt.quoteId),
                        months,
                        startForOption,
                        billing
                    );
                    res.optionsUpdated++;
                }
            } else if (hasTerm) {
                RLM_BambooSuitePlace.applyTermToAllOptions(
                    String.valueOf(oppId),
                    selectedRaw,
                    req.termMonths,
                    req.startDate,
                    filterList
                );
                res.optionsUpdated = targetIds.size();
            } else {
                RLM_BambooSuitePlace.applyBillingToAllOptions(
                    String.valueOf(oppId),
                    selectedRaw,
                    req.billingFrequency,
                    null,
                    null,
                    filterList
                );
                res.optionsUpdated = targetIds.size();
            }

            res.isSuccess = true;
            List<String> parts = new List<String>();
            if (hasTerm) {
                parts.add('term ' + String.valueOf(req.termMonths) + ' months');
            }
            if (hasBilling) {
                parts.add('billing ' + req.billingFrequency.trim());
            }
            res.summary =
                'Updated ' +
                String.valueOf(res.optionsUpdated) +
                ' suite option(s) with ' +
                String.join(parts, ' and ') +
                '. Quantities unchanged. Refresh options in Revenue Suite or Compare to verify.';
        } catch (Exception e) {
            String msg = e.getMessage();
            if (String.isBlank(msg)) {
                msg = e.getTypeName();
            }
            res.errorMessage = msg;
            res.summary = 'Could not apply commercial terms: ' + msg;
        }
        return res;
    }

    private static Set<Id> resolveTargetQuoteIds(
        List<RLM_BambooRevenueSuite.OptionSummaryDTO> options,
        Request req
    ) {
        Set<Id> targets = new Set<Id>();
        if (String.isNotBlank(req.optionLabel)) {
            Id qid = RLM_BambooRevenueSuite.resolveSuiteOptionQuoteId(
                req.opportunityId.trim(),
                req.optionLabel.trim()
            );
            targets.add(qid);
            return targets;
        }
        if (req.quoteIds != null && !req.quoteIds.isEmpty()) {
            for (String raw : req.quoteIds) {
                if (String.isBlank(raw)) {
                    continue;
                }
                targets.add(Id.valueOf(raw.trim()));
            }
            return targets;
        }
        for (RLM_BambooRevenueSuite.OptionSummaryDTO opt : options) {
            if (opt != null && opt.quoteId != null) {
                targets.add(opt.quoteId);
            }
        }
        return targets;
    }
}
