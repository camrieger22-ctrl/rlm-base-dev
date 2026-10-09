/**
 * Hosted MCP: one read for where a deal sits — Draft, approval, order, assets.
 */
global with sharing class RLM_MCP_GetDealStatus {
    global class StatusInput {
        @InvocableVariable(label='Quote Id')
        global String quoteId;
        @InvocableVariable(label='Quote Name')
        global String quoteName;
        @InvocableVariable(label='Account Name')
        global String accountName;
    }

    global class StatusOutput {
        @InvocableVariable(label='Is Success')
        global Boolean isSuccess;
        @InvocableVariable(label='Stage')
        global String stage;
        @InvocableVariable(label='Quote Url')
        global String quoteUrl;
        @InvocableVariable(label='Summary Display')
        global String summaryDisplay;
        @InvocableVariable(label='Needs Disambiguation')
        global Boolean needsDisambiguation;
        @InvocableVariable(label='Candidate Summaries Display')
        global String candidateSummariesDisplay;
        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    @InvocableMethod(
        label='Get Revenue Cloud Deal Status'
        description='Read-only: Draft / approval / order / assets for a quote. Do not submit, order, or activate from this tool.'
    )
    global static List<StatusOutput> getStatus(List<StatusInput> inputs) {
        List<StatusOutput> results = new List<StatusOutput>();
        if (inputs == null || inputs.isEmpty()) {
            return results;
        }
        for (StatusInput input : inputs) {
            results.add(describeOne(input));
        }
        return results;
    }

    private static StatusOutput describeOne(StatusInput input) {
        StatusOutput out = new StatusOutput();
        out.isSuccess = false;
        out.needsDisambiguation = false;
        try {
            Quote quote = resolveQuote(input, out);
            if (quote == null) {
                return out;
            }
            out.quoteUrl = RLM_MCP_RecordLinks.lightningUrl('Quote', quote.Id);
            ApprovalSubmission submission = latestSubmission(quote.Id);
            List<Order> orders = [
                SELECT Id, OrderNumber, Status, TotalAmount, ActivatedDate
                FROM Order
                WHERE QuoteId = :quote.Id
                ORDER BY CreatedDate DESC
                LIMIT 10
            ];
            Set<Id> orderIds = new Map<Id, Order>(orders).keySet();
            List<Asset> assets = assetsForOrders(quote.AccountId, orderIds);

            String approval = submission == null ? 'None' : String.valueOf(submission.Status);
            String stage = stageOf(quote, submission, orders, assets);
            out.stage = stage;
            List<String> rows = new List<String>{
                'Deal status: ' + quote.Name
                    + (quote.Account == null ? '' : ' / ' + quote.Account.Name)
            };
            String qLink = RLM_MCP_RecordLinks.markdown('Open Quote', 'Quote', quote.Id);
            if (String.isNotBlank(qLink)) {
                rows.add(qLink);
            }
            if (quote.OpportunityId != null) {
                String oLink = RLM_MCP_RecordLinks.markdown(
                    'Open Opportunity', 'Opportunity', quote.OpportunityId
                );
                if (String.isNotBlank(oLink)) {
                    rows.add(oLink);
                }
            }
            rows.add('Stage: ' + stage);
            rows.add('Quote status: ' + nullToDash(quote.Status)
                + (String.isBlank(quote.OriginalActionType) ? '' : ' (' + quote.OriginalActionType + ')'));
            rows.add('Lines: ' + RLM_MCP_RecordLinks.formatNumber(quote.LineItemCount));
            rows.add('Quote total: ' + RLM_MCP_RecordLinks.money(quote.GrandTotal));
            rows.add('Approval: ' + approval);
            rows.add('');
            rows.add('Orders:');
            if (orders.isEmpty()) {
                rows.add('- None yet.');
            } else {
                for (Order ord : orders) {
                    String line = '- ' + ord.OrderNumber + ' — ' + nullToDash(ord.Status)
                        + ', ' + RLM_MCP_RecordLinks.money(ord.TotalAmount);
                    String link = RLM_MCP_RecordLinks.markdown('Open Order', 'Order', ord.Id);
                    if (String.isNotBlank(link)) {
                        line += ' · ' + link;
                    }
                    rows.add(line);
                }
            }
            rows.add('');
            rows.add('Assets from these orders:');
            if (assets.isEmpty()) {
                rows.add('- None yet. Activate the order to create assets.');
            } else {
                for (Asset asset : assets) {
                    String name = asset.Product2 == null || String.isBlank(asset.Product2.Name)
                        ? asset.Name : asset.Product2.Name;
                    String line = '- ' + name + ' — ' + nullToDash(asset.Status);
                    String link = RLM_MCP_RecordLinks.markdown('Open Asset', 'Asset', asset.Id);
                    if (String.isNotBlank(link)) {
                        line += ' · ' + link;
                    }
                    rows.add(line);
                }
            }
            out.isSuccess = true;
            out.summaryDisplay = String.join(rows, '\n');
        } catch (Exception e) {
            out.isSuccess = false;
            out.errorMessage = e.getMessage() == null ? 'Deal status failed.' : e.getMessage();
        }
        return out;
    }

    private static String stageOf(
        Quote quote,
        ApprovalSubmission submission,
        List<Order> orders,
        List<Asset> assets
    ) {
        if (!assets.isEmpty()) {
            return 'Activated (assets created)';
        }
        if (!orders.isEmpty()) {
            for (Order ord : orders) {
                if (ord.Status != null && ord.Status.toLowerCase().contains('activ')) {
                    return 'Order activated (assets pending)';
                }
            }
            return 'Order created, not activated';
        }
        if (submission != null && submission.Status != null) {
            String st = String.valueOf(submission.Status).toLowerCase();
            if (st.contains('approv')) {
                return 'Approved';
            }
            if (st.contains('reject') || st.contains('recall')) {
                return 'Approval ' + submission.Status;
            }
            return 'In approval (' + submission.Status + ')';
        }
        return 'Draft quote';
    }

    private static List<Asset> assetsForOrders(Id accountId, Set<Id> orderIds) {
        if (accountId == null || orderIds == null || orderIds.isEmpty()) {
            return new List<Asset>();
        }
        Set<Id> productIds = new Set<Id>();
        for (OrderItem item : [
            SELECT Product2Id
            FROM OrderItem
            WHERE OrderId IN :orderIds
            LIMIT 200
        ]) {
            if (item.Product2Id != null) {
                productIds.add(item.Product2Id);
            }
        }
        if (productIds.isEmpty()) {
            return new List<Asset>();
        }
        return [
            SELECT Id, Name, Status, Product2.Name
            FROM Asset
            WHERE AccountId = :accountId
            AND Product2Id IN :productIds
            ORDER BY CreatedDate DESC
            LIMIT 20
        ];
    }

    private static ApprovalSubmission latestSubmission(Id quoteId) {
        List<ApprovalSubmission> rows = [
            SELECT Id, Status
            FROM ApprovalSubmission
            WHERE RelatedRecordId = :quoteId
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    private static Quote resolveQuote(StatusInput input, StatusOutput out) {
        if (input != null && String.isNotBlank(input.quoteId)) {
            try {
                Id qid = Id.valueOf(input.quoteId.trim());
                List<Quote> byId = [
                    SELECT Id, Name, Status, LineItemCount, GrandTotal, OriginalActionType,
                           AccountId, Account.Name, OpportunityId, Opportunity.Name
                    FROM Quote
                    WHERE Id = :qid
                    LIMIT 1
                ];
                if (byId.isEmpty()) {
                    out.errorMessage = 'No quote found for that Id.';
                    return null;
                }
                return byId[0];
            } catch (Exception e) {
                out.errorMessage = 'Invalid quote Id.';
                return null;
            }
        }
        String nameTerm = input == null ? null : blankToNull(input.quoteName);
        String acctTerm = input == null ? null : blankToNull(input.accountName);
        if (nameTerm == null && acctTerm == null) {
            out.errorMessage = 'Provide quoteId, or quoteName and/or accountName.';
            return null;
        }
        String np = nameTerm == null ? null : '%' + nameTerm + '%';
        String ap = acctTerm == null ? null : '%' + acctTerm + '%';
        List<Quote> matches;
        if (np != null && ap != null) {
            matches = [
                SELECT Id, Name, Status, LineItemCount, GrandTotal, OriginalActionType,
                       AccountId, Account.Name, OpportunityId, Opportunity.Name
                FROM Quote
                WHERE Name LIKE :np AND Account.Name LIKE :ap
                ORDER BY LastModifiedDate DESC
                LIMIT 10
            ];
        } else if (np != null) {
            matches = [
                SELECT Id, Name, Status, LineItemCount, GrandTotal, OriginalActionType,
                       AccountId, Account.Name, OpportunityId, Opportunity.Name
                FROM Quote
                WHERE Name LIKE :np
                ORDER BY LastModifiedDate DESC
                LIMIT 10
            ];
        } else {
            matches = [
                SELECT Id, Name, Status, LineItemCount, GrandTotal, OriginalActionType,
                       AccountId, Account.Name, OpportunityId, Opportunity.Name
                FROM Quote
                WHERE Account.Name LIKE :ap
                ORDER BY LastModifiedDate DESC
                LIMIT 10
            ];
        }
        if (matches.isEmpty()) {
            out.errorMessage = 'No quote matched.';
            return null;
        }
        if (matches.size() == 1) {
            return matches[0];
        }
        out.needsDisambiguation = true;
        List<String> rows = new List<String>{ 'Multiple quotes match. Which deal?' };
        Integer n = 1;
        for (Quote q : matches) {
            String acct = q.Account == null ? '' : q.Account.Name;
            rows.add(String.valueOf(n) + '. ' + q.Name + ' — ' + acct + ' (' + nullToDash(q.Status) + ')');
            n++;
        }
        out.candidateSummariesDisplay = String.join(rows, '\n');
        out.errorMessage = 'Multiple quotes match. Ask the user which one.';
        return null;
    }

    private static String blankToNull(String value) {
        return String.isBlank(value) ? null : value.trim();
    }

    private static String nullToDash(String value) {
        return String.isBlank(value) ? '—' : value;
    }
}
