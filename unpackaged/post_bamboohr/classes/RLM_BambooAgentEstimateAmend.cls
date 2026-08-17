/**
 * Agentforce action: amend rail estimate (Pricing API, no Quote).
 * POST /api/account-amend-estimate
 */
public with sharing class RLM_BambooAgentEstimateAmend {
    public class Request {
        @InvocableVariable(
            required=true
            label='Account Id'
            description='Salesforce Account Id for the customer changing licenses.'
        )
        public String accountId;

        @InvocableVariable(
            label='New quantity'
            description='Target seat count after the change. Omit to keep current seats when only adding modules.'
        )
        public Integer newQty;

        @InvocableVariable(
            label='Add-on SKUs (CSV)'
            description='Comma-separated modules to add, e.g. BAMBOO-ADD-TIME.'
        )
        public String addonSkusCsv;

        @InvocableVariable(
            label='Amend start date'
            description='YYYY-MM-DD when the change should take effect.'
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
            description='Today vs After monthly MRR. dueToday is not available until Generate quote.'
        )
        public String summary;

        @InvocableVariable(label='Account Id')
        public String accountId;

        @InvocableVariable(label='Account Name')
        public String accountName;

        @InvocableVariable(label='Currency')
        public String currencyCode;

        @InvocableVariable(label='Monthly Today')
        public Decimal monthlyToday;

        @InvocableVariable(label='Monthly After')
        public Decimal monthlyAfter;

        @InvocableVariable(label='Monthly Difference')
        public Decimal monthlyDifference;

        @InvocableVariable(label='New Quantity')
        public Integer newQty;

        @InvocableVariable(label='Response JSON')
        public String responseJson;
    }

    @InvocableMethod(
        label='BambooHR Estimate Amend'
        description='Estimates after-change monthly MRR for a license change via Pricing API (no Draft Quote). Due-today / prorated charge requires Generate Or Update Amend Quote.'
        category='BambooHR'
        callout=true
    )
    public static List<Result> run(List<Request> requests) {
        List<Result> out = new List<Result>();
        if (requests == null) {
            return out;
        }
        for (Request req : requests) {
            out.add(runOne(req));
        }
        return out;
    }

    @TestVisible
    static Result runOne(Request req) {
        Result res = new Result();
        res.isSuccess = false;
        if (req == null || String.isBlank(req.accountId)) {
            res.errorMessage = 'accountId is required.';
            return res;
        }

        Map<String, Object> body = new Map<String, Object>{
            'accountId' => req.accountId.trim(),
            'addonSkus' => RLM_BambooAgentBffClient.splitCsv(req.addonSkusCsv)
        };
        if (req.newQty != null) {
            body.put('newQty', req.newQty);
        }
        if (String.isNotBlank(req.startDate)) {
            body.put('startDate', req.startDate.trim());
        }

        RLM_BambooAgentBffClient.Response http = RLM_BambooAgentBffClient.post(
            '/api/account-amend-estimate',
            body
        );
        res.responseJson = http.body;
        if (!http.transportOk || http.jsonMap == null) {
            res.errorMessage = String.isNotBlank(http.error)
                ? http.error
                : 'No response from Get Pricing BFF.';
            return res;
        }
        if (!RLM_BambooAgentBffClient.isOk(http.jsonMap)) {
            res.errorMessage = RLM_BambooAgentBffClient.extractError(
                http.jsonMap,
                http.body,
                http.statusCode
            );
            return res;
        }

        Map<String, Object> monthly = (Map<String, Object>) http.jsonMap.get('monthly');
        res.isSuccess = true;
        res.accountId = RLM_BambooAgentBffClient.asString(http.jsonMap.get('accountId'));
        res.accountName = RLM_BambooAgentBffClient.asString(http.jsonMap.get('accountName'));
        res.currencyCode = RLM_BambooAgentBffClient.asString(http.jsonMap.get('currency'));
        res.newQty = RLM_BambooAgentBffClient.asInteger(http.jsonMap.get('newQty'));
        if (monthly != null) {
            res.monthlyToday = RLM_BambooAgentBffClient.asDecimal(monthly.get('today'));
            res.monthlyAfter = RLM_BambooAgentBffClient.asDecimal(monthly.get('after'));
            res.monthlyDifference = RLM_BambooAgentBffClient.asDecimal(monthly.get('difference'));
        }

        res.summary =
            'Amend estimate for ' +
            (String.isBlank(res.accountName) ? res.accountId : res.accountName) +
            ': Today ' +
            RLM_BambooAgentBffClient.money(res.currencyCode, res.monthlyToday) +
            ' / month → After ' +
            RLM_BambooAgentBffClient.money(res.currencyCode, res.monthlyAfter) +
            ' / month (Δ ' +
            RLM_BambooAgentBffClient.money(res.currencyCode, res.monthlyDifference) +
            '). Due today (prorated Quote charge) needs Generate quote — not available on estimate.';
        return res;
    }
}
