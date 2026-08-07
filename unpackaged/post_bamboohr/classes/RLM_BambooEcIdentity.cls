/**
 * Experience Cloud buyer identity for BambooHR Licenses & billing.
 *
 * Resolves the logged-in community User → Contact → Account, then issues a
 * short-lived HMAC handoff token so the external Get Pricing BFF can open
 * /account without a spoofable bare accountId. Secret is Custom Label
 * RLM_Bamboo_Ec_Handoff_Secret (must match BFF EC_HANDOFF_SECRET).
 */
public with sharing class RLM_BambooEcIdentity {

    public static final Integer HANDOFF_TTL_SECONDS = 300;

    public class BuyerContext {
        @AuraEnabled public Boolean isGuest;
        @AuraEnabled public Boolean isAuthenticated;
        @AuraEnabled public Boolean canManageLicenses;
        @AuraEnabled public Id userId;
        @AuraEnabled public Id contactId;
        @AuraEnabled public Id accountId;
        @AuraEnabled public String accountName;
        @AuraEnabled public String contactName;
        @AuraEnabled public String email;
        @AuraEnabled public String message;
    }

    public class Handoff {
        @AuraEnabled public String token;
        @AuraEnabled public String accountId;
        @AuraEnabled public String accountName;
        @AuraEnabled public String bffAccountUrl;
        @AuraEnabled public Integer expiresInSeconds;
    }

    @AuraEnabled(cacheable=true)
    public static BuyerContext getBuyerContext() {
        BuyerContext ctx = new BuyerContext();
        ctx.userId = UserInfo.getUserId();
        ctx.isGuest = UserInfo.getUserType() == 'Guest';
        ctx.isAuthenticated = !ctx.isGuest;
        ctx.canManageLicenses = false;

        if (ctx.isGuest) {
            ctx.message = 'Sign in to manage licenses for your company.';
            return ctx;
        }

        User u = [
            SELECT Id, ContactId, AccountId, Email, Name, Contact.Name, Contact.AccountId,
                   Contact.Account.Name, Account.Name
            FROM User
            WHERE Id = :UserInfo.getUserId()
            LIMIT 1
        ];

        ctx.email = u.Email;
        ctx.contactName = u.Name;
        ctx.contactId = u.ContactId;

        Id accountId = u.ContactId != null ? u.Contact.AccountId : u.AccountId;
        String accountName = null;
        if (u.ContactId != null && u.Contact.Account != null) {
            accountName = u.Contact.Account.Name;
            ctx.contactName = u.Contact.Name;
        } else if (u.Account != null) {
            accountName = u.Account.Name;
        }

        ctx.accountId = accountId;
        ctx.accountName = accountName;
        ctx.canManageLicenses = accountId != null && u.ContactId != null;

        if (!ctx.canManageLicenses) {
            ctx.message = u.ContactId == null
                ? 'This login is not linked to a customer Contact. Use a Customer Community user.'
                : 'No Account is linked to your Contact.';
        } else {
            ctx.message = 'Signed in as ' + ctx.contactName + ' · ' + accountName;
        }
        return ctx;
    }

    @AuraEnabled
    public static Handoff createHandoffToken() {
        BuyerContext ctx = getBuyerContext();
        if (!ctx.canManageLicenses) {
            throw new AuraHandledException(
                String.isBlank(ctx.message)
                    ? 'Sign in with a customer account to manage licenses.'
                    : ctx.message
            );
        }

        String token = buildHandoffToken(
            String.valueOf(ctx.accountId),
            String.valueOf(ctx.contactId),
            handoffSecret(),
            HANDOFF_TTL_SECONDS
        );

        String bffBase = Label.RLM_Bamboo_Get_Pricing_Bff_Url;
        if (String.isBlank(bffBase)) {
            throw new AuraHandledException(
                'Set Custom Label RLM_Bamboo_Get_Pricing_Bff_Url to your Get Pricing BFF.'
            );
        }
        bffBase = bffBase.trim().removeEnd('/');

        Handoff handoff = new Handoff();
        handoff.token = token;
        handoff.accountId = String.valueOf(ctx.accountId);
        handoff.accountName = ctx.accountName;
        handoff.expiresInSeconds = HANDOFF_TTL_SECONDS;
        handoff.bffAccountUrl =
            bffBase +
            '/account?ecToken=' +
            EncodingUtil.urlEncode(token, 'UTF-8');
        return handoff;
    }

    @TestVisible
    static String buildHandoffToken(
        String accountId,
        String contactId,
        String secret,
        Integer ttlSeconds
    ) {
        Long exp = Datetime.now().getTime() / 1000 + ttlSeconds;
        Map<String, Object> payload = new Map<String, Object>{
            'aid' => accountId,
            'cid' => contactId,
            'exp' => exp,
            'n' => String.valueOf(Math.abs(Crypto.getRandomInteger()))
        };
        String payloadB64 = EncodingUtil.base64Encode(Blob.valueOf(JSON.serialize(payload)));
        Blob mac = Crypto.generateMac(
            'hmacSHA256',
            Blob.valueOf(payloadB64),
            Blob.valueOf(secret)
        );
        return payloadB64 + '.' + EncodingUtil.base64Encode(mac);
    }

    @TestVisible
    static String handoffSecret() {
        String secret = Label.RLM_Bamboo_Ec_Handoff_Secret;
        if (String.isBlank(secret)) {
            throw new AuraHandledException(
                'Set Custom Label RLM_Bamboo_Ec_Handoff_Secret (must match BFF EC_HANDOFF_SECRET).'
            );
        }
        return secret.trim();
    }
}
