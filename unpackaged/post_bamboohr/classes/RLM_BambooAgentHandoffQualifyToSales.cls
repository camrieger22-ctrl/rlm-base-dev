/**
 * Agentforce action: wizard bounce → sales (never SelfServe, never Quote).
 * POST /api/qualify-handoff
 */
public with sharing class RLM_BambooAgentHandoffQualifyToSales {
    public class Request {
        @InvocableVariable(required=true label='Company')
        public String company;

        @InvocableVariable(required=true label='Work email')
        public String email;

        @InvocableVariable(label='Headcount')
        public Integer headcount;

        @InvocableVariable(label='Country')
        public String country;

        @InvocableVariable(label='Needs CSV')
        public String needsCsv;

        @InvocableVariable(label='Decision-maker role')
        public String dmRole;

        @InvocableVariable(label='First name')
        public String firstName;

        @InvocableVariable(label='Last name')
        public String lastName;

        @InvocableVariable(
            required=true
            label='Bounce type'
            description='size, geo, payroll, or elite.'
        )
        public String bounceType;

        @InvocableVariable(label='Bounce reason')
        public String bounceReason;
    }

    public class Result {
        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;

        @InvocableVariable(label='Error Message')
        public String errorMessage;

        @InvocableVariable(label='Summary')
        public String summary;

        @InvocableVariable(label='Status')
        public String status;

        @InvocableVariable(label='Reason')
        public String reason;

        @InvocableVariable(label='Account Id')
        public String accountId;

        @InvocableVariable(label='Contact Id')
        public String contactId;

        @InvocableVariable(label='Task Id')
        public String taskId;

        @InvocableVariable(label='Sign-in URL')
        public String signInUrl;

        @InvocableVariable(label='Already working')
        public Boolean alreadyWorking;

        @InvocableVariable(label='Response JSON')
        public String responseJson;
    }

    @InvocableMethod(
        label='BambooHR Handoff Qualify To Sales'
        description='Captures Payroll, Elite, 25+, or geo bounces for sales. Never stamps SelfServe. Never creates a Quote. Existing customers are directed to sign in.'
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
        if (req == null || String.isBlank(req.company) || String.isBlank(req.email)) {
            res.errorMessage = 'Work email and company are required to connect them with a person.';
            return res;
        }
        if (String.isBlank(req.bounceType)) {
            res.errorMessage = 'bounceType is required (size, geo, payroll, or elite).';
            return res;
        }

        Map<String, Object> body = new Map<String, Object>{
            'company' => req.company.trim(),
            'email' => req.email.trim(),
            'bounceType' => req.bounceType.trim(),
            'bounceReason' => String.isBlank(req.bounceReason)
                ? 'Qualified to talk to a person.'
                : req.bounceReason.trim(),
            'needs' => RLM_BambooAgentBffClient.splitCsv(req.needsCsv)
        };
        if (req.headcount != null) {
            body.put('headcount', req.headcount);
        }
        if (String.isNotBlank(req.country)) {
            body.put('country', req.country.trim().toUpperCase());
        }
        if (String.isNotBlank(req.dmRole)) {
            body.put('dmRole', req.dmRole.trim());
        }
        if (String.isNotBlank(req.firstName)) {
            body.put('firstName', req.firstName.trim());
        }
        if (String.isNotBlank(req.lastName)) {
            body.put('lastName', req.lastName.trim());
        }

        RLM_BambooAgentBffClient.Response http = RLM_BambooAgentBffClient.post(
            '/api/qualify-handoff',
            body
        );
        res.responseJson = http.body;
        if (!http.transportOk || http.jsonMap == null) {
            res.errorMessage = String.isNotBlank(http.error)
                ? http.error
                : 'No response from Get Pricing BFF.';
            return res;
        }

        mapHandoff(http.jsonMap, res);
        if (RLM_BambooAgentBffClient.isConflict(http) || res.status == 'existingCustomer') {
            res.isSuccess = false;
            res.errorMessage = String.isNotBlank(res.reason)
                ? res.reason
                : 'Existing customer — sign in instead of sales handoff.';
            res.summary =
                'This email is already a customer. Direct them to sign in / Licenses. Do not Create Quote.';
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
        res.summary =
            (res.alreadyWorking == true
                ? 'Sales is already working this account. Do not create a self-serve Quote.'
                : 'Captured for sales. A person will follow up. Do not create a self-serve Quote.') +
            (String.isNotBlank(res.reason) ? ' ' + res.reason : '');
        return res;
    }

    static void mapHandoff(Map<String, Object> jsonMap, Result res) {
        res.status = RLM_BambooAgentBffClient.asString(jsonMap.get('status'));
        res.reason = RLM_BambooAgentBffClient.asString(jsonMap.get('reason'));
        res.accountId = RLM_BambooAgentBffClient.asString(jsonMap.get('accountId'));
        res.contactId = RLM_BambooAgentBffClient.asString(jsonMap.get('contactId'));
        res.taskId = RLM_BambooAgentBffClient.asString(jsonMap.get('taskId'));
        res.signInUrl = RLM_BambooAgentBffClient.asString(jsonMap.get('signInUrl'));
        Object already = jsonMap.get('alreadyWorking');
        res.alreadyWorking = already == true || already == 'true';
    }
}
