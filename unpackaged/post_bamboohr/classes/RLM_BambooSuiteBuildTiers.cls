/**
 * Agentforce Invocable: ensure Option A/B/C and/or fill one Good/Better/Best
 * tier via RLM_BambooSuitePlace (ensure quotes via RevenueSuite DTO helpers).
 *
 * Call once with blank tierKey to ensure A/B/C exist, then once per tier
 * (Good → Better → Best) so each Place+price run stays under governor limits.
 *
 * Opportunity context: pass the Opportunity Id explicitly when the AE is on the
 * BambooHR Revenue Suite tab (custom tab page context is often not Opportunity).
 */
public with sharing class RLM_BambooSuiteBuildTiers {
    public class Request {
        @InvocableVariable(
            required=true
            label='Opportunity Id'
            description='18-character Opportunity Id that owns suite Option A/B/C Quotes. Required when page context is not Opportunity (e.g. Revenue Suite tab). Prefer currentRecordId when currentObjectApiName is Opportunity.'
        )
        public String opportunityId;

        @InvocableVariable(
            label='Tier key'
            description='Leave blank to ensure Option A/B/C Quotes exist without filling lines. Pass Good (Core Path B), Better (Workforce Pro package), or Best (Elite Path B) to clear and fill that option. Call ensure once, then Good, Better, Best in separate invocations.'
        )
        public String tierKey;

        @InvocableVariable(
            label='Seat count'
            description='Employee / seat quantity for every line on the filled tier. Defaults to 50 when blank or <= 0. Ignored when tierKey is blank (ensure-only).'
        )
        public Integer seatCount;

        @InvocableVariable(
            label='Term months'
            description='Subscription term: 1 (evergreen M2M), 12, 24, or 36. Defaults to 12. Ignored when tierKey is blank.'
        )
        public Integer termMonths;

        @InvocableVariable(
            label='Billing frequency'
            description='Monthly, Quarterly, or Annual. Defaults to Monthly. Ignored when tierKey is blank.'
        )
        public String billingFrequency;

        @InvocableVariable(
            label='Start date'
            description='Subscription start YYYY-MM-DD. Defaults to today. Ignored when tierKey is blank.'
        )
        public String startDate;
    }

    public class Result {
        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;

        @InvocableVariable(label='Error Message')
        public String errorMessage;

        @InvocableVariable(
            label='Summary'
            description='Human-readable result for the AE. Speak this verbatim; do not invent MRR or PEPM.'
        )
        public String summary;

        @InvocableVariable(label='Good Quote Id (Option A)')
        public Id goodQuoteId;

        @InvocableVariable(label='Better Quote Id (Option B)')
        public Id betterQuoteId;

        @InvocableVariable(label='Best Quote Id (Option C)')
        public Id bestQuoteId;

        @InvocableVariable(label='Filled Quote Id')
        public Id filledQuoteId;

        @InvocableVariable(label='Filled MRR')
        public Decimal filledMrr;
    }

    @InvocableMethod(
        label='BambooHR Suite Build Tier'
        description='BambooHR Revenue Suite: ensure Option A/B/C Quotes on an Opportunity, or fill one Good/Better/Best tier via Place Sales Transaction + FORCE pricing. Call blank tierKey first, then Good, Better, Best separately. Not for self-serve Get Pricing.'
        category='BambooHR'
    )
    public static List<Result> build(List<Request> requests) {
        List<Result> out = new List<Result>();
        if (requests == null) {
            return out;
        }
        for (Request req : requests) {
            out.add(buildOne(req));
        }
        return out;
    }

    @TestVisible
    static Result buildOne(Request req) {
        Result res = new Result();
        res.isSuccess = false;
        if (req == null || String.isBlank(req.opportunityId)) {
            res.errorMessage = 'opportunityId is required';
            return res;
        }
        try {
            RLM_BambooRevenueSuite.TierOptionsResultDTO ensured =
                RLM_BambooRevenueSuite.ensureGoodBetterBestOptions(req.opportunityId.trim());
            res.goodQuoteId = ensured.goodQuoteId;
            res.betterQuoteId = ensured.betterQuoteId;
            res.bestQuoteId = ensured.bestQuoteId;

            String tier = String.isBlank(req.tierKey) ? '' : req.tierKey.trim();
            if (String.isBlank(tier)) {
                res.isSuccess = true;
                res.summary =
                    'Options A (Good), B (Better), and C (Best) are ready. ' +
                    'Fill each tier next with tierKey Good, then Better, then Best.';
                return res;
            }

            Decimal seats = req.seatCount == null || req.seatCount <= 0
                ? 50
                : req.seatCount;
            Integer months = req.termMonths == null ? 12 : req.termMonths;
            String billing = String.isBlank(req.billingFrequency)
                ? 'Monthly'
                : req.billingFrequency;
            String startIso = String.isBlank(req.startDate)
                ? String.valueOf(Date.today())
                : req.startDate.trim();

            RLM_BambooRevenueSuite.OptionDetailDTO filled =
                RLM_BambooSuitePlace.fillTierOption(
                    quoteIdForTier(ensured, tier),
                    tier,
                    seats,
                    months,
                    startIso,
                    billing
                );

            res.isSuccess = true;
            res.filledQuoteId = filled.quoteId;
            res.filledMrr = filled.mrr;
            res.summary =
                tier +
                ' filled at ' +
                String.valueOf(seats.intValue()) +
                ' seats / ' +
                String.valueOf(months) +
                ' mo — MRR ' +
                formatMoney(filled.mrr) +
                '.';
        } catch (Exception e) {
            String msg = e.getMessage();
            if (String.isBlank(msg)) {
                msg = e.getTypeName();
            }
            res.errorMessage = msg;
            res.summary = 'Could not build tier: ' + msg;
        }
        return res;
    }

    private static String quoteIdForTier(
        RLM_BambooRevenueSuite.TierOptionsResultDTO ensured,
        String tierKey
    ) {
        String key = tierKey == null ? '' : tierKey.trim().toLowerCase();
        if (key == 'good') {
            return String.valueOf(ensured.goodQuoteId);
        }
        if (key == 'better') {
            return String.valueOf(ensured.betterQuoteId);
        }
        if (key == 'best') {
            return String.valueOf(ensured.bestQuoteId);
        }
        throw new AuraHandledException('tierKey must be Good, Better, Best, or blank');
    }

    private static String formatMoney(Decimal amount) {
        Decimal n = amount == null ? 0 : amount.setScale(2);
        return '$' + String.valueOf(n);
    }
}
