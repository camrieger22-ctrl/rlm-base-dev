/**
 * Agentforce action: Pricing API estimate for Get Pricing (no Opp/Quote).
 * POST /api/get-pricing-estimate
 */
public with sharing class RLM_BambooAgentEstimateGetPricing {
    public class Request {
        @InvocableVariable(
            required=true
            label='Headcount'
            description='Number of employees / seats to price (integer >= 1).'
        )
        public Integer headcount;

        @InvocableVariable(
            label='Country'
            description='Billing country code: US, CA, or UK. Defaults to US.'
        )
        public String country;

        @InvocableVariable(
            label='Plan SKU'
            description='Plan SKU: BAMBOO-CORE, BAMBOO-PRO, or BAMBOO-ELITE. Defaults to BAMBOO-PRO.'
        )
        public String planSku;

        @InvocableVariable(
            label='Add-on SKUs (CSV)'
            description='Comma-separated add-on SKUs, e.g. BAMBOO-ADD-PAYROLL,BAMBOO-ADD-BENEFITS.'
        )
        public String addonSkusCsv;

        @InvocableVariable(
            label='Free trial'
            description='True for convert-later free trial ($0 rail). Defaults to false.'
        )
        public Boolean freeTrial;

        @InvocableVariable(
            label='Start date'
            description='Subscription start date YYYY-MM-DD. Defaults to today on the BFF.'
        )
        public String startDate;

        @InvocableVariable(
            label='Term months'
            description='Subscription term in months: 12, 24, or 36. Defaults to 12.'
        )
        public Integer termMonths;
    }

    public class Result {
        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;

        @InvocableVariable(label='Error Message')
        public String errorMessage;

        @InvocableVariable(
            label='Summary'
            description='Human-readable PEPM / monthly estimate for the buyer. Speak this; do not invent numbers.'
        )
        public String summary;

        @InvocableVariable(label='Currency')
        public String currencyCode;

        @InvocableVariable(label='Net PEPM')
        public Decimal netPepm;

        @InvocableVariable(label='Monthly Total')
        public Decimal monthlyTotal;

        @InvocableVariable(label='Annual Total')
        public Decimal annualTotal;

        @InvocableVariable(label='Volume Percent')
        public Decimal volumePercent;

        @InvocableVariable(label='Pricing Source')
        public String pricingSource;

        @InvocableVariable(label='Response JSON')
        public String responseJson;
    }

    @InvocableMethod(
        label='BambooHR Estimate Get Pricing'
        description='Estimates BambooHR PEPM and monthly total via the Get Pricing BFF Pricing API. Does not create Opportunity or Quote. Use before collecting company/email for a Quote.'
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

        Map<String, Object> body = new Map<String, Object>{
            'headcount' => req.headcount,
            'country' => String.isBlank(req.country) ? 'US' : req.country.trim().toUpperCase(),
            'planSku' => String.isBlank(req.planSku) ? 'BAMBOO-PRO' : req.planSku.trim().toUpperCase(),
            'addonSkus' => RLM_BambooAgentBffClient.splitCsv(req.addonSkusCsv),
            'freeTrial' => req.freeTrial == true
        };
        if (String.isNotBlank(req.startDate)) {
            body.put('startDate', req.startDate.trim());
        }
        if (req.termMonths != null) {
            body.put('termMonths', req.termMonths);
        }

        RLM_BambooAgentBffClient.Response http = RLM_BambooAgentBffClient.post(
            '/api/get-pricing-estimate',
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
        res.currencyCode = RLM_BambooAgentBffClient.asString(http.jsonMap.get('currency'));
        res.netPepm = RLM_BambooAgentBffClient.asDecimal(http.jsonMap.get('netPepm'));
        res.monthlyTotal = RLM_BambooAgentBffClient.asDecimal(http.jsonMap.get('monthlyTotal'));
        res.annualTotal = RLM_BambooAgentBffClient.asDecimal(http.jsonMap.get('annualTotal'));
        res.volumePercent = RLM_BambooAgentBffClient.asDecimal(http.jsonMap.get('volumePercent'));
        res.pricingSource = RLM_BambooAgentBffClient.asString(http.jsonMap.get('pricingSource'));

        String plan = RLM_BambooAgentBffClient.asString(http.jsonMap.get('planSku'));
        Integer hc = RLM_BambooAgentBffClient.asInteger(http.jsonMap.get('headcount'));
        String warn = RLM_BambooAgentBffClient.joinWarnings(http.jsonMap.get('warnings'));
        res.summary =
            'Estimate for ' +
            plan +
            ' / ' +
            hc +
            ' seats: ' +
            RLM_BambooAgentBffClient.money(res.currencyCode, res.netPepm) +
            ' PEPM, ' +
            RLM_BambooAgentBffClient.money(res.currencyCode, res.monthlyTotal) +
            ' / month' +
            (res.volumePercent != null ? ' (volume ' + String.valueOf(res.volumePercent) + '%).' : '.') +
            ' No Quote created yet.' +
            (String.isNotBlank(warn) ? ' Note: ' + warn : '');
        return res;
    }
}
