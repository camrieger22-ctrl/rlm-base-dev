/**
 * Agentforce action: Place Get Pricing Quote → Order via BFF checkout.
 * POST /api/checkout. Requires buyer confirmation in the Agent Script.
 * Never collects card numbers — Pay Now URL only.
 */
public with sharing class RLM_BambooAgentPlaceGetPricingOrder {
    public class Request {
        @InvocableVariable(
            label='Quote Id'
            description='Get Pricing Draft Quote Id (lastQuoteId).'
        )
        public String quoteId;

        @InvocableVariable(
            label='Page Quote Id'
            description='Quote Id from page context when quoteId is blank.'
        )
        public String pageQuoteId;

        @InvocableVariable(
            label='Account Id'
            description='Session Account Id. Place fails if it does not match the Quote.'
        )
        public String accountId;
    }

    public class Result {
        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;

        @InvocableVariable(label='Error Message')
        public String errorMessage;

        @InvocableVariable(
            label='Summary'
            description='Order confirmation with Quote total and Pay Now URL when ready.'
        )
        public String summary;

        @InvocableVariable(label='Order Id')
        public String orderId;

        @InvocableVariable(label='Order Number')
        public String orderNumber;

        @InvocableVariable(label='Payment URL')
        public String paymentUrl;

        @InvocableVariable(label='Quote Total')
        public Decimal quoteTotal;

        @InvocableVariable(label='Start Date')
        public String startDate;

        @InvocableVariable(label='Response JSON')
        public String responseJson;
    }

    @InvocableMethod(
        label='BambooHR Place Get Pricing Order'
        description='Places the confirmed Get Pricing Quote (createOrderFromQuote + activate). Returns Order Id. Pay Now is Collect Payment when the URL is blank. Never send a card number. Requires user confirmation.'
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
        if (req == null || (String.isBlank(req.quoteId) && String.isBlank(req.pageQuoteId))) {
            res.errorMessage = 'Quote Id is required to Place the order.';
            return res;
        }
        String qid = RLM_BambooAgentBffClient.firstNonBlank(req.quoteId, req.pageQuoteId);
        Id quoteId;
        try {
            quoteId = Id.valueOf(qid);
        } catch (Exception e) {
            res.errorMessage = 'Invalid Quote Id.';
            return res;
        }
        if (!Test.isRunningTest()) {
            String gate = quotePlaceGate(quoteId, req.accountId, req.pageQuoteId);
            if (String.isNotBlank(gate)) {
                res.errorMessage = gate;
                return res;
            }
        }

        Map<String, Object> body = new Map<String, Object>{
            'quoteId' => qid,
            'collectPayment' => false,
            'chatFast' => true,
            'pollTimeout' => 20
        };
        RLM_BambooAgentBffClient.Response http = RLM_BambooAgentBffClient.post(
            '/api/checkout',
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
        res.orderNumber = RLM_BambooAgentBffClient.asString(http.jsonMap.get('orderNumber'));
        res.quoteTotal = RLM_BambooAgentBffClient.asDecimal(http.jsonMap.get('quoteTotal'));
        res.startDate = RLM_BambooAgentBffClient.asString(http.jsonMap.get('startDate'));
        res.paymentUrl = RLM_BambooAgentBffClient.asString(http.jsonMap.get('paymentUrl'));
        if (String.isBlank(res.paymentUrl)) {
            Map<String, Object> payment = RLM_BambooAgentBffClient.asMap(http.jsonMap.get('payment'));
            if (payment != null) {
                res.paymentUrl = RLM_BambooAgentBffClient.asString(payment.get('paymentUrl'));
            }
        }

        String totalBit = res.quoteTotal == null
            ? ''
            : ' Quote total ' + RLM_BambooAgentBffClient.money(null, res.quoteTotal) + '.';
        String startBit = String.isBlank(res.startDate) ? '' : ' Start ' + res.startDate + '.';
        String payBit = String.isBlank(res.paymentUrl)
            ? ' Pay Now URL is not ready yet — open the quote summary to pay.'
            : '\n' + res.paymentUrl;
        res.summary =
            'Order placed' +
            (String.isNotBlank(res.orderNumber) ? ' (' + res.orderNumber + ')' : '') +
            '.' +
            totalBit +
            startBit +
            payBit;
        if (String.isBlank(res.paymentUrl)) {
            res.summary += ' Call Collect Payment with the Order Id if the buyer needs a Pay Now link.';
        }
        return res;
    }

    @TestVisible
    static Boolean sessionAccountBlocksPlace(
        Id quoteAccountId,
        String sessionAccountId,
        String pageQuoteId,
        Id quoteId
    ) {
        if (quoteAccountId == null || String.isBlank(sessionAccountId)) {
            return false;
        }
        // Buyer is on /quote/{id} — a Licenses pin must not block this Place.
        if (String.isNotBlank(pageQuoteId) && quoteId != null) {
            try {
                if (Id.valueOf(pageQuoteId.trim()) == quoteId) {
                    return false;
                }
            } catch (Exception e) {
                // Fall through to the session-account comparison.
            }
        }
        try {
            return Id.valueOf(sessionAccountId.trim()) != quoteAccountId;
        } catch (Exception e) {
            return true;
        }
    }

    @TestVisible
    static String quotePlaceGate(Id quoteId, String sessionAccountId, String pageQuoteId) {
        List<Quote> rows = [
            SELECT Id, Status, Name, QuoteAccountId
            FROM Quote
            WHERE Id = :quoteId
            WITH USER_MODE
            LIMIT 1
        ];
        if (rows.isEmpty()) {
            return 'Quote not found.';
        }
        Quote q = rows[0];
        if (q.Status != null && q.Status != 'Draft') {
            return 'Quote is not Draft. Will not Place it.';
        }
        if (!RLM_BambooAgentBffClient.isAcquisitionDraftName(q.Name)) {
            return 'That Quote is not a Get Pricing self-serve Draft. Will not Place it.';
        }
        // USER_MODE treats Order.QuoteId as missing unless FLS is granted
        // (QueryException: No such column 'QuoteId'). Skip rather than fail Place;
        // BFF checkout still refuses a second Activated Order.
        try {
            if (Schema.sObjectType.Order.fields.QuoteId.isAccessible()) {
                List<Order> placed = [
                    SELECT Id
                    FROM Order
                    WHERE QuoteId = :quoteId AND Status = 'Activated'
                    WITH USER_MODE
                    LIMIT 1
                ];
                if (!placed.isEmpty()) {
                    return 'This Quote already has an Activated Order. Will not Place it again.';
                }
            }
        } catch (QueryException e) {
            // Agent user cannot see Order.QuoteId — continue to BFF Place.
        }
        if (sessionAccountBlocksPlace(q.QuoteAccountId, sessionAccountId, pageQuoteId, quoteId)) {
            return 'That Quote belongs to a different Account. Will not Place it.';
        }
        return null;
    }
}
