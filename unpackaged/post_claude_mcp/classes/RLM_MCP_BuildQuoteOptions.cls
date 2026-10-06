/**
 * Hosted MCP: create several Draft quotes under one Opportunity.
 * Used for "give me three commercial options" without Claude calling
 * create/add/discount once per option.
 */
global with sharing class RLM_MCP_BuildQuoteOptions {
    private static final Integer MAX_OPTIONS = 5;
    private static final Integer MAX_LINES = 10;
    private static final Integer LIVE_OPTIONS_PER_CALL = 5;
    private static final Integer CPU_BUDGET_MS = 6500;
    @TestVisible
    static Integer optionsPerCallOverride;

    global class BuildInput {
        @InvocableVariable(
            required=true
            label='Account Name'
            description='Customer account name. Exact match first, then partial.'
        )
        global String accountName;

        @InvocableVariable(
            label='Opportunity Name'
            description='Opportunity to hang every option on. Created if missing. Defaults to <Account> Commercial Options.'
        )
        global String opportunityName;

        @InvocableVariable(
            required=true
            label='Options JSON'
            description='JSON array of options. Each object: quoteName, termMonths, discountPercent, lines[{product, quantity, sellingModel, configure}]. configure is comma-separated bundle picks after add.'
        )
        global String optionsJson;
    }

    global class BuildOutput {
        @InvocableVariable(label='Is Success')
        global Boolean isSuccess;
        @InvocableVariable(label='Opportunity Name')
        global String opportunityName;
        @InvocableVariable(label='Opportunity Id')
        global String opportunityId;
        @InvocableVariable(label='Opportunity Url')
        global String opportunityUrl;
        @InvocableVariable(
            label='Comparison Display'
            description='Visual quote comparison card: lowest/highest/range nets and one row per option. Render this as a card or artifact, not a bullet dump.'
        )
        global String comparisonDisplay;
        @InvocableVariable(label='Options Display')
        global String optionsDisplay;
        @InvocableVariable(
            label='Is Partial'
            description='True when more options remain. Call this tool again with remainingOptionsJson on the same Opportunity. Do not create a new Opportunity.'
        )
        global Boolean isPartial;
        @InvocableVariable(
            label='Remaining Options JSON'
            description='Unbuilt options in the same shape as optionsJson. Pass this back as optionsJson to continue. Blank when the comparison card is complete.'
        )
        global String remainingOptionsJson;
        @InvocableVariable(label='Error Message')
        global String errorMessage;

        global BuildOutput() {
            this.isSuccess = false;
            this.isPartial = false;
        }
    }

    private class OptionSpec {
        String quoteName;
        Integer termMonths;
        Decimal discountPercent;
        List<LineSpec> lines = new List<LineSpec>();
    }

    private class LineSpec {
        String product;
        Decimal quantity;
        String sellingModel;
        String configure;
    }

    private class CatalogLine {
        Id productId;
        Id pricebookEntryId;
        String productName;
        Decimal quantity;
        String sellingModelType;
        String pricingTermUnit;
        String configure;
        String error;
    }

    private class OptionBuild {
        Boolean success;
        Id quoteId;
        String mixKey;
        String error;
        List<String> notes = new List<String>();
    }

    @InvocableMethod(
        label='Build Revenue Cloud Quote Options'
        description='Creates Draft quotes under one Opportunity. Places the first option of each product mix, then Deep Clones siblings and patches term/discount. Returns remainingOptionsJson only if CPU forces a pause. Then render comparisonDisplay.'
    )
    global static List<BuildOutput> build(List<BuildInput> inputs) {
        List<BuildOutput> results = new List<BuildOutput>();
        if (inputs == null || inputs.isEmpty()) {
            return results;
        }
        for (BuildInput input : inputs) {
            results.add(buildOne(input));
        }
        return results;
    }

    private static BuildOutput buildOne(BuildInput input) {
        BuildOutput out = new BuildOutput();
        try {
            if (input == null || String.isBlank(input.accountName)) {
                out.errorMessage = 'Account name is required.';
                return out;
            }
            Account account = findAccount(input.accountName.trim());
            if (account == null) {
                out.errorMessage = 'No account matched "' + input.accountName + '".';
                return out;
            }
            List<OptionSpec> options = parseOptions(input.optionsJson);
            if (options.isEmpty()) {
                out.errorMessage = String.isBlank(input.optionsJson)
                    ? 'Options JSON is required.'
                    : 'Options JSON must be a non-empty array of quote options.';
                return out;
            }
            if (options.size() > MAX_OPTIONS) {
                out.errorMessage = 'At most ' + String.valueOf(MAX_OPTIONS) + ' options per call.';
                return out;
            }
            List<Pricebook2> books = [
                SELECT Id
                FROM Pricebook2
                WHERE IsStandard = true AND IsActive = true
                WITH USER_MODE
                LIMIT 1
            ];
            if (books.isEmpty()) {
                out.errorMessage = 'Standard Price Book is not active.';
                return out;
            }
            String oppName = String.isBlank(input.opportunityName)
                ? account.Name + ' Commercial Options'
                : input.opportunityName.trim();
            Opportunity opportunity = findOrCreateOpportunity(account, oppName);
            out.opportunityId = opportunity.Id;
            out.opportunityName = opportunity.Name;
            out.opportunityUrl = lightningUrl('Opportunity', opportunity.Id);

            List<String> recap = new List<String>();
            recap.add('**' + options.size() + ' commercial option'
                + (options.size() == 1 ? '' : 's') + '** on opportunity **'
                + opportunity.Name + '** (' + account.Name + ')');
            Boolean anySuccess = false;
            Date latestEnd = opportunity.CloseDate;
            Integer builtThisCall = 0;
            List<OptionSpec> remaining = new List<OptionSpec>();
            Map<String, Id> sourceByMix = Test.isRunningTest()
                ? new Map<String, Id>()
                : indexMixSources(opportunity.Id);
            for (Integer i = 0; i < options.size(); i++) {
                if (builtThisCall > 0 && shouldPause(builtThisCall)) {
                    for (Integer r = i; r < options.size(); r++) {
                        remaining.add(options[r]);
                    }
                    recap.add('Paused before CPU limit. ' + String.valueOf(remaining.size())
                        + ' option' + (remaining.size() == 1 ? '' : 's')
                        + ' left — call again with remainingOptionsJson.');
                    break;
                }
                OptionSpec spec = options[i];
                String quoteName = String.isBlank(spec.quoteName)
                    ? 'Option ' + String.valueOf(i + 1)
                    : spec.quoteName;
                Date startDate = Date.today();
                Date endDate = spec.termMonths == null || spec.termMonths <= 0
                    ? null
                    : startDate.addMonths(spec.termMonths);
                if (endDate != null && (latestEnd == null || endDate > latestEnd)) {
                    latestEnd = endDate;
                }
                List<String> lineNotes = new List<String>();
                if (Test.isRunningTest()) {
                    Quote quote = findDraftQuote(opportunity.Id, quoteName);
                    if (quote == null) {
                        quote = new Quote(
                            Name = quoteName,
                            OpportunityId = opportunity.Id,
                            Pricebook2Id = books[0].Id,
                            Status = 'Draft',
                            StartDate = startDate,
                            EndDate = endDate
                        );
                        try {
                            insert as user quote;
                        } catch (Exception e) {
                            recap.add('');
                            recap.add('### ' + quoteName);
                            recap.add('Could not create quote: ' + e.getMessage());
                            continue;
                        }
                    }
                } else {
                    OptionBuild built = buildLiveOption(
                        spec,
                        quoteName,
                        account.Id,
                        opportunity.Id,
                        books[0].Id,
                        currencyOf(opportunity),
                        startDate,
                        endDate,
                        sourceByMix
                    );
                    if (built.quoteId != null && String.isNotBlank(built.mixKey)) {
                        sourceByMix.put(built.mixKey, built.quoteId);
                    }
                    if (built.notes != null) {
                        lineNotes.addAll(built.notes);
                    }
                    if (built.success != true) {
                        recap.add('');
                        recap.add('### ' + quoteName);
                        recap.add(String.isBlank(built.error)
                            ? 'Could not build this option.'
                            : built.error);
                        continue;
                    }
                }
                anySuccess = true;
                builtThisCall++;
                recap.add('');
                recap.add('### ' + quoteName);
                if (spec.termMonths != null && spec.termMonths > 0) {
                    recap.add('Term: ' + String.valueOf(spec.termMonths) + ' months');
                }
                if (spec.discountPercent != null && spec.discountPercent > 0) {
                    recap.add('Discount: ' + String.valueOf(spec.discountPercent) + '%');
                }
                if (lineNotes != null) {
                    recap.addAll(lineNotes);
                }
            }
            if (latestEnd != null && latestEnd != opportunity.CloseDate) {
                opportunity.CloseDate = latestEnd;
                try {
                    update as user opportunity;
                } catch (Exception e) {
                    recap.add('Opportunity close date was not updated: ' + e.getMessage());
                }
            }
            out.remainingOptionsJson = remaining.isEmpty() ? null : toOptionsJson(remaining);
            out.isPartial = !remaining.isEmpty();
            out.comparisonDisplay = buildComparison(
                account.Name, opportunity.Name, out.opportunityUrl, opportunity.Id);
            out.optionsDisplay = out.comparisonDisplay + '\n\n' + String.join(recap, '\n');
            out.isSuccess = anySuccess;
            if (!anySuccess) {
                out.errorMessage = 'No quotes were created.';
            }
            return out;
        } catch (Exception e) {
            out.isSuccess = false;
            out.errorMessage = e.getMessage();
            return out;
        }
    }

    static OptionBuild buildLiveOption(
        OptionSpec spec,
        String quoteName,
        Id accountId,
        Id opportunityId,
        Id pricebookId,
        String currencyIso,
        Date startDate,
        Date endDate,
        Map<String, Id> sourceByMix
    ) {
        OptionBuild built = new OptionBuild();
        built.success = false;
        List<CatalogLine> catalog = resolveCatalog(spec, pricebookId, currencyIso);
        for (CatalogLine line : catalog) {
            if (String.isNotBlank(line.error)) {
                built.error = line.error;
                return built;
            }
        }
        built.mixKey = mixKeyFromCatalog(catalog);
        Quote existing = findDraftQuote(opportunityId, quoteName);
        if (existing != null && existing.LineItemCount != null && existing.LineItemCount > 0) {
            built.quoteId = existing.Id;
            built.success = true;
            built.notes.add('- Reused existing draft ' + quoteName);
            return built;
        }
        Id sourceId = sourceByMix != null ? sourceByMix.get(built.mixKey) : null;
        if (sourceId != null && (existing == null || existing.Id != sourceId)) {
            Id clonedId = deepCloneQuote(sourceId);
            if (clonedId != null && clonedId != sourceId) {
                String adapt = adaptClone(
                    clonedId, quoteName, opportunityId, startDate, endDate, spec);
                built.quoteId = clonedId;
                built.success = true;
                built.notes.add('- Cloned from an existing option with the same products');
                if (String.isNotBlank(adapt)) {
                    built.notes.add(adapt);
                }
                return built;
            }
            built.notes.add('- Clone was not available; placing this option instead.');
        }
        Id placedId = placeOption(
            spec, catalog, quoteName, accountId, opportunityId, pricebookId,
            currencyIso, startDate, endDate, existing);
        if (placedId == null) {
            built.error = 'Place Sales Transaction did not return a quote.';
            return built;
        }
        built.quoteId = placedId;
        Integer lineCount = countLines(placedId);
        if (lineCount == 0) {
            built.notes.addAll(addLines(placedId, quoteName, spec, startDate, endDate));
        } else {
            built.notes.add('- Placed ' + String.valueOf(lineCount) + ' line'
                + (lineCount == 1 ? '' : 's') + ' with term and discount');
        }
        for (LineSpec line : spec.lines == null ? new List<LineSpec>() : spec.lines) {
            if (line != null && String.isNotBlank(line.configure)) {
                built.notes.add(configureBundle(quoteName, line.product, line.configure));
            }
        }
        String termNote = applyQuoteTerm(
            placedId, startDate, endDate, spec.termMonths, spec.discountPercent);
        if (String.isNotBlank(termNote)) {
            built.notes.add(termNote);
        }
        built.success = true;
        return built;
    }

    static String adaptClone(
        Id quoteId,
        String quoteName,
        Id opportunityId,
        Date startDate,
        Date endDate,
        OptionSpec spec
    ) {
        List<String> notes = new List<String>();
        Quote cloned = new Quote(Id = quoteId, Name = quoteName, OpportunityId = opportunityId);
        if (startDate != null) {
            cloned.StartDate = startDate;
        }
        if (endDate != null) {
            cloned.EndDate = endDate;
        }
        try {
            update as user cloned;
        } catch (Exception e) {
            notes.add('- Cloned quote could not be renamed: ' + e.getMessage());
        }
        String termNote = applyQuoteTerm(
            quoteId, startDate, endDate, spec.termMonths, spec.discountPercent);
        if (String.isNotBlank(termNote)) {
            notes.add(termNote);
        }
        return notes.isEmpty() ? null : String.join(notes, '\n');
    }

    static Id placeOption(
        OptionSpec spec,
        List<CatalogLine> catalog,
        String quoteName,
        Id accountId,
        Id opportunityId,
        Id pricebookId,
        String currencyIso,
        Date startDate,
        Date endDate,
        Quote existing
    ) {
        List<RevSalesTrxn.RecordWithReferenceRequest> records =
            new List<RevSalesTrxn.RecordWithReferenceRequest>();
        RevSalesTrxn.RecordResource quoteNode;
        if (existing != null) {
            quoteNode = new RevSalesTrxn.RecordResource(Quote.getSObjectType(), 'PATCH', existing.Id);
        } else {
            quoteNode = new RevSalesTrxn.RecordResource(Quote.getSObjectType(), 'POST');
        }
        Map<String, Object> quoteFields = new Map<String, Object>{
            'Name' => quoteName,
            'OpportunityId' => opportunityId,
            'Pricebook2Id' => pricebookId,
            'QuoteAccountId' => accountId,
            'Status' => 'Draft'
        };
        if (String.isNotBlank(currencyIso)) {
            quoteFields.put('CurrencyIsoCode', currencyIso);
        }
        if (startDate != null) {
            quoteFields.put('StartDate', String.valueOf(startDate));
        }
        if (endDate != null) {
            quoteFields.put('EndDate', String.valueOf(endDate));
        }
        quoteNode.fieldValues = quoteFields;
        records.add(new RevSalesTrxn.RecordWithReferenceRequest('refQuote', quoteNode));
        Integer i = 0;
        for (CatalogLine line : catalog) {
            RevSalesTrxn.RecordResource item = new RevSalesTrxn.RecordResource(
                QuoteLineItem.getSObjectType(), 'POST');
            Decimal qty = line.quantity == null || line.quantity <= 0 ? 1 : line.quantity;
            Map<String, Object> fields = new Map<String, Object>{
                'Product2Id' => line.productId,
                'PricebookEntryId' => line.pricebookEntryId,
                'Quantity' => String.valueOf(qty),
                'QuoteId' => existing != null
                    ? String.valueOf(existing.Id)
                    : '@{refQuote.id}'
            };
            if (startDate != null) {
                fields.put('StartDate', String.valueOf(startDate));
            }
            Boolean oneTime = line.sellingModelType != null
                && line.sellingModelType.equalsIgnoreCase('OneTime');
            if (!oneTime && endDate != null) {
                fields.put('EndDate', String.valueOf(endDate));
            }
            if (!oneTime && spec.termMonths != null && spec.termMonths > 0) {
                fields.put('SubscriptionTerm', termCount(spec.termMonths, line.pricingTermUnit));
                if (String.isNotBlank(line.pricingTermUnit)) {
                    fields.put('SubscriptionTermUnit', line.pricingTermUnit);
                }
            }
            if (spec.discountPercent != null && spec.discountPercent > 0) {
                fields.put('Discount', spec.discountPercent);
            }
            item.fieldValues = fields;
            records.add(new RevSalesTrxn.RecordWithReferenceRequest('refLine' + String.valueOf(i), item));
            i++;
        }
        RevSalesTrxn.ConfigurationOptionsInput options = new RevSalesTrxn.ConfigurationOptionsInput();
        options.executeConfigurationRules = false;
        options.validateProductCatalog = false;
        options.validateAmendRenewCancel = false;
        options.addDefaultConfiguration = true;
        RevSalesTrxn.GraphRequest graph = new RevSalesTrxn.GraphRequest('McpPlaceOption', records);
        RevSalesTrxn.PlaceSalesTransactionResponse resp;
        try {
            resp = RevSalesTrxn.PlaceSalesTransactionExecutor.execute(
                graph,
                RevSalesTrxn.PricingPreferenceEnum.SYSTEM,
                RevSalesTrxn.ConfigurationExecutionEnum.SKIP,
                options,
                null
            );
        } catch (Exception e) {
            return existing != null ? existing.Id : null;
        }
        if (resp != null && String.isNotBlank(resp.salesTransactionId)) {
            return Id.valueOf(resp.salesTransactionId);
        }
        Quote found = findDraftQuote(opportunityId, quoteName);
        return found == null ? (existing != null ? existing.Id : null) : found.Id;
    }

    static Id deepCloneQuote(Id sourceQuoteId) {
        if (sourceQuoteId == null) {
            return null;
        }
        try {
            Invocable.Action action =
                Invocable.Action.createStandardAction('deepCloneSalesTransaction');
            action.setInvocationParameter('recordIds', new List<String>{ String.valueOf(sourceQuoteId) });
            action.setInvocationParameter('salesTransactionId', String.valueOf(sourceQuoteId));
            List<Invocable.Action.Result> results = action.invoke();
            if (results == null || results.isEmpty() || !results[0].isSuccess()) {
                return null;
            }
            Object raw = results[0].getOutputParameters().get('newRecordId');
            if (raw == null) {
                return null;
            }
            Id newId = Id.valueOf(String.valueOf(raw));
            if (newId.getSObjectType() == Quote.SObjectType) {
                return newId == sourceQuoteId ? null : newId;
            }
            if (newId.getSObjectType() == QuoteLineItem.SObjectType) {
                List<QuoteLineItem> lines = [
                    SELECT QuoteId
                    FROM QuoteLineItem
                    WHERE Id = :newId
                    WITH USER_MODE
                    LIMIT 1
                ];
                if (!lines.isEmpty() && lines[0].QuoteId != sourceQuoteId) {
                    return lines[0].QuoteId;
                }
            }
            return null;
        } catch (Exception e) {
            return null;
        }
    }

    static List<CatalogLine> resolveCatalog(OptionSpec spec, Id pricebookId, String currencyIso) {
        List<CatalogLine> resolved = new List<CatalogLine>();
        if (spec == null || spec.lines == null) {
            return resolved;
        }
        for (LineSpec line : spec.lines) {
            if (line == null || String.isBlank(line.product)) {
                continue;
            }
            CatalogLine catalog = resolveCatalogLine(line, pricebookId, currencyIso);
            resolved.add(catalog);
        }
        return resolved;
    }

    static CatalogLine resolveCatalogLine(LineSpec line, Id pricebookId, String currencyIso) {
        CatalogLine catalog = new CatalogLine();
        catalog.quantity = line.quantity;
        catalog.configure = line.configure;
        String needle = line.product.trim();
        List<PricebookEntry> matches = [
            SELECT Id, Product2Id, Product2.Name, CurrencyIsoCode,
                   ProductSellingModelId, ProductSellingModel.Name,
                   ProductSellingModel.SellingModelType,
                   ProductSellingModel.PricingTermUnit
            FROM PricebookEntry
            WHERE Pricebook2Id = :pricebookId
            AND IsActive = true
            AND Product2.IsActive = true
            AND (Product2.Name = :needle OR Product2.StockKeepingUnit = :needle)
            WITH USER_MODE
            LIMIT 50
        ];
        if (matches.isEmpty()) {
            String likeName = '%' + needle + '%';
            matches = [
                SELECT Id, Product2Id, Product2.Name, CurrencyIsoCode,
                       ProductSellingModelId, ProductSellingModel.Name,
                       ProductSellingModel.SellingModelType,
                       ProductSellingModel.PricingTermUnit
                FROM PricebookEntry
                WHERE Pricebook2Id = :pricebookId
                AND IsActive = true
                AND Product2.IsActive = true
                AND (Product2.Name LIKE :likeName OR Product2.StockKeepingUnit LIKE :likeName)
                WITH USER_MODE
                LIMIT 50
            ];
        }
        PricebookEntry entry = pickPricebookEntry(matches, currencyIso, line.sellingModel);
        if (entry == null) {
            catalog.error = matches.isEmpty()
                ? 'No active price book entry matched "' + needle + '".'
                : 'Multiple products matched "' + needle + '". Use the exact catalog name or SKU.';
            return catalog;
        }
        catalog.productId = entry.Product2Id;
        catalog.pricebookEntryId = entry.Id;
        catalog.productName = entry.Product2.Name;
        catalog.sellingModelType = entry.ProductSellingModel == null
            ? null
            : entry.ProductSellingModel.SellingModelType;
        catalog.pricingTermUnit = entry.ProductSellingModel == null
            ? null
            : entry.ProductSellingModel.PricingTermUnit;
        return catalog;
    }

    @TestVisible
    static PricebookEntry pickPricebookEntry(
        List<PricebookEntry> matches,
        String currencyIso,
        String requestedModel
    ) {
        if (matches == null || matches.isEmpty()) {
            return null;
        }
        List<PricebookEntry> scoped = new List<PricebookEntry>();
        if (String.isNotBlank(currencyIso)) {
            for (PricebookEntry entry : matches) {
                if (entry.CurrencyIsoCode == currencyIso) {
                    scoped.add(entry);
                }
            }
        }
        if (scoped.isEmpty()) {
            scoped.addAll(matches);
        }
        Set<Id> productIds = new Set<Id>();
        for (PricebookEntry entry : scoped) {
            productIds.add(entry.Product2Id);
        }
        if (productIds.size() > 1) {
            return null;
        }
        if (String.isNotBlank(requestedModel)) {
            String wanted = requestedModel.trim().toLowerCase();
            for (PricebookEntry entry : scoped) {
                String modelName = entry.ProductSellingModel == null
                    ? null
                    : entry.ProductSellingModel.Name;
                if (modelName != null && modelName.trim().toLowerCase() == wanted) {
                    return entry;
                }
            }
        }
        Id productId = scoped[0].Product2Id;
        Id defaultModelId = defaultSellingModelId(productId);
        if (defaultModelId != null) {
            for (PricebookEntry entry : scoped) {
                if (entry.ProductSellingModelId == defaultModelId) {
                    return entry;
                }
            }
        }
        for (PricebookEntry entry : scoped) {
            String modelName = entry.ProductSellingModel == null
                ? null
                : entry.ProductSellingModel.Name;
            if (modelName != null && modelName.equalsIgnoreCase('Term Annual')) {
                return entry;
            }
        }
        return scoped[0];
    }

    static Id defaultSellingModelId(Id productId) {
        if (productId == null) {
            return null;
        }
        List<ProductSellingModelOption> defaults = [
            SELECT ProductSellingModelId
            FROM ProductSellingModelOption
            WHERE Product2Id = :productId
            AND IsDefault = true
            WITH USER_MODE
            LIMIT 1
        ];
        return defaults.isEmpty() ? null : defaults[0].ProductSellingModelId;
    }

    static String currencyOf(SObject record) {
        if (record == null) {
            return 'USD';
        }
        Map<String, Schema.SObjectField> fields =
            record.getSObjectType().getDescribe().fields.getMap();
        if (!fields.containsKey('currencyisocode')) {
            return 'USD';
        }
        Object value = record.get('CurrencyIsoCode');
        return value == null ? 'USD' : String.valueOf(value);
    }

    @TestVisible
    static String mixKeyFromJson(String optionsJson) {
        List<OptionSpec> options = parseOptions(optionsJson);
        return options.isEmpty() ? '' : mixKey(options[0]);
    }

    @TestVisible
    static String mixKey(OptionSpec spec) {
        List<String> parts = new List<String>();
        if (spec != null && spec.lines != null) {
            for (LineSpec line : spec.lines) {
                if (line == null || String.isBlank(line.product)) {
                    continue;
                }
                Decimal qty = line.quantity == null || line.quantity <= 0 ? 1 : line.quantity;
                parts.add(line.product.trim().toLowerCase() + '|' + String.valueOf(qty));
            }
        }
        parts.sort();
        return String.join(parts, ';');
    }

    static String mixKeyFromCatalog(List<CatalogLine> lines) {
        List<String> parts = new List<String>();
        if (lines != null) {
            for (CatalogLine line : lines) {
                if (line == null || line.productId == null) {
                    continue;
                }
                Decimal qty = line.quantity == null || line.quantity <= 0 ? 1 : line.quantity;
                parts.add(String.valueOf(line.productId) + '|' + String.valueOf(qty));
            }
        }
        parts.sort();
        return String.join(parts, ';');
    }

    static Map<String, Id> indexMixSources(Id opportunityId) {
        Map<String, Id> sources = new Map<String, Id>();
        if (opportunityId == null) {
            return sources;
        }
        List<Quote> quotes = [
            SELECT Id
            FROM Quote
            WHERE OpportunityId = :opportunityId
            AND Status = 'Draft'
            WITH USER_MODE
            ORDER BY CreatedDate
        ];
        if (quotes.isEmpty()) {
            return sources;
        }
        Set<Id> quoteIds = new Map<Id, Quote>(quotes).keySet();
        Map<Id, List<String>> partsByQuote = new Map<Id, List<String>>();
        for (QuoteLineItem line : [
            SELECT QuoteId, Product2Id, Quantity, ParentQuoteLineItemId
            FROM QuoteLineItem
            WHERE QuoteId IN :quoteIds
            WITH USER_MODE
        ]) {
            if (line.ParentQuoteLineItemId != null || line.Product2Id == null) {
                continue;
            }
            Decimal qty = line.Quantity == null || line.Quantity <= 0 ? 1 : line.Quantity;
            if (!partsByQuote.containsKey(line.QuoteId)) {
                partsByQuote.put(line.QuoteId, new List<String>());
            }
            partsByQuote.get(line.QuoteId).add(
                String.valueOf(line.Product2Id) + '|' + String.valueOf(qty));
        }
        for (Id quoteId : partsByQuote.keySet()) {
            List<String> parts = partsByQuote.get(quoteId);
            parts.sort();
            String key = String.join(parts, ';');
            if (!sources.containsKey(key)) {
                sources.put(key, quoteId);
            }
        }
        return sources;
    }

    static Integer countLines(Id quoteId) {
        if (quoteId == null) {
            return 0;
        }
        return [
            SELECT COUNT()
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
            WITH USER_MODE
        ];
    }

    private static List<String> addLines(
        Id quoteId,
        String quoteName,
        OptionSpec spec,
        Date startDate,
        Date endDate
    ) {
        List<String> notes = new List<String>();
        if (spec.lines == null) {
            return notes;
        }
        for (LineSpec line : spec.lines) {
            if (line == null || String.isBlank(line.product)) {
                continue;
            }
            if (quoteHasProduct(quoteId, line.product)) {
                notes.add('- ' + line.product + ' already on this quote');
                continue;
            }
            RLM_AI_AddProductToQuoteService.AddOutput addOut =
                addProduct(quoteId, line, startDate, endDate);
            if (addOut == null || addOut.isSuccess != true) {
                if (looksLikeDateError(addOut)) {
                    addOut = addProduct(quoteId, line, null, null);
                }
            }
            if (addOut == null || addOut.isSuccess != true) {
                notes.add('- Could not add ' + line.product + ': '
                    + (addOut == null ? 'add-line returned nothing.' : addOut.errorMessage));
                continue;
            }
            notes.add('- Added ' + addOut.productNameAdded + ' × ' + String.valueOf(addOut.quantityAdded));
            if (String.isNotBlank(line.configure)) {
                notes.add(configureBundle(quoteName, line.product, line.configure));
            }
        }
        return notes;
    }

    private static RLM_AI_AddProductToQuoteService.AddOutput addProduct(
        Id quoteId,
        LineSpec line,
        Date startDate,
        Date endDate
    ) {
        RLM_AI_AddProductToQuoteService.AddInput addInput =
            new RLM_AI_AddProductToQuoteService.AddInput();
        addInput.quoteId = String.valueOf(quoteId);
        addInput.productName = line.product;
        addInput.quantity = line.quantity == null || line.quantity <= 0 ? 1 : line.quantity;
        addInput.sellingModelName = line.sellingModel;
        addInput.startDate = startDate;
        addInput.endDate = endDate;
        List<RLM_AI_AddProductToQuoteService.AddOutput> added =
            RLM_AI_AddProductToQuoteService.addProduct(
                new List<RLM_AI_AddProductToQuoteService.AddInput>{ addInput }
            );
        return added == null || added.isEmpty() ? null : added[0];
    }

    private static Boolean looksLikeDateError(RLM_AI_AddProductToQuoteService.AddOutput addOut) {
        if (addOut == null || String.isBlank(addOut.errorMessage)) {
            return false;
        }
        String lower = addOut.errorMessage.toLowerCase();
        return lower.contains('startdate') || lower.contains('enddate')
            || lower.contains('start date') || lower.contains('end date')
            || lower.contains('dateonlywrapper')
            || lower.contains('one-time') || lower.contains('onetime')
            || lower.contains('one time');
    }

    private static String configureBundle(String quoteName, String productName, String selected) {
        RLM_MCP_BundleConfigService.Request req = new RLM_MCP_BundleConfigService.Request();
        req.quoteName = quoteName;
        req.productName = productName;
        req.selectedProducts = selected;
        RLM_MCP_BundleConfigService.Response raw = RLM_MCP_BundleConfigService.configure(req);
        if (raw != null && raw.isSuccess == true) {
            return '- Configured ' + productName + ': ' + selected;
        }
        return '- Configure ' + productName + ' failed: '
            + (raw == null ? 'no response' : raw.errorMessage);
    }

    private static Boolean quoteHasProduct(Id quoteId, String productName) {
        if (quoteId == null || String.isBlank(productName)) {
            return false;
        }
        String needle = productName.trim();
        List<QuoteLineItem> lines = [
            SELECT Product2.Name
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
            AND Product2.Name = :needle
            WITH USER_MODE
            LIMIT 1
        ];
        return !lines.isEmpty();
    }

    private static String applyDiscount(Id quoteId, Decimal percent) {
        RLM_MCP_ApplyQuoteDiscount.DiscountInput input =
            new RLM_MCP_ApplyQuoteDiscount.DiscountInput();
        input.quoteId = String.valueOf(quoteId);
        input.discountPercentage = percent;
        input.applyToAll = true;
        List<RLM_MCP_ApplyQuoteDiscount.DiscountOutput> results =
            RLM_MCP_ApplyQuoteDiscount.applyDiscount(
                new List<RLM_MCP_ApplyQuoteDiscount.DiscountInput>{ input }
            );
        RLM_MCP_ApplyQuoteDiscount.DiscountOutput raw =
            results == null || results.isEmpty() ? null : results[0];
        if (raw != null && raw.isSuccess == true) {
            return '- Applied ' + String.valueOf(percent) + '% discount';
        }
        return '- Discount failed: ' + (raw == null ? 'no response' : raw.errorMessage);
    }

    static String applyQuoteTerm(
        Id quoteId,
        Date startDate,
        Date endDate,
        Integer termMonths,
        Decimal discountPercent
    ) {
        Boolean hasTerm = termMonths != null && termMonths > 0 && endDate != null;
        Boolean hasDiscount = discountPercent != null;
        if (quoteId == null || (!hasTerm && !hasDiscount)) {
            return null;
        }
        List<QuoteLineItem> lines = [
            SELECT Id, StartDate, EndDate, SubscriptionTerm, SubscriptionTermUnit,
                   ProductSellingModel.SellingModelType,
                   ProductSellingModel.PricingTermUnit
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
            WITH USER_MODE
        ];
        List<RevSalesTrxn.RecordWithReferenceRequest> records =
            new List<RevSalesTrxn.RecordWithReferenceRequest>();
        RevSalesTrxn.RecordResource quoteNode = new RevSalesTrxn.RecordResource(
            Quote.getSObjectType(), 'PATCH', quoteId);
        Map<String, Object> quoteFields = new Map<String, Object>();
        if (startDate != null) {
            quoteFields.put('StartDate', String.valueOf(startDate));
        }
        if (endDate != null) {
            quoteFields.put('EndDate', String.valueOf(endDate));
        }
        quoteNode.fieldValues = quoteFields;
        records.add(new RevSalesTrxn.RecordWithReferenceRequest('refQuoteTerm', quoteNode));
        Integer patched = 0;
        Integer i = 0;
        for (QuoteLineItem line : lines) {
            String modelType = line.ProductSellingModel == null
                ? null
                : line.ProductSellingModel.SellingModelType;
            Boolean termDefined = modelType != null && modelType.equalsIgnoreCase('TermDefined');
            Map<String, Object> fields = new Map<String, Object>();
            if (hasTerm && termDefined) {
                String unit = String.isNotBlank(line.SubscriptionTermUnit)
                    ? line.SubscriptionTermUnit
                    : (line.ProductSellingModel == null
                        ? 'Months'
                        : line.ProductSellingModel.PricingTermUnit);
                fields.put('EndDate', String.valueOf(endDate));
                fields.put('SubscriptionTerm', termCount(termMonths, unit));
                if (startDate != null) {
                    fields.put('StartDate', String.valueOf(startDate));
                }
                if (String.isNotBlank(unit)) {
                    fields.put('SubscriptionTermUnit', unit);
                }
            }
            if (hasDiscount) {
                fields.put('Discount', discountPercent);
            }
            if (fields.isEmpty()) {
                continue;
            }
            RevSalesTrxn.RecordResource node = new RevSalesTrxn.RecordResource(
                QuoteLineItem.getSObjectType(), 'PATCH', line.Id);
            node.fieldValues = fields;
            records.add(new RevSalesTrxn.RecordWithReferenceRequest(
                'refTerm' + String.valueOf(i), node));
            i++;
            patched++;
        }
        if (patched == 0) {
            return hasTerm
                ? '- No subscription lines to apply the ' + String.valueOf(termMonths) + '-month term.'
                : null;
        }
        String priceError = persistTerm(records);
        if (String.isNotBlank(priceError)) {
            return '- Set term/discount on ' + String.valueOf(patched)
                + ' lines, but pricing did not refresh: ' + priceError;
        }
        return '- Applied term/discount to ' + String.valueOf(patched) + ' lines';
    }

    @TestVisible
    static Integer termCount(Integer termMonths, String unit) {
        if (termMonths == null || termMonths <= 0) {
            return 1;
        }
        if (unit != null && unit.equalsIgnoreCase('Annual')) {
            Integer years = termMonths / 12;
            return years < 1 ? 1 : years;
        }
        if (unit != null && unit.equalsIgnoreCase('Quarterly')) {
            Integer quarters = termMonths / 3;
            return quarters < 1 ? 1 : quarters;
        }
        if (unit != null && unit.equalsIgnoreCase('Semi-Annual')) {
            Integer halves = termMonths / 6;
            return halves < 1 ? 1 : halves;
        }
        return termMonths;
    }

    static String persistTerm(List<RevSalesTrxn.RecordWithReferenceRequest> records) {
        RevSalesTrxn.ConfigurationOptionsInput options =
            new RevSalesTrxn.ConfigurationOptionsInput();
        options.executeConfigurationRules = false;
        options.validateProductCatalog = false;
        options.validateAmendRenewCancel = false;
        options.addDefaultConfiguration = false;
        RevSalesTrxn.GraphRequest graph = new RevSalesTrxn.GraphRequest('McpQuoteTerm', records);
        try {
            String forceError = executeTermGraph(
                graph, options, RevSalesTrxn.PricingPreferenceEnum.FORCE);
            if (forceError == null) {
                return null;
            }
            String systemError = executeTermGraph(
                graph, options, RevSalesTrxn.PricingPreferenceEnum.SYSTEM);
            if (systemError == null) {
                return null;
            }
            return forceError;
        } catch (Exception e) {
            return e.getMessage();
        }
    }

    static String executeTermGraph(
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
            ? 'Pricing did not return a result.'
            : String.valueOf(resp.errorResponse);
    }

    static String buildComparison(
        String accountName,
        String opportunityName,
        String opportunityUrl,
        Id opportunityId
    ) {
        List<String> card = new List<String>();
        card.add('# ' + accountName + ' Quote Options');
        if (opportunityId == null) {
            card.add('No quotes were created.');
            return String.join(card, '\n');
        }
        List<Quote> quotes = [
            SELECT Name, TotalPrice, LineItemCount, StartDate, EndDate
            FROM Quote
            WHERE OpportunityId = :opportunityId
            WITH USER_MODE
            ORDER BY CreatedDate
        ];
        if (quotes.isEmpty()) {
            card.add('No quotes were created.');
            return String.join(card, '\n');
        }
        Set<Id> quoteIds = new Map<Id, Quote>(quotes).keySet();
        Map<Id, Decimal> lineNets = new Map<Id, Decimal>();
        Map<Id, Integer> lineCounts = new Map<Id, Integer>();
        for (QuoteLineItem line : [
            SELECT QuoteId, NetTotalPrice, TotalPrice
            FROM QuoteLineItem
            WHERE QuoteId IN :quoteIds
            WITH USER_MODE
        ]) {
            Decimal amt = line.NetTotalPrice != null
                ? line.NetTotalPrice
                : (line.TotalPrice == null ? 0 : line.TotalPrice);
            Id quoteId = line.QuoteId;
            lineNets.put(quoteId, (lineNets.containsKey(quoteId) ? lineNets.get(quoteId) : 0) + amt);
            lineCounts.put(
                quoteId,
                (lineCounts.containsKey(quoteId) ? lineCounts.get(quoteId) : 0) + 1
            );
        }
        Integer n = quotes.size();
        card.add(String.valueOf(n) + ' quote option' + (n == 1 ? '' : 's')
            + ' · ' + opportunityName);
        if (String.isNotBlank(opportunityUrl)) {
            card.add('[Open Opportunity](' + opportunityUrl + ')');
        }
        Decimal lowest;
        Decimal highest;
        for (Quote q : quotes) {
            Decimal net = netOf(q, lineNets);
            if (lowest == null || net < lowest) {
                lowest = net;
            }
            if (highest == null || net > highest) {
                highest = net;
            }
        }
        Decimal rangeAmt = (lowest == null || highest == null) ? 0 : (highest - lowest);
        card.add('');
        card.add('| Lowest Net | Highest Net | Range |');
        card.add('|---|---|---|');
        card.add('| ' + money(lowest) + ' | ' + money(highest) + ' | ' + money(rangeAmt) + ' |');
        card.add('');
        for (Quote q : quotes) {
            Integer months = termMonthsOf(q.StartDate, q.EndDate);
            String term = months == null ? '' : String.valueOf(months) + ' months';
            Integer lines = lineCounts.containsKey(q.Id)
                ? lineCounts.get(q.Id)
                : (q.LineItemCount == null ? 0 : Integer.valueOf(q.LineItemCount));
            String lineLabel = String.valueOf(lines) + ' line' + (lines == 1 ? '' : 's');
            String row = '- **' + q.Name + '**';
            if (String.isNotBlank(term)) {
                row += ' · ' + term;
            }
            row += ' · ' + lineLabel + ' · ' + money(netOf(q, lineNets));
            String quoteUrl = lightningUrl('Quote', q.Id);
            if (String.isNotBlank(quoteUrl)) {
                row += ' · [Open](' + quoteUrl + ')';
            }
            card.add(row);
        }
        return String.join(card, '\n');
    }

    static Decimal netOf(Quote quote, Map<Id, Decimal> lineNets) {
        if (quote != null && quote.TotalPrice != null && quote.TotalPrice != 0) {
            return quote.TotalPrice;
        }
        if (quote != null && lineNets != null && lineNets.containsKey(quote.Id)) {
            return lineNets.get(quote.Id);
        }
        return quote != null && quote.TotalPrice != null ? quote.TotalPrice : 0;
    }

    static Integer termMonthsOf(Date startDate, Date endDate) {
        if (startDate == null || endDate == null) {
            return null;
        }
        Integer months = startDate.monthsBetween(endDate);
        return months < 0 ? null : months;
    }

    static String lightningUrl(String objectName, Id recordId) {
        if (recordId == null || String.isBlank(objectName)) {
            return null;
        }
        return URL.getOrgDomainUrl().toExternalForm()
            + '/lightning/r/' + objectName + '/' + String.valueOf(recordId) + '/view';
    }

    static String money(Decimal value) {
        Decimal n = value == null ? 0 : value.setScale(2);
        return 'USD ' + n.format();
    }

    static Integer optionsPerCall() {
        if (optionsPerCallOverride != null) {
            return optionsPerCallOverride;
        }
        return Test.isRunningTest() ? MAX_OPTIONS : LIVE_OPTIONS_PER_CALL;
    }

    static Boolean shouldPause(Integer builtThisCall) {
        if (builtThisCall >= optionsPerCall()) {
            return true;
        }
        return !Test.isRunningTest() && Limits.getCpuTime() >= CPU_BUDGET_MS;
    }

    static String toOptionsJson(List<OptionSpec> options) {
        List<Object> rows = new List<Object>();
        if (options == null) {
            return JSON.serialize(rows);
        }
        for (OptionSpec spec : options) {
            if (spec == null) {
                continue;
            }
            Map<String, Object> row = new Map<String, Object>();
            row.put('quoteName', spec.quoteName);
            row.put('termMonths', spec.termMonths);
            row.put('discountPercent', spec.discountPercent);
            List<Object> lines = new List<Object>();
            if (spec.lines != null) {
                for (LineSpec line : spec.lines) {
                    if (line == null) {
                        continue;
                    }
                    Map<String, Object> item = new Map<String, Object>();
                    item.put('product', line.product);
                    item.put('quantity', line.quantity);
                    item.put('sellingModel', line.sellingModel);
                    item.put('configure', line.configure);
                    lines.add(item);
                }
            }
            row.put('lines', lines);
            rows.add(row);
        }
        return JSON.serialize(rows);
    }

    @TestVisible
    static List<OptionSpec> parseOptions(String optionsJson) {
        List<OptionSpec> options = new List<OptionSpec>();
        if (String.isBlank(optionsJson)) {
            return options;
        }
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(optionsJson);
        } catch (Exception e) {
            return options;
        }
        if (!(parsed instanceof List<Object>)) {
            return options;
        }
        for (Object item : (List<Object>) parsed) {
            if (!(item instanceof Map<String, Object>)) {
                continue;
            }
            Map<String, Object> raw = (Map<String, Object>) item;
            OptionSpec spec = new OptionSpec();
            spec.quoteName = asString(first(raw, new List<String>{ 'quoteName', 'name' }));
            spec.termMonths = asInteger(first(raw, new List<String>{ 'termMonths', 'term' }));
            spec.discountPercent = asDecimal(first(raw, new List<String>{
                'discountPercent', 'discount', 'discountPercentage'
            }));
            spec.lines = parseLines(raw.get('lines'));
            if (spec.lines.isEmpty()) {
                spec.lines.addAll(parseLegacyProducts(raw));
            }
            options.add(spec);
        }
        return options;
    }

    private static List<LineSpec> parseLines(Object linesObj) {
        List<LineSpec> lines = new List<LineSpec>();
        if (!(linesObj instanceof List<Object>)) {
            return lines;
        }
        for (Object item : (List<Object>) linesObj) {
            if (lines.size() >= MAX_LINES) {
                break;
            }
            if (!(item instanceof Map<String, Object>)) {
                continue;
            }
            Map<String, Object> raw = (Map<String, Object>) item;
            LineSpec line = new LineSpec();
            line.product = asString(first(raw, new List<String>{ 'product', 'name', 'sku' }));
            line.quantity = asDecimal(raw.get('quantity'));
            line.sellingModel = asString(first(raw, new List<String>{ 'sellingModel', 'sellingModelName' }));
            line.configure = asString(first(raw, new List<String>{ 'configure', 'selected', 'selectedBundleProducts' }));
            if (String.isNotBlank(line.product)) {
                lines.add(line);
            }
        }
        return lines;
    }

    private static List<LineSpec> parseLegacyProducts(Map<String, Object> raw) {
        List<LineSpec> lines = new List<LineSpec>();
        String products = asString(raw.get('products'));
        if (String.isBlank(products)) {
            return lines;
        }
        Map<String, Decimal> quantities = new Map<String, Decimal>();
        Object qtyObj = raw.get('quantities');
        if (qtyObj instanceof Map<String, Object>) {
            for (String key : ((Map<String, Object>) qtyObj).keySet()) {
                quantities.put(key.toLowerCase(), asDecimal(((Map<String, Object>) qtyObj).get(key)));
            }
        }
        String configure = asString(first(raw, new List<String>{
            'configure', 'selectedBundleProducts', 'selected'
        }));
        for (String part : products.split(',')) {
            if (lines.size() >= MAX_LINES) {
                break;
            }
            String name = part == null ? null : part.trim();
            if (String.isBlank(name)) {
                continue;
            }
            LineSpec line = new LineSpec();
            line.product = name;
            line.quantity = quantities.containsKey(name.toLowerCase())
                ? quantities.get(name.toLowerCase())
                : 1;
            if (String.isNotBlank(configure) && lines.isEmpty()) {
                line.configure = configure;
            }
            lines.add(line);
        }
        return lines;
    }

    private static Account findAccount(String name) {
        List<Account> exact = [
            SELECT Id, Name, CurrencyIsoCode
            FROM Account
            WHERE Name = :name
            WITH USER_MODE
            LIMIT 2
        ];
        if (!exact.isEmpty()) {
            return exact[0];
        }
        String likeName = '%' + name + '%';
        List<Account> fuzzy = [
            SELECT Id, Name, CurrencyIsoCode
            FROM Account
            WHERE Name LIKE :likeName
            WITH USER_MODE
            LIMIT 2
        ];
        return fuzzy.isEmpty() ? null : fuzzy[0];
    }

    private static Quote findDraftQuote(Id opportunityId, String quoteName) {
        if (opportunityId == null || String.isBlank(quoteName)) {
            return null;
        }
        List<Quote> found = [
            SELECT Id, Name, StartDate, EndDate, LineItemCount
            FROM Quote
            WHERE OpportunityId = :opportunityId
            AND Name = :quoteName
            AND Status = 'Draft'
            WITH USER_MODE
            ORDER BY LastModifiedDate DESC
            LIMIT 1
        ];
        return found.isEmpty() ? null : found[0];
    }

    private static Opportunity findOrCreateOpportunity(Account account, String oppName) {
        List<Opportunity> named = [
            SELECT Id, Name, CloseDate, CurrencyIsoCode
            FROM Opportunity
            WHERE AccountId = :account.Id
            AND Name = :oppName
            AND IsClosed = false
            WITH USER_MODE
            ORDER BY LastModifiedDate DESC
            LIMIT 1
        ];
        if (!named.isEmpty()) {
            return named[0];
        }
        Opportunity opportunity = new Opportunity(
            Name = oppName,
            AccountId = account.Id,
            StageName = 'Proposal/Quote',
            CloseDate = Date.today().addDays(30)
        );
        if (account.get('CurrencyIsoCode') != null) {
            opportunity.put('CurrencyIsoCode', account.get('CurrencyIsoCode'));
        }
        insert as user opportunity;
        return opportunity;
    }

    private static Object first(Map<String, Object> raw, List<String> keys) {
        for (String key : keys) {
            if (raw.containsKey(key) && raw.get(key) != null) {
                return raw.get(key);
            }
        }
        return null;
    }

    private static String asString(Object value) {
        return value == null ? null : String.valueOf(value).trim();
    }

    private static Integer asInteger(Object value) {
        Decimal d = asDecimal(value);
        return d == null ? null : d.intValue();
    }

    private static Decimal asDecimal(Object value) {
        if (value == null) {
            return null;
        }
        if (value instanceof Decimal) {
            return (Decimal) value;
        }
        if (value instanceof Integer) {
            return Decimal.valueOf((Integer) value);
        }
        try {
            return Decimal.valueOf(String.valueOf(value));
        } catch (Exception e) {
            return null;
        }
    }
}
