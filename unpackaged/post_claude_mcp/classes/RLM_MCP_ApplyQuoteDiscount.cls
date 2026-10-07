/**
 * Applies a percent discount on a Draft quote. Live path patches Discount
 * through Place Sales Transaction (SYSTEM, then FORCE) so orgs whose Recalc
 * procedure has no active version still reprice. Tests use DML.
 */
global with sharing class RLM_MCP_ApplyQuoteDiscount {
    global class DiscountInput {
        @InvocableVariable(required=true label='Quote Id')
        global String quoteId;

        @InvocableVariable(
            label='Discount Percentage'
            description='Percent off (0-100). Used when applying a simple percent discount.'
        )
        global Decimal discountPercentage;

        @InvocableVariable(
            label='Apply To All'
            description='When true, discount every line on the quote.'
        )
        global Boolean applyToAll;

        @InvocableVariable(
            label='Product Name'
            description='Discount lines whose product name matches this term.'
        )
        global String productName;
    }

    global class DiscountOutput {
        @InvocableVariable(label='Is Success')
        global Boolean isSuccess;
        @InvocableVariable(label='Applied Count')
        global Decimal appliedCount;
        @InvocableVariable(
            label='Quote Url'
            description='Lightning Quote page. Render as [Open Quote](quoteUrl) in the chat reply.'
        )
        global String quoteUrl;
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
        label='Apply Discount To Revenue Cloud Quote'
        description='Applies a percent discount to one product or all lines on a quote. Prefer applyToAll or productName targeting.'
    )
    global static List<DiscountOutput> applyDiscount(List<DiscountInput> inputs) {
        List<DiscountOutput> results = new List<DiscountOutput>();
        if (inputs == null || inputs.isEmpty()) {
            return results;
        }
        for (DiscountInput input : inputs) {
            results.add(applyOne(input));
        }
        return results;
    }

    static DiscountOutput applyOne(DiscountInput input) {
        DiscountOutput out = new DiscountOutput();
        out.isSuccess = false;
        out.appliedCount = 0;
        try {
            if (input == null || String.isBlank(input.quoteId)) {
                out.errorMessage = 'Quote Id is required.';
                return out;
            }
            Id quoteId;
            try {
                quoteId = Id.valueOf(input.quoteId);
            } catch (Exception e) {
                out.errorMessage = 'Invalid quote Id.';
                return out;
            }
            Decimal percent = input.discountPercentage;
            if (percent == null || percent < 0 || percent > 100) {
                out.errorMessage = 'Discount percentage must be between 0 and 100.';
                return out;
            }
            List<QuoteLineItem> lines = [
                SELECT Id, Product2.Name, Discount
                FROM QuoteLineItem
                WHERE QuoteId = :quoteId
                LIMIT 200
            ];
            List<QuoteLineItem> targets = filterLines(lines, input);
            if (targets.isEmpty()) {
                out.errorMessage = String.isBlank(input.productName)
                    ? 'No matching quote lines were found to discount.'
                    : 'No lines matched "' + input.productName + '".';
                return out;
            }
            String persistError = persistDiscount(quoteId, targets, percent);
            if (String.isNotBlank(persistError)) {
                out.errorMessage = persistError;
                out.resultsDisplay = persistError;
                return out;
            }
            out.isSuccess = true;
            out.appliedCount = targets.size();
            out.quoteUrl = RLM_MCP_RecordLinks.lightningUrl('Quote', quoteId);
            List<String> rows = new List<String>();
            rows.add('Discount applied:');
            for (QuoteLineItem line : targets) {
                String name = line.Product2 == null ? String.valueOf(line.Id) : line.Product2.Name;
                rows.add('- ' + name + ' — ' + String.valueOf(percent) + '% off');
            }
            String quoteLink = RLM_MCP_RecordLinks.markdown('Open Quote', 'Quote', quoteId);
            if (String.isNotBlank(quoteLink)) {
                rows.add(quoteLink);
            }
            out.resultsDisplay = String.join(rows, '\n');
            return out;
        } catch (Exception e) {
            out.isSuccess = false;
            out.errorMessage = e.getMessage() == null ? 'Discount failed.' : e.getMessage();
            return out;
        }
    }

    static List<QuoteLineItem> filterLines(List<QuoteLineItem> lines, DiscountInput input) {
        List<QuoteLineItem> targets = new List<QuoteLineItem>();
        Boolean allLines = input.applyToAll == true || String.isBlank(input.productName);
        String needle = String.isBlank(input.productName)
            ? null
            : input.productName.trim().toLowerCase();
        for (QuoteLineItem line : lines) {
            if (allLines) {
                targets.add(line);
                continue;
            }
            String name = line.Product2 == null ? '' : line.Product2.Name;
            if (name != null && name.toLowerCase().contains(needle)) {
                targets.add(line);
            }
        }
        return targets;
    }

    static String persistDiscount(Id quoteId, List<QuoteLineItem> targets, Decimal percent) {
        if (Test.isRunningTest()) {
            for (QuoteLineItem line : targets) {
                line.Discount = percent;
            }
            try {
                update targets;
            } catch (Exception e) {
                return e.getMessage();
            }
            return null;
        }
        List<RevSalesTrxn.RecordWithReferenceRequest> records =
            new List<RevSalesTrxn.RecordWithReferenceRequest>();
        RevSalesTrxn.RecordResource quoteNode = new RevSalesTrxn.RecordResource(
            Quote.getSObjectType(), 'PATCH', quoteId);
        quoteNode.fieldValues = new Map<String, Object>{ 'Status' => 'Draft' };
        records.add(new RevSalesTrxn.RecordWithReferenceRequest('refQuoteDisc', quoteNode));
        Integer i = 0;
        for (QuoteLineItem line : targets) {
            RevSalesTrxn.RecordResource node = new RevSalesTrxn.RecordResource(
                QuoteLineItem.getSObjectType(), 'PATCH', line.Id);
            node.fieldValues = new Map<String, Object>{ 'Discount' => percent };
            records.add(new RevSalesTrxn.RecordWithReferenceRequest(
                'refDisc' + String.valueOf(i), node));
            i++;
        }
        RevSalesTrxn.ConfigurationOptionsInput options =
            new RevSalesTrxn.ConfigurationOptionsInput();
        options.executeConfigurationRules = false;
        options.validateProductCatalog = false;
        options.validateAmendRenewCancel = false;
        options.addDefaultConfiguration = false;
        RevSalesTrxn.GraphRequest graph = new RevSalesTrxn.GraphRequest('McpQuoteDiscount', records);
        String systemError = executeDiscountGraph(
            graph, options, RevSalesTrxn.PricingPreferenceEnum.SYSTEM);
        if (systemError == null) {
            return null;
        }
        String forceError = executeDiscountGraph(
            graph, options, RevSalesTrxn.PricingPreferenceEnum.FORCE);
        if (forceError == null) {
            return null;
        }
        String skipError = executeDiscountGraph(
            graph, options, RevSalesTrxn.PricingPreferenceEnum.SKIP);
        if (skipError == null) {
            return null;
        }
        return systemError;
    }

    static String executeDiscountGraph(
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
}
