/**
 * Agentforce action: Contact lookup by work email (never a Lead).
 * POST /api/qualify-lookup
 */
public with sharing class RLM_BambooAgentLookupQualifyEmail {
    public class Request {
        @InvocableVariable(
            required=true
            label='Work email'
            description='Buyer work email to classify: selfServe, salesWorking, or existingCustomer.'
        )
        public String email;
    }

    public class Result {
        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;

        @InvocableVariable(label='Error Message')
        public String errorMessage;

        @InvocableVariable(label='Summary')
        public String summary;

        @InvocableVariable(label='Status' description='selfServe, salesWorking, or existingCustomer.')
        public String status;

        @InvocableVariable(label='Reason')
        public String reason;

        @InvocableVariable(label='Account Id')
        public String accountId;

        @InvocableVariable(label='Contact Id')
        public String contactId;

        @InvocableVariable(label='Sign-in URL')
        public String signInUrl;

        @InvocableVariable(label='Matched')
        public Boolean matched;

        @InvocableVariable(label='Response JSON')
        public String responseJson;
    }

    @InvocableMethod(
        label='BambooHR Lookup Qualify Email'
        description='Looks up Contact by work email. Returns selfServe, salesWorking, or existingCustomer. Never creates a Lead. Do not Create Quote unless status is selfServe.'
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
        if (req == null || String.isBlank(req.email)) {
            res.errorMessage = 'Work email is required.';
            return res;
        }

        RLM_BambooAgentBffClient.Response http = RLM_BambooAgentBffClient.post(
            '/api/qualify-lookup',
            new Map<String, Object>{ 'email' => req.email.trim() }
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
        mapLookup(http.jsonMap, res);
        return res;
    }

    static void mapLookup(Map<String, Object> jsonMap, Result res) {
        res.status = RLM_BambooAgentBffClient.asString(jsonMap.get('status'));
        res.reason = RLM_BambooAgentBffClient.asString(jsonMap.get('reason'));
        res.accountId = RLM_BambooAgentBffClient.asString(jsonMap.get('accountId'));
        res.contactId = RLM_BambooAgentBffClient.asString(jsonMap.get('contactId'));
        res.signInUrl = RLM_BambooAgentBffClient.asString(jsonMap.get('signInUrl'));
        Object matched = jsonMap.get('matched');
        res.matched = matched == true || matched == 'true';
        if (res.status == 'existingCustomer') {
            res.summary =
                'This email is already a BambooHR customer. Direct them to sign in / Licenses — do not create a new Quote.' +
                (String.isNotBlank(res.signInUrl) ? ' Sign-in: ' + res.signInUrl : '');
        } else if (res.status == 'salesWorking') {
            res.summary =
                'Sales is already working this account. Do not create a competing self-serve Quote.' +
                (String.isNotBlank(res.reason) ? ' ' + res.reason : '');
        } else {
            res.summary =
                'Email is clear for self-serve. Call Commit Qualify Identity with company + email before Create Quote.';
        }
    }
}
