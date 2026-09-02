/**
 * Agentforce Invocable: set seat count on all lines of one Bamboo Revenue Suite
 * option quote via RLM_BambooSuitePlace (PST + FORCE).
 *
 * Use when the AE changes headcount/seats on Option A/B/C without rebuilding
 * Good/Better/Best tiers. Do NOT use LineManagement Update_Record_Fields.
 */
public with sharing class RLM_BambooSuiteUpdateSeats {
    public class Request {
        @InvocableVariable(
            label='Quote Id'
            description='Suite option Quote Id (0Q0…). When blank, pass opportunityId + optionLabel.'
        )
        public String quoteId;

        @InvocableVariable(
            label='Opportunity Id'
            description='Opportunity that owns Option A/B/C. Required when quoteId is blank.'
        )
        public String opportunityId;

        @InvocableVariable(
            label='Option label'
            description='Good, Better, Best, or Option A/B/C. Required when quoteId is blank.'
        )
        public String optionLabel;

        @InvocableVariable(
            required=true
            label='Seat count'
            description='Employee / seat quantity applied to every line on the targeted option.'
        )
        public Integer seatCount;

        @InvocableVariable(
            label='Term months'
            description='Optional. 1 (M2M), 12, 24, or 36. When set, restamps term (and billing when provided) after seat update.'
        )
        public Integer termMonths;

        @InvocableVariable(
            label='Billing frequency'
            description='Optional. Monthly, Quarterly, or Annual. Applied with termMonths when either is set.'
        )
        public String billingFrequency;

        @InvocableVariable(
            label='Start date'
            description='Optional subscription start YYYY-MM-DD. Defaults to the option current start or today.'
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
            description='Human-readable result. Speak verbatim; do not invent MRR.'
        )
        public String summary;

        @InvocableVariable(label='Quote Id')
        public Id quoteId;

        @InvocableVariable(label='Filled MRR')
        public Decimal filledMrr;
    }

    @InvocableMethod(
        label='BambooHR Suite Update Seats'
        description='Set seat count on all lines of one Bamboo Revenue Suite option quote via Place + FORCE. Preserves bundle hierarchy and reprices volume tiers. Not for Good/Better/Best tier rebuilds.'
        category='BambooHR'
    )
    public static List<Result> updateSeats(List<Request> requests) {
        List<Result> out = new List<Result>();
        if (requests == null) {
            return out;
        }
        for (Request req : requests) {
            out.add(updateOne(req));
        }
        return out;
    }

    @TestVisible
    public static Result updateOne(Request req) {
        Result res = new Result();
        res.isSuccess = false;
        if (req == null || req.seatCount == null || req.seatCount <= 0) {
            res.errorMessage = 'seatCount is required and must be > 0';
            return res;
        }
        try {
            Id qId = resolveQuoteId(req);
            if (
                RLM_BambooRevenueSuite.isTxnOrchestratorEnabled() &&
                !RLM_BambooRevenueSuite.isTxnJobInProgressPublic()
            ) {
                return enqueueUpdateSeatsViaOrchestrator(req, qId);
            }
            RLM_BambooRevenueSuite.OptionDetailDTO detail =
                RLM_BambooSuitePlace.updateOptionSeatCount(
                    String.valueOf(qId),
                    req.seatCount
                );
            Boolean hasTerm = req.termMonths != null;
            Boolean hasBilling = String.isNotBlank(req.billingFrequency);
            if (hasTerm || hasBilling) {
                Integer months = hasTerm
                    ? req.termMonths
                    : detail.termMonths;
                String billing = hasBilling
                    ? req.billingFrequency.trim()
                    : detail.billingFrequency;
                String startIso = String.isNotBlank(req.startDate)
                    ? req.startDate.trim()
                    : (String.isNotBlank(detail.startDate)
                          ? detail.startDate
                          : String.valueOf(Date.today()));
                detail = RLM_BambooSuitePlace.applyTermToOption(
                    String.valueOf(qId),
                    months,
                    startIso,
                    billing
                );
            }
            res.isSuccess = true;
            res.quoteId = detail.quoteId;
            res.filledMrr = detail.mrr;
            List<String> parts = new List<String>{
                String.valueOf(req.seatCount) + ' seats'
            };
            if (hasTerm) {
                parts.add('term ' + String.valueOf(req.termMonths) + ' months');
            }
            if (hasBilling) {
                parts.add('billing ' + req.billingFrequency.trim());
            }
            res.summary =
                detail.optionLabel +
                ' updated — ' +
                String.join(parts, ', ') +
                ' — MRR ' +
                formatMoney(detail.mrr) +
                '. Refresh options in Revenue Suite. If the Quote record line editor still shows the old qty, hard-refresh that tab.';
        } catch (Exception e) {
            String msg = e.getMessage();
            if (String.isBlank(msg)) {
                msg = e.getTypeName();
            }
            res.errorMessage = msg;
            res.summary = 'Could not update seats: ' + msg;
        }
        return res;
    }

    private static Result enqueueUpdateSeatsViaOrchestrator(Request req, Id qId) {
        Result res = new Result();
        res.isSuccess = false;
        Quote q = [
            SELECT OpportunityId
            FROM Quote
            WHERE Id = :qId
            WITH USER_MODE
            LIMIT 1
        ];
        Map<String, Object> fields = new Map<String, Object>{
            'quoteId' => String.valueOf(qId),
            'opportunityId' => String.valueOf(q.OpportunityId),
            'optionLabel' => req.optionLabel,
            'seatCount' => req.seatCount,
            'termMonths' => req.termMonths,
            'billingFrequency' => req.billingFrequency,
            'startDate' => req.startDate
        };
        RLM_BambooSuiteTxnOrchestrator.EnqueueRequest enq =
            new RLM_BambooSuiteTxnOrchestrator.EnqueueRequest();
        enq.opportunityId = q.OpportunityId;
        enq.quoteId = qId;
        enq.requestType = 'Place';
        enq.payloadJson = RLM_BambooSuiteTxnOrchestrator.buildPayload(
            'UpdateSeats',
            fields
        );
        enq.restoreSync = false;
        RLM_BambooSuiteTxnOrchestrator.JobStatusDTO status =
            RLM_BambooSuiteTxnOrchestrator.enqueueAndRunSync(enq);
        if (status == null || status.status != 'Succeeded') {
            res.errorMessage = status != null && String.isNotBlank(status.errorMessage)
                ? status.errorMessage
                : 'Suite transaction failed.';
            res.summary = 'Could not update seats: ' + res.errorMessage;
            return res;
        }
        RLM_BambooRevenueSuite.OptionDetailDTO detail =
            RLM_BambooRevenueSuite.getOptionDetail(String.valueOf(qId));
        res.isSuccess = true;
        res.quoteId = detail.quoteId;
        res.filledMrr = detail.mrr;
        List<String> parts = new List<String>{
            String.valueOf(req.seatCount) + ' seats'
        };
        if (req.termMonths != null) {
            parts.add('term ' + String.valueOf(req.termMonths) + ' months');
        }
        if (String.isNotBlank(req.billingFrequency)) {
            parts.add('billing ' + req.billingFrequency.trim());
        }
        res.summary =
            detail.optionLabel +
            ' updated — ' +
            String.join(parts, ', ') +
            ' — MRR ' +
            formatMoney(detail.mrr) +
            '. Refresh options in Revenue Suite. If the Quote record line editor still shows the old qty, hard-refresh that tab.';
        return res;
    }

    private static Id resolveQuoteId(Request req) {
        if (req != null && String.isNotBlank(req.quoteId)) {
            return Id.valueOf(req.quoteId.trim());
        }
        if (
            req == null ||
            String.isBlank(req.opportunityId) ||
            String.isBlank(req.optionLabel)
        ) {
            throw new AuraHandledException(
                'Provide quoteId or both opportunityId and optionLabel (Good/Better/Best or Option A/B/C).'
            );
        }
        return RLM_BambooRevenueSuite.resolveSuiteOptionQuoteId(
            req.opportunityId.trim(),
            req.optionLabel.trim()
        );
    }

    private static String formatMoney(Decimal amount) {
        Decimal n = amount == null ? 0 : amount.setScale(2);
        return '$' + String.valueOf(n);
    }
}
