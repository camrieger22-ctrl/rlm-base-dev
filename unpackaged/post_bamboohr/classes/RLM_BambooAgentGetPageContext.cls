/**
 * Agentforce action: read the self-serve wizard context stamped on the
 * Messaging Session by the Route_to_BambooHR_Assistant routing flow.
 *
 * Read-only context variables hydrate once at session start, which races the
 * routing flow that stamps these fields. Reading them as an action instead
 * resolves the values at turn time, after the stamp has committed.
 */
public with sharing class RLM_BambooAgentGetPageContext {
    @TestVisible
    static final Map<String, String> BEAT_LABELS = new Map<String, String>{
        '1' => 'team size (employees)',
        '2' => 'location (US/CA)',
        '3' => 'needs (Core or Pro)',
        '4' => 'decision-maker role',
        '5' => 'create your account'
    };

    @TestVisible
    static final Map<String, String> BOUNCE_LABELS = new Map<String, String>{
        'size' => '25 or more employees',
        'geo' => 'outside the US and Canada',
        'payroll' => 'Payroll',
        'elite' => 'Elite'
    };

    public class Request {
        @InvocableVariable(
            label='Messaging Session Id'
            description='Messaging Session record Id. Pass the RoutableId variable.'
            required=true
        )
        public String messagingSessionId;
    }

    public class Result {
        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;

        @InvocableVariable(label='Error Message')
        public String errorMessage;

        @InvocableVariable(
            label='Summary'
            description='Human-readable page context: current wizard beat, headcount, surface, bounce.'
        )
        public String summary;

        @InvocableVariable(
            label='Has Context'
            description='False when the buyer opened chat without any wizard context.'
        )
        public Boolean hasContext;

        @InvocableVariable(label='Qualify Step' description='Wizard beat 1-5, blank when unknown.')
        public String qualifyStep;

        @InvocableVariable(label='Qualify Step Label')
        public String qualifyStepLabel;

        @InvocableVariable(label='Bounce Type' description='size, geo, payroll, elite, or blank.')
        public String bounceType;

        @InvocableVariable(label='Headcount' description='Employee count the buyer entered.')
        public String headcount;

        @InvocableVariable(label='Page' description='get-pricing, quote, account, or activate.')
        public String page;
    }

    @InvocableMethod(
        label='BambooHR Get Page Context'
        description='Reads the buyer\'s current self-serve wizard beat, headcount, surface, and sales bounce from the Messaging Session. Call this before answering "where am I?" or any page-orientation question.'
        category='BambooHR'
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
        res.hasContext = false;

        if (req == null || String.isBlank(req.messagingSessionId)) {
            res.errorMessage = 'Provide the Messaging Session Id (RoutableId).';
            return res;
        }

        Id sessionId;
        try {
            sessionId = Id.valueOf(req.messagingSessionId.trim());
        } catch (Exception e) {
            res.errorMessage = 'Invalid Messaging Session Id.';
            return res;
        }
        if (sessionId.getSObjectType() != MessagingSession.SObjectType) {
            res.errorMessage = 'Id is not a Messaging Session.';
            return res;
        }

        List<MessagingSession> sessions;
        try {
            sessions = [
                SELECT
                    Id,
                    RLM_Bamboo_QualifyStep__c,
                    RLM_Bamboo_BounceType__c,
                    RLM_Bamboo_Headcount__c,
                    RLM_Bamboo_Page__c
                FROM MessagingSession
                WHERE Id = :sessionId
                WITH USER_MODE
                LIMIT 1
            ];
        } catch (Exception e) {
            res.errorMessage = 'Cannot read Messaging Session context: ' + e.getMessage();
            return res;
        }
        if (sessions.isEmpty()) {
            res.errorMessage = 'Messaging Session not found.';
            return res;
        }

        MessagingSession ms = sessions[0];
        res.isSuccess = true;
        res.qualifyStep = blankToNull(ms.RLM_Bamboo_QualifyStep__c);
        res.bounceType = blankToNull(ms.RLM_Bamboo_BounceType__c);
        res.headcount = blankToNull(ms.RLM_Bamboo_Headcount__c);
        res.page = blankToNull(ms.RLM_Bamboo_Page__c);
        res.qualifyStepLabel = res.qualifyStep == null ? null : BEAT_LABELS.get(res.qualifyStep);
        res.hasContext =
            res.qualifyStep != null ||
            res.bounceType != null ||
            res.headcount != null ||
            res.page != null;
        res.summary = buildSummary(res);
        return res;
    }

    @TestVisible
    static String buildSummary(Result res) {
        if (!res.hasContext) {
            return 'No page context on this conversation — ask the buyer what they see on screen.';
        }

        List<String> parts = new List<String>();
        if (res.qualifyStep != null) {
            String label = res.qualifyStepLabel;
            parts.add(
                label == null
                    ? 'Buyer is on wizard beat ' + res.qualifyStep + ' of 5'
                    : 'Buyer is on wizard beat ' +
                      res.qualifyStep +
                      ' of 5: ' +
                      label
            );
        }
        if (res.headcount != null) {
            parts.add('entered ' + res.headcount + ' employees');
        }
        if (res.page != null) {
            parts.add('on the ' + res.page + ' surface');
        }
        if (res.bounceType != null) {
            String why = BOUNCE_LABELS.get(res.bounceType);
            parts.add(
                'routed to sales because of ' +
                (why == null ? res.bounceType : why)
            );
        }
        return String.join(parts, '; ') + '.';
    }

    @TestVisible
    static String blankToNull(String value) {
        return String.isBlank(value) ? null : value.trim();
    }
}
