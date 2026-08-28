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

    @TestVisible
    static final Map<String, String> PAGE_LABELS = new Map<String, String>{
        'get-pricing' => 'Get Pricing (qualify wizard)',
        'quote' => 'the quote summary',
        'account' => 'Licenses & billing',
        'activate' => 'Activate',
        'amend-quote' => 'the amend quote summary'
    };

    public class Request {
        @InvocableVariable(
            label='Messaging Session Id'
            description='Messaging Session record Id. Pass the RoutableId variable.'
            required=true
        )
        public String messagingSessionId;

        @InvocableVariable(label='Current Quote Id' description='lastQuoteId so a blank page does not wipe session.')
        public String currentQuoteId;

        @InvocableVariable(label='Current Account Id' description='activeAccountId so a blank page does not wipe session.')
        public String currentAccountId;

        @InvocableVariable(
            label='Current qualify session Id'
            description='qualifySessionId so a blank page does not wipe session.'
        )
        public String currentQualifySessionId;

        @InvocableVariable(
            label='Current committed'
            description='qualifyCommitted (true) so a blank page does not wipe it.'
        )
        public String currentCommitted;
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

        @InvocableVariable(label='Account Id' description='Account from pre-chat when chat opened on Licenses / quote / Activate.')
        public String accountId;

        @InvocableVariable(label='Quote Id' description='Get Pricing Quote Id when chat opened on /quote/{id}.')
        public String quoteId;

        @InvocableVariable(label='Qualify session Id' description='BFF qualify wizard session Id from pre-chat.')
        public String qualifySessionId;

        @InvocableVariable(label='Quote URL' description='Absolute summary URL when a Quote Id is known.')
        public String quoteUrl;

        @InvocableVariable(label='Qualify committed')
        public String qualifyCommitted;

        @InvocableVariable(label='Quote start date' description='YYYY-MM-DD from Quote or first line.')
        public String startDate;

        @InvocableVariable(label='Quote monthly / total')
        public Decimal monthlyTotal;

        @InvocableVariable(
            label='Monthly total (text)'
            description='String form of monthlyTotal for Agent Script session variables.'
        )
        public String monthlyTotalText;

        @InvocableVariable(label='Plan label' description='Product name from the Quote line when a Quote Id is known.')
        public String planLabel;

        @InvocableVariable(
            label='Place recitation'
            description='Exact sentence the Purchase topic must speak before Place. Empty when no Quote Id.'
        )
        public String placeRecitation;
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
                    RLM_Bamboo_Page__c,
                    RLM_Bamboo_AccountId__c,
                    RLM_Bamboo_QuoteId__c,
                    RLM_Bamboo_QualifySessionId__c
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
        mergeSticky(
            res,
            blankToNull(ms.RLM_Bamboo_AccountId__c),
            blankToNull(ms.RLM_Bamboo_QuoteId__c),
            blankToNull(ms.RLM_Bamboo_QualifySessionId__c),
            req
        );
        res.qualifyStepLabel = res.qualifyStep == null ? null : BEAT_LABELS.get(res.qualifyStep);
        res.hasContext =
            res.qualifyStep != null ||
            res.bounceType != null ||
            res.headcount != null ||
            res.page != null ||
            res.accountId != null ||
            res.quoteId != null ||
            res.qualifySessionId != null;
        res.placeRecitation = buildPlaceRecitation(res);
        res.summary = buildSummary(res);
        return res;
    }

    @TestVisible
    static String buildPlaceRecitation(Result res) {
        if (res == null || String.isBlank(res.quoteId)) {
            return null;
        }
        List<String> bits = new List<String>{
            'Ready to Place Get Pricing Quote ' + res.quoteId
        };
        if (res.planLabel != null) {
            bits.add('plan ' + res.planLabel);
        }
        if (res.headcount != null) {
            bits.add(res.headcount + ' seats');
        }
        if (res.startDate != null) {
            bits.add('start ' + res.startDate);
        }
        if (res.monthlyTotalText != null) {
            bits.add('term total ' + res.monthlyTotalText);
        }
        bits.add('Calling Place now — never ask the buyer to type yes in chat');
        return String.join(bits, '; ') + '.';
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
        if (res.planLabel != null) {
            parts.add(res.planLabel);
        }
        if (res.startDate != null) {
            parts.add('start ' + res.startDate);
        }
        if (res.monthlyTotalText != null) {
            parts.add('term total ' + res.monthlyTotalText);
        }
        if (res.page != null) {
            String pageLabel = PAGE_LABELS.get(res.page);
            parts.add(pageLabel == null ? 'on the ' + res.page + ' surface' : 'on ' + pageLabel);
        }
        if (res.quoteId != null) {
            parts.add('sticky Quote ' + res.quoteId);
        }
        if (res.quoteUrl != null) {
            parts.add('quote URL ' + res.quoteUrl);
        }
        if (res.accountId != null) {
            parts.add('Account Id ' + res.accountId);
        }
        if (res.qualifySessionId != null) {
            parts.add('qualify session ' + res.qualifySessionId);
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
    static void mergeSticky(
        Result res,
        String pageAccountId,
        String pageQuoteId,
        String pageQualifySessionId,
        Request req
    ) {
        String currentQuote = req == null ? null : req.currentQuoteId;
        String currentAccount = req == null ? null : req.currentAccountId;
        String currentSession = req == null ? null : req.currentQualifySessionId;
        String currentCommitted = req == null ? null : req.currentCommitted;
        res.accountId = RLM_BambooAgentBffClient.firstNonBlank(pageAccountId, currentAccount);
        res.quoteId = RLM_BambooAgentBffClient.firstNonBlank(pageQuoteId, currentQuote);
        res.qualifySessionId = RLM_BambooAgentBffClient.firstNonBlank(
            pageQualifySessionId,
            currentSession
        );
        if (String.isNotBlank(res.quoteId)) {
            res.qualifyCommitted = 'true';
            try {
                res.quoteUrl = RLM_BambooAgentBffClient.baseUrl() + '/quote/' + res.quoteId;
            } catch (Exception e) {
                res.quoteUrl = '/quote/' + res.quoteId;
            }
            fillQuoteSnapshot(res);
        } else {
            res.qualifyCommitted = blankToNull(currentCommitted);
            res.quoteUrl = null;
        }
    }

    @TestVisible
    static void preferQuoteAccount(Result res, String quoteAccountId) {
        if (res == null || String.isBlank(quoteAccountId)) {
            return;
        }
        res.accountId = quoteAccountId.trim();
    }

    @TestVisible
    static void fillQuoteSnapshot(Result res) {
        if (res == null || String.isBlank(res.quoteId) || Test.isRunningTest()) {
            return;
        }
        Id qid;
        try {
            qid = Id.valueOf(res.quoteId.trim());
        } catch (Exception e) {
            return;
        }
        if (qid.getSObjectType() != Quote.SObjectType) {
            return;
        }
        try {
            List<Quote> quotes = [
                SELECT StartDate, TotalPrice, QuoteAccountId
                FROM Quote
                WHERE Id = :qid
                WITH USER_MODE
                LIMIT 1
            ];
            if (quotes.isEmpty()) {
                return;
            }
            Quote q = quotes[0];
            preferQuoteAccount(res, q.QuoteAccountId);
            res.monthlyTotal = q.TotalPrice;
            if (res.monthlyTotal != null) {
                res.monthlyTotalText = String.valueOf(res.monthlyTotal);
            }
            if (q.StartDate != null) {
                res.startDate = String.valueOf(q.StartDate);
            }
        } catch (QueryException e) {
            // Agent user missing Quote FLS — still return page Quote Id for Place.
            return;
        }
        try {
            List<QuoteLineItem> lines = [
                SELECT Quantity, StartDate, EndDate, Product2.Name
                FROM QuoteLineItem
                WHERE QuoteId = :qid
                WITH USER_MODE
                ORDER BY CreatedDate ASC
                LIMIT 1
            ];
            if (lines.isEmpty()) {
                return;
            }
            QuoteLineItem line = lines[0];
            if (line.Product2 != null && String.isNotBlank(line.Product2.Name)) {
                res.planLabel = line.Product2.Name;
            }
            if (line.Quantity != null) {
                res.headcount = String.valueOf(line.Quantity.intValue());
            }
            if (res.startDate == null && line.StartDate != null) {
                res.startDate = String.valueOf(line.StartDate);
            }
        } catch (QueryException e) {
            // Line FLS missing — header snapshot is enough to Place.
        }
    }

    @TestVisible
    static String blankToNull(String value) {
        return String.isBlank(value) ? null : value.trim();
    }
}
