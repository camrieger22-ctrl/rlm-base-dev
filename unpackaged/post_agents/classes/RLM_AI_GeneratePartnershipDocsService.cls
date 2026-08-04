/**
 * Invocable: generate Chicago Bears partnership proposal and/or deck for a Quote.
 * Backs Quinn AmendmentStudio → Generate_Partnership_Documents.
 * Resolves DocumentTemplate by name and calls RLM_DocumentGenerationCreate (Advanced).
 */
public with sharing class RLM_AI_GeneratePartnershipDocsService {

    public static final String TEMPLATE_PROPOSAL = 'RLM_Bears_Partnership_Proposal';
    public static final String TEMPLATE_DECK = 'RLM_Bears_Partnership_Deck';

    /** Test seam: when non-null, skips DocumentTemplate SOQL and uses this map (Name → Id). */
    @TestVisible
    private static Map<String, Id> templateIdByNameOverride;

    /** Test seam: when true, skip DocumentGenerationProcess insert. */
    @TestVisible
    private static Boolean skipDocumentCreate = false;

    public class GenerateInput {
        @InvocableVariable(required=true label='Quote Id'
            description='18-character Quote Id (0Q0...) to generate documents for.')
        public String quoteId;

        @InvocableVariable(required=true label='Document Type'
            description='Which documents to generate: proposal, deck, or both.')
        public String documentType;
    }

    public class GenerateOutput {
        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;

        @InvocableVariable(label='Result Display'
            description='Names-only confirmation of queued document generation.')
        public String resultDisplay;

        @InvocableVariable(label='Error Message')
        public String errorMessage;

        public GenerateOutput() {
            this.isSuccess = false;
            this.resultDisplay = '';
            this.errorMessage = '';
        }
    }

    @InvocableMethod(
        label='Generate Partnership Documents'
        description='Queues Advanced OmniStudio DocGen for the Chicago Bears partnership Word proposal and/or PowerPoint deck against the given Quote. Returns a names-only confirmation; files appear on the quote shortly.'
    )
    public static List<GenerateOutput> generate(List<GenerateInput> inputs) {
        List<GenerateOutput> results = new List<GenerateOutput>();
        if (inputs == null || inputs.isEmpty()) {
            return results;
        }
        for (GenerateInput input : inputs) {
            results.add(build(input));
        }
        return results;
    }

    private static GenerateOutput build(GenerateInput input) {
        GenerateOutput out = new GenerateOutput();
        if (input == null || String.isBlank(input.quoteId)) {
            out.errorMessage = 'Quote Id is required.';
            return out;
        }
        Id quoteId = RLM_AI_ConfigServiceUtils.toIdOrNull(input.quoteId);
        if (quoteId == null || !RLM_AI_ConfigServiceUtils.hasPrefix(input.quoteId, RLM_AI_ConfigServiceUtils.QUOTE_PREFIX)) {
            out.errorMessage = 'Invalid quote Id.';
            return out;
        }

        Set<String> wanted = parseDocumentTypes(input.documentType);
        if (wanted.isEmpty()) {
            out.errorMessage =
                'Document type must be proposal, deck, or both.';
            return out;
        }

        List<Quote> quotes = [
            SELECT Id, QuoteNumber, Name
            FROM Quote
            WHERE Id = :quoteId
            WITH USER_MODE
            LIMIT 1
        ];
        if (quotes.isEmpty()) {
            out.errorMessage = 'Quote was not found or is not readable.';
            return out;
        }
        Quote q = quotes[0];

        Map<String, Id> templates = resolveTemplates(wanted);
        List<String> missing = new List<String>();
        for (String name : wanted) {
            if (!templates.containsKey(name) || templates.get(name) == null) {
                missing.add(name);
            }
        }
        if (!missing.isEmpty()) {
            out.errorMessage =
                'Active document template(s) not found: ' + String.join(missing, ', ')
                + '. Ask an admin to deploy and activate the Bears partnership templates.';
            return out;
        }

        List<String> queued = new List<String>();
        try {
            for (String templateName : wanted) {
                Id templateId = templates.get(templateName);
                String title = buildTitle(templateName, q);
                if (skipDocumentCreate == true) {
                    queued.add(labelFor(templateName) + ' ("' + title + '")');
                    continue;
                }
                RLM_DocumentGenerationCreate.Request req = new RLM_DocumentGenerationCreate.Request();
                req.CurrentRecordId = String.valueOf(quoteId);
                req.DocTemplateId = templateId;
                req.DocTitle = title;
                List<RLM_DocumentGenerationCreate.Response> responses =
                    RLM_DocumentGenerationCreate.CreateDocument(
                        new List<RLM_DocumentGenerationCreate.Request>{ req }
                    );
                if (responses == null || responses.isEmpty() || responses[0].NewContentId == null) {
                    out.errorMessage = 'Document generation did not start for ' + labelFor(templateName) + '.';
                    return out;
                }
                queued.add(labelFor(templateName) + ' ("' + title + '")');
            }
        } catch (Exception e) {
            out.errorMessage =
                'Could not start document generation. Try again in a moment or check template setup.';
            return out;
        }

        out.isSuccess = true;
        out.resultDisplay =
            'Queued Advanced DocGen for Quote ' + safe(q.QuoteNumber) + ':\n'
            + '- ' + String.join(queued, '\n- ')
            + '\nFiles will appear on the quote shortly - refresh Files if they are not visible yet.';
        return out;
    }

    private static Set<String> parseDocumentTypes(String raw) {
        Set<String> wanted = new Set<String>();
        if (String.isBlank(raw)) {
            return wanted;
        }
        String normalized = raw.trim().toLowerCase();
        if (normalized == 'both' || normalized == 'all' || normalized == 'proposal and deck') {
            wanted.add(TEMPLATE_PROPOSAL);
            wanted.add(TEMPLATE_DECK);
            return wanted;
        }
        if (normalized == 'proposal' || normalized == 'word' || normalized == 'docx') {
            wanted.add(TEMPLATE_PROPOSAL);
            return wanted;
        }
        if (normalized == 'deck' || normalized == 'ppt' || normalized == 'pptx' || normalized == 'powerpoint') {
            wanted.add(TEMPLATE_DECK);
            return wanted;
        }
        return wanted;
    }

    private static Map<String, Id> resolveTemplates(Set<String> names) {
        if (templateIdByNameOverride != null) {
            Map<String, Id> filtered = new Map<String, Id>();
            for (String name : names) {
                if (templateIdByNameOverride.containsKey(name)) {
                    filtered.put(name, templateIdByNameOverride.get(name));
                }
            }
            return filtered;
        }
        Map<String, Id> byName = new Map<String, Id>();
        for (DocumentTemplate dt : [
            SELECT Id, Name, VersionNumber
            FROM DocumentTemplate
            WHERE Name IN :names
              AND Status = 'Active'
            WITH USER_MODE
            ORDER BY Name ASC, VersionNumber DESC
        ]) {
            if (!byName.containsKey(dt.Name)) {
                byName.put(dt.Name, dt.Id);
            }
        }
        return byName;
    }

    private static String buildTitle(String templateName, Quote q) {
        String quoteLabel = String.isNotBlank(q.QuoteNumber) ? q.QuoteNumber : 'Quote';
        if (templateName == TEMPLATE_DECK) {
            return 'Bears Partnership Deck - ' + quoteLabel;
        }
        return 'Bears Partnership Proposal - ' + quoteLabel;
    }

    private static String labelFor(String templateName) {
        if (templateName == TEMPLATE_DECK) {
            return 'PowerPoint deck';
        }
        return 'Word proposal';
    }

    private static String safe(String value) {
        return String.isBlank(value) ? '' : value;
    }
}
