/**
 * Hosted MCP: Start Sync / Stop Sync a named quote onto its Opportunity.
 * Writes Opportunity.SyncedQuoteId (same field as the Lightning buttons).
 * Does not insert OpportunityLineItem rows; the platform copies flattened lines.
 */
global with sharing class RLM_MCP_SyncQuoteToOpportunity {
    private static final Integer MAX_CANDIDATES = 50;
    private static final String FLATTEN_NOTE =
        'Opportunities do not store bundles or attributes. Salesforce copies '
        + 'each quote product as its own Opportunity product. Attributes and '
        + 'term-defined fields do not copy.';

    global class SyncInput {
        @InvocableVariable(
            label='Quote Id'
            description='Optional 18-character Quote Id (starts with 0Q0). Takes precedence over names.'
        )
        global String quoteId;

        @InvocableVariable(
            label='Quote Name'
            description='Quote name or fragment. Also matched against the account name.'
        )
        global String quoteName;

        @InvocableVariable(
            label='Account Name'
            description='Optional account name to narrow the search.'
        )
        global String accountName;

        @InvocableVariable(
            label='Opportunity Name'
            description='Optional Opportunity name when the account has several deals.'
        )
        global String opportunityName;

        @InvocableVariable(
            label='Action'
            description='sync (default, Start Sync) or unsync (Stop Sync). Call only when they named a quote to sync or unsync. Never after create.'
        )
        global String action;
    }

    global class SyncOutput {
        @InvocableVariable(label='Is Success')
        global Boolean isSuccess;
        @InvocableVariable(label='Action')
        global String action;
        @InvocableVariable(label='Is Syncing')
        global Boolean isSyncing;
        @InvocableVariable(label='Quote Id')
        global String quoteId;
        @InvocableVariable(label='Quote Name')
        global String quoteName;
        @InvocableVariable(
            label='Quote Url'
            description='Lightning Quote page. Render as [Open Quote](quoteUrl).'
        )
        global String quoteUrl;
        @InvocableVariable(label='Opportunity Id')
        global String opportunityId;
        @InvocableVariable(label='Opportunity Name')
        global String opportunityName;
        @InvocableVariable(
            label='Opportunity Url'
            description='Lightning Opportunity page. Render as [Open Opportunity](opportunityUrl).'
        )
        global String opportunityUrl;
        @InvocableVariable(label='Opportunity Product Count')
        global Decimal opportunityProductCount;
        @InvocableVariable(label='Previous Synced Quote Name')
        global String previousSyncedQuoteName;
        @InvocableVariable(label='Results Display')
        global String resultsDisplay;
        @InvocableVariable(label='Needs Disambiguation')
        global Boolean needsDisambiguation;
        @InvocableVariable(label='Candidate Summaries Display')
        global String candidateSummariesDisplay;
        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    @InvocableMethod(
        label='Sync Revenue Cloud Quote To Opportunity'
        description='Start or stop quote-to-opportunity sync. action=sync or unsync. Same as Lightning Start Sync / Stop Sync. Never insert OpportunityLineItem. Never auto-run after create.'
    )
    global static List<SyncOutput> syncQuote(List<SyncInput> inputs) {
        List<SyncOutput> results = new List<SyncOutput>();
        if (inputs == null || inputs.isEmpty()) {
            return results;
        }
        for (SyncInput input : inputs) {
            results.add(syncOne(input));
        }
        return results;
    }

    private static SyncOutput syncOne(SyncInput input) {
        SyncOutput out = new SyncOutput();
        out.isSuccess = false;
        out.needsDisambiguation = false;
        try {
            if (input == null) {
                out.errorMessage = 'Provide a quote name, account name, or Quote Id.';
                return out;
            }
            String action = normalizeAction(input.action);
            if (action == null) {
                out.errorMessage = 'action must be sync or unsync.';
                return out;
            }
            out.action = action;
            Quote quote = resolveQuote(input, out);
            if (quote == null) {
                return out;
            }
            out.quoteId = quote.Id;
            out.quoteName = quote.Name;
            out.quoteUrl = RLM_MCP_RecordLinks.lightningUrl('Quote', quote.Id);
            if (quote.OpportunityId == null) {
                out.errorMessage = 'Quote **' + quote.Name
                    + '** has no Opportunity. Create or clone first, then sync.';
                return out;
            }
            Opportunity opportunity = [
                SELECT Id, Name, SyncedQuoteId, SyncedQuote.Name
                FROM Opportunity
                WHERE Id = :quote.OpportunityId
                WITH USER_MODE
                LIMIT 1
            ];
            out.opportunityId = opportunity.Id;
            out.opportunityName = opportunity.Name;
            out.opportunityUrl = RLM_MCP_RecordLinks.lightningUrl(
                'Opportunity', opportunity.Id);
            if (opportunity.SyncedQuoteId != null
                && opportunity.SyncedQuoteId != quote.Id
                && opportunity.SyncedQuote != null) {
                out.previousSyncedQuoteName = opportunity.SyncedQuote.Name;
            }
            if (action == 'sync') {
                applySync(quote, opportunity, out);
            } else {
                applyUnsync(quote, opportunity, out);
            }
        } catch (Exception e) {
            out.isSuccess = false;
            out.errorMessage = e.getMessage();
        }
        return out;
    }

    private static void applySync(Quote quote, Opportunity opportunity, SyncOutput out) {
        if (opportunity.SyncedQuoteId == quote.Id) {
            finishRecap(quote, opportunity, out, true, 'already syncing');
            return;
        }
        Opportunity patch = new Opportunity(
            Id = opportunity.Id,
            SyncedQuoteId = quote.Id
        );
        Database.update(patch, AccessLevel.USER_MODE);
        finishRecap(quote, opportunity, out, true, opportunity.SyncedQuoteId == null
            ? 'started'
            : 'switched');
    }

    private static void applyUnsync(Quote quote, Opportunity opportunity, SyncOutput out) {
        if (opportunity.SyncedQuoteId == null) {
            finishRecap(quote, opportunity, out, false, 'already stopped');
            return;
        }
        if (opportunity.SyncedQuoteId != quote.Id) {
            out.errorMessage = 'Opportunity **' + opportunity.Name
                + '** is syncing **'
                + (String.isBlank(out.previousSyncedQuoteName)
                    ? String.valueOf(opportunity.SyncedQuoteId)
                    : out.previousSyncedQuoteName)
                + '**, not **' + quote.Name
                + '**. Name that quote to unsync, or sync this one instead.';
            return;
        }
        Opportunity patch = new Opportunity(
            Id = opportunity.Id,
            SyncedQuoteId = null
        );
        Database.update(patch, AccessLevel.USER_MODE);
        finishRecap(quote, opportunity, out, false, 'stopped');
    }

    private static void finishRecap(
        Quote quote,
        Opportunity opportunity,
        SyncOutput out,
        Boolean expectSyncing,
        String mode
    ) {
        Quote freshQuote = [
            SELECT Id, Name, IsSyncing
            FROM Quote
            WHERE Id = :quote.Id
            WITH USER_MODE
            LIMIT 1
        ];
        Opportunity freshOpp = [
            SELECT Id, Name, SyncedQuoteId
            FROM Opportunity
            WHERE Id = :opportunity.Id
            WITH USER_MODE
            LIMIT 1
        ];
        Integer oliCount = [
            SELECT COUNT()
            FROM OpportunityLineItem
            WHERE OpportunityId = :opportunity.Id
        ];
        out.isSyncing = freshQuote.IsSyncing == true;
        out.opportunityProductCount = oliCount;
        out.isSuccess = true;
        List<String> rows = new List<String>();
        if (mode == 'already syncing') {
            rows.add('**' + freshQuote.Name + '** is already syncing to **'
                + freshOpp.Name + '**.');
        } else if (mode == 'already stopped') {
            rows.add('**' + freshQuote.Name + '** is not syncing to **'
                + freshOpp.Name + '**.');
        } else if (mode == 'switched') {
            rows.add('Now syncing **' + freshQuote.Name + '** to **'
                + freshOpp.Name + '**.');
            if (String.isNotBlank(out.previousSyncedQuoteName)) {
                rows.add('Replaced **' + out.previousSyncedQuoteName + '**.');
            }
        } else if (mode == 'started') {
            rows.add('Started sync of **' + freshQuote.Name + '** to **'
                + freshOpp.Name + '**.');
        } else {
            rows.add('Stopped sync of **' + freshQuote.Name + '** on **'
                + freshOpp.Name + '**.');
        }
        rows.add('Quote IsSyncing: ' + String.valueOf(out.isSyncing) + '.');
        rows.add('Opportunity products: ' + String.valueOf(oliCount) + '.');
        if (expectSyncing) {
            rows.add(FLATTEN_NOTE);
        }
        String quoteLink = RLM_MCP_RecordLinks.markdown('Open Quote', 'Quote', quote.Id);
        String oppLink = RLM_MCP_RecordLinks.markdown(
            'Open Opportunity', 'Opportunity', opportunity.Id);
        if (String.isNotBlank(quoteLink)) {
            rows.add(quoteLink);
        }
        if (String.isNotBlank(oppLink)) {
            rows.add(oppLink);
        }
        out.resultsDisplay = String.join(rows, '\n');
    }

    private static String normalizeAction(String raw) {
        if (String.isBlank(raw) || raw.trim().equalsIgnoreCase('sync')
            || raw.trim().equalsIgnoreCase('start')) {
            return 'sync';
        }
        if (raw.trim().equalsIgnoreCase('unsync')
            || raw.trim().equalsIgnoreCase('stop')) {
            return 'unsync';
        }
        return null;
    }

    private static Quote resolveQuote(SyncInput input, SyncOutput out) {
        if (String.isNotBlank(input.quoteId)) {
            Id qid = toQuoteId(input.quoteId);
            if (qid == null) {
                out.errorMessage = 'Invalid Quote Id: ' + input.quoteId;
                return null;
            }
            List<Quote> byId = [
                SELECT Id, Name, Status, LineItemCount, OpportunityId,
                    Opportunity.Name, IsSyncing
                FROM Quote
                WHERE Id = :qid
                WITH USER_MODE
                LIMIT 1
            ];
            if (byId.isEmpty()) {
                out.errorMessage = 'No quote found for Id ' + qid + '.';
                return null;
            }
            return byId[0];
        }
        String nameTerm = String.isBlank(input.quoteName) ? null : input.quoteName.trim();
        String acctTerm = String.isBlank(input.accountName) ? null : input.accountName.trim();
        String oppTerm = String.isBlank(input.opportunityName)
            ? null : input.opportunityName.trim();
        if (nameTerm == null && acctTerm == null && oppTerm == null) {
            out.errorMessage = 'Provide a quote name, account name, opportunity name, or Quote Id.';
            return null;
        }
        List<Quote> matches = findQuotes(nameTerm, acctTerm, oppTerm);
        if (matches.isEmpty()) {
            out.errorMessage = 'No quote found matching "'
                + firstTerm(nameTerm, acctTerm, oppTerm) + '".';
            return null;
        }
        if (nameTerm != null) {
            List<Quote> exact = new List<Quote>();
            for (Quote match : matches) {
                if (match.Name != null && match.Name.equalsIgnoreCase(nameTerm)) {
                    exact.add(match);
                }
            }
            if (exact.size() == 1) {
                return exact[0];
            }
            if (!exact.isEmpty()) {
                matches = exact;
            }
        }
        if (matches.size() == 1) {
            return matches[0];
        }
        out.needsDisambiguation = true;
        out.candidateSummariesDisplay = buildCandidateDisplay(matches);
        out.errorMessage = 'Multiple quotes match. Ask the user which one to sync.';
        return null;
    }

    private static List<Quote> findQuotes(String nameTerm, String acctTerm, String oppTerm) {
        String np = nameTerm == null ? null : '%' + nameTerm + '%';
        String ap = acctTerm == null ? null : '%' + acctTerm + '%';
        String op = oppTerm == null ? null : '%' + oppTerm + '%';
        if (np != null && ap != null && op != null) {
            return [
                SELECT Id, Name, Status, LineItemCount, OpportunityId,
                    Opportunity.Name, IsSyncing
                FROM Quote
                WHERE (Name LIKE :np OR Account.Name LIKE :np)
                AND Account.Name LIKE :ap
                AND Opportunity.Name LIKE :op
                WITH USER_MODE
                ORDER BY LastModifiedDate DESC
                LIMIT :MAX_CANDIDATES
            ];
        }
        if (np != null && ap != null) {
            return [
                SELECT Id, Name, Status, LineItemCount, OpportunityId,
                    Opportunity.Name, IsSyncing
                FROM Quote
                WHERE (Name LIKE :np OR Account.Name LIKE :np)
                AND Account.Name LIKE :ap
                WITH USER_MODE
                ORDER BY LastModifiedDate DESC
                LIMIT :MAX_CANDIDATES
            ];
        }
        if (np != null && op != null) {
            return [
                SELECT Id, Name, Status, LineItemCount, OpportunityId,
                    Opportunity.Name, IsSyncing
                FROM Quote
                WHERE (Name LIKE :np OR Account.Name LIKE :np)
                AND Opportunity.Name LIKE :op
                WITH USER_MODE
                ORDER BY LastModifiedDate DESC
                LIMIT :MAX_CANDIDATES
            ];
        }
        if (ap != null && op != null) {
            return [
                SELECT Id, Name, Status, LineItemCount, OpportunityId,
                    Opportunity.Name, IsSyncing
                FROM Quote
                WHERE Account.Name LIKE :ap
                AND Opportunity.Name LIKE :op
                WITH USER_MODE
                ORDER BY LastModifiedDate DESC
                LIMIT :MAX_CANDIDATES
            ];
        }
        if (np != null) {
            return [
                SELECT Id, Name, Status, LineItemCount, OpportunityId,
                    Opportunity.Name, IsSyncing
                FROM Quote
                WHERE Name LIKE :np OR Account.Name LIKE :np
                WITH USER_MODE
                ORDER BY LastModifiedDate DESC
                LIMIT :MAX_CANDIDATES
            ];
        }
        if (ap != null) {
            return [
                SELECT Id, Name, Status, LineItemCount, OpportunityId,
                    Opportunity.Name, IsSyncing
                FROM Quote
                WHERE Account.Name LIKE :ap
                WITH USER_MODE
                ORDER BY LastModifiedDate DESC
                LIMIT :MAX_CANDIDATES
            ];
        }
        return [
            SELECT Id, Name, Status, LineItemCount, OpportunityId,
                Opportunity.Name, IsSyncing
            FROM Quote
            WHERE Opportunity.Name LIKE :op
            WITH USER_MODE
            ORDER BY LastModifiedDate DESC
            LIMIT :MAX_CANDIDATES
        ];
    }

    private static String buildCandidateDisplay(List<Quote> quotes) {
        List<String> lines = new List<String>{
            'Multiple quotes match. Which one should I sync to its opportunity?'
        };
        Integer ordinal = 1;
        for (Quote quote : quotes) {
            String line = String.valueOf(ordinal) + '. **' + quote.Name + '**';
            if (quote.Opportunity != null && String.isNotBlank(quote.Opportunity.Name)) {
                line += ' on ' + quote.Opportunity.Name;
            }
            if (quote.IsSyncing == true) {
                line += ' (already syncing)';
            }
            String quoteLink = RLM_MCP_RecordLinks.markdown('Open', 'Quote', quote.Id);
            if (String.isNotBlank(quoteLink)) {
                line += ' · ' + quoteLink;
            }
            lines.add(line);
            ordinal++;
        }
        return String.join(lines, '\n');
    }

    private static String firstTerm(String a, String b, String c) {
        if (a != null) {
            return a;
        }
        if (b != null) {
            return b;
        }
        return c;
    }

    private static Id toQuoteId(String raw) {
        try {
            Id parsed = Id.valueOf(raw.trim());
            return parsed.getSObjectType() == Quote.SObjectType ? parsed : null;
        } catch (Exception e) {
            return null;
        }
    }
}
