/**
 * Agentforce action: Place a Licenses amend (qty / modules) via BFF.
 * POST /api/account-amend. Distinct from acquisition Place.
 */
public with sharing class RLM_BambooAgentPlaceAmend {
    public class Request {
        @InvocableVariable(required=true label='Account Id')
        public String accountId;

        @InvocableVariable(label='New quantity')
        public Integer newQty;

        @InvocableVariable(label='Add-on SKUs CSV')
        public String addonSkusCsv;

        @InvocableVariable(label='Start date')
        public String startDate;

        @InvocableVariable(label='Amend Quotes JSON')
        public String amendQuotesJson;

        @InvocableVariable(label='Module Quote Id')
        public String moduleQuoteId;
    }

    public class Result {
        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;

        @InvocableVariable(label='Error Message')
        public String errorMessage;

        @InvocableVariable(label='Summary')
        public String summary;

        @InvocableVariable(label='Amend Order Id')
        public String amendOrderId;

        @InvocableVariable(label='Amend Order Number')
        public String amendOrderNumber;

        @InvocableVariable(label='Payment URL')
        public String paymentUrl;

        @InvocableVariable(label='Account Id')
        public String accountId;

        @InvocableVariable(label='Response JSON')
        public String responseJson;
    }

    @InvocableMethod(
        label='BambooHR Place Amend'
        description='Places a confirmed Licenses amend Quote (seats or modules). Not acquisition Place. Never take a card number.'
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
            res.errorMessage = 'Account Id is required.';
            return res;
        }
        try {
            Id.valueOf(req.accountId.trim());
        } catch (Exception e) {
            res.errorMessage = 'Invalid Account Id.';
            return res;
        }
        if (req.newQty == null && String.isBlank(req.addonSkusCsv)) {
            res.errorMessage = 'Provide newQty and/or addon SKUs to Place the amend.';
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
        if (String.isNotBlank(req.moduleQuoteId)) {
            body.put('moduleQuoteId', req.moduleQuoteId.trim());
        }
        List<Object> preferred = RLM_BambooAgentGenerateAmendQuote.parseAmendQuotes(
            req.amendQuotesJson
        );
        if (!preferred.isEmpty()) {
            body.put('amendQuotes', preferred);
        }

        RLM_BambooAgentBffClient.Response http = RLM_BambooAgentBffClient.post(
            '/api/account-amend',
            body
        );
        res.responseJson = http.body;
        if (!http.transportOk || http.jsonMap == null) {
            res.errorMessage = String.isNotBlank(http.error)
                ? http.error
                : 'No response from Get Pricing BFF.';
            return res;
        }
        if (!RLM_BambooAgentBffClient.http2xx(http) || !RLM_BambooAgentBffClient.isOk(http.jsonMap)) {
            res.errorMessage = RLM_BambooAgentBffClient.extractError(
                http.jsonMap,
                http.body,
                http.statusCode
            );
            return res;
        }

        res.isSuccess = true;
        res.accountId = RLM_BambooAgentBffClient.asString(http.jsonMap.get('accountId'));
        res.amendOrderId = RLM_BambooAgentBffClient.asString(http.jsonMap.get('amendOrderId'));
        res.amendOrderNumber = RLM_BambooAgentBffClient.asString(
            http.jsonMap.get('amendOrderNumber')
        );
        Map<String, Object> payment = RLM_BambooAgentBffClient.asMap(http.jsonMap.get('payment'));
        if (payment != null) {
            res.paymentUrl = RLM_BambooAgentBffClient.asString(payment.get('paymentUrl'));
        }
        String payBit = String.isBlank(res.paymentUrl)
            ? ''
            : '\n' + res.paymentUrl;
        res.summary =
            'License change placed' +
            (String.isNotBlank(res.amendOrderNumber)
                ? ' (' + res.amendOrderNumber + ')'
                : '') +
            '.' +
            payBit;
        return res;
    }
}
