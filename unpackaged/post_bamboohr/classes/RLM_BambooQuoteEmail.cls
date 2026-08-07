/**
 * Send a BambooHR quote email from Salesforce (activity on the Quote).
 * Optional ContentVersion attachment (DocGen PDF). Invoked by the Get Pricing
 * BFF via the Actions API after PDF generation.
 */
public with sharing class RLM_BambooQuoteEmail {

    public class Request {
        @InvocableVariable(required=true label='Quote Id')
        public Id quoteId;
        @InvocableVariable(label='ContentVersion Id (PDF attachment)')
        public Id contentVersionId;
        @InvocableVariable(label='To address override')
        public String toAddress;
    }

    public class Result {
        @InvocableVariable public Boolean success;
        @InvocableVariable public String message;
        @InvocableVariable public String toAddress;
        @InvocableVariable public Id quoteId;
    }

    @InvocableMethod(
        label='BambooHR Send Quote Email'
        description='Emails the Quote Contact (or override) with an optional DocGen PDF attachment.'
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
        res.quoteId = req == null ? null : req.quoteId;
        if (req == null || req.quoteId == null) {
            res.message = 'quoteId is required';
            return res;
        }

        Quote q = [
            SELECT Id, QuoteNumber, Name, ExpirationDate, GrandTotal,
                   ContactId, Contact.Email, Contact.Name,
                   AccountId, Account.Name
            FROM Quote
            WHERE Id = :req.quoteId
            WITH USER_MODE
            LIMIT 1
        ];

        String toAddr = String.isNotBlank(req.toAddress)
            ? req.toAddress.trim()
            : (q.Contact != null ? q.Contact.Email : null);
        if (String.isBlank(toAddr)) {
            res.message =
                'No email address — set Contact.Email on the Quote or pass toAddress.';
            return res;
        }
        res.toAddress = toAddr;

        String company = q.Account != null ? q.Account.Name : 'your company';
        String qNum = String.isNotBlank(q.QuoteNumber) ? q.QuoteNumber : String.valueOf(q.Id);
        String subject = 'Your BambooHR quote ' + qNum;
        String contactName = (q.Contact != null && String.isNotBlank(q.Contact.Name))
            ? q.Contact.Name
            : 'there';

        String html =
            '<p>Hi ' +
            escapeHtml(contactName) +
            ',</p>' +
            '<p>Thanks for requesting pricing for <strong>' +
            escapeHtml(company) +
            '</strong>.</p>' +
            '<p>Your Salesforce quote <strong>' +
            escapeHtml(qNum) +
            '</strong> is ready' +
            (req.contentVersionId != null ? ' — see the attached PDF' : '') +
            '.</p>' +
            '<p>This message was sent from Salesforce Revenue Cloud (BambooHR Get Pricing demo).</p>';

        String plain =
            'Hi ' +
            contactName +
            ',\n\n' +
            'Thanks for requesting pricing for ' +
            company +
            '.\n' +
            'Your Salesforce quote ' +
            qNum +
            ' is ready' +
            (req.contentVersionId != null ? ' — see the attached PDF' : '') +
            '.\n\n' +
            'Sent from Salesforce Revenue Cloud (BambooHR Get Pricing demo).\n';

        Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
        mail.setSubject(subject);
        mail.setHtmlBody(html);
        mail.setPlainTextBody(plain);
        mail.setWhatId(q.Id);
        mail.setSaveAsActivity(true);
        mail.setUseSignature(false);

        if (q.ContactId != null && String.isBlank(req.toAddress)) {
            mail.setTargetObjectId(q.ContactId);
            mail.setTreatTargetObjectAsRecipient(true);
        } else {
            mail.setToAddresses(new List<String>{ toAddr });
            if (q.ContactId != null) {
                mail.setTargetObjectId(q.ContactId);
                mail.setTreatTargetObjectAsRecipient(false);
            }
        }

        if (req.contentVersionId != null) {
            ContentVersion cv = [
                SELECT Id, Title, FileExtension, VersionData
                FROM ContentVersion
                WHERE Id = :req.contentVersionId
                WITH USER_MODE
                LIMIT 1
            ];
            Messaging.EmailFileAttachment att = new Messaging.EmailFileAttachment();
            String ext = String.isNotBlank(cv.FileExtension) ? cv.FileExtension : 'pdf';
            String fname = String.isNotBlank(cv.Title) ? cv.Title : ('BambooHR-Quote-' + qNum);
            if (!fname.toLowerCase().endsWith('.' + ext.toLowerCase())) {
                fname = fname + '.' + ext;
            }
            att.setFileName(fname);
            att.setBody(cv.VersionData);
            att.setContentType(ext.toLowerCase() == 'pdf' ? 'application/pdf' : 'application/octet-stream');
            mail.setFileAttachments(new List<Messaging.EmailFileAttachment>{ att });
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
