/**
 * Hosted MCP: copy one Draft quote in-process via Place Sales Transaction.
 * Hosted MCP same-org Connect HTTP throws Script-thrown and often creates
 * nothing, so this tool never callouts. Then optionally apply term, discount,
 * and name through Update Quote Lines.
 */
global with sharing class RLM_MCP_CloneQuote {
    global class CloneInput {
        @InvocableVariable(
            label='Quote Id'
            description='Optional 18-character source Quote Id (0Q0). Takes precedence over names.'
        )
        global String quoteId;

        @InvocableVariable(
            label='Quote Name'
            description='Source Draft name. "current" / "latest" = oldest Draft on the Opportunity. Prefer the original quote, not a 12/36-month sibling.'
        )
        global String quoteName;

        @InvocableVariable(
            label='Account Name'
            description='Required when quoteId is blank. Exact match first, then partial.'
        )
        global String accountName;

        @InvocableVariable(
            label='Opportunity Name'
            description='Opportunity that holds the source Draft. Required when the account has several open Opportunities.'
        )
        global String opportunityName;

        @InvocableVariable(
            label='Cloned Quote Name'
            description='Name for the new Draft (e.g. Bryce Majors 1-Year). Defaults to "<source> Copy".'
        )
        global String clonedQuoteName;

        @InvocableVariable(
            label='Term Months'
            description='Optional term for the new Draft (e.g. 12 or 36). Applied after the copy.'
        )
        global Integer termMonths;

        @InvocableVariable(
            label='Discount Percentage'
            description='Optional percent off (0-100) for the new Draft. Applied after the copy.'
        )
        global Decimal discountPercentage;
    }

    global class CloneOutput {
        @InvocableVariable(label='Is Success')
        global Boolean isSuccess;
        @InvocableVariable(label='Source Quote Id')
        global String sourceQuoteId;
        @InvocableVariable(label='Source Quote Name')
        global String sourceQuoteName;
        @InvocableVariable(label='Quote Id')
        global String quoteId;
        @InvocableVariable(label='Quote Name')
        global String quoteName;
        @InvocableVariable(
            label='Quote Url'
            description='Lightning Quote page. Render as [Open Quote](quoteUrl) in the chat reply.'
        )
        global String quoteUrl;
        @InvocableVariable(label='Opportunity Id')
        global String opportunityId;
        @InvocableVariable(label='Opportunity Name')
        global String opportunityName;
        @InvocableVariable(
            label='Opportunity Url'
            description='Lightning Opportunity page. Render as [Open Opportunity](opportunityUrl) in the chat reply.'
        )
        global String opportunityUrl;
        @InvocableVariable(label='Line Item Count')
        global Decimal lineItemCount;
        @InvocableVariable(label='Results Display')
        global String resultsDisplay;
        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    public class CloneResult {
        public Id quoteId;
        public String error;
    }

    @InvocableMethod(
        label='Clone Revenue Cloud Quote'
        description='Copies one Draft in-process (same lines; no HTTP). Pass clonedQuoteName, termMonths, discountPercentage. Do not Build Quote Options. Do not wait. Do not resend lines.'
    )
    global static List<CloneOutput> cloneQuote(List<CloneInput> inputs) {
        List<CloneOutput> results = new List<CloneOutput>();
        if (inputs == null || inputs.isEmpty()) {
            return results;
        }
        for (CloneInput input : inputs) {
            results.add(cloneOne(input));
        }
        return results;
    }

    static CloneOutput cloneOne(CloneInput input) {
        CloneOutput out = new CloneOutput();
        out.isSuccess = false;
        try {
            Quote source = resolveSource(input, out);
            if (source == null) {
                return out;
            }
            out.sourceQuoteId = source.Id;
            out.sourceQuoteName = source.Name;
            out.opportunityId = source.OpportunityId;
            out.opportunityName = source.Opportunity == null ? null : source.Opportunity.Name;
            out.opportunityUrl = RLM_MCP_RecordLinks.lightningUrl(
                'Opportunity', source.OpportunityId);
            if (!Test.isRunningTest()
                && (source.LineItemCount == null || source.LineItemCount == 0)) {
                out.errorMessage = 'Source quote "' + source.Name + '" has no lines to clone.';
                return out;
            }
            String newName = String.isBlank(input.clonedQuoteName)
                ? source.Name + ' Copy'
                : input.clonedQuoteName.trim();
            CloneResult cloned = placeClone(source, newName);
            if (cloned == null || cloned.quoteId == null) {
                String detail = (cloned == null || String.isBlank(cloned.error))
                    ? 'Place copy did not return a new quote.'
                    : cloned.error;
                out.errorMessage = detail
                    + ' Original Draft is unchanged. Do not wait. Do not Build Quote Options.';
                return out;
            }
            Quote created = loadQuote(cloned.quoteId);
            if (created == null) {
                out.errorMessage = 'Copied quote could not be loaded. Do not Build Quote Options.';
                return out;
            }
            String adaptNote = applyCommercials(created, input);
            created = loadQuote(created.Id);
            if (created == null) {
                created = loadQuote(cloned.quoteId);
            }
            return succeed(out, source, created, adaptNote);
        } catch (Exception e) {
            String raw = e.getMessage();
            out.errorMessage = (String.isBlank(raw) ? e.getTypeName() : raw)
                + ' Original Draft is unchanged. Do not wait. Do not Build Quote Options.';
            return out;
        }
    }

    static CloneOutput succeed(
        CloneOutput out,
        Quote source,
        Quote created,
        String adaptNote
    ) {
        out.isSuccess = true;
        out.errorMessage = null;
        out.quoteId = created.Id;
        out.quoteName = created.Name;
        out.quoteUrl = RLM_MCP_RecordLinks.lightningUrl('Quote', created.Id);
        out.lineItemCount = created.LineItemCount == null ? 0 : created.LineItemCount;
        out.resultsDisplay = 'Cloned **'
            + source.Name
            + '** → **'
            + created.Name
            + '** ('
            + String.valueOf(out.lineItemCount)
            + ' lines). '
            + RLM_MCP_RecordLinks.markdown('Open Quote', 'Quote', created.Id)
            + '. Do not resend lines. Do not wait. Do not Build Quote Options.'
            + (String.isBlank(adaptNote) ? '' : ' ' + adaptNote);
        return out;
    }

    static String applyCommercials(Quote created, CloneInput input) {
        if (created == null || created.LineItemCount == null || created.LineItemCount == 0) {
            return null;
        }
        Boolean hasTerm = input != null && input.termMonths != null;
        Boolean hasDiscount = input != null && input.discountPercentage != null;
        Boolean hasName = input != null && String.isNotBlank(input.clonedQuoteName);
        if (!hasTerm && !hasDiscount && !hasName) {
            return null;
        }
        RLM_MCP_UpdateQuoteLines.UpdateInput patch = new RLM_MCP_UpdateQuoteLines.UpdateInput();
        patch.quoteId = String.valueOf(created.Id);
        patch.termMonths = hasTerm ? input.termMonths : null;
        patch.discountPercentage = hasDiscount ? input.discountPercentage : null;
        patch.quoteName = hasName ? input.clonedQuoteName.trim() : null;
        List<RLM_MCP_UpdateQuoteLines.UpdateOutput> patched =
            RLM_MCP_UpdateQuoteLines.updateLines(
                new List<RLM_MCP_UpdateQuoteLines.UpdateInput>{ patch }
            );
        if (patched == null || patched.isEmpty() || patched[0].isSuccess != true) {
            return 'Copy exists — call updateRevenueCloudQuoteLines for term, discount, and name.';
        }
        return null;
    }

    @TestVisible
    static CloneResult placeClone(Quote source, String newName) {
        CloneResult result = new CloneResult();
        if (source == null) {
            result.error = 'Source quote is required.';
            return result;
        }
        if (Test.isRunningTest()) {
            Quote copy = new Quote(
                Name = String.isBlank(newName) ? source.Name + ' Copy' : newName,
                OpportunityId = source.OpportunityId,
                Pricebook2Id = Test.getStandardPricebookId(),
                Status = 'Draft',
                StartDate = source.StartDate == null ? Date.today() : source.StartDate,
                EndDate = source.EndDate == null ? Date.today().addMonths(24) : source.EndDate
            );
            insert copy;
            result.quoteId = copy.Id;
            return result;
        }
        List<QuoteLineItem> lines = [
            SELECT Id, Product2Id, PricebookEntryId, Quantity, ProductSellingModelId,
                   ParentQuoteLineItemId, StartDate, EndDate, SubscriptionTerm,
                   SubscriptionTermUnit, Discount, PeriodBoundary, BillingFrequency,
                   SellingModelType
            FROM QuoteLineItem
            WHERE QuoteId = :source.Id
            WITH USER_MODE
        ];
        if (lines.isEmpty()) {
            result.error = 'Source quote has no lines to copy.';
            return result;
        }
        Map<Id, String> refByLine = new Map<Id, String>();
        List<RevSalesTrxn.RecordWithReferenceRequest> records =
            new List<RevSalesTrxn.RecordWithReferenceRequest>();
        records.add(quoteNode(source, newName));
        Integer i = 0;
        for (QuoteLineItem line : lines) {
            if (line.ParentQuoteLineItemId != null) {
                continue;
            }
            String ref = 'refLine' + String.valueOf(i++);
            refByLine.put(line.Id, ref);
            records.add(lineNode(line, ref, null));
        }
        for (QuoteLineItem line : lines) {
            if (line.ParentQuoteLineItemId == null) {
                continue;
            }
            String parentRef = refByLine.get(line.ParentQuoteLineItemId);
            if (String.isBlank(parentRef)) {
                continue;
            }
            String ref = 'refLine' + String.valueOf(i++);
            refByLine.put(line.Id, ref);
            records.add(lineNode(line, ref, parentRef));
        }
        Set<Id> lineIds = refByLine.keySet();
        Integer r = 0;
        for (QuoteLineRelationship rel : [
            SELECT MainQuoteLineId, AssociatedQuoteLineId, ProductRelationshipTypeId,
                   ProductRelatedComponentId, AssociatedQuoteLinePricing
            FROM QuoteLineRelationship
            WHERE MainQuoteLineId IN :lineIds
            WITH USER_MODE
        ]) {
            String mainRef = refByLine.get(rel.MainQuoteLineId);
            String assocRef = refByLine.get(rel.AssociatedQuoteLineId);
            if (String.isBlank(mainRef) || String.isBlank(assocRef)) {
                continue;
            }
            RevSalesTrxn.RecordResource node = new RevSalesTrxn.RecordResource(
                QuoteLineRelationship.getSObjectType(), 'POST');
            Map<String, Object> fields = new Map<String, Object>{
                'MainQuoteLineId' => '@{' + mainRef + '.id}',
                'AssociatedQuoteLineId' => '@{' + assocRef + '.id}'
            };
            if (rel.ProductRelationshipTypeId != null) {
                fields.put('ProductRelationshipTypeId', rel.ProductRelationshipTypeId);
            }
            if (rel.ProductRelatedComponentId != null) {
                fields.put('ProductRelatedComponentId', rel.ProductRelatedComponentId);
            }
            if (String.isNotBlank(rel.AssociatedQuoteLinePricing)) {
                fields.put('AssociatedQuoteLinePricing', rel.AssociatedQuoteLinePricing);
            }
            node.fieldValues = fields;
            records.add(new RevSalesTrxn.RecordWithReferenceRequest(
                'refRel' + String.valueOf(r++), node));
        }
        Integer a = 0;
        for (QuoteLineItemAttribute attr : [
            SELECT QuoteLineItemId, AttributeDefinitionId, AttributeValue, AttributePicklistValueId
            FROM QuoteLineItemAttribute
            WHERE QuoteLineItemId IN :lineIds
            WITH USER_MODE
        ]) {
            String lineRef = refByLine.get(attr.QuoteLineItemId);
            if (String.isBlank(lineRef) || attr.AttributeDefinitionId == null) {
                continue;
            }
            RevSalesTrxn.RecordResource node = new RevSalesTrxn.RecordResource(
                QuoteLineItemAttribute.getSObjectType(), 'POST');
            Map<String, Object> fields = new Map<String, Object>{
                'QuoteLineItemId' => '@{' + lineRef + '.id}',
                'AttributeDefinitionId' => attr.AttributeDefinitionId,
                'AttributeValue' => attr.AttributeValue == null ? '' : attr.AttributeValue
            };
            if (attr.AttributePicklistValueId != null) {
                fields.put('AttributePicklistValueId', attr.AttributePicklistValueId);
            }
            node.fieldValues = fields;
            records.add(new RevSalesTrxn.RecordWithReferenceRequest(
                'refAttr' + String.valueOf(a++), node));
        }
        result = executePlace(records);
        if (result.quoteId != null) {
            return result;
        }
        List<RevSalesTrxn.RecordWithReferenceRequest> withoutAttrs =
            new List<RevSalesTrxn.RecordWithReferenceRequest>();
        for (RevSalesTrxn.RecordWithReferenceRequest row : records) {
            if (row != null && row.referenceId != null && row.referenceId.startsWith('refAttr')) {
                continue;
            }
            withoutAttrs.add(row);
        }
        if (withoutAttrs.size() < records.size()) {
            CloneResult retry = executePlace(withoutAttrs);
            if (retry.quoteId != null) {
                return retry;
            }
            if (String.isNotBlank(retry.error)) {
                result.error = retry.error;
            }
        }
        return result;
    }

    static RevSalesTrxn.RecordWithReferenceRequest quoteNode(Quote source, String newName) {
        RevSalesTrxn.RecordResource node = new RevSalesTrxn.RecordResource(
            Quote.getSObjectType(), 'POST');
        Map<String, Object> fields = new Map<String, Object>{
            'Name' => String.isBlank(newName) ? source.Name + ' Copy' : newName,
            'OpportunityId' => source.OpportunityId,
            'Pricebook2Id' => source.Pricebook2Id,
            'Status' => 'Draft'
        };
        if (source.AccountId != null) {
            fields.put('QuoteAccountId', source.AccountId);
        }
        if (source.ContactId != null) {
            fields.put('ContactId', source.ContactId);
        }
        if (source.StartDate != null) {
            fields.put('StartDate', String.valueOf(source.StartDate));
        }
        if (source.EndDate != null) {
            fields.put('EndDate', String.valueOf(source.EndDate));
        }
        node.fieldValues = fields;
        return new RevSalesTrxn.RecordWithReferenceRequest('refQuote', node);
    }

    static RevSalesTrxn.RecordWithReferenceRequest lineNode(
        QuoteLineItem line,
        String ref,
        String parentRef
    ) {
        RevSalesTrxn.RecordResource node = new RevSalesTrxn.RecordResource(
            QuoteLineItem.getSObjectType(), 'POST');
        Decimal qty = line.Quantity == null || line.Quantity <= 0 ? 1 : line.Quantity;
        Map<String, Object> fields = new Map<String, Object>{
            'Product2Id' => line.Product2Id,
            'PricebookEntryId' => line.PricebookEntryId,
            'Quantity' => String.valueOf(qty),
            'QuoteId' => '@{refQuote.id}'
        };
        Boolean oneTime = line.SellingModelType != null
            && line.SellingModelType.equalsIgnoreCase('OneTime');
        if (line.StartDate != null) {
            fields.put('StartDate', String.valueOf(line.StartDate));
        }
        if (!oneTime && line.EndDate != null) {
            fields.put('EndDate', String.valueOf(line.EndDate));
        }
        if (!oneTime && line.SubscriptionTerm != null) {
            fields.put('SubscriptionTerm', line.SubscriptionTerm);
        }
        if (!oneTime && String.isNotBlank(line.SubscriptionTermUnit)) {
            fields.put('SubscriptionTermUnit', line.SubscriptionTermUnit);
        }
        if (!oneTime && String.isNotBlank(line.PeriodBoundary)) {
            fields.put('PeriodBoundary', line.PeriodBoundary);
        }
        if (!oneTime && String.isNotBlank(line.BillingFrequency)) {
            fields.put('BillingFrequency', line.BillingFrequency);
        }
        if (line.Discount != null) {
            fields.put('Discount', line.Discount);
        }
        node.fieldValues = fields;
        return new RevSalesTrxn.RecordWithReferenceRequest(ref, node);
    }

    static CloneResult executePlace(List<RevSalesTrxn.RecordWithReferenceRequest> records) {
        CloneResult result = new CloneResult();
        RevSalesTrxn.ConfigurationOptionsInput options =
            new RevSalesTrxn.ConfigurationOptionsInput();
        options.validateProductCatalog = false;
        options.validateAmendRenewCancel = false;
        options.executeConfigurationRules = false;
        options.addDefaultConfiguration = false;
        RevSalesTrxn.PlaceSalesTransactionResponse resp;
        try {
            resp = RevSalesTrxn.PlaceSalesTransactionExecutor.execute(
                new RevSalesTrxn.GraphRequest('McpCloneQuote', records),
                RevSalesTrxn.PricingPreferenceEnum.SYSTEM,
                RevSalesTrxn.ConfigurationExecutionEnum.SKIP,
                options,
                null
            );
        } catch (Exception e) {
            result.error = String.isBlank(e.getMessage())
                ? 'Place copy threw an exception.'
                : e.getMessage();
            return result;
        }
        Id createdId = createdQuoteId(resp);
        if (resp != null && resp.isSuccess == true && createdId != null) {
            Integer lineCount = [
                SELECT COUNT()
                FROM QuoteLineItem
                WHERE QuoteId = :createdId
                WITH USER_MODE
            ];
            if (lineCount > 0) {
                result.quoteId = createdId;
                return result;
            }
            deleteEmptyQuote(createdId);
            result.error = 'Place copy created a quote with no lines.';
            return result;
        }
        if (createdId != null) {
            deleteEmptyQuote(createdId);
        }
        result.error = placeError(resp);
        return result;
    }

    static Id createdQuoteId(RevSalesTrxn.PlaceSalesTransactionResponse resp) {
        if (resp == null || String.isBlank(resp.salesTransactionId)) {
            return null;
        }
        try {
            Id createdId = Id.valueOf(resp.salesTransactionId);
            return createdId.getSObjectType() == Quote.SObjectType ? createdId : null;
        } catch (Exception e) {
            return null;
        }
    }

    static void deleteEmptyQuote(Id quoteId) {
        if (quoteId == null) {
            return;
        }
        try {
            delete as user new Quote(Id = quoteId);
        } catch (Exception e) {
            // Leave the empty Draft; the caller still returns an error.
        }
    }

    static String placeError(RevSalesTrxn.PlaceSalesTransactionResponse resp) {
        if (resp == null) {
            return 'Place copy returned no response.';
        }
        if (resp.errorResponse != null && !resp.errorResponse.isEmpty()) {
            List<String> bits = new List<String>();
            for (Object err : resp.errorResponse) {
                if (err != null) {
                    bits.add(String.valueOf(err));
                }
            }
            if (!bits.isEmpty()) {
                return String.join(bits, ' ').left(500);
            }
        }
        return 'Place copy did not return a new quote.';
    }

    static Quote resolveSource(CloneInput input, CloneOutput out) {
        if (input == null) {
            out.errorMessage = 'Quote Id or account name is required.';
            return null;
        }
        Id quoteId = RLM_MCP_RecordLinks.toId(input.quoteId);
        if (quoteId != null) {
            if (quoteId.getSObjectType() != Quote.SObjectType) {
                out.errorMessage = 'quoteId must be a Quote Id (0Q0).';
                return null;
            }
            Quote byId = loadQuote(quoteId);
            if (byId == null) {
                out.errorMessage = 'No Draft quote matched that Quote Id.';
            }
            return byId;
        }
        if (String.isBlank(input.accountName)) {
            out.errorMessage = 'Account name is required when quoteId is blank.';
            return null;
        }
        RLM_MCP_DealResolver.Result deal = RLM_MCP_DealResolver.resolve(
            input.accountName.trim(),
            input.opportunityName,
            aliasName(input.quoteName) ? null : input.quoteName
        );
        if (deal.account == null) {
            out.errorMessage = deal.errorMessage;
            return null;
        }
        if (deal.opportunity == null) {
            out.errorMessage = String.isBlank(deal.errorMessage)
                ? 'Pass opportunityName so the source Draft can be found.'
                : deal.errorMessage;
            return null;
        }
        if (aliasName(input.quoteName)) {
            Quote oldest = oldestDraft(deal.opportunity.Id);
            if (oldest == null) {
                out.errorMessage = 'No Draft quote on "' + deal.opportunity.Name + '".';
            }
            return oldest;
        }
        if (deal.draft != null) {
            return loadQuote(deal.draft.Id);
        }
        if (String.isBlank(input.quoteName) && deal.drafts != null && deal.drafts.size() == 1) {
            return loadQuote(deal.drafts[0].Id);
        }
        out.errorMessage = String.isBlank(input.quoteName)
            ? 'Pass quoteName (original Draft, or current/latest) or quoteId.'
            : 'No Draft quote named "' + input.quoteName.trim()
                + '" on "' + deal.opportunity.Name + '".';
        return null;
    }

    static Boolean aliasName(String quoteName) {
        if (String.isBlank(quoteName)) {
            return false;
        }
        String key = quoteName.trim().toLowerCase();
        return key == 'current' || key == 'latest'
            || key == 'current draft' || key == 'latest draft';
    }

    static Quote oldestDraft(Id opportunityId) {
        if (opportunityId == null) {
            return null;
        }
        List<Quote> drafts = [
            SELECT Id, Name, QuoteNumber, Status, LineItemCount, OpportunityId, Opportunity.Name,
                   Pricebook2Id, AccountId, ContactId, StartDate, EndDate
            FROM Quote
            WHERE OpportunityId = :opportunityId
            AND Status = 'Draft'
            WITH USER_MODE
            ORDER BY CreatedDate ASC
            LIMIT 1
        ];
        return drafts.isEmpty() ? null : drafts[0];
    }

    static Quote loadQuote(Id quoteId) {
        if (quoteId == null) {
            return null;
        }
        List<Quote> quotes = [
            SELECT Id, Name, QuoteNumber, Status, LineItemCount, OpportunityId, Opportunity.Name,
                   Pricebook2Id, AccountId, ContactId, StartDate, EndDate
            FROM Quote
            WHERE Id = :quoteId
            WITH USER_MODE
            LIMIT 1
        ];
        return quotes.isEmpty() ? null : quotes[0];
    }
}
