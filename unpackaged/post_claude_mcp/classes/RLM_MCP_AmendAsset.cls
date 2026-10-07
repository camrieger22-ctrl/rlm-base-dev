/**
 * Hosted MCP: start an asset amendment via initiateAmendment (quote output).
 * Closing the amendment still uses Create Order From Quote + Activate Order.
 */
global with sharing class RLM_MCP_AmendAsset {
    private static final Integer MAX_CANDIDATES = 50;
    private static final String OUTPUT_QUOTE = 'Quote';

    global class AmendInput {
        @InvocableVariable(
            label='Asset Id'
            description='Optional 18-character Asset Id (starts with 02i). Takes precedence over names.'
        )
        global String assetId;

        @InvocableVariable(
            label='Account Name'
            description='Account that owns the asset, e.g. Acme.'
        )
        global String accountName;

        @InvocableVariable(
            label='Product Name'
            description='Asset product name or SKU fragment, e.g. QuantumBit Database or QB-DB.'
        )
        global String productName;

        @InvocableVariable(
            required=true
            label='Quantity Change'
            description='Delta to add (positive) or reduce (negative). 5 adds five; -2 removes two. Not the new total.'
        )
        global Decimal quantityChange;

        @InvocableVariable(
            required=true
            label='Start Date'
            description='Required amendment start date yyyy-mm-dd. Ask the user. Do not assume today.'
        )
        global String startDate;
    }

    global class AmendOutput {
        @InvocableVariable(label='Is Success')
        global Boolean isSuccess;
        @InvocableVariable(
            label='Is Partial'
            description='True when the amendment quote is not visible yet. Call this tool again with the same asset.'
        )
        global Boolean isPartial;
        @InvocableVariable(label='Message')
        global String message;
        @InvocableVariable(label='Asset Id')
        global String assetId;
        @InvocableVariable(
            label='Asset Url'
            description='Lightning Asset page. Render as [Open Asset](assetUrl) in the chat reply.'
        )
        global String assetUrl;
        @InvocableVariable(label='Asset Name')
        global String assetName;
        @InvocableVariable(label='Quote Id')
        global String quoteId;
        @InvocableVariable(label='Quote Name')
        global String quoteName;
        @InvocableVariable(
            label='Quote Url'
            description='Lightning amendment Quote page. Render as [Open Quote](quoteUrl) in the chat reply.'
        )
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

    public interface AmendmentInvoker {
        InvokeResult start(Id assetId, Date startDay, Decimal quantityChange, Id opportunityId);
    }

    public class DefaultAmendmentInvoker implements AmendmentInvoker {
        public InvokeResult start(
            Id assetId,
            Date startDay,
            Decimal quantityChange,
            Id opportunityId
        ) {
            try {
                Invocable.Action action =
                    Invocable.Action.createStandardAction('initiateAmendment');
                action.setInvocationParameter(
                    'amendAssetIds',
                    new List<String>{ String.valueOf(assetId) }
                );
                // Apex Datetime stringifies as "yyyy-MM-dd HH:mm:ss" (space). The
                // action parser only accepts yyyy-MM-dd'T'HH:mm:ss.
                action.setInvocationParameter(
                    'amendStartDate',
                    String.valueOf(startDay) + 'T00:00:00'
                );
                action.setInvocationParameter('quantityChange', quantityChange);
                action.setInvocationParameter('amendOutputType', OUTPUT_QUOTE);
                action.setInvocationParameter('skipPricing', false);
                if (opportunityId != null) {
                    action.setInvocationParameter(
                        'amendOpportunityId',
                        String.valueOf(opportunityId)
                    );
                }
                List<Invocable.Action.Result> results = action.invoke();
                if (results == null || results.isEmpty()) {
                    return new InvokeResult(false, null, 'initiateAmendment returned no result.');
                }
                if (!results[0].isSuccess()) {
                    List<String> msgs = new List<String>();
                    for (Invocable.Action.Error err : results[0].getErrors()) {
                        msgs.add(err.getMessage());
                    }
                    return new InvokeResult(false, null, String.join(msgs, '; '));
                }
                Map<String, Object> outs = results[0].getOutputParameters();
                Id quoteId = firstId(outs == null ? null : outs.get('amendRecordId'));
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
    static AmendmentInvoker invoker = new DefaultAmendmentInvoker();

    @InvocableMethod(
        label='Amend Revenue Cloud Asset'
        description='Starts an asset amendment by creating an amendment Quote via initiateAmendment. quantityChange is a delta. Then create an order from that quote and activate it. Never update Asset rows yourself.'
    )
    global static List<AmendOutput> amend(List<AmendInput> inputs) {
        List<AmendOutput> results = new List<AmendOutput>();
        if (inputs == null || inputs.isEmpty()) {
            return results;
        }
        for (AmendInput input : inputs) {
            results.add(amendOne(input));
        }
        return results;
    }

    private static AmendOutput amendOne(AmendInput input) {
        AmendOutput out = new AmendOutput();
        out.isSuccess = false;
        out.isPartial = false;
        out.needsDisambiguation = false;
        try {
            if (input == null || input.quantityChange == null) {
                out.errorMessage = 'Quantity change is required (positive to add, negative to reduce).';
                return out;
            }
            Asset asset = resolveAsset(input, out);
            if (asset == null) {
                return out;
            }
            stampAsset(out, asset);
            if (String.isBlank(input.startDate)) {
                out.errorMessage =
                    'Amendment start date is required (yyyy-mm-dd). Ask the user; do not assume today.';
                return out;
            }
            Date startDay = parseDate(input.startDate);
            if (startDay == null) {
                out.errorMessage = 'Start date must be yyyy-mm-dd.';
                return out;
            }
            Asset root = rootOf(asset);
            Boolean isComponent = root != null && root.Id != asset.Id;
            Decimal initiateQty = isComponent ? 0 : input.quantityChange;
            Id opportunityId = findOpenOpportunity(asset.AccountId);
            InvokeResult created = invoker.start(
                root.Id,
                startDay,
                initiateQty,
                opportunityId
            );
            if (created == null || created.isSuccess != true) {
                out.errorMessage = created != null && String.isNotBlank(created.errorMessage)
                    ? created.errorMessage
                    : 'Could not start the amendment.';
                return out;
            }
            Id quoteId = RLM_MCP_RecordLinks.toId(created.quoteId);
            if (quoteId == null) {
                Quote polled = findLatestAmendQuote(asset.AccountId);
                quoteId = polled == null ? null : polled.Id;
            }
            if (quoteId == null) {
                out.isPartial = true;
                out.errorMessage = 'Amendment started but the quote is not visible yet. Call amend again with the same asset.';
                return out;
            }
            Quote quote = [
                SELECT Id, Name
                FROM Quote
                WHERE Id = :quoteId
                WITH USER_MODE
                LIMIT 1
            ];
            if (isComponent) {
                String patchError = applyComponentDelta(quote.Id, asset, input.quantityChange);
                if (String.isNotBlank(patchError)) {
                    out.errorMessage = patchError;
                    return out;
                }
            }
            out.isSuccess = true;
            out.quoteId = quote.Id;
            out.quoteName = quote.Name;
            out.quoteUrl = RLM_MCP_RecordLinks.lightningUrl('Quote', quote.Id);
            String delta = input.quantityChange > 0
                ? '+' + String.valueOf(input.quantityChange)
                : String.valueOf(input.quantityChange);
            String product = asset.Product2 == null || String.isBlank(asset.Product2.Name)
                ? asset.Name
                : asset.Product2.Name;
            String parentName = root.Product2 == null || String.isBlank(root.Product2.Name)
                ? root.Name
                : root.Product2.Name;
            List<String> lines = new List<String>();
            if (isComponent) {
                lines.add(
                    'Created amendment quote **' + quote.Name + '** from parent **'
                        + parentName + '** and applied quantity change ' + delta
                        + ' to **' + product + '**.'
                );
            } else {
                lines.add(
                    'Created amendment quote **' + quote.Name + '** for **' + product
                        + '** (quantity change ' + delta + ').'
                );
            }
            lines.add('Next: create an order from this quote, then activate it so the asset updates.');
            String quoteLink = RLM_MCP_RecordLinks.markdown('Open Quote', 'Quote', quote.Id);
            String assetLink = RLM_MCP_RecordLinks.markdown('Open Asset', 'Asset', asset.Id);
            if (String.isNotBlank(quoteLink)) {
                lines.add(quoteLink);
            }
            if (String.isNotBlank(assetLink)) {
                lines.add(assetLink);
            }
            out.message = String.join(lines, '\n');
            return out;
        } catch (Exception e) {
            out.isSuccess = false;
            out.errorMessage = e.getMessage();
            return out;
        }
    }

    private static void stampAsset(AmendOutput out, Asset asset) {
        out.assetId = asset.Id;
        out.assetName = asset.Name;
        out.assetUrl = RLM_MCP_RecordLinks.lightningUrl('Asset', asset.Id);
    }

    private static Asset rootOf(Asset asset) {
        Asset current = asset;
        Integer hops = 0;
        while (current != null && current.ParentId != null && hops < 8) {
            List<Asset> parents = queryAssetsById(current.ParentId);
            if (parents.isEmpty()) {
                break;
            }
            current = parents[0];
            hops++;
        }
        return current;
    }

    private static String applyComponentDelta(Id quoteId, Asset component, Decimal delta) {
        if (quoteId == null || component == null || component.Product2Id == null || delta == null) {
            return 'Could not apply the quantity change to the bundle component line.';
        }
        List<QuoteLineItem> lines = [
            SELECT Id, Quantity, QuoteActionId, Product2.Name
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId AND Product2Id = :component.Product2Id
            WITH USER_MODE
            LIMIT 2
        ];
        if (lines.isEmpty()) {
            String name = component.Product2 == null ? component.Name : component.Product2.Name;
            return 'Amendment quote has no line for ' + name + '.';
        }
        if (lines.size() > 1) {
            return 'Multiple amendment lines match that component. Ask the user which line.';
        }
        QuoteLineItem line = lines[0];
        if (line.QuoteActionId != null) {
            try {
                update new QuoteAction(Id = line.QuoteActionId, Type = 'Amend');
            } catch (Exception e) {
                return e.getMessage();
            }
        }
        if (Test.isRunningTest()) {
            line.Quantity = delta;
            try {
                update line;
            } catch (Exception e) {
                return e.getMessage();
            }
            return null;
        }
        return persistLineQuantity(quoteId, line.Id, delta);
    }

    private static String persistLineQuantity(Id quoteId, Id lineId, Decimal quantity) {
        List<RevSalesTrxn.RecordWithReferenceRequest> records =
            new List<RevSalesTrxn.RecordWithReferenceRequest>();
        RevSalesTrxn.RecordResource quoteNode = new RevSalesTrxn.RecordResource(
            Quote.getSObjectType(), 'PATCH', quoteId);
        quoteNode.fieldValues = new Map<String, Object>{ 'Status' => 'Draft' };
        records.add(new RevSalesTrxn.RecordWithReferenceRequest('refAmendQuote', quoteNode));
        RevSalesTrxn.RecordResource lineNode = new RevSalesTrxn.RecordResource(
            QuoteLineItem.getSObjectType(), 'PATCH', lineId);
        lineNode.fieldValues = new Map<String, Object>{ 'Quantity' => quantity };
        records.add(new RevSalesTrxn.RecordWithReferenceRequest('refAmendLine', lineNode));
        RevSalesTrxn.ConfigurationOptionsInput options =
            new RevSalesTrxn.ConfigurationOptionsInput();
        options.executeConfigurationRules = false;
        options.validateProductCatalog = false;
        options.validateAmendRenewCancel = false;
        options.addDefaultConfiguration = false;
        RevSalesTrxn.GraphRequest graph = new RevSalesTrxn.GraphRequest('McpAmendQty', records);
        String forceError = executeQuantityGraph(
            graph, options, RevSalesTrxn.PricingPreferenceEnum.FORCE);
        if (forceError == null) {
            return null;
        }
        String systemError = executeQuantityGraph(
            graph, options, RevSalesTrxn.PricingPreferenceEnum.SYSTEM);
        return forceError != null ? forceError : systemError;
    }

    private static String executeQuantityGraph(
        RevSalesTrxn.GraphRequest graph,
        RevSalesTrxn.ConfigurationOptionsInput options,
        RevSalesTrxn.PricingPreferenceEnum pricingPref
    ) {
        RevSalesTrxn.PlaceSalesTransactionResponse resp =
            RevSalesTrxn.PlaceSalesTransactionExecutor.execute(
                graph,
                pricingPref,
                RevSalesTrxn.ConfigurationExecutionEnum.SKIP,
                options,
                null
            );
        if (resp != null && resp.isSuccess) {
            return null;
        }
        return resp == null || resp.errorResponse == null
            ? 'Could not price the amendment quantity change.'
            : String.valueOf(resp.errorResponse);
    }

    private static Asset resolveAsset(AmendInput input, AmendOutput out) {
        if (String.isNotBlank(input.assetId)) {
            Id aid = typedAssetId(input.assetId);
            if (aid == null) {
                out.errorMessage = 'Invalid Asset Id.';
                return null;
            }
            List<Asset> byId = queryAssetsById(aid);
            if (byId.isEmpty()) {
                out.errorMessage = 'No asset found for that Id.';
                return null;
            }
            return byId[0];
        }
        String accountTerm = blankToNull(input.accountName);
        String productTerm = blankToNull(input.productName);
        if (accountTerm == null && productTerm == null) {
            out.errorMessage = 'Provide an asset Id, or an account name and product name.';
            return null;
        }
        List<Asset> matches = findAssets(accountTerm, productTerm);
        if (matches.isEmpty()) {
            out.errorMessage = 'No asset found matching that account and product.';
            return null;
        }
        if (productTerm != null) {
            List<Asset> exact = new List<Asset>();
            for (Asset asset : matches) {
                String name = asset.Product2 == null ? '' : asset.Product2.Name;
                String sku = asset.Product2 == null ? '' : asset.Product2.StockKeepingUnit;
                if ((name != null && name.equalsIgnoreCase(productTerm))
                    || (sku != null && sku.equalsIgnoreCase(productTerm))
                    || (asset.Name != null && asset.Name.equalsIgnoreCase(productTerm))
                ) {
                    exact.add(asset);
                }
            }
            if (exact.size() == 1) {
                return exact[0];
            }
        }
        if (matches.size() == 1) {
            return matches[0];
        }
        out.needsDisambiguation = true;
        out.candidateSummariesDisplay = buildCandidates(matches);
        out.errorMessage = 'Multiple assets match. Ask the user which one to amend.';
        return null;
    }

    private static List<Asset> queryAssetsById(Id assetId) {
        return [
            SELECT Id, Name, AccountId, Account.Name, Quantity, Status, ParentId, Product2Id,
                Product2.Name, Product2.StockKeepingUnit, LifecycleStartDate
            FROM Asset
            WHERE Id = :assetId
            WITH USER_MODE
            LIMIT 1
        ];
    }

    private static List<Asset> findAssets(String accountTerm, String productTerm) {
        String ap = accountTerm == null ? null : '%' + accountTerm + '%';
        String pp = productTerm == null ? null : '%' + productTerm + '%';
        if (ap != null && pp != null) {
            return [
                SELECT Id, Name, AccountId, Account.Name, Quantity, Status, ParentId, Product2Id,
                    Product2.Name, Product2.StockKeepingUnit, LifecycleStartDate
                FROM Asset
                WHERE Account.Name LIKE :ap
                AND (
                    Name LIKE :pp
                    OR Product2.Name LIKE :pp
                    OR Product2.StockKeepingUnit LIKE :pp
                )
                WITH USER_MODE
                ORDER BY LastModifiedDate DESC
                LIMIT :MAX_CANDIDATES
            ];
        }
        if (ap != null) {
            return [
                SELECT Id, Name, AccountId, Account.Name, Quantity, Status, ParentId, Product2Id,
                    Product2.Name, Product2.StockKeepingUnit, LifecycleStartDate
                FROM Asset
                WHERE Account.Name LIKE :ap
                WITH USER_MODE
                ORDER BY LastModifiedDate DESC
                LIMIT :MAX_CANDIDATES
            ];
        }
        return [
            SELECT Id, Name, AccountId, Account.Name, Quantity, Status, ParentId, Product2Id,
                Product2.Name, Product2.StockKeepingUnit, LifecycleStartDate
            FROM Asset
            WHERE Name LIKE :pp
            OR Product2.Name LIKE :pp
            OR Product2.StockKeepingUnit LIKE :pp
            WITH USER_MODE
            ORDER BY LastModifiedDate DESC
            LIMIT :MAX_CANDIDATES
        ];
    }

    private static Id findOpenOpportunity(Id accountId) {
        if (accountId == null) {
            return null;
        }
        List<Opportunity> opps = [
            SELECT Id
            FROM Opportunity
            WHERE AccountId = :accountId AND IsClosed = false
            WITH USER_MODE
            ORDER BY LastModifiedDate DESC
            LIMIT 1
        ];
        return opps.isEmpty() ? null : opps[0].Id;
    }

    private static Quote findLatestAmendQuote(Id accountId) {
        if (accountId == null) {
            return null;
        }
        List<Quote> quotes = [
            SELECT Id, Name
            FROM Quote
            WHERE AccountId = :accountId AND OriginalActionType = 'Amend'
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        return quotes.isEmpty() ? null : quotes[0];
    }

    private static String buildCandidates(List<Asset> assets) {
        List<String> lines = new List<String>{
            'Multiple assets match. Which one should I amend?'
        };
        Integer ordinal = 1;
        for (Asset asset : assets) {
            String name = asset.Product2 == null || String.isBlank(asset.Product2.Name)
                ? asset.Name
                : asset.Product2.Name;
            String row = ordinal + '. **' + name + '**';
            if (asset.Account != null && String.isNotBlank(asset.Account.Name)) {
                row += ' (' + asset.Account.Name + ')';
            }
            if (asset.Quantity != null) {
                row += ', qty ' + String.valueOf(asset.Quantity);
            }
            String link = RLM_MCP_RecordLinks.markdown('Open', 'Asset', asset.Id);
            if (String.isNotBlank(link)) {
                row += ' · ' + link;
            }
            lines.add(row);
            ordinal++;
        }
        return String.join(lines, '\n');
    }

    private static Id typedAssetId(String raw) {
        Id parsed = RLM_MCP_RecordLinks.toId(raw);
        if (parsed == null || parsed.getSObjectType() != Asset.SObjectType) {
            return null;
        }
        return parsed;
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
            return null;
        }
    }

    private static String blankToNull(String value) {
        return String.isBlank(value) ? null : value.trim();
    }
}
