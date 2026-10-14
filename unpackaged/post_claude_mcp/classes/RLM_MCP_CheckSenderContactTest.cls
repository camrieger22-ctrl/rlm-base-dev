@IsTest
private class RLM_MCP_CheckSenderContactTest {
    @TestSetup
    static void setup() {
        Id pbId = Test.getStandardPricebookId();
        update new Pricebook2(Id = pbId, IsActive = true);
        Account account = new Account(Name = 'MCP Sender Check Account');
        insert account;
        Contact jordan = new Contact(
            AccountId = account.Id,
            FirstName = 'Jordan',
            LastName = 'Hale',
            Email = 'jordan.hale.mcp@example.test'
        );
        insert jordan;
        insert new Contact(
            AccountId = account.Id,
            FirstName = 'Bryce',
            LastName = 'Majors',
            Email = null
        );
        Opportunity opportunity = new Opportunity(
            Name = 'MCP Sender Check Opp',
            AccountId = account.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert opportunity;
        insert new Quote(
            Name = 'MCP Sender Check Quote',
            OpportunityId = opportunity.Id,
            Pricebook2Id = pbId,
            Status = 'Draft',
            ContactId = jordan.Id
        );
    }

    private static RLM_MCP_CheckSenderContact.CheckOutput run(
        RLM_MCP_CheckSenderContact.CheckInput input
    ) {
        return RLM_MCP_CheckSenderContact.checkSender(
            new List<RLM_MCP_CheckSenderContact.CheckInput>{ input }
        )[0];
    }

    @IsTest
    static void requiresAccountAndFrom() {
        RLM_MCP_CheckSenderContact.CheckOutput missing =
            run(new RLM_MCP_CheckSenderContact.CheckInput());
        System.assertEquals(false, missing.isSuccess);
        RLM_MCP_CheckSenderContact.CheckInput noEmail =
            new RLM_MCP_CheckSenderContact.CheckInput();
        noEmail.accountName = 'MCP Sender Check Account';
        RLM_MCP_CheckSenderContact.CheckOutput out = run(noEmail);
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('From email'), out.errorMessage);
    }

    @IsTest
    static void alreadyOnAccountIsQuiet() {
        RLM_MCP_CheckSenderContact.CheckInput input =
            new RLM_MCP_CheckSenderContact.CheckInput();
        input.accountName = 'MCP Sender Check Account';
        input.fromEmail = 'jordan.hale.mcp@example.test';
        input.fromName = 'Jordan Hale';
        RLM_MCP_CheckSenderContact.CheckOutput out = run(input);
        System.assertEquals(true, out.isSuccess, '' + out.errorMessage);
        System.assertEquals(false, out.needsAction);
        System.assert(out.promptDisplay.contains('already'), out.promptDisplay);
    }

    @IsTest
    static void unknownFromPromptsAdd() {
        RLM_MCP_CheckSenderContact.CheckInput input =
            new RLM_MCP_CheckSenderContact.CheckInput();
        input.accountName = 'MCP Sender Check Account';
        input.fromEmail = 'crieger@salesforce.com';
        input.fromName = 'Bryce Majors';
        Test.startTest();
        RLM_MCP_CheckSenderContact.CheckOutput out = run(input);
        Test.stopTest();
        System.assertEquals(true, out.isSuccess, '' + out.errorMessage);
        System.assertEquals(true, out.needsAction);
        System.assert(out.promptDisplay.contains('crieger@salesforce.com'), out.promptDisplay);
        System.assert(out.promptDisplay.contains('Set this From address on Bryce Majors'), out.promptDisplay);
        System.assert(out.promptDisplay.contains('Ask the rep (do not add a Contact yet)'), out.promptDisplay);
        System.assert(out.promptDisplay.contains('never the customer email'), out.promptDisplay);
    }

    @IsTest
    static void unknownNamePromptsAddNew() {
        RLM_MCP_CheckSenderContact.CheckInput input =
            new RLM_MCP_CheckSenderContact.CheckInput();
        input.accountName = 'MCP Sender Check Account';
        input.fromEmail = 'priya.shah.from@example.test';
        input.fromName = 'Priya Shah';
        RLM_MCP_CheckSenderContact.CheckOutput out = run(input);
        System.assertEquals(true, out.needsAction);
        System.assert(out.promptDisplay.contains('Add Priya Shah as a Contact'), out.promptDisplay);
        System.assert(!out.promptDisplay.contains('Set this From address'), out.promptDisplay);
    }

    @IsTest
    static void forQuoteOmitsFromWarns() {
        Id quoteId = [SELECT Id FROM Quote WHERE Name = 'MCP Sender Check Quote'].Id;
        RLM_MCP_CheckSenderContact.CheckOutput out =
            RLM_MCP_CheckSenderContact.forQuote(quoteId, null, 'Bryce Majors');
        System.assertEquals(true, out.isSuccess, '' + out.errorMessage);
        System.assertEquals(true, out.needsAction);
        System.assert(out.promptDisplay.contains('Jordan Hale'), out.promptDisplay);
        System.assert(out.promptDisplay.contains('fromEmail'), out.promptDisplay);
        System.assert(
            out.promptDisplay.contains('Do not assume Jordan Hale sent it'),
            out.promptDisplay
        );
    }

    @IsTest
    static void forQuoteUnknownFromPromptsAdd() {
        Id quoteId = [SELECT Id FROM Quote WHERE Name = 'MCP Sender Check Quote'].Id;
        RLM_MCP_CheckSenderContact.CheckOutput out =
            RLM_MCP_CheckSenderContact.forQuote(
                quoteId,
                'crieger@salesforce.com',
                'Bryce Majors'
            );
        System.assertEquals(true, out.needsAction);
        System.assert(out.promptDisplay.contains('crieger@salesforce.com'), out.promptDisplay);
        System.assert(
            out.promptDisplay.contains('Set this From address on Bryce Majors'),
            out.promptDisplay
        );
        String joined = RLM_MCP_CheckSenderContact.append('Updated quote.', out);
        System.assert(joined.contains('Updated quote.'), joined);
        System.assert(joined.contains('crieger@salesforce.com'), joined);
    }
}
