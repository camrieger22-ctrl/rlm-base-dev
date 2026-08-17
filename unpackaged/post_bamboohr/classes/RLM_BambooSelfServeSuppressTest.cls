/**
 * Proves the workshop suppress Flow: SelfServe Contacts are Do Not Call
 * with no SDR Task; a normal inbound Contact still gets one.
 *
 * Rationale (Jeff ~01:59): “it has to exist so we can mark it sales don’t
 * touch” and not put self-serve through the normal process.
 *
 * Uses RLM_Bamboo_DoNotCall__c — some demo orgs lack standard Contact.DoNotCall.
 */
@isTest
private class RLM_BambooSelfServeSuppressTest {

    @isTest
    static void selfServeContact_isDoNotCall_andHasNoSdrTask() {
        Account a = new Account(
            Name = 'SelfServe Suppress Co',
            RLM_Bamboo_SelfServe__c = true
        );
        insert a;

        Test.startTest();
        Contact c = new Contact(
            AccountId = a.Id,
            FirstName = 'Pat',
            LastName = 'Buyer',
            Email = 'pat-selfserve@example.com'
        );
        insert c;
        Test.stopTest();

        Contact stored = [
            SELECT RLM_Bamboo_DoNotCall__c
            FROM Contact
            WHERE Id = :c.Id
        ];
        System.assertEquals(
            true,
            stored.RLM_Bamboo_DoNotCall__c,
            'Self-serve Contact must be Do Not Call'
        );
        Integer sdr = [
            SELECT COUNT()
            FROM Task
            WHERE WhoId = :c.Id AND Subject = 'SDR: qualify inbound'
        ];
        System.assertEquals(0, sdr, 'Self-serve must not create an SDR Task');
    }

    @isTest
    static void inboundContact_getsSdrTask() {
        Account a = new Account(Name = 'Inbound SDR Co');
        insert a;

        Test.startTest();
        Contact c = new Contact(
            AccountId = a.Id,
            FirstName = 'Alex',
            LastName = 'Inbound',
            Email = 'alex-inbound@example.com'
        );
        insert c;
        Test.stopTest();

        Integer sdr = [
            SELECT COUNT()
            FROM Task
            WHERE WhoId = :c.Id AND Subject = 'SDR: qualify inbound'
        ];
        System.assertEquals(
            1,
            sdr,
            'Non-self-serve inbound Contact should get the SDR Task the Flow creates'
        );
    }
}
