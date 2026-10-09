/**
 * Hosted MCP: start a renewal or cancellation Quote via initiateRenewal /
 * initiateCancellation. Then create an order and activate. Never PATCH Asset.
 */
global with sharing class RLM_MCP_RenewOrCancelAsset {
    private static final Integer MAX_CANDIDATES = 50;
    private static final String OUTPUT_QUOTE = 'Quote';

    global class ChangeInput {
        @InvocableVariable(
            required=true
            label='Action'
            description='renew or cancel. Confirm cancel with the user first.'
        )
        global String action;

        @InvocableVariable(label='Asset Id')
        global String assetId;

        @InvocableVariable(label='Account Name')
        global String accountName;

        @InvocableVariable(label='Product Name')
        global String productName;

        @InvocableVariable(
            label='Start Date'
            description='yyyy-mm-dd. Required for cancel. Required for early or expired renewals. Do not assume today.'
        )
        global String startDate;

        @InvocableVariable(
            label='Opportunity Name'
            description='Optional open Opportunity to hang the renew/cancel quote on.'
        )
        global String opportunityName;
    }

    global class ChangeOutput {
        @InvocableVariable(label='Is Success')
        global Boolean isSuccess;
        @InvocableVariable(label='Is Partial')
        global Boolean isPartial;
        @InvocableVariable(label='Message')
        global String message;
        @InvocableVariable(label='Asset Id')
        global String assetId;
        @InvocableVariable(label='Asset Url')
        global String assetUrl;
        @InvocableVariable(label='Quote Id')
        global String quoteId;
        @InvocableVariable(label='Quote Url')
        global String quoteUrl;
        @InvocableVariable(label='Needs Disambiguation')
        global Boolean needsDisambiguation;
        @InvocableVariable(label='Candidate Summaries Display')
        global String candidateSummariesDisplay;
        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    public class InvokeResult {
        public Boolean isSuccess;
        public String quoteId;
        public String errorMessage;
        public InvokeResult(Boolean isSuccess, String quoteId, String errorMessage) {
            this.isSuccess = isSuccess;
            this.quoteId = quoteId;
            this.errorMessage = errorMessage;
        }
    }

    public interface LifecycleInvoker {
        InvokeResult start(String actionName, Id assetId, Date startDay, Id opportunityId);
    }

    public class DefaultLifecycleInvoker implements LifecycleInvoker {
        public InvokeResult start(String actionName, Id assetId, Date startDay, Id opportunityId) {
            try {
                Boolean isRenew = actionName == 'renew';
                Invocable.Action action = Invocable.Action.createStandardAction(
                    isRenew ? 'initiateRenewal' : 'initiateCancellation'
                );
                if (isRenew) {
                    action.setInvocationParameter(
                        'renewAssetIds',
                        new List<String>{ String.valueOf(assetId) }
                    );
                    action.setInvocationParameter('renewOutputType', OUTPUT_QUOTE);
                    if (startDay != null) {
                        action.setInvocationParameter(
                            'renewStartDate',
                            String.valueOf(startDay) + 'T00:00:00'
                        );
                    }
                    if (opportunityId != null) {
                        action.setInvocationParameter(
                            'renewOpportunityId',
                            String.valueOf(opportunityId)
                        );
                    }
                } else {
                    action.setInvocationParameter(
                        'cancelAssetIds',
                        new List<String>{ String.valueOf(assetId) }
                    );
                    action.setInvocationParameter('cancelOutputType', OUTPUT_QUOTE);
                    action.setInvocationParameter(
                        'cancelStartDate',
                        String.valueOf(startDay) + 'T00:00:00'
                    );
                    if (opportunityId != null) {
                        action.setInvocationParameter(
                            'cancelOpportunityId',
                            String.valueOf(opportunityId)
                        );
                    }
                }
                action.setInvocationParameter('skipPricing', false);
                List<Invocable.Action.Result> results = action.invoke();
                if (results == null || results.isEmpty()) {
                    return new InvokeResult(false, null, actionName + ' returned no result.');
                }
                if (!results[0].isSuccess()) {
                    List<String> msgs = new List<String>();
                    for (Invocable.Action.Error err : results[0].getErrors()) {
                        msgs.add(err.getMessage());
                    }
                    return new InvokeResult(false, null, String.join(msgs, '; '));
                }
                Map<String, Object> outs = results[0].getOutputParameters();
                Id quoteId = firstId(outs == null ? null : outs.get(
                    isRenew ? 'renewRecordId' : 'cancelRecordId'
                ));
                if (quoteId == null && outs != null) {
                    quoteId = firstId(outs.get('record_id'));
                }
                return new InvokeResult(true, quoteId == null ? null : String.valueOf(quoteId), null);
            } catch (Exception e) {
                return new InvokeResult(false, null, e.getMessage());
            }
        }
    }

    @TestVisible
    static LifecycleInvoker invoker = new DefaultLifecycleInvoker();

    @InvocableMethod(
        label='Renew Or Cancel Revenue Cloud Asset'
        description='Starts a renewal or cancellation Quote. action=renew or cancel. Confirm cancel first. Then create order and activate. Never PATCH Asset.'
    )
    global static List<ChangeOutput> change(List<ChangeInput> inputs) {
        List<ChangeOutput> results = new List<ChangeOutput>();
        if (inputs == null || inputs.isEmpty()) {
            return results;
        }
        for (ChangeInput input : inputs) {
            results.add(changeOne(input));
        }
        return results;
    }

    private static ChangeOutput changeOne(ChangeInput input) {
        ChangeOutput out = new ChangeOutput();
        out.isSuccess = false;
        out.isPartial = false;
        out.needsDisambiguation = false;
        try {
            String actionName = normalizeAction(input == null ? null : input.action);
            if (actionName == null) {
                out.errorMessage = 'Action must be renew or cancel.';
                return out;
            }
            Asset asset = resolveAsset(input, out);
            if (asset == null) {
                return out;
            }
            out.assetId = asset.Id;
            out.assetUrl = RLM_MCP_RecordLinks.lightningUrl('Asset', asset.Id);
            Date startDay = parseDate(input.startDate);
            if (actionName == 'cancel' && startDay == null) {
                out.errorMessage = 'Cancel start date is required (yyyy-mm-dd). Ask the user; do not assume today.';
                return out;
            }
            if (String.isNotBlank(input.startDate) && startDay == null) {
                out.errorMessage = 'Start date must be yyyy-mm-dd.';
                return out;
            }
            Id opportunityId = resolveOpportunityId(asset.AccountId, input.opportunityName);
            InvokeResult created = invoker.start(actionName, asset.Id, startDay, opportunityId);
            if (created == null || created.isSuccess != true) {
                out.errorMessage = created != null && String.isNotBlank(created.errorMessage)
                    ? created.errorMessage
                    : 'Could not start the ' + actionName + '.';
                return out;
            }
            Id quoteId = RLM_MCP_RecordLinks.toId(created.quoteId);
            if (quoteId == null) {
                Quote polled = findLatestActionQuote(asset.AccountId, actionName);
                quoteId = polled == null ? null : polled.Id;
            }
            if (quoteId == null) {
                out.isPartial = true;
                out.errorMessage = 'Started the ' + actionName
                    + ' but the quote is not visible yet. Call again with the same asset.';
                return out;
            }
            Quote quote = [SELECT Id, Name FROM Quote WHERE Id = :quoteId LIMIT 1];
            out.isSuccess = true;
            out.quoteId = quote.Id;
            out.quoteUrl = RLM_MCP_RecordLinks.lightningUrl('Quote', quote.Id);
            String product = asset.Product2 == null || String.isBlank(asset.Product2.Name)
                ? asset.Name : asset.Product2.Name;
            List<String> lines = new List<String>{
                'Created ' + actionName + ' quote **' + quote.Name + '** for **' + product + '**.'
            };
            if (startDay != null) {
                lines.add('Start: ' + String.valueOf(startDay));
            }
            lines.add('Next: create an order from this quote, then activate it.');
            String qLink = RLM_MCP_RecordLinks.markdown('Open Quote', 'Quote', quote.Id);
            String aLink = RLM_MCP_RecordLinks.markdown('Open Asset', 'Asset', asset.Id);
            if (String.isNotBlank(qLink)) {
                lines.add(qLink);
            }
            if (String.isNotBlank(aLink)) {
                lines.add(aLink);
            }
            out.message = String.join(lines, '\n');
        } catch (Exception e) {
            out.isSuccess = false;
            out.errorMessage = e.getMessage() == null ? 'Lifecycle change failed.' : e.getMessage();
        }
        return out;
    }

    private static String normalizeAction(String raw) {
        if (String.isBlank(raw)) {
            return null;
        }
        String value = raw.trim().toLowerCase();
        if (value == 'renew' || value == 'renewal') {
            return 'renew';
        }
        if (value == 'cancel' || value == 'cancellation') {
            return 'cancel';
        }
        return null;
    }

    private static Asset resolveAsset(ChangeInput input, ChangeOutput out) {
        if (input != null && String.isNotBlank(input.assetId)) {
            Id aid = RLM_MCP_RecordLinks.toId(input.assetId);
            if (aid == null || aid.getSObjectType() != Asset.SObjectType) {
                out.errorMessage = 'Invalid Asset Id.';
                return null;
            }
            List<Asset> byId = [
                SELECT Id, Name, AccountId, Account.Name, Quantity, Status, Product2.Name
                FROM Asset
                WHERE Id = :aid
                LIMIT 1
            ];
            if (byId.isEmpty()) {
                out.errorMessage = 'No asset found for that Id.';
                return null;
            }
            return byId[0];
        }
        String accountTerm = input == null ? null : blankToNull(input.accountName);
        String productTerm = input == null ? null : blankToNull(input.productName);
        if (accountTerm == null && productTerm == null) {
            out.errorMessage = 'Provide an asset Id, or an account name and product name.';
            return null;
        }
        String ap = accountTerm == null ? null : '%' + accountTerm + '%';
        String pp = productTerm == null ? null : '%' + productTerm + '%';
        List<Asset> matches;
        if (ap != null && pp != null) {
            matches = [
                SELECT Id, Name, AccountId, Account.Name, Quantity, Status, Product2.Name
                FROM Asset
                WHERE Account.Name LIKE :ap
                AND (Name LIKE :pp OR Product2.Name LIKE :pp OR Product2.StockKeepingUnit LIKE :pp)
                ORDER BY LastModifiedDate DESC
                LIMIT :MAX_CANDIDATES
            ];
        } else if (ap != null) {
            matches = [
                SELECT Id, Name, AccountId, Account.Name, Quantity, Status, Product2.Name
                FROM Asset
                WHERE Account.Name LIKE :ap
                ORDER BY LastModifiedDate DESC
                LIMIT :MAX_CANDIDATES
            ];
        } else {
            matches = [
                SELECT Id, Name, AccountId, Account.Name, Quantity, Status, Product2.Name
                FROM Asset
                WHERE Name LIKE :pp OR Product2.Name LIKE :pp
                ORDER BY LastModifiedDate DESC
                LIMIT :MAX_CANDIDATES
            ];
        }
        if (matches.isEmpty()) {
            out.errorMessage = 'No asset found matching that account and product.';
            return null;
        }
        if (matches.size() == 1) {
            return matches[0];
        }
        out.needsDisambiguation = true;
        List<String> rows = new List<String>{ 'Multiple assets match. Which one?' };
        Integer n = 1;
        for (Asset asset : matches) {
            String name = asset.Product2 == null || String.isBlank(asset.Product2.Name)
                ? asset.Name : asset.Product2.Name;
            rows.add(String.valueOf(n) + '. ' + name
                + (asset.Account == null ? '' : ' (' + asset.Account.Name + ')'));
            n++;
        }
        out.candidateSummariesDisplay = String.join(rows, '\n');
        out.errorMessage = 'Multiple assets match. Ask the user which one.';
        return null;
    }

    private static Id resolveOpportunityId(Id accountId, String opportunityName) {
        if (accountId == null) {
            return null;
        }
        if (String.isNotBlank(opportunityName)) {
            return RLM_MCP_DealResolver.findNamedOpenOpportunity(accountId, opportunityName);
        }
        List<Opportunity> opps = [
            SELECT Id
            FROM Opportunity
            WHERE AccountId = :accountId AND IsClosed = false
            WITH USER_MODE
            ORDER BY LastModifiedDate DESC
            LIMIT 2
        ];
        return opps.size() == 1 ? opps[0].Id : null;
    }

    private static Quote findLatestActionQuote(Id accountId, String actionName) {
        if (accountId == null) {
            return null;
        }
        String typeName = actionName == 'renew' ? 'Renew' : 'Cancel';
        List<Quote> quotes = [
            SELECT Id, Name
            FROM Quote
            WHERE AccountId = :accountId AND OriginalActionType = :typeName
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        return quotes.isEmpty() ? null : quotes[0];
    }

    private static Id firstId(Object raw) {
        if (raw == null) {
            return null;
        }
        if (raw instanceof List<Object>) {
            List<Object> items = (List<Object>) raw;
            return items.isEmpty() ? null : firstId(items[0]);
        }
        return RLM_MCP_RecordLinks.toId(String.valueOf(raw));
    }

    private static Date parseDate(String raw) {
        if (String.isBlank(raw)) {
            return null;
        }
        String day = raw.trim();
        if (day.length() >= 10) {
            day = day.substring(0, 10);
        }
        try {
            return Date.valueOf(day);
        } catch (Exception e) {
            return parseUsDate(raw);
        }
    }

    private static Date parseUsDate(String raw) {
        try {
            List<String> parts = raw.trim().split('[/\\-]');
            if (parts.size() != 3) {
                return null;
            }
            Integer a = Integer.valueOf(parts[0]);
            Integer b = Integer.valueOf(parts[1]);
            Integer c = Integer.valueOf(parts[2]);
            if (parts[0].length() == 4) {
                return Date.newInstance(a, b, c);
            }
            Integer year = c < 100 ? 2000 + c : c;
            return Date.newInstance(year, a, b);
        } catch (Exception e) {
            return null;
        }
    }

    private static String blankToNull(String value) {
        return String.isBlank(value) ? null : value.trim();
    }
}
