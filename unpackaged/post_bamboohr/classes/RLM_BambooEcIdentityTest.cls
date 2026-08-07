@IsTest
private class RLM_BambooEcIdentityTest {

    @IsTest
    static void guestOrInternalContextHasNoLicensesFlag() {
        Test.startTest();
        RLM_BambooEcIdentity.BuyerContext ctx = RLM_BambooEcIdentity.getBuyerContext();
        Test.stopTest();

        System.assertNotEquals(null, ctx);
        System.assertEquals(false, ctx.isGuest, 'Unit tests run as an internal user');
        System.assertEquals(true, ctx.isAuthenticated);
        System.assertEquals(
            false,
            ctx.canManageLicenses,
            'Internal users without ContactId cannot manage licenses'
        );
        System.assertNotEquals(null, ctx.message);
    }

    @IsTest
    static void createHandoffFailsWithoutCustomerContact() {
        Boolean threw = false;
        try {
            Test.startTest();
            RLM_BambooEcIdentity.createHandoffToken();
            Test.stopTest();
        } catch (AuraHandledException e) {
            threw = true;
        }
        System.assertEquals(true, threw, 'Expected AuraHandledException without Contact');
    }

    @IsTest
    static void buildHandoffTokenShapeIsVerifiable() {
        String secret = 'unit-test-handoff-secret';
        String token = RLM_BambooEcIdentity.buildHandoffToken(
            '001000000000001AAA',
            '003000000000001AAA',
            secret,
            120
        );
        System.assert(token.contains('.'), token);
        List<String> parts = token.split('\\.');
        System.assertEquals(2, parts.size());

        Blob payloadBlob = EncodingUtil.base64Decode(parts[0]);
        Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(
            payloadBlob.toString()
        );
        System.assertEquals('001000000000001AAA', (String) payload.get('aid'));
        System.assertEquals('003000000000001AAA', (String) payload.get('cid'));
        System.assertNotEquals(null, payload.get('exp'));

        Blob expected = Crypto.generateMac(
            'hmacSHA256',
            Blob.valueOf(parts[0]),
            Blob.valueOf(secret)
        );
        System.assertEquals(EncodingUtil.base64Encode(expected), parts[1]);
    }
}
