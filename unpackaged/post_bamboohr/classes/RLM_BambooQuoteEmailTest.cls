@IsTest
private class RLM_BambooQuoteEmailTest {

    private static Quote makeQuote(String contactEmail) {
        Account a = new Account(Name = 'Bamboo Quote Email Test Co');
        insert a;
        Contact c = new Contact(
            LastName = 'Buyer',
            Email = contactEmail,
            AccountId = a.Id
        );
        insert c;
        Opportunity opp = new Opportunity(
            Name = 'Email Test Opp',
            AccountId = a.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30),
            Pricebook2Id = Test.getStandardPricebookId()
        );
        insert opp;
        Quote q = new Quote(
            Name = 'Email Test Quote',
            OpportunityId = opp.Id,
            ContactId = c.Id,
            Pricebook2Id = Test.getStandardPricebookId()
        );
        insert q;
        return q;
    }

    @IsTest
    static void sendFailsWithoutEmail() {
        Quote q = makeQuote(null);

        RLM_BambooQuoteEmail.Request req = new RLM_BambooQuoteEmail.Request();
        req.quoteId = q.Id;

        Test.startTest();
        List<RLM_BambooQuoteEmail.Result> results = RLM_BambooQuoteEmail.send(
            new List<RLM_BambooQuoteEmail.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(false, results[0].success);
        System.assert(results[0].message.contains('email'), results[0].message);
    }

    @IsTest
    static void sendSucceedsWithOverrideAddress() {
        Quote q = makeQuote('buyer@example.com');

        RLM_BambooQuoteEmail.Request req = new RLM_BambooQuoteEmail.Request();
        req.quoteId = q.Id;
        req.toAddress = 'override@example.com';

        Test.startTest();
        List<RLM_BambooQuoteEmail.Result> results = RLM_BambooQuoteEmail.send(
            new List<RLM_BambooQuoteEmail.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertNotEquals(null, results[0].message);
        System.assertEquals('override@example.com', results[0].toAddress);
    }
}
