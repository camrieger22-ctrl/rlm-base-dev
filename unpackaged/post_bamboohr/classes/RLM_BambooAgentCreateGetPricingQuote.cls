/**
 * Agentforce action: create Get Pricing Quote via BFF.
 * POST /api/get-pricing (requires company + work email).
 */
public with sharing class RLM_BambooAgentCreateGetPricingQuote {
    public class Request {
        @InvocableVariable(required=true label='Headcount' description='Seats / employees (>= 1).')
        public Integer headcount;

        @InvocableVariable(label='Country' description='US, CA, or UK. Defaults to US.')
        public String country;

        @InvocableVariable(label='Plan SKU' description='BAMBOO-CORE, BAMBOO-PRO, or BAMBOO-ELITE.')
        public String planSku;

        @InvocableVariable(label='Add-on SKUs (CSV)' description='Comma-separated add-on SKUs.')
        public String addonSkusCsv;

        @InvocableVariable(label='Free trial' description='True for convert-later free trial Quote.')
        public Boolean freeTrial;

        @InvocableVariable(label='Start date' description='YYYY-MM-DD start date.')
        public String startDate;

        @InvocableVariable(label='Term months' description='12, 24, or 36.')
        public Integer termMonths;

        @InvocableVariable(
            required=true
            label='Company'
            description='Buyer company / Account name. Required to create a Quote.'
        )
        public String company;

        @InvocableVariable(
            required=true
            label='Work email'
            description='Buyer work email for the Contact. Required to create a Quote.'
        )
        public String email;

        @InvocableVariable(label='First name')
        public String firstName;

        @InvocableVariable(label='Last name')
        public String lastName;

        @InvocableVariable(label='Phone')
        public String phone;

        @InvocableVariable(label='Job title')
        public String jobTitle;
    }

    public class Result {
        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;

        @InvocableVariable(label='Error Message')
        public String errorMessage;

        @InvocableVariable(
            label='Summary'
            description='Human-readable confirmation with Quote link. Direct Place order to the summary CTA.'
        )
        public String summary;

        @InvocableVariable(label='Quote Id')
        public String quoteId;

        @InvocableVariable(label='Quote URL path' description='Relative path e.g. /quote/0Q0…')
        public String quoteUrl;

        @InvocableVariable(label='Account Id')
        public String accountId;

        @InvocableVariable(label='Currency')
        public String currencyCode;

        @InvocableVariable(label='Net PEPM')
        public Decimal netPepm;

        @InvocableVariable(label='Monthly Total')
        public Decimal monthlyTotal;

        @InvocableVariable(label='Response JSON')
        public String responseJson;
    }

    @InvocableMethod(
        label='BambooHR Create Get Pricing Quote'
        description='Creates a Revenue Cloud Quote via the Get Pricing BFF after company and work email are collected. Returns the branded summary path. Do not place the order in chat.'
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
        if (req == null || req.headcount == null || req.headcount < 1) {
            res.errorMessage = 'headcount must be an integer >= 1.';
            return res;
        }
        if (String.isBlank(req.company) || String.isBlank(req.email)) {
            res.errorMessage = 'Company and work email are required to create a Quote.';
            return res;
        }

        Map<String, Object> body = new Map<String, Object>{
            'headcount' => req.headcount,
            'country' => String.isBlank(req.country) ? 'US' : req.country.trim().toUpperCase(),
            'planSku' => String.isBlank(req.planSku) ? 'BAMBOO-PRO' : req.planSku.trim().toUpperCase(),
            'addonSkus' => RLM_BambooAgentBffClient.splitCsv(req.addonSkusCsv),
            'freeTrial' => req.freeTrial == true,
            'placeQuote' => true,
            'company' => req.company.trim(),
            'email' => req.email.trim(),
            'firstName' => req.firstName,
            'lastName' => req.lastName,
            'phone' => req.phone,
            'jobTitle' => req.jobTitle
        };
        if (String.isNotBlank(req.startDate)) {
            body.put('startDate', req.startDate.trim());
        }
        if (req.termMonths != null) {
            body.put('termMonths', req.termMonths);
        }

        RLM_BambooAgentBffClient.Response http = RLM_BambooAgentBffClient.post(
            '/api/get-pricing',
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

        res.isSuccess = true;
        res.quoteId = RLM_BambooAgentBffClient.asString(http.jsonMap.get('quoteId'));
        res.quoteUrl = RLM_BambooAgentBffClient.asString(http.jsonMap.get('quoteUrl'));
        if (String.isBlank(res.quoteUrl) && String.isNotBlank(res.quoteId)) {
            res.quoteUrl = '/quote/' + res.quoteId;
        }
        // Messaging won't make relative paths clickable — prefer absolute BFF URL.
        if (String.isNotBlank(res.quoteUrl) && res.quoteUrl.startsWith('/')) {
            res.quoteUrl = RLM_BambooAgentBffClient.baseUrl() + res.quoteUrl;
        }
        res.accountId = RLM_BambooAgentBffClient.asString(http.jsonMap.get('accountId'));
        res.currencyCode = RLM_BambooAgentBffClient.asString(http.jsonMap.get('currency'));
        res.netPepm = RLM_BambooAgentBffClient.asDecimal(http.jsonMap.get('netPepm'));
        res.monthlyTotal = RLM_BambooAgentBffClient.asDecimal(http.jsonMap.get('monthlyTotal'));
        // BFF netPepm is plan-only; Estimate + UI hero use blended (monthly ÷ seats).
        if (res.monthlyTotal != null && req.headcount != null && req.headcount > 0) {
            res.netPepm = (res.monthlyTotal / Decimal.valueOf(req.headcount)).setScale(2);
        }

        // Put the absolute URL alone so Messaging can auto-link it.
        res.summary =
            'Quote ready for ' +
            req.company.trim() +
            '. Monthly ' +
            RLM_BambooAgentBffClient.money(res.currencyCode, res.monthlyTotal) +
            ' (' +
            RLM_BambooAgentBffClient.money(res.currencyCode, res.netPepm) +
            ' PEPM). Place order stays on that summary — do not place from chat. Review quote:\n' +
            res.quoteUrl;
        return res;
    }
}
