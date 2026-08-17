/**
 * Agentforce action: Licenses & billing snapshot from BFF.
 * GET /api/account-console?accountId=… or ?company=…
 */
public with sharing class RLM_BambooAgentGetLicensesSummary {
    public class Request {
        @InvocableVariable(
            label='Account Id'
            description='Salesforce Account Id. Prefer this when page context provides accountId.'
        )
        public String accountId;

        @InvocableVariable(
            label='Company'
            description='Account name lookup when Account Id is unknown (demo pin).'
        )
        public String company;
    }

    public class Result {
        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;

        @InvocableVariable(label='Error Message')
        public String errorMessage;

        @InvocableVariable(
            label='Summary'
            description='Human-readable licenses snapshot: seats, Current MRR, country.'
        )
        public String summary;

        @InvocableVariable(label='Account Id')
        public String accountId;

        @InvocableVariable(label='Account Name')
        public String accountName;

        @InvocableVariable(label='Current Quantity')
        public Integer currentQuantity;

        @InvocableVariable(label='Recurring Monthly (Current MRR)')
        public Decimal recurringMonthly;

        @InvocableVariable(label='Currency')
        public String currencyCode;

        @InvocableVariable(label='Response JSON')
        public String responseJson;
    }

    @InvocableMethod(
        label='BambooHR Get Licenses Summary'
        description='Loads Licenses & billing for an Account via the Get Pricing BFF (Current MRR / seats from Salesforce Assets). Use before amend estimate.'
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
        if (req == null || (String.isBlank(req.accountId) && String.isBlank(req.company))) {
            res.errorMessage = 'Provide accountId or company.';
            return res;
        }

        String q;
        if (String.isNotBlank(req.accountId)) {
            q = 'accountId=' + EncodingUtil.urlEncode(req.accountId.trim(), 'UTF-8');
        } else {
            q = 'company=' + EncodingUtil.urlEncode(req.company.trim(), 'UTF-8');
        }

        RLM_BambooAgentBffClient.Response http = RLM_BambooAgentBffClient.get(
            '/api/account-console?' + q
        );
        res.responseJson = http.body;
        if (!http.transportOk || http.jsonMap == null) {
            res.errorMessage = String.isNotBlank(http.error)
                ? http.error
                : 'No response from Get Pricing BFF.';
            return res;
        }
        if (http.jsonMap.containsKey('ok') && !RLM_BambooAgentBffClient.isOk(http.jsonMap)) {
            res.errorMessage = RLM_BambooAgentBffClient.extractError(
                http.jsonMap,
                http.body,
                http.statusCode
            );
            return res;
        }

        Map<String, Object> account = (Map<String, Object>) http.jsonMap.get('account');
        Map<String, Object> sub = (Map<String, Object>) http.jsonMap.get('subscription');
        if (account == null || sub == null) {
            res.errorMessage = 'Unexpected account-console payload.';
            return res;
        }

        res.isSuccess = true;
        res.accountId = RLM_BambooAgentBffClient.asString(account.get('id'));
        res.accountName = RLM_BambooAgentBffClient.asString(account.get('name'));
        res.currencyCode = RLM_BambooAgentBffClient.asString(account.get('currency'));
        res.currentQuantity = RLM_BambooAgentBffClient.asInteger(sub.get('currentQuantity'));
        res.recurringMonthly = RLM_BambooAgentBffClient.asDecimal(sub.get('recurringMonthly'));

        res.summary =
            (String.isBlank(res.accountName) ? 'Account' : res.accountName) +
            ' has ' +
            String.valueOf(res.currentQuantity) +
            ' seats at Current MRR ' +
            RLM_BambooAgentBffClient.money(res.currencyCode, res.recurringMonthly) +
            ' / month. Use this as Today when discussing license changes.';
        return res;
    }
}
