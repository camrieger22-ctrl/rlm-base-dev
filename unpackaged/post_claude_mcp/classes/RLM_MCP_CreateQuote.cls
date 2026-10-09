/**
 * Global invocable for Hosted MCP: create a Draft Revenue Cloud Quote
 * from an account name. Optional linesJson adds every product in the same
 * call so Claude does not round-trip add-product once per SKU.
 */
global with sharing class RLM_MCP_CreateQuote {
    private static final Integer MAX_LINES = 20;

    public interface LineAdder {
        List<RLM_AI_AddProductToQuoteService.AddOutput> add(
            List<RLM_AI_AddProductToQuoteService.AddInput> inputs
        );
    }

    public class DefaultLineAdder implements LineAdder {
        public List<RLM_AI_AddProductToQuoteService.AddOutput> add(
            List<RLM_AI_AddProductToQuoteService.AddInput> inputs
        ) {
            return RLM_AI_AddProductToQuoteService.addProduct(inputs);
        }
    }

    @TestVisible
    static LineAdder lineAdder = new DefaultLineAdder();

    global class CreateInput {
        @InvocableVariable(
            required=true
            label='Account Name'
            description='Customer account name. Exact match first, then partial. Example: Apex Dynamics.'
        )
        global String accountName;

        @InvocableVariable(
            label='Quote Name'
            description='Optional quote name. Defaults to New Quote For <Account>.'
        )
        global String quoteName;

        @InvocableVariable(
            label='Opportunity Name'
            description='Required when the account has several open Opportunities. Create or reuse this named Opportunity. Do not reuse a differently named open Opportunity.'
        )
        global String opportunityName;

        @InvocableVariable(
            label='Contact Email'
            description='Optional sender email. Sets Quote.ContactId so activate can stamp Bill-to.'
        )
        global String contactEmail;

        @InvocableVariable(
            label='Term Months'
            description='Optional subscription term in months (e.g. 12). Sets quote StartDate and EndDate.'
        )
        global Integer termMonths;

        @InvocableVariable(
            label='Lines JSON'
            description='Optional JSON array of lines to add in this call: [{"product":"QuantumBit Database","quantity":10}]. Do not call add-product per SKU when this is set.'
        )
        global String linesJson;
    }

    global class CreateOutput {
        @InvocableVariable(label='Is Success')
        global Boolean isSuccess;

        @InvocableVariable(label='Quote Id')
        global String quoteId;

        @InvocableVariable(
            label='Quote Url'
            description='Lightning Quote page. Render as [Open Quote](quoteUrl) in the chat reply.'
        )
        global String quoteUrl;

        @InvocableVariable(label='Quote Name')
        global String quoteName;

        @InvocableVariable(label='Account Name')
        global String accountName;

        @InvocableVariable(label='Opportunity Id')
        global String opportunityId;

        @InvocableVariable(
            label='Opportunity Url'
            description='Lightning Opportunity page. Render as [Open Opportunity](opportunityUrl) in the chat reply.'
        )
        global String opportunityUrl;

        @InvocableVariable(
            label='Lines Display'
            description='Names-only recap of lines added from linesJson.'
        )
        global String linesDisplay;

        @InvocableVariable(
            label='Already Existed'
            description='True when this call reused an existing Draft. Call updateQuoteLines or addProduct; do not create again.'
        )
        global Boolean alreadyExisted;

        @InvocableVariable(label='Message')
        global String message;

        global CreateOutput() {
            this.isSuccess = false;
            this.alreadyExisted = false;
        }
    }

    @InvocableMethod(
        label='Create Revenue Cloud Quote'
        description='Creates a Draft quote, or reuses the Draft on the same Opportunity and quote name. Pass opportunityName, termMonths, and linesJson. Do not pre-query Product2 or call add-product per SKU.'
    )
    global static List<CreateOutput> createQuote(List<CreateInput> inputs) {
        List<CreateOutput> results = new List<CreateOutput>();
        if (inputs == null || inputs.isEmpty()) {
            return results;
        }
        for (CreateInput input : inputs) {
            results.add(createOne(input));
        }
        return results;
    }

    private static CreateOutput createOne(CreateInput input) {
        CreateOutput out = new CreateOutput();
        if (input == null || String.isBlank(input.accountName)) {
            out.message = 'Account name is required.';
            return out;
        }

        List<LineSpec> specs = parseLinesJson(input.linesJson, out);
        if (out.message != null && out.isSuccess != true) {
            return out;
        }

        String wantedQuoteName = String.isBlank(input.quoteName) ? null : input.quoteName.trim();
        RLM_MCP_DealResolver.Result deal = RLM_MCP_DealResolver.resolve(
            input.accountName.trim(),
            input.opportunityName,
            wantedQuoteName
        );
        if (deal.needsDisambiguation == true) {
            out.message = deal.errorMessage;
            return out;
        }
        if (deal.account == null) {
            out.message = 'No account matched "' + input.accountName
                + '". Confirm with the user, then call createRevenueCloudProspect, then retry Create Quote.';
            return out;
        }
        out.accountName = deal.account.Name;

        List<Pricebook2> books = [
            SELECT Id
            FROM Pricebook2
            WHERE IsStandard = true AND IsActive = true
            WITH USER_MODE
            LIMIT 1
        ];
        if (books.isEmpty()) {
            out.message = 'Standard Price Book is not active.';
            return out;
        }

        Opportunity opportunity = deal.opportunity;
        if (opportunity == null) {
            String oppName = String.isNotBlank(input.opportunityName)
                ? input.opportunityName.trim()
                : deal.account.Name + ' Quote Opportunity';
            try {
                opportunity = insertOpportunity(deal.account, oppName);
            } catch (Exception e) {
                out.message = 'Could not create Opportunity: ' + e.getMessage();
                return out;
            }
        }
        out.opportunityId = opportunity.Id;
        out.opportunityUrl = RLM_MCP_RecordLinks.lightningUrl('Opportunity', opportunity.Id);

        String name = String.isBlank(wantedQuoteName)
            ? 'New Quote For ' + deal.account.Name
            : wantedQuoteName;
        if (deal.draft != null) {
            return reuseDraft(out, deal, opportunity, name);
        }

        Date startDate = Date.today();
        Date endDate = (input.termMonths != null && input.termMonths > 0)
            ? startDate.addMonths(input.termMonths)
            : null;
        Quote quote = new Quote(
            Name = name,
            OpportunityId = opportunity.Id,
            Pricebook2Id = books[0].Id,
            Status = 'Draft',
            StartDate = startDate,
            ContactId = contactIdFor(deal.account.Id, input.contactEmail)
        );
        if (endDate != null) {
            quote.EndDate = endDate;
        }
        try {
            insert as user quote;
        } catch (Exception e) {
            out.message = 'Could not create Quote: ' + e.getMessage();
            return out;
        }

        out.isSuccess = true;
        out.alreadyExisted = false;
        out.quoteId = quote.Id;
        out.quoteUrl = RLM_MCP_RecordLinks.lightningUrl('Quote', quote.Id);
        out.quoteName = name;
        List<String> lines = new List<String>{
            'Created draft quote ' + name + ' on ' + deal.account.Name + '.'
        };
        if (!specs.isEmpty()) {
            appendAddedLines(out, quote.Id, specs, startDate, endDate, lines);
            String overlap = ownedOverlapWarning(deal.account.Id, specs);
            if (String.isNotBlank(overlap)) {
                lines.add(overlap);
            }
        }
        String quoteLink = RLM_MCP_RecordLinks.markdown('Open Quote', 'Quote', quote.Id);
        String oppLink = RLM_MCP_RecordLinks.markdown(
            'Open Opportunity', 'Opportunity', opportunity.Id);
        if (String.isNotBlank(quoteLink)) {
            lines.add(quoteLink);
        }
        if (String.isNotBlank(oppLink)) {
            lines.add(oppLink);
        }
        out.message = String.join(lines, '\n');
        return out;
    }

    private class LineSpec {
        String product;
        Decimal quantity;
        String sellingModel;
    }

    private static List<LineSpec> parseLinesJson(String raw, CreateOutput out) {
        List<LineSpec> specs = new List<LineSpec>();
        if (String.isBlank(raw)) {
            return specs;
        }
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(raw);
        } catch (Exception e) {
            out.message = 'linesJson is not valid JSON. Pass an array of {product, quantity}.';
            return specs;
        }
        if (!(parsed instanceof List<Object>)) {
            out.message = 'linesJson must be a JSON array of {product, quantity}.';
            return specs;
        }
        for (Object item : (List<Object>) parsed) {
            if (specs.size() >= MAX_LINES) {
                break;
            }
            if (!(item instanceof Map<String, Object>)) {
                continue;
            }
            Map<String, Object> row = (Map<String, Object>) item;
            LineSpec spec = new LineSpec();
            spec.product = asString(first(row, new List<String>{ 'product', 'name', 'sku' }));
            spec.quantity = asDecimal(first(row, new List<String>{ 'quantity', 'qty' }));
            spec.sellingModel = asString(first(row, new List<String>{
                'sellingModel', 'sellingModelName'
            }));
            if (String.isNotBlank(spec.product)) {
                specs.add(spec);
            }
        }
        if (specs.isEmpty()) {
            out.message = 'linesJson had no products. Each item needs a product name.';
        }
        return specs;
    }

    private static void appendAddedLines(
        CreateOutput out,
        Id quoteId,
        List<LineSpec> specs,
        Date startDate,
        Date endDate,
        List<String> recap
    ) {
        List<RLM_AI_AddProductToQuoteService.AddInput> inputs =
            new List<RLM_AI_AddProductToQuoteService.AddInput>();
        for (LineSpec spec : specs) {
            RLM_AI_AddProductToQuoteService.AddInput addIn =
                new RLM_AI_AddProductToQuoteService.AddInput();
            addIn.quoteId = String.valueOf(quoteId);
            addIn.productName = spec.product;
            addIn.quantity = spec.quantity;
            addIn.sellingModelName = spec.sellingModel;
            addIn.startDate = startDate;
            addIn.endDate = endDate;
            inputs.add(addIn);
        }
        List<RLM_AI_AddProductToQuoteService.AddOutput> added = lineAdder.add(inputs);
        List<String> addedLines = new List<String>();
        if (added == null) {
            recap.add('Could not add lines.');
            return;
        }
        for (Integer i = 0; i < added.size(); i++) {
            RLM_AI_AddProductToQuoteService.AddOutput row = added[i];
            String product = (i < specs.size()) ? specs[i].product : 'line';
            if (row != null && row.isSuccess == true) {
                String bit = (row.quantityAdded == null ? '' : String.valueOf(row.quantityAdded) + ' × ')
                    + (String.isBlank(row.productNameAdded) ? product : row.productNameAdded);
                addedLines.add(bit);
                recap.add('- ' + bit);
            } else if (row != null && row.needsDisambiguation == true) {
                recap.add('- Could not add ' + product + ' (multiple matches). Ask which product.');
            } else {
                String err = (row == null || String.isBlank(row.errorMessage))
                    ? 'could not be added'
                    : row.errorMessage;
                recap.add('- ' + product + ': ' + err);
            }
        }
        out.linesDisplay = addedLines.isEmpty() ? null : String.join(addedLines, '\n');
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

    private static Decimal asDecimal(Object value) {
        if (value == null) {
            return 1;
        }
        if (value instanceof Decimal) {
            return (Decimal) value;
        }
        try {
            return Decimal.valueOf(String.valueOf(value).trim());
        } catch (Exception e) {
            return 1;
        }
    }

    private static String ownedOverlapWarning(Id accountId, List<LineSpec> specs) {
        if (accountId == null || specs == null || specs.isEmpty()) {
            return null;
        }
        List<Asset> assets = [
            SELECT Name, Product2.Name, Product2.StockKeepingUnit
            FROM Asset
            WHERE AccountId = :accountId
            AND Status != 'Obsolete'
            WITH USER_MODE
            LIMIT 50
        ];
        if (assets.isEmpty()) {
            return null;
        }
        Set<String> owned = new Set<String>();
        for (LineSpec spec : specs) {
            if (String.isBlank(spec.product)) {
                continue;
            }
            String term = spec.product.toLowerCase();
            for (Asset asset : assets) {
                String name = asset.Product2 == null || String.isBlank(asset.Product2.Name)
                    ? (asset.Name == null ? '' : asset.Name.toLowerCase())
                    : asset.Product2.Name.toLowerCase();
                String sku = asset.Product2 == null || String.isBlank(asset.Product2.StockKeepingUnit)
                    ? '' : asset.Product2.StockKeepingUnit.toLowerCase();
                if (name == term || sku == term || name.contains(term) || term.contains(name)) {
                    owned.add(String.isBlank(asset.Product2 == null ? null : asset.Product2.Name)
                        ? asset.Name : asset.Product2.Name);
                }
            }
        }
        if (owned.isEmpty()) {
            return null;
        }
        return 'They already own ' + String.join(new List<String>(owned), ', ')
            + '. Confirm amend vs new sale (amendRevenueCloudAsset) before submitting.';
    }

    private static CreateOutput reuseDraft(
        CreateOutput out,
        RLM_MCP_DealResolver.Result deal,
        Opportunity opportunity,
        String name
    ) {
        out.isSuccess = true;
        out.alreadyExisted = true;
        out.quoteId = deal.draft.Id;
        out.quoteUrl = RLM_MCP_RecordLinks.lightningUrl('Quote', deal.draft.Id);
        out.quoteName = deal.draft.Name;
        List<String> lines = new List<String>{
            'Reused existing draft quote ' + deal.draft.Name + ' on ' + deal.account.Name + '.',
            'Do not create another. Call updateRevenueCloudQuoteLines or addProductToRevenueCloudQuote if quantities or SKUs changed.'
        };
        String quoteLink = RLM_MCP_RecordLinks.markdown('Open Quote', 'Quote', deal.draft.Id);
        String oppLink = RLM_MCP_RecordLinks.markdown(
            'Open Opportunity', 'Opportunity', opportunity.Id);
        if (String.isNotBlank(quoteLink)) {
            lines.add(quoteLink);
        }
        if (String.isNotBlank(oppLink)) {
            lines.add(oppLink);
        }
        out.message = String.join(lines, '\n');
        return out;
    }

    private static Id contactIdFor(Id accountId, String email) {
        Contact contact = RLM_MCP_DealResolver.findContact(accountId, email);
        return contact == null ? null : contact.Id;
    }

    private static Opportunity insertOpportunity(Account account, String name) {
        Opportunity opportunity = new Opportunity(
            Name = name,
            AccountId = account.Id,
            StageName = 'Proposal/Quote',
            CloseDate = Date.today().addDays(30)
        );
        insert as user opportunity;
        return opportunity;
    }
}
