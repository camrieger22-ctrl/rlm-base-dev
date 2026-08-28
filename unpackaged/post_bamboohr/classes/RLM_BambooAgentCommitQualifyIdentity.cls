/**
 * Agentforce action: beat-5 Account/Contact SelfServe stamp (no Quote).
 * POST /api/qualify-commit
 */
public with sharing class RLM_BambooAgentCommitQualifyIdentity {
    public class Request {
        @InvocableVariable(required=true label='Company')
        public String company;

        @InvocableVariable(required=true label='Work email')
        public String email;

        @InvocableVariable(required=true label='Headcount')
        public Integer headcount;

        @InvocableVariable(label='Country' description='US, CA, or UK. Defaults to US.')
        public String country;

        @InvocableVariable(label='Needs CSV')
        public String needsCsv;

        @InvocableVariable(label='Decision-maker role')
        public String dmRole;

        @InvocableVariable(label='First name')
        public String firstName;

        @InvocableVariable(label='Last name')
        public String lastName;

        @InvocableVariable(label='Qualify session Id')
        public String sessionId;
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

        @InvocableVariable(label='Committed' description='true only when SelfServe stamp succeeded.')
        public String committed;

        @InvocableVariable(label='Response JSON')
        public String responseJson;
    }

    @InvocableMethod(
        label='BambooHR Commit Qualify Identity'
        description='Creates or updates Account and Contact and stamps SelfServe before any Quote. Dual-motion and existing customers return conflict — do not Create Quote.'
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
        res.committed = 'false';
        if (req == null || String.isBlank(req.company) || String.isBlank(req.email)) {
            res.errorMessage = 'Company and work email are required to create the self-serve account.';
            return res;
        }
        if (req.headcount == null || req.headcount < 1) {
            res.errorMessage = 'headcount must be an integer >= 1.';
            return res;
        }

        Map<String, Object> body = new Map<String, Object>{
            'company' => req.company.trim(),
            'email' => req.email.trim(),
            'headcount' => req.headcount,
            'country' => String.isBlank(req.country) ? 'US' : req.country.trim().toUpperCase(),
            'needs' => RLM_BambooAgentBffClient.splitCsv(req.needsCsv)
        };
        if (String.isNotBlank(req.dmRole)) {
            body.put('dmRole', req.dmRole.trim());
        }
        if (String.isNotBlank(req.firstName)) {
            body.put('firstName', req.firstName.trim());
        }
        if (String.isNotBlank(req.lastName)) {
            body.put('lastName', req.lastName.trim());
        }
        if (String.isNotBlank(req.sessionId)) {
            body.put('sessionId', req.sessionId.trim());
        }

        RLM_BambooAgentBffClient.Response http = RLM_BambooAgentBffClient.post(
            '/api/qualify-commit',
            body
        );
        res.responseJson = http.body;
        if (!http.transportOk || http.jsonMap == null) {
            res.errorMessage = String.isNotBlank(http.error)
                ? http.error
                : 'No response from Get Pricing BFF.';
            return res;
        }

        mapIdentity(http.jsonMap, res);
        if (RLM_BambooAgentBffClient.isConflict(http)) {
            res.isSuccess = false;
            res.errorMessage = String.isNotBlank(res.reason)
                ? res.reason
                : RLM_BambooAgentBffClient.extractError(http.jsonMap, http.body, http.statusCode);
            res.summary = conflictSummary(res);
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
        res.committed = 'true';
        res.summary =
            'Self-serve Account is stamped. Sales will not call. You may estimate and Create Quote.' +
            (String.isNotBlank(res.accountId) ? ' Account ' + res.accountId + '.' : '');
        return res;
    }

    static void mapIdentity(Map<String, Object> jsonMap, Result res) {
        res.status = RLM_BambooAgentBffClient.asString(jsonMap.get('status'));
        res.reason = RLM_BambooAgentBffClient.asString(jsonMap.get('reason'));
        res.accountId = RLM_BambooAgentBffClient.asString(jsonMap.get('accountId'));
        res.contactId = RLM_BambooAgentBffClient.asString(jsonMap.get('contactId'));
        res.signInUrl = RLM_BambooAgentBffClient.asString(jsonMap.get('signInUrl'));
    }

    static String conflictSummary(Result res) {
        if (res.status == 'existingCustomer') {
            return 'This email is already a customer. Sign in / Licenses — do not Create Quote.';
        }
        if (res.status == 'salesWorking') {
            return 'Sales is already working this account. Do not create a competing Quote.';
        }
        return String.isNotBlank(res.reason)
            ? res.reason
            : 'Cannot stamp self-serve for this email.';
    }
}
