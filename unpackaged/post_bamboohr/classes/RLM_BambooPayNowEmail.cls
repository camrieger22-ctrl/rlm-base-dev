/**
 * Email a Salesforce Pay Now link (BambooHR Get Pricing / Licenses demo).
 * Invoked by the BFF via the Actions API after PaymentLink create.
 */
public with sharing class RLM_BambooPayNowEmail {

    public class Request {
        @InvocableVariable(required=true label='Payment URL')
        public String paymentUrl;
        @InvocableVariable(label='Invoice Id')
        public Id invoiceId;
        @InvocableVariable(label='Account Id')
        public Id accountId;
        @InvocableVariable(label='To address override')
        public String toAddress;
        @InvocableVariable(label='Invoice number (display)')
        public String invoiceNumber;
        @InvocableVariable(label='Amount due')
        public Decimal amountDue;
        @InvocableVariable(label='Licenses return URL (BFF)')
        public String licensesUrl;
    }

    public class Result {
        @InvocableVariable public Boolean success;
        @InvocableVariable public String message;
        @InvocableVariable public String toAddress;
        @InvocableVariable public Id invoiceId;
    }

    @InvocableMethod(
        label='BambooHR Send Pay Now Email'
        description='Emails a Pay Now payment URL to the buyer (Contact or override).'
        category='BambooHR'
    )
    public static List<Result> send(List<Request> requests) {
        List<Result> out = new List<Result>();
        if (requests == null) {
            return out;
        }
        for (Request req : requests) {
            out.add(sendOne(req));
        }
        return out;
    }

    @TestVisible
    static Result sendOne(Request req) {
        Result res = new Result();
        res.success = false;
        res.invoiceId = req == null ? null : req.invoiceId;
        if (req == null || String.isBlank(req.paymentUrl)) {
            res.message = 'paymentUrl is required';
            return res;
        }

        String payUrl = req.paymentUrl.trim();
        Invoice inv = null;
        Account acct = null;
        Contact contact = null;

        if (req.invoiceId != null) {
            List<Invoice> invs = [
                SELECT Id, InvoiceNumber, DocumentNumber, Balance, TotalAmountWithTax,
                       BillingAccountId, BillingAccount.Name
                FROM Invoice
                WHERE Id = :req.invoiceId
                WITH USER_MODE
                LIMIT 1
            ];
            if (!invs.isEmpty()) {
                inv = invs[0];
                res.invoiceId = inv.Id;
            }
        }

        Id accountId = req.accountId;
        if (accountId == null && inv != null) {
            accountId = inv.BillingAccountId;
        }
        if (accountId != null) {
            List<Account> accts = [
                SELECT Id, Name
                FROM Account
                WHERE Id = :accountId
                WITH USER_MODE
                LIMIT 1
            ];
            if (!accts.isEmpty()) {
                acct = accts[0];
            }
            List<Contact> contacts = [
                SELECT Id, Name, Email
                FROM Contact
                WHERE AccountId = :accountId AND Email != null
                WITH USER_MODE
                ORDER BY CreatedDate ASC
                LIMIT 1
            ];
            if (!contacts.isEmpty()) {
                contact = contacts[0];
            }
        }

        String toAddr = String.isNotBlank(req.toAddress)
            ? req.toAddress.trim()
            : (contact != null ? contact.Email : null);
        if (String.isBlank(toAddr)) {
            res.message =
                'No email address — pass toAddress or ensure the Account has a Contact with Email.';
            return res;
        }
        res.toAddress = toAddr;

        String company = acct != null ? acct.Name : 'your company';
        String invNum = String.isNotBlank(req.invoiceNumber)
            ? req.invoiceNumber
            : (
                inv != null
                    ? (
                        String.isNotBlank(inv.InvoiceNumber)
                            ? inv.InvoiceNumber
                            : inv.DocumentNumber
                    )
                    : null
            );
        Decimal amount = req.amountDue;
        if (amount == null && inv != null) {
            amount = inv.Balance;
        }
        String contactName = (contact != null && String.isNotBlank(contact.Name))
            ? contact.Name
            : 'there';

        String subject = String.isNotBlank(invNum)
            ? 'Pay your BambooHR invoice ' + invNum
            : 'Pay your BambooHR invoice';

        String amountBit = amount != null
            ? ('Amount due: <strong>' +
               String.valueOf(amount.setScale(2)) +
               '</strong>.</p><p>')
            : '';
        String invBit = String.isNotBlank(invNum)
            ? ('Invoice <strong>' + escapeHtml(invNum) + '</strong>. ')
            : '';
        String licensesBit = String.isNotBlank(req.licensesUrl)
            ? ('<p><a href="' +
               escapeHtml(req.licensesUrl.trim()) +
               '">View licenses &amp; invoices</a> after you pay.</p>')
            : '';

        String html =
            '<p>Hi ' +
            escapeHtml(contactName) +
            ',</p>' +
            '<p>Thanks for choosing BambooHR for <strong>' +
            escapeHtml(company) +
            '</strong>.</p>' +
            '<p>' +
            invBit +
            amountBit +
            'Use the secure Salesforce Pay Now link below to pay by card:</p>' +
            '<p><a href="' +
            escapeHtml(payUrl) +
            '">Pay now</a></p>' +
            '<p style="word-break:break-all;font-size:12px;color:#555;">' +
            escapeHtml(payUrl) +
            '</p>' +
            licensesBit +
            '<p>Open the pay link in a private / incognito window if you are also signed into Salesforce.</p>' +
            '<p>This message was sent from Salesforce Revenue Cloud (BambooHR Get Pricing demo).</p>';

        String plainAmount = amount != null ? ('Amount due: ' + String.valueOf(amount.setScale(2)) + '\n') : '';
        String plainInv = String.isNotBlank(invNum) ? ('Invoice ' + invNum + '\n') : '';
        String plainLicenses = String.isNotBlank(req.licensesUrl)
            ? ('View licenses & invoices: ' + req.licensesUrl.trim() + '\n')
            : '';
        String plain =
            'Hi ' +
            contactName +
            ',\n\n' +
            'Thanks for choosing BambooHR for ' +
            company +
            '.\n' +
            plainInv +
            plainAmount +
            'Pay now: ' +
            payUrl +
            '\n' +
            plainLicenses +
            '\nOpen the pay link in a private / incognito window if you are also signed into Salesforce.\n' +
            'Sent from Salesforce Revenue Cloud (BambooHR Get Pricing demo).\n';

        Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
        mail.setSubject(subject);
        mail.setHtmlBody(html);
        mail.setPlainTextBody(plain);
        mail.setSaveAsActivity(true);
        mail.setUseSignature(false);

        if (inv != null) {
            mail.setWhatId(inv.Id);
        } else if (acct != null) {
            mail.setWhatId(acct.Id);
        }

        if (contact != null && String.isBlank(req.toAddress)) {
            mail.setTargetObjectId(contact.Id);
            mail.setTreatTargetObjectAsRecipient(true);
        } else {
            mail.setToAddresses(new List<String>{ toAddr });
            if (contact != null) {
                mail.setTargetObjectId(contact.Id);
                mail.setTreatTargetObjectAsRecipient(false);
            }
        }

        Messaging.SendEmailResult[] results = Messaging.sendEmail(
            new List<Messaging.SingleEmailMessage>{ mail },
            false
        );
        if (results != null && !results.isEmpty() && results[0].isSuccess()) {
            res.success = true;
            res.message = 'Email sent to ' + toAddr;
            return res;
        }

        String err = 'SendEmail failed';
        if (results != null && !results.isEmpty() && results[0].getErrors() != null) {
            List<String> bits = new List<String>();
            for (Messaging.SendEmailError e : results[0].getErrors()) {
                bits.add(e.getMessage());
            }
            if (!bits.isEmpty()) {
                err = String.join(bits, '; ');
            }
        }
        res.message = err;
        return res;
    }

    private static String escapeHtml(String value) {
        if (value == null) {
            return '';
        }
        return value
            .replace('&', '&amp;')
            .replace('<', '&lt;')
            .replace('>', '&gt;')
            .replace('"', '&quot;');
    }
}
