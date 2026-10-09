/**
 * Shared account / Opportunity / Draft resolver for Hosted MCP quoting.
 * Not an MCP tool. Callers decide whether to insert when opportunity is null.
 */
public with sharing class RLM_MCP_DealResolver {
    public class Result {
        public Account account;
        public Opportunity opportunity;
        public Quote draft;
        public List<Opportunity> openOpportunities;
        public List<Quote> drafts;
        public Boolean needsDisambiguation;
        public String errorMessage;
        public String candidateSummariesDisplay;

        public Result() {
            this.openOpportunities = new List<Opportunity>();
            this.drafts = new List<Quote>();
            this.needsDisambiguation = false;
        }
    }

    public static Result resolveAccount(String accountName) {
        Result out = new Result();
        if (String.isBlank(accountName)) {
            out.errorMessage = 'Account name is required.';
            return out;
        }
        String term = accountName.trim();
        List<Account> exact = [
            SELECT Id, Name
            FROM Account
            WHERE Name = :term
            WITH USER_MODE
            LIMIT 10
        ];
        if (exact.size() == 1) {
            out.account = exact[0];
            return out;
        }
        if (exact.size() > 1) {
            out.needsDisambiguation = true;
            out.candidateSummariesDisplay = accountChoices(term, exact);
            out.errorMessage = 'Multiple accounts match "' + term + '". Ask the user which one.';
            return out;
        }
        String likeName = '%' + term + '%';
        List<Account> fuzzy = [
            SELECT Id, Name
            FROM Account
            WHERE Name LIKE :likeName
            WITH USER_MODE
            ORDER BY Name
            LIMIT 10
        ];
        if (fuzzy.isEmpty()) {
            out.errorMessage = 'No account matched "' + term + '".';
            return out;
        }
        if (fuzzy.size() > 1) {
            out.needsDisambiguation = true;
            out.candidateSummariesDisplay = accountChoices(term, fuzzy);
            out.errorMessage = 'Multiple accounts match "' + term + '". Ask the user which one.';
            return out;
        }
        out.account = fuzzy[0];
        return out;
    }

    /**
     * Resolve account, optional named open Opportunity, and a reusable Draft.
     * Does not insert Opportunity or Quote.
     */
    public static Result resolve(
        String accountName,
        String opportunityName,
        String quoteName
    ) {
        Result out = resolveAccount(accountName);
        if (out.account == null) {
            return out;
        }
        out.openOpportunities = [
            SELECT Id, Name, LastModifiedDate
            FROM Opportunity
            WHERE AccountId = :out.account.Id
            AND IsClosed = false
            WITH USER_MODE
            ORDER BY LastModifiedDate DESC
            LIMIT 20
        ];
        if (String.isNotBlank(opportunityName)) {
            String wanted = opportunityName.trim();
            for (Opportunity opp : out.openOpportunities) {
                if (opp.Name == wanted) {
                    out.opportunity = opp;
                    break;
                }
            }
        } else if (out.openOpportunities.size() > 1) {
            out.needsDisambiguation = true;
            out.candidateSummariesDisplay = opportunityChoices(out.account.Name, out.openOpportunities);
            out.errorMessage =
                'This account has several open Opportunities. Pass opportunityName. Do not guess.';
            return out;
        } else if (out.openOpportunities.size() == 1) {
            out.opportunity = out.openOpportunities[0];
        }
        if (out.opportunity == null) {
            return out;
        }
        out.drafts = [
            SELECT Id, Name, QuoteNumber, Status, LineItemCount, LastModifiedDate,
                   OpportunityId, Opportunity.Name, ContactId
            FROM Quote
            WHERE OpportunityId = :out.opportunity.Id
            AND Status = 'Draft'
            WITH USER_MODE
            ORDER BY LastModifiedDate DESC
            LIMIT 15
        ];
        out.draft = pickReusableDraft(out.drafts, quoteName);
        return out;
    }

    public static Quote pickReusableDraft(List<Quote> drafts, String quoteName) {
        if (drafts == null || drafts.isEmpty()) {
            return null;
        }
        if (String.isNotBlank(quoteName)) {
            String wanted = quoteName.trim();
            for (Quote quote : drafts) {
                if (quote.Name == wanted) {
                    return quote;
                }
            }
            return null;
        }
        return drafts.size() == 1 ? drafts[0] : null;
    }

    public static List<Quote> listDrafts(Id accountId, Id opportunityId) {
        if (accountId == null) {
            return new List<Quote>();
        }
        if (opportunityId != null) {
            return [
                SELECT Id, Name, QuoteNumber, Status, LineItemCount, LastModifiedDate,
                       OpportunityId, Opportunity.Name
                FROM Quote
                WHERE AccountId = :accountId
                AND OpportunityId = :opportunityId
                AND Status = 'Draft'
                WITH USER_MODE
                ORDER BY LastModifiedDate DESC
                LIMIT 15
            ];
        }
        return [
            SELECT Id, Name, QuoteNumber, Status, LineItemCount, LastModifiedDate,
                   OpportunityId, Opportunity.Name
            FROM Quote
            WHERE AccountId = :accountId
            AND Status = 'Draft'
            WITH USER_MODE
            ORDER BY LastModifiedDate DESC
            LIMIT 15
        ];
    }

    public static Id findNamedOpenOpportunity(Id accountId, String opportunityName) {
        if (accountId == null || String.isBlank(opportunityName)) {
            return null;
        }
        String wanted = opportunityName.trim();
        List<Opportunity> named = [
            SELECT Id
            FROM Opportunity
            WHERE AccountId = :accountId
            AND Name = :wanted
            AND IsClosed = false
            WITH USER_MODE
            ORDER BY LastModifiedDate DESC
            LIMIT 1
        ];
        return named.isEmpty() ? null : named[0].Id;
    }

    public static Contact findContact(Id accountId, String email) {
        if (accountId == null) {
            return null;
        }
        if (String.isNotBlank(email)) {
            String wanted = email.trim();
            List<Contact> byEmail = [
                SELECT Id, Email, AccountId
                FROM Contact
                WHERE AccountId = :accountId
                AND Email = :wanted
                WITH USER_MODE
                LIMIT 1
            ];
            if (!byEmail.isEmpty()) {
                return byEmail[0];
            }
        }
        List<Contact> oldest = [
            SELECT Id, Email, AccountId
            FROM Contact
            WHERE AccountId = :accountId
            WITH USER_MODE
            ORDER BY CreatedDate ASC
            LIMIT 1
        ];
        return oldest.isEmpty() ? null : oldest[0];
    }

    private static String accountChoices(String term, List<Account> accounts) {
        List<String> rows = new List<String>{
            'Multiple accounts match "' + term + '". Which one?'
        };
        Integer n = 1;
        for (Account account : accounts) {
            rows.add(String.valueOf(n) + '. ' + account.Name);
            n++;
        }
        return String.join(rows, '\n');
    }

    private static String opportunityChoices(String accountName, List<Opportunity> opps) {
        List<String> rows = new List<String>{
            'Open Opportunities on ' + accountName + '. Which deal?'
        };
        Integer n = 1;
        for (Opportunity opp : opps) {
            rows.add(String.valueOf(n) + '. ' + opp.Name);
            n++;
        }
        return String.join(rows, '\n');
    }
}
