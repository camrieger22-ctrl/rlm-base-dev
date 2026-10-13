/**
 * Hosted MCP: draft an unsent customer email from parent quote lines.
 * Body is customer-safe (no Lightning URLs). AE links stay on coachDisplay.
 * Never send mail.
 */
global with sharing class RLM_MCP_DraftCustomerReply {
    private static final List<String> MONTHS = new List<String>{
        'January', 'February', 'March', 'April', 'May', 'June',
        'July', 'August', 'September', 'October', 'November', 'December'
    };

    global class ReplyInput {
        @InvocableVariable(label='Quote Id')
        global String quoteId;
        @InvocableVariable(label='Quote Name')
        global String quoteName;
        @InvocableVariable(label='Account Name')
        global String accountName;
        @InvocableVariable(
            label='Purpose'
            description='Optional. Ignored in the customer body. Does not send.'
        )
        global String purpose;
    }

    global class ReplyOutput {
        @InvocableVariable(label='Is Success')
        global Boolean isSuccess;
        @InvocableVariable(label='Subject')
        global String subject;
        @InvocableVariable(
            label='Body Display'
            description='Customer email body. Put this in Gmail draft/create verbatim. No Salesforce URLs.'
        )
        global String bodyDisplay;
        @InvocableVariable(
            label='Coach Display'
            description='Rep-only. Render in Claude chat. Do not put these Lightning links in the Gmail body.'
        )
        global String coachDisplay;
        @InvocableVariable(label='Public Pdf Url')
        global String publicPdfUrl;
        @InvocableVariable(label='Quote Url')
        global String quoteUrl;
        @InvocableVariable(label='Pdf Url')
        global String pdfUrl;
        @InvocableVariable(label='Needs Disambiguation')
        global Boolean needsDisambiguation;
        @InvocableVariable(label='Candidate Summaries Display')
        global String candidateSummariesDisplay;
        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    @InvocableMethod(
        label='Draft Revenue Cloud Customer Reply'
        description='Drafts a short unsent HTML customer email from parent lines. Includes a customer-safe proposal PDF link from the latest file on the quote. To add that link to an existing Gmail draft, call this once and patch the draft. Do not preview. Never send.'
    )
    global static List<ReplyOutput> draft(List<ReplyInput> inputs) {
        List<ReplyOutput> results = new List<ReplyOutput>();
        if (inputs == null || inputs.isEmpty()) {
            return results;
        }
        for (ReplyInput input : inputs) {
            results.add(draftOne(input));
        }
        return results;
    }

    private static ReplyOutput draftOne(ReplyInput input) {
        ReplyOutput out = new ReplyOutput();
        out.isSuccess = false;
        out.needsDisambiguation = false;
        try {
            if (input == null
                || (String.isBlank(input.quoteId)
                    && String.isBlank(input.quoteName)
                    && String.isBlank(input.accountName))
            ) {
                out.errorMessage = 'Provide quoteId, quoteName, or accountName.';
                return out;
            }
            Quote quote = resolveQuote(input, out);
            if (quote == null && String.isNotBlank(out.errorMessage)) {
                return out;
            }
            String accountName = quote == null || quote.Account == null
                ? blankToNull(input.accountName)
                : quote.Account.Name;
            String firstName = (quote != null && quote.Contact != null)
                ? blankToNull(quote.Contact.FirstName)
                : null;
            Integer termMonths = termMonthsOf(quote);
            List<QuoteLineItem> parents = new List<QuoteLineItem>();
            Map<Id, Decimal> parentAmounts = new Map<Id, Decimal>();
            Decimal discountPct = null;
            if (quote != null) {
                List<QuoteLineItem> allLines = [
                    SELECT Id, Quantity, Discount, TotalPrice, NetTotalPrice,
                           Product2.Name, ParentQuoteLineItemId
                    FROM QuoteLineItem
                    WHERE QuoteId = :quote.Id
                    ORDER BY LineNumber NULLS LAST, CreatedDate
                    LIMIT 200
                ];
                Map<Id, Decimal> childExtra = new Map<Id, Decimal>();
                for (QuoteLineItem line : allLines) {
                    if (line.ParentQuoteLineItemId == null) {
                        if (parents.size() < 20) {
                            parents.add(line);
                        }
                    } else {
                        addAmount(childExtra, line.ParentQuoteLineItemId, lineAmount(line));
                    }
                }
                for (QuoteLineItem parent : parents) {
                    parentAmounts.put(
                        parent.Id,
                        lineAmount(parent) + nvl(childExtra.get(parent.Id))
                    );
                }
                discountPct = commonLineDiscount(parents);
                out.quoteUrl = RLM_MCP_RecordLinks.lightningUrl('Quote', quote.Id);
                ContentVersion pdf = latestPdfOnQuote(quote.Id);
                if (pdf != null) {
                    out.pdfUrl = RLM_MCP_RecordLinks.lightningUrl(
                        'ContentDocument', pdf.ContentDocumentId
                    );
                    out.publicPdfUrl = publicUrlFor(pdf, quote);
                }
            }

            out.subject = customerSubject(accountName, termMonths);
            out.bodyDisplay = customerBody(
                firstName,
                accountName,
                quote,
                termMonths,
                discountPct,
                parents,
                parentAmounts,
                out.publicPdfUrl
            );
            out.coachDisplay = coachBody(quote, out.quoteUrl, out.pdfUrl, out.publicPdfUrl);
            out.isSuccess = true;
        } catch (Exception e) {
            out.isSuccess = false;
            out.errorMessage = e.getMessage() == null ? 'Draft failed.' : e.getMessage();
        }
        return out;
    }

    private static String customerSubject(String accountName, Integer termMonths) {
        String who = String.isBlank(accountName) ? 'Your' : accountName;
        if (termMonths != null && termMonths > 0) {
            return who + ' — ' + String.valueOf(termMonths) + '-month proposal';
        }
        return who + ' — proposal';
    }

    private static String customerBody(
        String firstName,
        String accountName,
        Quote quote,
        Integer termMonths,
        Decimal discountPct,
        List<QuoteLineItem> parents,
        Map<Id, Decimal> parentAmounts,
        String publicPdfUrl
    ) {
        List<String> body = new List<String>();
        body.add(htmlP(String.isBlank(firstName) ? 'Hi,' : 'Hi ' + firstName + ','));
        String who = String.isBlank(accountName) ? 'your account' : accountName;
        String opener = 'Thank you for the conversation. Here is the updated';
        if (termMonths != null && termMonths > 0) {
            opener += ' ' + String.valueOf(termMonths) + '-month';
        }
        opener += ' proposal for ' + who;
        if (discountPct != null && discountPct > 0) {
            opener += ', with '
                + RLM_MCP_RecordLinks.formatNumber(discountPct)
                + '% applied to the subscription lines';
        }
        opener += '.';
        body.add(htmlP(opener));
        if (quote != null && (quote.StartDate != null || quote.EndDate != null)) {
            body.add(htmlP('Term: ' + humanRange(quote.StartDate, quote.EndDate)));
        }
        if (parents != null && !parents.isEmpty()) {
            body.add(htmlP('Included:'));
            body.add('<ul>');
            for (QuoteLineItem line : parents) {
                String name = line.Product2 == null ? 'Line' : line.Product2.Name;
                String row = htmlEscape(name)
                    + ' ('
                    + RLM_MCP_RecordLinks.formatNumber(line.Quantity)
                    + ')';
                Decimal amt = parentAmounts == null ? null : parentAmounts.get(line.Id);
                if (amt != null && amt > 0) {
                    row += ' — ' + dollars(amt);
                }
                body.add('<li>' + row + '</li>');
            }
            body.add('</ul>');
        }
        if (quote != null && quote.GrandTotal != null && quote.GrandTotal > 0) {
            body.add(htmlP('Investment: ' + dollars(quote.GrandTotal)));
        }
        if (String.isNotBlank(publicPdfUrl)) {
            body.add(
                '<p>The full line detail is in the '
                + htmlLink(publicPdfUrl, 'proposal PDF')
                + '.</p>'
            );
        } else {
            body.add(htmlP('The full line detail is in the proposal PDF (attached).'));
        }
        body.add(htmlP('If quantities or term should change, reply here and we will revise.'));
        body.add('<p>Best regards,<br/>' + htmlEscape(UserInfo.getName()) + '</p>');
        return String.join(body, '\n');
    }

    private static String coachBody(
        Quote quote,
        String quoteUrl,
        String pdfUrl,
        String publicPdfUrl
    ) {
        List<String> rows = new List<String>{
            'This email has not been sent. Put subject + bodyDisplay in a new Gmail draft/create verbatim.',
            'bodyDisplay is HTML. Prefer Gmail html / body_html / isHtml. Keep the proposal PDF <a href> — do not paste the raw URL.',
            'Do not put Salesforce Lightning links in the customer email. The customer cannot open them.',
            'If they asked to add a PDF link to an existing Gmail draft: put bodyDisplay (or the proposal PDF <a href>) into that draft. Do not preview. Do not create a second draft. Do not explain.',
            'Preview only when they asked to generate a new proposal PDF or the customer pack, and no PDF exists on the quote.',
            'If Gmail can attach a file, attach the proposal PDF. Otherwise tell the user to attach it from Open PDF and leave the draft unsent.',
            'Never send_message or Gmail/Outlook send.'
        };
        if (String.isNotBlank(quoteUrl)) {
            rows.add('[Open Quote](' + quoteUrl + ')');
        }
        if (String.isNotBlank(pdfUrl)) {
            rows.add('[Open PDF](' + pdfUrl + ')');
        }
        if (String.isNotBlank(publicPdfUrl)) {
            rows.add('Public proposal link (customer-safe): ' + publicPdfUrl);
        }
        return String.join(rows, '\n');
    }

    private static Decimal commonLineDiscount(List<QuoteLineItem> lines) {
        if (lines == null || lines.isEmpty()) {
            return null;
        }
        Decimal first = null;
        for (QuoteLineItem line : lines) {
            if (line.Discount == null || line.Discount <= 0) {
                continue;
            }
            if (first == null) {
                first = line.Discount;
            } else if (first != line.Discount) {
                return first;
            }
        }
        return first;
    }

    private static Integer termMonthsOf(Quote quote) {
        if (quote == null || quote.StartDate == null || quote.EndDate == null) {
            return null;
        }
        Integer months = quote.StartDate.monthsBetween(quote.EndDate);
        return months <= 0 ? null : months;
    }

    private static String humanRange(Date startDate, Date endDate) {
        if (startDate == null && endDate == null) {
            return '';
        }
        if (startDate == null) {
            return humanDate(endDate);
        }
        if (endDate == null) {
            return humanDate(startDate);
        }
        return humanDate(startDate) + ' – ' + humanDate(endDate);
    }

    private static String humanDate(Date value) {
        if (value == null) {
            return '';
        }
        return MONTHS[value.month() - 1]
            + ' '
            + String.valueOf(value.day())
            + ', '
            + String.valueOf(value.year());
    }

    private static Decimal lineAmount(QuoteLineItem line) {
        if (line == null) {
            return 0;
        }
        if (line.NetTotalPrice != null) {
            return line.NetTotalPrice;
        }
        return line.TotalPrice == null ? 0 : line.TotalPrice;
    }

    private static void addAmount(Map<Id, Decimal> byId, Id key, Decimal amount) {
        if (key == null) {
            return;
        }
        byId.put(key, nvl(byId.get(key)) + nvl(amount));
    }

    private static Decimal nvl(Decimal value) {
        return value == null ? 0 : value;
    }

    private static String htmlP(String text) {
        return '<p>' + htmlEscape(text) + '</p>';
    }

    private static String htmlLink(String url, String label) {
        return '<a href="' + htmlEscape(url) + '">' + htmlEscape(label) + '</a>';
    }

    private static String htmlEscape(String value) {
        return value == null ? '' : value.escapeHtml4();
    }

    private static String dollars(Decimal value) {
        Decimal n = value == null ? 0 : value.setScale(0, System.RoundingMode.HALF_UP);
        return '$' + n.format();
    }

    private static ContentVersion latestPdfOnQuote(Id quoteId) {
        if (quoteId == null) {
            return null;
        }
        List<ContentDocumentLink> links = [
            SELECT ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :quoteId
            ORDER BY SystemModstamp DESC
            LIMIT 20
        ];
        if (links.isEmpty()) {
            return null;
        }
        Set<Id> docIds = new Set<Id>();
        for (ContentDocumentLink link : links) {
            docIds.add(link.ContentDocumentId);
        }
        List<ContentVersion> pdfs = [
            SELECT Id, ContentDocumentId, FileType, Title, CreatedDate
            FROM ContentVersion
            WHERE ContentDocumentId IN :docIds
            AND IsLatest = true
            AND FileType = 'PDF'
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        return pdfs.isEmpty() ? null : pdfs[0];
    }

    public static String publicUrlFor(ContentVersion pdf, Quote quote) {
        if (pdf == null) {
            return null;
        }
        List<ContentDistribution> existing = [
            SELECT DistributionPublicUrl
            FROM ContentDistribution
            WHERE ContentVersionId = :pdf.Id
            ORDER BY CreatedDate DESC
            LIMIT 5
        ];
        for (ContentDistribution row : existing) {
            if (String.isNotBlank(row.DistributionPublicUrl)) {
                return row.DistributionPublicUrl;
            }
        }
        try {
            String title = (quote != null && String.isNotBlank(quote.Name))
                ? quote.Name
                : 'Proposal';
            if (title.length() > 80) {
                title = title.substring(0, 80);
            }
            ContentDistribution dist = new ContentDistribution(
                Name = title + ' PDF',
                ContentVersionId = pdf.Id,
                PreferencesAllowViewInBrowser = true,
                PreferencesAllowOriginalDownload = true,
                PreferencesNotifyOnVisit = false,
                PreferencesLinkLatestVersion = true
            );
            insert dist;
            List<ContentDistribution> created = [
                SELECT DistributionPublicUrl
                FROM ContentDistribution
                WHERE Id = :dist.Id
                LIMIT 1
            ];
            if (created.isEmpty() || String.isBlank(created[0].DistributionPublicUrl)) {
                return null;
            }
            return created[0].DistributionPublicUrl;
        } catch (Exception e) {
            return null;
        }
    }

    private static Quote resolveQuote(ReplyInput input, ReplyOutput out) {
        if (String.isNotBlank(input.quoteId)) {
            try {
                Id qid = Id.valueOf(input.quoteId.trim());
                List<Quote> byId = [
                    SELECT Id, Name, QuoteNumber, GrandTotal, StartDate, EndDate,
                           LastModifiedDate,
                           AccountId, Account.Name, ContactId, Contact.FirstName
                    FROM Quote
                    WHERE Id = :qid
                    LIMIT 1
                ];
                if (byId.isEmpty()) {
                    out.errorMessage = 'No quote found for that Id.';
                    return null;
                }
                return byId[0];
            } catch (Exception e) {
                out.errorMessage = 'Invalid quote Id.';
                return null;
            }
        }
        String nameTerm = blankToNull(input.quoteName);
        String acctTerm = blankToNull(input.accountName);
        if (nameTerm == null && acctTerm == null) {
            return null;
        }
        String np = nameTerm == null ? null : '%' + nameTerm + '%';
        String ap = acctTerm == null ? null : '%' + acctTerm + '%';
        List<Quote> matches;
        if (np != null && ap != null) {
            matches = [
                    SELECT Id, Name, QuoteNumber, GrandTotal, StartDate, EndDate,
                           LastModifiedDate,
                           AccountId, Account.Name, ContactId, Contact.FirstName
                FROM Quote
                WHERE Name LIKE :np AND Account.Name LIKE :ap
                ORDER BY LastModifiedDate DESC
                LIMIT 8
            ];
        } else if (np != null) {
            matches = [
                    SELECT Id, Name, QuoteNumber, GrandTotal, StartDate, EndDate,
                           LastModifiedDate,
                           AccountId, Account.Name, ContactId, Contact.FirstName
                FROM Quote
                WHERE Name LIKE :np
                ORDER BY LastModifiedDate DESC
                LIMIT 8
            ];
        } else {
            matches = [
                    SELECT Id, Name, QuoteNumber, GrandTotal, StartDate, EndDate,
                           LastModifiedDate,
                           AccountId, Account.Name, ContactId, Contact.FirstName
                FROM Quote
                WHERE Account.Name LIKE :ap
                ORDER BY LastModifiedDate DESC
                LIMIT 8
            ];
        }
        if (matches.isEmpty()) {
            return null;
        }
        if (matches.size() == 1) {
            return matches[0];
        }
        out.needsDisambiguation = true;
        List<String> rows = new List<String>{ 'Multiple quotes match. Which one should the reply use?' };
        Integer n = 1;
        for (Quote q : matches) {
            rows.add(String.valueOf(n) + '. ' + q.Name);
            n++;
        }
        out.candidateSummariesDisplay = String.join(rows, '\n');
        out.errorMessage = 'Multiple quotes match. Ask the user which one.';
        return null;
    }

    private static String blankToNull(String value) {
        return String.isBlank(value) ? null : value.trim();
    }
}
