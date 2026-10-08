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
            description='If set, create or reuse this Opportunity on the account. Do not reuse a differently named open Opportunity.'
        )
        global String opportunityName;

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

        @InvocableVariable(label='Message')
        global String message;

        global CreateOutput() {
            this.isSuccess = false;
        }
    }

    @InvocableMethod(
        label='Create Revenue Cloud Quote'
        description='Creates a Draft quote. Pass opportunityName, termMonths, and linesJson ([{product, quantity}]) to add every line in this call. Do not pre-query Product2 or call add-product per SKU.'
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

        Account account = findAccount(input.accountName.trim());
        if (account == null) {
            out.message = 'No account matched "' + input.accountName + '".';
            return out;
        }
        out.accountName = account.Name;

        List<LineSpec> specs = parseLinesJson(input.linesJson, out);
        if (out.message != null && out.isSuccess != true) {
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
            out.message = 'Standard Price Book is not active.';
            return out;
        }

        Opportunity opportunity;
        try {
            opportunity = resolveOpportunity(account, input.opportunityName);
        } catch (Exception e) {
            out.message = 'Could not create Opportunity: ' + e.getMessage();
            return out;
        }
        out.opportunityId = opportunity.Id;
        out.opportunityUrl = RLM_MCP_RecordLinks.lightningUrl('Opportunity', opportunity.Id);

        String name = String.isBlank(input.quoteName)
            ? 'New Quote For ' + account.Name
            : input.quoteName.trim();
        Date startDate = Date.today();
        Date endDate = (input.termMonths != null && input.termMonths > 0)
            ? startDate.addMonths(input.termMonths)
            : null;
        Quote quote = new Quote(
            Name = name,
            OpportunityId = opportunity.Id,
            Pricebook2Id = books[0].Id,
            Status = 'Draft',
            StartDate = startDate
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
        out.quoteId = quote.Id;
        out.quoteUrl = RLM_MCP_RecordLinks.lightningUrl('Quote', quote.Id);
        out.quoteName = name;
        List<String> lines = new List<String>{
            'Created draft quote ' + name + ' on ' + account.Name + '.'
        };
        if (!specs.isEmpty()) {
            appendAddedLines(out, quote.Id, specs, startDate, endDate, lines);
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

    private static Account findAccount(String name) {
        List<Account> exact = [
            SELECT Id, Name
            FROM Account
            WHERE Name = :name
            WITH USER_MODE
            LIMIT 2
        ];
        if (exact.size() == 1) {
            return exact[0];
        }
        if (exact.size() > 1) {
            return exact[0];
        }
        String likeName = '%' + name + '%';
        List<Account> fuzzy = [
            SELECT Id, Name
            FROM Account
            WHERE Name LIKE :likeName
            WITH USER_MODE
            LIMIT 2
        ];
        return fuzzy.isEmpty() ? null : fuzzy[0];
    }

    private static Opportunity resolveOpportunity(Account account, String opportunityName) {
        if (String.isNotBlank(opportunityName)) {
            String wanted = opportunityName.trim();
            List<Opportunity> named = [
                SELECT Id
                FROM Opportunity
                WHERE AccountId = :account.Id
                AND Name = :wanted
                AND IsClosed = false
                WITH USER_MODE
                ORDER BY LastModifiedDate DESC
                LIMIT 1
            ];
            if (!named.isEmpty()) {
                return named[0];
            }
            return insertOpportunity(account, wanted);
        }
        Opportunity existing = findOpenOpportunity(account.Id);
        return existing != null
            ? existing
            : insertOpportunity(account, account.Name + ' Quote Opportunity');
    }

    private static Opportunity findOpenOpportunity(Id accountId) {
        List<Opportunity> opps = [
            SELECT Id
            FROM Opportunity
            WHERE AccountId = :accountId AND IsClosed = false
            WITH USER_MODE
            ORDER BY LastModifiedDate DESC
            LIMIT 1
        ];
        return opps.isEmpty() ? null : opps[0];
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
