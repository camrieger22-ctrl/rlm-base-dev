/**
 * Hosted MCP: preview the Quote Proposal PDF via Document Generation
 * (same path as Preview PDF on the quote). Defaults to RLM_QuoteProposal.
 * Generation is async — return isPartial until the PDF exists.
 */
global with sharing class RLM_MCP_PreviewQuoteDocument {
    private static final Integer MAX_CANDIDATES = 50;
    private static final String DEFAULT_TEMPLATE = 'RLM_QuoteProposal';
    private static final Set<String> IN_FLIGHT = new Set<String>{ 'InProgress', 'Waiting' };

    global class PreviewInput {
        @InvocableVariable(
            label='Quote Id'
            description='Optional 18-character Quote Id (starts with 0Q0). Takes precedence over names.'
        )
        global String quoteId;

        @InvocableVariable(
            label='Quote Name'
            description='Quote name, quote number (e.g. 00000505), or fragment. Also matched against the account name.'
        )
        global String quoteName;

        @InvocableVariable(
            label='Account Name'
            description='Optional account name to narrow the search, e.g. Acme.'
        )
        global String accountName;

        @InvocableVariable(
            label='Template Name'
            description='Optional DocumentTemplate name. Defaults to RLM_QuoteProposal. Must be Active.'
        )
        global String templateName;

        @InvocableVariable(
            label='Document Generation Process Id'
            description='Pass back documentGenerationProcessId when isPartial is true so the same run is polled.'
        )
        global String documentGenerationProcessId;
    }

    global class PreviewOutput {
        @InvocableVariable(label='Is Success')
        global Boolean isSuccess;
        @InvocableVariable(
            label='Is Partial'
            description='True when the PDF is still generating. Immediately call this tool again with quoteId and documentGenerationProcessId. Do not write a wait message to the user.'
        )
        global Boolean isPartial;
        @InvocableVariable(label='Message')
        global String message;
        @InvocableVariable(label='Quote Id')
        global String quoteId;
        @InvocableVariable(label='Quote Name')
        global String quoteName;
        @InvocableVariable(
            label='Quote Url'
            description='Lightning Quote page. Render as [Open Quote](quoteUrl) in the chat reply.'
        )
        global String quoteUrl;
        @InvocableVariable(label='Template Name')
        global String templateName;
        @InvocableVariable(label='Document Generation Process Id')
        global String documentGenerationProcessId;
        @InvocableVariable(label='Content Document Id')
        global String contentDocumentId;
        @InvocableVariable(label='Content Version Id')
        global String contentVersionId;
        @InvocableVariable(
            label='Pdf Url'
            description='Lightning Files page for the PDF. Render as [Open PDF](pdfUrl) in the chat reply.'
        )
        global String pdfUrl;
        @InvocableVariable(label='Needs Disambiguation')
        global Boolean needsDisambiguation;
        @InvocableVariable(label='Candidate Summaries Display')
        global String candidateSummariesDisplay;
        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    public class StartResult {
        public Id processId;
        public String errorMessage;
        public StartResult(Id processId, String errorMessage) {
            this.processId = processId;
            this.errorMessage = errorMessage;
        }
    }

    public interface ProcessStarter {
        StartResult start(Id quoteId, Id templateId, String title);
    }

    public class DefaultProcessStarter implements ProcessStarter {
        public StartResult start(Id quoteId, Id templateId, String title) {
            RLM_DocumentGenerationCreate.Request req = new RLM_DocumentGenerationCreate.Request();
            req.CurrentRecordId = quoteId;
            req.DocTemplateId = templateId;
            req.DocTitle = title;
            List<RLM_DocumentGenerationCreate.Response> responses =
                RLM_DocumentGenerationCreate.CreateDocument(
                    new List<RLM_DocumentGenerationCreate.Request>{ req }
                );
            if (responses == null || responses.isEmpty() || responses[0].NewContentId == null) {
                return new StartResult(null, 'Document generation did not start.');
            }
            return new StartResult(responses[0].NewContentId, null);
        }
    }

    @TestVisible
    private static ProcessStarter starter = new DefaultProcessStarter();

    @InvocableMethod(
        label='Preview Revenue Cloud Quote Document'
        description='Generates the Quote Proposal PDF (RLM_QuoteProposal). Reuses the last PDF when the quote is unchanged. If isPartial, immediately call again with quoteId and documentGenerationProcessId; do not reply to the user. Never insert ContentVersion rows yourself.'
    )
    global static List<PreviewOutput> preview(List<PreviewInput> inputs) {
        List<PreviewOutput> results = new List<PreviewOutput>();
        if (inputs == null || inputs.isEmpty()) {
            return results;
        }
        for (PreviewInput input : inputs) {
            results.add(previewOne(input));
        }
        return results;
    }

    private static PreviewOutput previewOne(PreviewInput input) {
        PreviewOutput out = new PreviewOutput();
        out.isSuccess = false;
        out.isPartial = false;
        out.needsDisambiguation = false;
        try {
            if (input == null) {
                out.errorMessage = 'Provide a quote name, quote number, account name, or Quote Id.';
                return out;
            }
            Quote q = resolveQuote(input, out);
            if (q == null) {
                return out;
            }
            out.quoteId = q.Id;
            out.quoteName = q.Name;
            out.quoteUrl = RLM_MCP_RecordLinks.lightningUrl('Quote', q.Id);

            String wanted = String.isBlank(input.templateName)
                ? DEFAULT_TEMPLATE
                : input.templateName.trim();
            DocumentTemplate template = resolveTemplate(wanted, out);
            if (template == null) {
                return out;
            }
            out.templateName = template.Name;

            if (q.LineItemCount == null || q.LineItemCount == 0) {
                out.errorMessage = 'Quote ' + q.Name + ' has no lines. Add a product before generating a document.';
                return out;
            }

            Id processId = existingProcessId(input.documentGenerationProcessId, q, template.Id);
            if (processId == null) {
                String title = q.Name + ' - ' + template.Name;
                StartResult started = starter.start(q.Id, template.Id, title);
                if (started == null || started.processId == null) {
                    out.errorMessage = started != null && String.isNotBlank(started.errorMessage)
                        ? started.errorMessage
                        : 'Document generation did not start.';
                    return out;
                }
                // The engine runs after this transaction commits, so a same-txn
                // poll cannot see Success. Return isPartial for the next call.
                out.documentGenerationProcessId = started.processId;
                out.isPartial = true;
                out.isSuccess = true;
                out.message = retryNowMessage(q.Id, started.processId, template.Name, q.Name);
                return out;
            }
            out.documentGenerationProcessId = processId;

            List<DocumentGenerationProcess> processes = [
                SELECT Id, Status, ResponseText, ReferenceObject
                FROM DocumentGenerationProcess
                WHERE Id = :processId
                LIMIT 1
            ];
            if (processes.isEmpty()) {
                out.errorMessage = 'Document generation process ' + processId + ' was not found.';
                return out;
            }
            DocumentGenerationProcess dgp = processes[0];
            String status = String.valueOf(dgp.Status);
            if (IN_FLIGHT.contains(status)) {
                out.isPartial = true;
                out.isSuccess = true;
                out.message = retryNowMessage(q.Id, processId, template.Name, q.Name);
                return out;
            }
            if (status == 'Failure' || status == 'Blocked') {
                out.errorMessage = 'Document generation '
                    + status.toLowerCase()
                    + (String.isBlank(dgp.ResponseText) ? '.' : ': ' + dgp.ResponseText);
                return out;
            }
            if (status != 'Success') {
                out.isPartial = true;
                out.isSuccess = true;
                out.message = retryNowMessage(q.Id, processId, template.Name, q.Name);
                return out;
            }

            ContentVersion pdf = pdfFromResponse(dgp.ResponseText);
            if (pdf == null) {
                out.isPartial = true;
                out.isSuccess = true;
                out.message = retryNowMessage(q.Id, processId, template.Name, q.Name);
                return out;
            }
            out.contentDocumentId = pdf.ContentDocumentId;
            out.contentVersionId = pdf.Id;
            out.pdfUrl = RLM_MCP_RecordLinks.lightningUrl('ContentDocument', pdf.ContentDocumentId);
            out.isSuccess = true;
            List<String> bits = new List<String>();
            String pdfLink = RLM_MCP_RecordLinks.markdown('Open PDF', 'ContentDocument', pdf.ContentDocumentId);
            String quoteLink = RLM_MCP_RecordLinks.markdown('Open Quote', 'Quote', q.Id);
            if (String.isNotBlank(pdfLink)) {
                bits.add(pdfLink);
            }
            if (String.isNotBlank(quoteLink)) {
                bits.add(quoteLink);
            }
            out.message = 'Preview of **'
                + template.Name
                + '** for **'
                + q.Name
                + '** is ready.\n'
                + String.join(bits, '\n');
        } catch (Exception e) {
            out.isSuccess = false;
            out.isPartial = false;
            String msg = e.getMessage();
            out.errorMessage = e.getTypeName() + ': '
                + (String.isBlank(msg) ? '(no message)' : msg);
        }
        return out;
    }

    private static String retryNowMessage(Id quoteId, Id processId, String templateName, String quoteName) {
        return 'RETRY_NOW. Do not reply to the user. Immediately call previewRevenueCloudQuoteDocument with quoteId='
            + quoteId
            + ' and documentGenerationProcessId='
            + processId
            + ' (template '
            + templateName
            + ' for '
            + quoteName
            + ').';
    }

    private static Id existingProcessId(String rawProcessId, Quote q, Id templateId) {
        if (String.isNotBlank(rawProcessId)) {
            Id parsed = RLM_MCP_RecordLinks.toId(rawProcessId);
            if (parsed == null) {
                return null;
            }
            List<DocumentGenerationProcess> byId = [
                SELECT Id
                FROM DocumentGenerationProcess
                WHERE Id = :parsed
                LIMIT 1
            ];
            return byId.isEmpty() ? null : byId[0].Id;
        }
        String quoteKey = String.valueOf(q.Id);
        List<DocumentGenerationProcess> openJobs = [
            SELECT Id
            FROM DocumentGenerationProcess
            WHERE ReferenceObject = :quoteKey
            AND DocumentTemplateId = :templateId
            AND Status IN :IN_FLIGHT
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (!openJobs.isEmpty()) {
            return openJobs[0].Id;
        }
        List<DocumentGenerationProcess> doneJobs = [
            SELECT Id, LastModifiedDate, ResponseText
            FROM DocumentGenerationProcess
            WHERE ReferenceObject = :quoteKey
            AND DocumentTemplateId = :templateId
            AND Status = 'Success'
            ORDER BY LastModifiedDate DESC
            LIMIT 1
        ];
        if (doneJobs.isEmpty()) {
            return null;
        }
        DocumentGenerationProcess done = doneJobs[0];
        if (q.LastModifiedDate != null && done.LastModifiedDate < q.LastModifiedDate) {
            return null;
        }
        if (pdfFromResponse(done.ResponseText) == null) {
            return null;
        }
        return done.Id;
    }

    private static ContentVersion pdfFromResponse(String responseText) {
        if (String.isBlank(responseText)) {
            return null;
        }
        Set<Id> versionIds = new Set<Id>();
        for (String token : responseText.split(',')) {
            String trimmed = token.trim();
            if (String.isBlank(trimmed)) {
                continue;
            }
            Id parsed = RLM_MCP_RecordLinks.toId(trimmed);
            if (parsed != null) {
                versionIds.add(parsed);
            }
        }
        if (versionIds.isEmpty()) {
            return null;
        }
        List<ContentVersion> pdfs = [
            SELECT Id, FileType, ContentDocumentId
            FROM ContentVersion
            WHERE Id IN :versionIds AND FileType = 'PDF'
            LIMIT 1
        ];
        if (!pdfs.isEmpty()) {
            return pdfs[0];
        }
        List<ContentVersion> anyVersion = [
            SELECT Id, FileType, ContentDocumentId
            FROM ContentVersion
            WHERE Id IN :versionIds
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        return anyVersion.isEmpty() ? null : anyVersion[0];
    }

    private static DocumentTemplate resolveTemplate(String wanted, PreviewOutput out) {
        List<DocumentTemplate> exact = [
            SELECT Id, Name, Status, IsActive
            FROM DocumentTemplate
            WHERE Name = :wanted
            ORDER BY LastModifiedDate DESC
            LIMIT 5
        ];
        DocumentTemplate active;
        DocumentTemplate anyMatch;
        for (DocumentTemplate dt : exact) {
            if (anyMatch == null) {
                anyMatch = dt;
            }
            if (dt.IsActive == true && (dt.Status == null || dt.Status == 'Active')) {
                active = dt;
                break;
            }
        }
        if (active != null) {
            return active;
        }
        if (anyMatch != null) {
            out.errorMessage = 'Document template **'
                + anyMatch.Name
                + '** is not Active (Status='
                + anyMatch.Status
                + '). Activate it or use **'
                + DEFAULT_TEMPLATE
                + '**.';
            return null;
        }
        out.errorMessage = 'No document template named "'
            + wanted
            + '". Default is **'
            + DEFAULT_TEMPLATE
            + '**.';
        return null;
    }

    private static Quote resolveQuote(PreviewInput input, PreviewOutput out) {
        if (String.isNotBlank(input.quoteId)) {
            Id qid = toQuoteId(input.quoteId);
            if (qid == null) {
                out.errorMessage = 'Invalid Quote Id: ' + input.quoteId;
                return null;
            }
            List<Quote> byId = [
                SELECT Id, Name, QuoteNumber, Status, LineItemCount, GrandTotal,
                       LastModifiedDate, Account.Name
                FROM Quote
                WHERE Id = :qid
                LIMIT 1
            ];
            if (byId.isEmpty()) {
                out.errorMessage = 'No quote found for Id ' + qid + '.';
                return null;
            }
            return byId[0];
        }

        String nameTerm = String.isBlank(input.quoteName) ? null : input.quoteName.trim();
        String acctTerm = String.isBlank(input.accountName) ? null : input.accountName.trim();
        if (nameTerm == null && acctTerm == null) {
            out.errorMessage = 'Provide a quote name, quote number, account name, or Quote Id.';
            return null;
        }

        List<Quote> matches = findQuotes(nameTerm, acctTerm);
        if (matches.isEmpty()) {
            out.errorMessage = 'No quote found matching "'
                + (nameTerm != null ? nameTerm : acctTerm) + '".';
            return null;
        }
        if (nameTerm != null) {
            List<Quote> exact = new List<Quote>();
            for (Quote m : matches) {
                if (m.Name != null && m.Name.equalsIgnoreCase(nameTerm)) {
                    exact.add(m);
                } else if (m.QuoteNumber != null && m.QuoteNumber.equalsIgnoreCase(nameTerm)) {
                    exact.add(m);
                }
            }
            if (exact.size() == 1) {
                return exact[0];
            }
        }
        List<Quote> withLines = new List<Quote>();
        for (Quote m : matches) {
            if (m.LineItemCount != null && m.LineItemCount > 0) {
                withLines.add(m);
            }
        }
        if (withLines.isEmpty()) {
            out.errorMessage = 'Matching quotes have no lines. Add a product before generating a document.';
            return null;
        }
        if (withLines.size() == 1) {
            return withLines[0];
        }
        out.needsDisambiguation = true;
        out.candidateSummariesDisplay = buildCandidateDisplay(withLines);
        out.errorMessage = 'Multiple quotes match. Ask the user which one to preview.';
        return null;
    }

    private static List<Quote> findQuotes(String nameTerm, String acctTerm) {
        String np = nameTerm == null ? null : '%' + nameTerm + '%';
        String ap = acctTerm == null ? null : '%' + acctTerm + '%';
        if (np != null && ap != null) {
            return [
                SELECT Id, Name, QuoteNumber, Status, LineItemCount, GrandTotal,
                       LastModifiedDate, Account.Name
                FROM Quote
                WHERE (Name LIKE :np OR QuoteNumber LIKE :np OR Account.Name LIKE :np)
                AND Account.Name LIKE :ap
                ORDER BY LastModifiedDate DESC
                LIMIT :MAX_CANDIDATES
            ];
        }
        if (np != null) {
            return [
                SELECT Id, Name, QuoteNumber, Status, LineItemCount, GrandTotal,
                       LastModifiedDate, Account.Name
                FROM Quote
                WHERE Name LIKE :np OR QuoteNumber LIKE :np OR Account.Name LIKE :np
                ORDER BY LastModifiedDate DESC
                LIMIT :MAX_CANDIDATES
            ];
        }
        return [
            SELECT Id, Name, QuoteNumber, Status, LineItemCount, GrandTotal,
                   LastModifiedDate, Account.Name
            FROM Quote
            WHERE Account.Name LIKE :ap
            ORDER BY LastModifiedDate DESC
            LIMIT :MAX_CANDIDATES
        ];
    }

    private static String buildCandidateDisplay(List<Quote> quotes) {
        List<String> lines = new List<String>();
        lines.add('Multiple quotes match. Which one should I preview?');
        Integer ordinal = 1;
        for (Quote q : quotes) {
            String line = ordinal + '. **' + q.Name + '**';
            if (String.isNotBlank(q.QuoteNumber)) {
                line += ' (' + q.QuoteNumber + ')';
            }
            if (q.Account != null && String.isNotBlank(q.Account.Name)) {
                line += ' · ' + q.Account.Name;
            }
            String quoteLink = RLM_MCP_RecordLinks.markdown('Open', 'Quote', q.Id);
            if (String.isNotBlank(quoteLink)) {
                line += ' · ' + quoteLink;
            }
            lines.add(line);
            ordinal++;
        }
        return String.join(lines, '\n');
    }

    private static Id toQuoteId(String raw) {
        try {
            Id parsed = Id.valueOf(raw.trim());
            return parsed.getSObjectType() == Quote.SObjectType ? parsed : null;
        } catch (Exception e) {
            return null;
        }
    }
}
