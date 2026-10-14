@IsTest
private class RLM_MCP_AddAccountContactTest {
    @TestSetup
    static void setup() {
        update new Pricebook2(Id = Test.getStandardPricebookId(), IsActive = true);
        Account account = new Account(Name = 'MCP Add Contact Account');
        insert account;
        insert new Contact(
            AccountId = account.Id,
            FirstName = 'Bryce',
            LastName = 'Majors',
            Email = null
        );
        Opportunity opportunity = new Opportunity(
            Name = 'MCP Add Contact Opp',
            AccountId = account.Id,
            StageName = 'Proposal/Quote',
            CloseDate = Date.today().addDays(30)
        );
        insert opportunity;
        Quote quote = new Quote(
            Name = 'MCP Add Contact Quote',
            OpportunityId = opportunity.Id,
            Pricebook2Id = Test.getStandardPricebookId(),
            Status = 'Draft'
        );
        insert quote;
    }

    private static RLM_MCP_AddAccountContact.AddOutput run(
        RLM_MCP_AddAccountContact.AddInput input
    ) {
        return RLM_MCP_AddAccountContact.addContact(
            new List<RLM_MCP_AddAccountContact.AddInput>{ input }
        )[0];
    }

    @IsTest
    static void requiresAccountAndFromEmail() {
        RLM_MCP_AddAccountContact.AddOutput missingAccount =
            run(new RLM_MCP_AddAccountContact.AddInput());
        System.assertEquals(false, missingAccount.isSuccess);
        System.assert(missingAccount.errorMessage.contains('Account name'), missingAccount.errorMessage);
        RLM_MCP_AddAccountContact.AddInput noEmail = new RLM_MCP_AddAccountContact.AddInput();
        noEmail.accountName = 'MCP Add Contact Account';
        RLM_MCP_AddAccountContact.AddOutput missingEmail = run(noEmail);
        System.assertEquals(false, missingEmail.isSuccess);
        System.assert(missingEmail.errorMessage.contains('From address'), missingEmail.errorMessage);
    }

    @IsTest
    static void setsBlankEmailOnNameMatch() {
        RLM_MCP_AddAccountContact.AddInput input = new RLM_MCP_AddAccountContact.AddInput();
        input.accountName = 'MCP Add Contact Account';
        input.contactFirstName = 'Bryce';
        input.contactLastName = 'Majors';
        input.contactEmail = 'bryce.majors.from@example.test';
        Quote quote = [SELECT Id FROM Quote WHERE Name = 'MCP Add Contact Quote' LIMIT 1];
        input.quoteId = String.valueOf(quote.Id);

        Test.startTest();
        RLM_MCP_AddAccountContact.AddOutput out = run(input);
        Test.stopTest();

        System.assertEquals(true, out.isSuccess, '' + out.errorMessage);
        System.assertEquals(true, out.emailUpdated);
        System.assertEquals(false, out.contactCreated);
        Contact contact = [
            SELECT Email FROM Contact WHERE Id = :out.contactId
        ];
        System.assertEquals('bryce.majors.from@example.test', contact.Email);
        Quote stamped = [SELECT ContactId FROM Quote WHERE Id = :quote.Id];
        System.assertEquals(Id.valueOf(out.contactId), stamped.ContactId);
        System.assert(out.resultsDisplay.contains('Do not create another quote'), out.resultsDisplay);
    }

    @IsTest
    static void addsNewContactWhenNameIsNew() {
        RLM_MCP_AddAccountContact.AddInput input = new RLM_MCP_AddAccountContact.AddInput();
        input.accountName = 'MCP Add Contact Account';
        input.contactFirstName = 'Priya';
        input.contactLastName = 'Shah';
        input.contactEmail = 'priya.shah.from@example.test';

        Test.startTest();
        RLM_MCP_AddAccountContact.AddOutput out = run(input);
        Test.stopTest();

        System.assertEquals(true, out.isSuccess, '' + out.errorMessage);
        System.assertEquals(true, out.contactCreated);
        System.assertEquals(
            1,
            [
                SELECT COUNT()
                FROM Contact
                WHERE Email = 'priya.shah.from@example.test'
            ]
        );
    }

    @IsTest
    static void addsTitlePhoneAndMailingFromEmail() {
        RLM_MCP_AddAccountContact.AddInput input = new RLM_MCP_AddAccountContact.AddInput();
        input.accountName = 'MCP Add Contact Account';
        input.contactFirstName = 'Priya';
        input.contactLastName = 'Shah';
        input.contactEmail = 'priya.shah.from@example.test';
        input.title = 'VP, Operations';
        input.phone = '415-555-0100';
        input.mailingStreet = '1 Market St';
        input.mailingCity = 'San Francisco';
        input.mailingState = 'CA';
        input.mailingPostalCode = '94105';
        input.mailingCountry = 'United States';

        Test.startTest();
        RLM_MCP_AddAccountContact.AddOutput out = run(input);
        Test.stopTest();

        System.assertEquals(true, out.isSuccess, '' + out.errorMessage);
        System.assertEquals(true, out.contactCreated);
        Contact contact = [
            SELECT Title, Phone, MailingStreet, MailingCity, MailingState,
                MailingPostalCode, MailingCountry
            FROM Contact
            WHERE Id = :out.contactId
        ];
        System.assertEquals('VP, Operations', contact.Title);
        System.assertEquals('415-555-0100', contact.Phone);
        System.assertEquals('1 Market St', contact.MailingStreet);
        System.assertEquals('San Francisco', contact.MailingCity);
        System.assertEquals('CA', contact.MailingState);
        System.assertEquals('94105', contact.MailingPostalCode);
        System.assertEquals('United States', contact.MailingCountry);
        System.assert(out.resultsDisplay.contains('VP, Operations'), out.resultsDisplay);
        System.assert(out.resultsDisplay.contains('415-555-0100'), out.resultsDisplay);
        System.assert(out.resultsDisplay.contains('1 Market St'), out.resultsDisplay);
    }

    @IsTest
    static void refusesOverwriteWithoutSetEmail() {
        Contact named = [
            SELECT Id FROM Contact WHERE LastName = 'Majors' LIMIT 1
        ];
        named.Email = 'old.bryce@example.test';
        update named;
        RLM_MCP_AddAccountContact.AddInput input = new RLM_MCP_AddAccountContact.AddInput();
        input.accountName = 'MCP Add Contact Account';
        input.contactFirstName = 'Bryce';
        input.contactLastName = 'Majors';
        input.contactEmail = 'new.bryce.from@example.test';

        RLM_MCP_AddAccountContact.AddOutput out = run(input);
        System.assertEquals(false, out.isSuccess);
        System.assertEquals(true, out.needsDisambiguation);
        System.assert(out.errorMessage.contains('setEmail'), out.errorMessage);
    }

    @IsTest
    static void setEmailReplacesExisting() {
        Contact named = [
            SELECT Id FROM Contact WHERE LastName = 'Majors' LIMIT 1
        ];
        named.Email = 'old.bryce@example.test';
        update named;
        RLM_MCP_AddAccountContact.AddInput input = new RLM_MCP_AddAccountContact.AddInput();
        input.accountName = 'MCP Add Contact Account';
        input.contactFirstName = 'Bryce';
        input.contactLastName = 'Majors';
        input.contactEmail = 'new.bryce.from@example.test';
        input.action = 'setEmail';

        Test.startTest();
        RLM_MCP_AddAccountContact.AddOutput out = run(input);
        Test.stopTest();

        System.assertEquals(true, out.isSuccess, '' + out.errorMessage);
        System.assertEquals(true, out.emailUpdated);
        System.assertEquals(
            'new.bryce.from@example.test',
            [SELECT Email FROM Contact WHERE Id = :named.Id].Email
        );
    }

    @IsTest
    static void missingAccountDoesNotCreateOne() {
        RLM_MCP_AddAccountContact.AddInput input = new RLM_MCP_AddAccountContact.AddInput();
        input.accountName = 'No Such MCP Add Contact Co XYZ';
        input.contactEmail = 'nobody.from@example.test';
        input.contactLastName = 'Nobody';
        RLM_MCP_AddAccountContact.AddOutput out = run(input);
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('createRevenueCloudQuote'), out.errorMessage);
        System.assertEquals(
            0,
            [SELECT COUNT() FROM Account WHERE Name = 'No Such MCP Add Contact Co XYZ']
        );
    }
}
