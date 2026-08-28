/**
 * Agentforce action: complete Activate checklist steps via BFF.
 * POST /api/activate. People, admin email, time-off policy — no PAN.
 */
public with sharing class RLM_BambooAgentCompleteActivate {
    public class Request {
        @InvocableVariable(label='Account Id')
        public String accountId;

        @InvocableVariable(label='Company')
        public String company;

        @InvocableVariable(label='First name')
        public String firstName;

        @InvocableVariable(label='Last name')
        public String lastName;

        @InvocableVariable(label='Email')
        public String email;

        @InvocableVariable(label='Admin email')
        public String adminEmail;

        @InvocableVariable(label='Time-off policy')
        public String timeOffPolicy;
    }

    public class Result {
        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;

        @InvocableVariable(label='Error Message')
        public String errorMessage;

        @InvocableVariable(label='Summary')
        public String summary;

        @InvocableVariable(label='Account Id')
        public String accountId;

        @InvocableVariable(label='Paid')
        public Boolean paid;

        @InvocableVariable(label='Login ready')
        public Boolean loginReady;

        @InvocableVariable(label='Licenses URL')
        public String licensesUrl;

        @InvocableVariable(label='Response JSON')
        public String responseJson;
    }

    @InvocableMethod(
        label='BambooHR Complete Activate'
        description='Records Activate people, admin email, or time-off policy on the Account. Returns the aha checklist.'
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
            res.errorMessage = 'Account Id or company is required.';
            return res;
        }
        Map<String, Object> body = new Map<String, Object>();
        if (String.isNotBlank(req.accountId)) {
            try {
                Id.valueOf(req.accountId.trim());
            } catch (Exception e) {
                res.errorMessage = 'Invalid Account Id.';
                return res;
            }
            body.put('accountId', req.accountId.trim());
        }
        if (String.isNotBlank(req.company)) {
            body.put('company', req.company.trim());
        }
        if (String.isNotBlank(req.firstName)) {
            body.put('firstName', req.firstName.trim());
        }
        if (String.isNotBlank(req.lastName)) {
            body.put('lastName', req.lastName.trim());
        }
        if (String.isNotBlank(req.email)) {
            body.put('email', req.email.trim());
        }
        if (String.isNotBlank(req.adminEmail)) {
            body.put('adminEmail', req.adminEmail.trim());
        }
        if (String.isNotBlank(req.timeOffPolicy)) {
            body.put('timeOffPolicy', req.timeOffPolicy.trim());
        }

        RLM_BambooAgentBffClient.Response http = RLM_BambooAgentBffClient.post(
            '/api/activate',
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
        Object paidObj = http.jsonMap.get('paid');
        res.paid = paidObj instanceof Boolean ? (Boolean) paidObj : null;
        Object loginObj = http.jsonMap.get('loginReady');
        res.loginReady = loginObj instanceof Boolean ? (Boolean) loginObj : null;
        res.licensesUrl = RLM_BambooAgentBffClient.asString(http.jsonMap.get('licensesUrl'));
        String msg = RLM_BambooAgentBffClient.asString(http.jsonMap.get('message'));
        res.summary = String.isNotBlank(msg)
            ? msg
            : 'Activate checklist updated.';
        return res;
    }
}
