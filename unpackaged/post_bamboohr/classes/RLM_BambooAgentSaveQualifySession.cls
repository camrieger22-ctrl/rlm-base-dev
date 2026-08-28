/**
 * Agentforce action: persist Get Pricing qualify wizard beats.
 * POST /api/qualify-session
 */
public with sharing class RLM_BambooAgentSaveQualifySession {
    public class Request {
        @InvocableVariable(label='Qualify session Id' description='Reuse on later beats. Blank creates a new session.')
        public String sessionId;

        @InvocableVariable(
            label='Page qualify session Id'
            description='Pre-chat qualify session when sessionId is blank.'
        )
        public String pageQualifySessionId;

        @InvocableVariable(label='Step' description='Wizard beat 1–5.')
        public Integer step;

        @InvocableVariable(label='Headcount' description='Employee count.')
        public Integer headcount;

        @InvocableVariable(label='Country' description='US, CA, or UK.')
        public String country;

        @InvocableVariable(label='Needs CSV' description='Comma-separated needs, e.g. hiring,timetracking.')
        public String needsCsv;

        @InvocableVariable(label='Decision-maker role')
        public String dmRole;

        @InvocableVariable(label='Work email')
        public String email;

        @InvocableVariable(label='Company')
        public String company;

        @InvocableVariable(label='First name')
        public String firstName;

        @InvocableVariable(label='Last name')
        public String lastName;

        @InvocableVariable(label='Bounce type' description='size, geo, payroll, or elite when bouncing to sales.')
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

        @InvocableVariable(label='Qualify session Id')
        public String sessionId;

        @InvocableVariable(label='Step')
        public Integer step;

        @InvocableVariable(label='Response JSON')
        public String responseJson;
    }

    @InvocableMethod(
        label='BambooHR Save Qualify Session'
        description='Persists Get Pricing qualify beats (size, geo, needs, role, identity). Returns sessionId to reuse. Does not create Account or Quote.'
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
        if (req == null) {
            res.errorMessage = 'Qualify session request is required.';
            return res;
        }

        Map<String, Object> body = new Map<String, Object>();
        String sid = RLM_BambooAgentBffClient.firstNonBlank(req.sessionId, req.pageQualifySessionId);
        if (String.isNotBlank(sid)) {
            body.put('sessionId', sid);
        }
        if (req.step != null) {
            body.put('step', req.step);
        }
        if (req.headcount != null) {
            body.put('headcount', req.headcount);
        }
        if (String.isNotBlank(req.country)) {
            body.put('country', req.country.trim().toUpperCase());
        }
        List<String> needs = RLM_BambooAgentBffClient.splitCsv(req.needsCsv);
        if (!needs.isEmpty()) {
            body.put('needs', needs);
        }
        if (String.isNotBlank(req.dmRole)) {
            body.put('dmRole', req.dmRole.trim());
        }
        if (String.isNotBlank(req.email)) {
            body.put('email', req.email.trim());
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
        if (String.isNotBlank(req.bounceType)) {
            body.put('bounceType', req.bounceType.trim());
        }
        if (String.isNotBlank(req.bounceReason)) {
            body.put('bounceReason', req.bounceReason.trim());
        }

        RLM_BambooAgentBffClient.Response http = RLM_BambooAgentBffClient.post(
            '/api/qualify-session',
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

        Map<String, Object> session = RLM_BambooAgentBffClient.asMap(http.jsonMap.get('session'));
        res.isSuccess = true;
        res.sessionId = session == null
            ? null
            : RLM_BambooAgentBffClient.asString(session.get('sessionId'));
        res.step = session == null ? req.step : RLM_BambooAgentBffClient.asInteger(session.get('step'));
        res.summary =
            'Saved qualify progress' +
            (String.isNotBlank(res.sessionId) ? ' (session ' + res.sessionId + ')' : '') +
            (res.step != null ? ', beat ' + String.valueOf(res.step) : '') +
            '. No Account or Quote yet.';
        return res;
    }
}
