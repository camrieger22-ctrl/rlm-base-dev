/**
 * Agentforce action: create or update sticky Draft amend Quote(s).
 * POST /api/account-amend-preview only (BFF auto-caches for /amend-quote/{id}).
 * Always pass prior amendQuotesJson / moduleQuoteId on subsequent edits.
 */
public with sharing class RLM_BambooAgentGenerateAmendQuote {
    public class Request {
        @InvocableVariable(
            required=true
            label='Account Id'
            description='Salesforce Account Id for the customer changing licenses.'
        )
        public String accountId;

        @InvocableVariable(
            label='New quantity'
            description='Target seat count. Omit when only adding modules.'
        )
        public Integer newQty;

        @InvocableVariable(
            label='Add-on SKUs (CSV)'
            description='Comma-separated modules to add.'
        )
        public String addonSkusCsv;

        @InvocableVariable(
            label='Amend start date'
            description='YYYY-MM-DD when the change should take effect.'
        )
        public String startDate;

        @InvocableVariable(
            label='Sticky amendQuotes JSON'
            description='JSON array from a prior Generate Or Update response (quoteId + assetIds). Pass back on every edit so the same Draft Quote is reused.'
        )
        public String amendQuotesJson;

        @InvocableVariable(
            label='Sticky module Quote Id'
            description='Prior add-module Draft Quote Id from a previous Generate Or Update response.'
        )
        public String moduleQuoteId;
    }

    public class Result {
        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;

        @InvocableVariable(label='Error Message')
        public String errorMessage;

        @InvocableVariable(
            label='Summary'
            description='Due-today prorated charge + After monthly + amend summary path. Place order stays on the summary CTA.'
        )
        public String summary;

        @InvocableVariable(label='Account Id')
        public String accountId;

        @InvocableVariable(label='Account Name')
        public String accountName;

        @InvocableVariable(label='Currency')
        public String currencyCode;

        @InvocableVariable(label='Due Today')
        public Decimal dueToday;

        @InvocableVariable(label='Monthly Today')
        public Decimal monthlyToday;

        @InvocableVariable(label='Monthly After')
        public Decimal monthlyAfter;

        @InvocableVariable(label='Sticky amendQuotes JSON')
        public String amendQuotesJson;

        @InvocableVariable(label='Sticky module Quote Id')
        public String moduleQuoteId;

        @InvocableVariable(label='Amend Quote URL path')
        public String amendQuoteUrl;

        @InvocableVariable(label='Sticky reused')
        public Boolean sticky;

        @InvocableVariable(label='Response JSON')
        public String responseJson;
    }

    @InvocableMethod(
        label='BambooHR Generate Or Update Amend Quote'
        description='Creates or updates sticky Draft amend Quote(s) via the Get Pricing BFF (single callout; BFF caches the amend summary). Always reuse returned amendQuotesJson and moduleQuoteId on the next edit. Due today is the prorated Quote charge.'
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
        if (String.isNotBlank(req.moduleQuoteId)) {
            body.put('moduleQuoteId', req.moduleQuoteId.trim());
        }
        List<Object> preferred = parseAmendQuotes(req.amendQuotesJson);
        if (!preferred.isEmpty()) {
            body.put('amendQuotes', preferred);
        }

        // Single callout — BFF auto-caches for /amend-quote/{id}.
        RLM_BambooAgentBffClient.Response http = RLM_BambooAgentBffClient.post(
            '/api/account-amend-preview',
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

        fillFromPreview(res, http.jsonMap);
        res.amendQuoteUrl = RLM_BambooAgentBffClient.asString(
            http.jsonMap.get('amendQuoteUrl')
        );
        if (String.isBlank(res.amendQuoteUrl)) {
            String cacheId = firstAmendQuoteId(res.amendQuotesJson);
            if (String.isBlank(cacheId)) {
                cacheId = res.moduleQuoteId;
            }
            if (String.isNotBlank(cacheId)) {
                res.amendQuoteUrl = '/amend-quote/' + cacheId;
            }
        }
        // Messaging won't make relative paths clickable — prefer absolute BFF URL.
        if (String.isNotBlank(res.amendQuoteUrl) && res.amendQuoteUrl.startsWith('/')) {
            res.amendQuoteUrl = RLM_BambooAgentBffClient.baseUrl() + res.amendQuoteUrl;
        }

        res.isSuccess = true;
        res.summary =
            'Draft amend Quote ready for ' +
            (String.isBlank(res.accountName) ? res.accountId : res.accountName) +
            '. Due today (prorated) ' +
            RLM_BambooAgentBffClient.money(res.currencyCode, res.dueToday) +
            '; After monthly ' +
            RLM_BambooAgentBffClient.money(res.currencyCode, res.monthlyAfter) +
            (res.sticky == true ? ' (reused sticky Draft).' : '.') +
            ' Place order stays on that summary — do not place from chat.' +
            (String.isNotBlank(res.amendQuoteUrl)
                ? '\nReview amend quote:\n' + res.amendQuoteUrl
                : ' Open Licenses amend summary to Place order.');
        return res;
    }

    private static void fillFromPreview(Result res, Map<String, Object> jsonMap) {
        res.accountId = RLM_BambooAgentBffClient.asString(jsonMap.get('accountId'));
        res.accountName = RLM_BambooAgentBffClient.asString(jsonMap.get('accountName'));
        res.currencyCode = RLM_BambooAgentBffClient.asString(jsonMap.get('currency'));
        res.dueToday = RLM_BambooAgentBffClient.asDecimal(jsonMap.get('dueToday'));
        res.moduleQuoteId = RLM_BambooAgentBffClient.asString(jsonMap.get('moduleQuoteId'));
        res.sticky = jsonMap.get('sticky') == true;
        Map<String, Object> monthly = (Map<String, Object>) jsonMap.get('monthly');
        if (monthly != null) {
            res.monthlyToday = RLM_BambooAgentBffClient.asDecimal(monthly.get('today'));
            res.monthlyAfter = RLM_BambooAgentBffClient.asDecimal(monthly.get('after'));
        }
        Object aq = jsonMap.get('amendQuotes');
        if (aq != null) {
            res.amendQuotesJson = JSON.serialize(aq);
        }
    }

    @TestVisible
    static String firstAmendQuoteId(String amendQuotesJson) {
        if (String.isBlank(amendQuotesJson)) {
            return null;
        }
        try {
            List<Object> drafts = (List<Object>) JSON.deserializeUntyped(amendQuotesJson);
            if (!drafts.isEmpty() && drafts[0] instanceof Map<String, Object>) {
                return RLM_BambooAgentBffClient.asString(
                    ((Map<String, Object>) drafts[0]).get('quoteId')
                );
            }
        } catch (Exception e) {
            return null;
        }
        return null;
    }

    @TestVisible
    static List<Object> parseAmendQuotes(String raw) {
        List<Object> out = new List<Object>();
        if (String.isBlank(raw)) {
            return out;
        }
        try {
            Object parsed = JSON.deserializeUntyped(raw.trim());
            if (parsed instanceof List<Object>) {
                for (Object row : (List<Object>) parsed) {
                    if (row instanceof Map<String, Object>) {
                        Map<String, Object> m = (Map<String, Object>) row;
                        if (m.get('quoteId') != null) {
                            out.add(m);
                        }
                    }
                }
            }
        } catch (Exception e) {
            // Invalid sticky JSON — proceed without preferred ids.
        }
        return out;
    }
}
