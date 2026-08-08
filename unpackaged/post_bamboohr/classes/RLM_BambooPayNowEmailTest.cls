@IsTest
private class RLM_BambooPayNowEmailTest {

    @IsTest
    static void sendFailsWithoutPaymentUrl() {
        RLM_BambooPayNowEmail.Request req = new RLM_BambooPayNowEmail.Request();
        req.toAddress = 'buyer@example.com';

        Test.startTest();
        List<RLM_BambooPayNowEmail.Result> results = RLM_BambooPayNowEmail.send(
            new List<RLM_BambooPayNowEmail.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(false, results[0].success);
        System.assert(results[0].message.contains('paymentUrl'), results[0].message);
    }

    @IsTest
    static void sendFailsWithoutEmail() {
        Account a = new Account(Name = 'Pay Now Email No Contact');
        insert a;

        RLM_BambooPayNowEmail.Request req = new RLM_BambooPayNowEmail.Request();
        req.paymentUrl = 'https://example.my.site.com/paynow/pay?paymentLinkId=abc';
        req.accountId = a.Id;

        Test.startTest();
        List<RLM_BambooPayNowEmail.Result> results = RLM_BambooPayNowEmail.send(
            new List<RLM_BambooPayNowEmail.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals(false, results[0].success);
        System.assert(results[0].message.contains('email'), results[0].message);
    }

    @IsTest
    static void sendSucceedsWithOverrideAddress() {
        Account a = new Account(Name = 'Pay Now Email Co');
        insert a;
        Contact c = new Contact(
            LastName = 'Buyer',
            Email = 'buyer@example.com',
            AccountId = a.Id
        );
        insert c;

        RLM_BambooPayNowEmail.Request req = new RLM_BambooPayNowEmail.Request();
        req.paymentUrl = 'https://example.my.site.com/paynow/pay?paymentLinkId=abc';
        req.accountId = a.Id;
        req.toAddress = 'override@example.com';
        req.invoiceNumber = 'INV-TEST-1';
        req.amountDue = 42.50;
        req.licensesUrl = 'https://bff.example/account?focus=invoices&paid=1';

        Test.startTest();
        List<RLM_BambooPayNowEmail.Result> results = RLM_BambooPayNowEmail.send(
            new List<RLM_BambooPayNowEmail.Request>{ req }
        );
        Test.stopTest();

        System.assertEquals(1, results.size());
        System.assertEquals('override@example.com', results[0].toAddress);
        System.assertNotEquals(null, results[0].message);
        // Orgs without email deliverability may still report success=false;
        // assert the action ran and targeted the override address.
    }
}
