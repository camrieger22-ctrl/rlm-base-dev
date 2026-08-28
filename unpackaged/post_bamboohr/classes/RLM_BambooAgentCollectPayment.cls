/**
 * Agentforce action: mint or refresh Pay Now URL via BFF.
 * POST /api/collect-payment. Never collects PAN.
 */
public with sharing class RLM_BambooAgentCollectPayment {
    public class Request {
        @InvocableVariable(label='Order Id' description='Order Id from Place.')
        public String orderId;

        @InvocableVariable(label='Invoice Id' description='Invoice Id when known.')
        public String invoiceId;
    }

    public class Result {
        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;

        @InvocableVariable(label='Error Message')
        public String errorMessage;

        @InvocableVariable(label='Summary')
        public String summary;

        @InvocableVariable(label='Payment URL')
        public String paymentUrl;

        @InvocableVariable(label='Invoice Id')
        public String invoiceId;

        @InvocableVariable(label='Order Id')
        public String orderId;

        @InvocableVariable(label='Response JSON')
        public String responseJson;
    }

    @InvocableMethod(
        label='BambooHR Collect Payment'
        description='Returns a Pay Now URL for an Order or Invoice. Never send a card number.'
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
        if (req == null || (String.isBlank(req.orderId) && String.isBlank(req.invoiceId))) {
            res.errorMessage = 'Order Id or Invoice Id is required.';
            return res;
        }
        Map<String, Object> body = new Map<String, Object>();
        if (String.isNotBlank(req.orderId)) {
            try {
                Id.valueOf(req.orderId.trim());
            } catch (Exception e) {
                res.errorMessage = 'Invalid Order Id.';
                return res;
            }
            body.put('orderId', req.orderId.trim());
        }
        if (String.isNotBlank(req.invoiceId)) {
            try {
                Id.valueOf(req.invoiceId.trim());
            } catch (Exception e) {
                res.errorMessage = 'Invalid Invoice Id.';
                return res;
            }
            body.put('invoiceId', req.invoiceId.trim());
        }
        body.put('pollTimeout', 90);

        RLM_BambooAgentBffClient.Response http = RLM_BambooAgentBffClient.post(
            '/api/collect-payment',
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
        res.orderId = RLM_BambooAgentBffClient.asString(http.jsonMap.get('orderId'));
        res.invoiceId = RLM_BambooAgentBffClient.asString(http.jsonMap.get('invoiceId'));
        res.paymentUrl = RLM_BambooAgentBffClient.asString(http.jsonMap.get('paymentUrl'));
        if (String.isBlank(res.paymentUrl)) {
            res.errorMessage = RLM_BambooAgentBffClient.asString(http.jsonMap.get('blockedReason'));
            if (String.isBlank(res.errorMessage)) {
                res.errorMessage = 'Pay Now URL is not ready yet.';
            }
            res.isSuccess = false;
            return res;
        }
        res.summary = 'Pay Now is ready. Paste this URL. Never take a card number.\n' + res.paymentUrl;
        return res;
    }
}
