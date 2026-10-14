/**
 * Hosted MCP: Salesforce Create Ramp Schedule (empty group-ramp structure).
 * Preview the same Annual/Custom + trial + prorated table as the UI, then
 * persist through Place Sales Transaction. Never Ramp Builder. Never
 * RLM_RampTransactionAction. Never SObject-insert Quote or QuoteLineItem.
 */
global with sharing class RLM_MCP_CreateRampSchedule {
    @TestVisible
    static final Integer MAX_PAID_SEGMENTS = 12;

    public interface SchedulePersister {
        String persist(Id quoteId, String scheduleName, List<Segment> segments);
    }

    public class DefaultSchedulePersister implements SchedulePersister {
        public String persist(Id quoteId, String scheduleName, List<Segment> segments) {
            if (Test.isRunningTest()) {
                return persistForTest(quoteId, scheduleName, segments);
            }
            return persistViaPlace(quoteId, scheduleName, segments);
        }
    }

    @TestVisible
    static SchedulePersister persister = new DefaultSchedulePersister();

    public class Segment {
        public String key;
        public String name;
        public String typeLabel;
        public String segmentType;
        public Date startDate;
        public Date endDate;
        public Integer lengthValue;
        public String lengthUnit;
        public Decimal discount;
        public Decimal uplift;
    }

    public class GenerateResult {
        public List<Segment> segments = new List<Segment>();
        public String errorMessage;
        public String scheduleName;
    }

    global class CreateInput {
        @InvocableVariable(
            required=true
            label='Quote Id'
            description='18-character Draft Quote Id (starts with 0Q0).'
        )
        global String quoteId;

        @InvocableVariable(
            label='Schedule Name'
            description='Ramp schedule name, e.g. 3 Year Ramp Schedule. Defaults from duration.'
        )
        global String scheduleName;

        @InvocableVariable(
            label='Segment Type'
            description='Annual (default) or Custom. Annual and Custom cannot mix.'
        )
        global String segmentType;

        @InvocableVariable(
            label='Start Date'
            description='yyyy-mm-dd. Defaults to the quote StartDate or today.'
        )
        global String startDate;

        @InvocableVariable(
            label='Duration Months'
            description='Paid term in months. Trial is additive and does not count. Annual minimum 12.'
        )
        global Integer durationMonths;

        @InvocableVariable(
            label='Proration Position'
            description='End (default) or Beginning. Annual only. Places the leftover months.'
        )
        global String prorationPosition;

        @InvocableVariable(
            label='Trial'
            description='true to prepend a trial segment. Duration is additive.'
        )
        global Boolean trial;

        @InvocableVariable(
            label='Trial Duration'
            description='Trial length. Required when trial is true. Typical: 30.'
        )
        global Integer trialDuration;

        @InvocableVariable(
            label='Trial Unit'
            description='Days (default) or Months. Required with trialDuration when trial is true.'
        )
        global String trialUnit;

        @InvocableVariable(
            label='Trial Discount'
            description='Percent off on the trial segment. Defaults to 100 (free trial).'
        )
        global Decimal trialDiscount;

        @InvocableVariable(
            label='Custom Segment Count'
            description='How many equal Custom segments to split durationMonths into. Custom only.'
        )
        global Integer customSegmentCount;

        @InvocableVariable(
            label='Confirm'
            description='false (default) previews only. true persists the empty schedule. Create does not edit an existing schedule.'
        )
        global Boolean confirm;
    }

    global class CreateOutput {
        @InvocableVariable(label='Is Success')
        global Boolean isSuccess;
        @InvocableVariable(label='Quote Url')
        global String quoteUrl;
        @InvocableVariable(label='Schedule Name')
        global String scheduleName;
        @InvocableVariable(label='Segment Count')
        global Decimal segmentCount;
        @InvocableVariable(label='Results Display')
        global String resultsDisplay;
        @InvocableVariable(
            label='Needs Action'
            description='True on preview. Recap the table and wait for confirm before creating.'
        )
        global Boolean needsAction;
        @InvocableVariable(label='Prompt Display')
        global String promptDisplay;
        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    @InvocableMethod(
        label='Create Revenue Cloud Ramp Schedule'
        description='Preview or create the standard empty group ramp schedule (Annual/Custom, trial, prorated stub). confirm=false previews. confirm=true persists. Never Ramp Builder. Never edit an existing schedule.'
    )
    global static List<CreateOutput> createSchedule(List<CreateInput> inputs) {
        List<CreateOutput> results = new List<CreateOutput>();
        if (inputs == null || inputs.isEmpty()) {
            return results;
        }
        for (CreateInput input : inputs) {
            results.add(createOne(input));
        }
        return results;
    }

    private static CreateOutput createOne(CreateInput input) {
        CreateOutput out = new CreateOutput();
        out.isSuccess = false;
        out.needsAction = false;
        try {
            if (input == null || String.isBlank(input.quoteId)) {
                out.errorMessage = 'Quote Id is required.';
                return out;
            }
            Id quoteId;
            try {
                quoteId = Id.valueOf(input.quoteId.trim());
            } catch (Exception e) {
                out.errorMessage = 'Invalid quote Id.';
                return out;
            }
            Quote quote = [
                SELECT Id, Name, Status, StartDate, EndDate
                FROM Quote
                WHERE Id = :quoteId
                WITH USER_MODE
                LIMIT 1
            ];
            out.quoteUrl = RLM_MCP_RecordLinks.lightningUrl('Quote', quote.Id);
            if (quote.Status != 'Draft') {
                out.errorMessage = 'Quote must be Draft. Create Ramp Schedule does not edit an ordered or submitted quote.';
                return out;
            }
            Integer existingSchedules = [
                SELECT COUNT()
                FROM QuoteLineGroup
                WHERE QuoteId = :quote.Id
                AND Type = 'RampScheduleGroup'
                WITH USER_MODE
            ];
            if (existingSchedules > 0) {
                out.errorMessage = 'This quote already has a ramp schedule. Create Ramp Schedule does not edit. Describe or patch quantities with applyRevenueCloudQuoteRamp.';
                return out;
            }
            Date start = parseStart(input.startDate, quote.StartDate);
            if (start == null) {
                out.errorMessage = 'Start date is required (yyyy-mm-dd).';
                return out;
            }
            GenerateResult generated = generate(
                start,
                input.durationMonths,
                input.segmentType,
                input.prorationPosition,
                input.trial,
                input.trialDuration,
                input.trialUnit,
                input.customSegmentCount,
                input.trialDiscount,
                input.scheduleName
            );
            if (String.isNotBlank(generated.errorMessage)) {
                out.errorMessage = generated.errorMessage;
                return out;
            }
            out.scheduleName = generated.scheduleName;
            out.segmentCount = generated.segments.size();
            Boolean doCreate = input.confirm == true;
            if (!doCreate) {
                out.isSuccess = true;
                out.needsAction = true;
                out.resultsDisplay = previewTable(generated.scheduleName, generated.segments);
                out.promptDisplay = confirmPrompt(generated.scheduleName, generated.segments.size());
                return out;
            }
            String persistError = persister.persist(
                quote.Id, generated.scheduleName, generated.segments);
            if (String.isNotBlank(persistError)) {
                out.errorMessage = persistError;
                return out;
            }
            List<String> recap = new List<String>{
                'Created ramp schedule **' + generated.scheduleName + '** with '
                    + String.valueOf(generated.segments.size()) + ' segments.'
            };
            recap.add(previewTable(generated.scheduleName, generated.segments));
            String link = RLM_MCP_RecordLinks.markdown('Open Quote', 'Quote', quote.Id);
            if (String.isNotBlank(link)) {
                recap.add(link);
            }
            recap.add('Schedule is empty. Add a product across segments with applyRevenueCloudQuoteRamp (productName + segmentsJson). Do not open Ramp Builder.');
            out.isSuccess = true;
            out.resultsDisplay = String.join(recap, '\n');
        } catch (Exception e) {
            out.isSuccess = false;
            out.errorMessage = e.getMessage() == null ? 'Create Ramp Schedule failed.' : e.getMessage();
        }
        return out;
    }

    @TestVisible
    static GenerateResult generate(
        Date start,
        Integer durationMonths,
        String segmentTypeRaw,
        String prorationRaw,
        Boolean trialFlag,
        Integer trialDuration,
        String trialUnitRaw,
        Integer customSegmentCount,
        Decimal trialDiscount,
        String scheduleName
    ) {
        GenerateResult result = new GenerateResult();
        String segmentType = normalizeType(segmentTypeRaw);
        if (segmentType != 'Annual' && segmentType != 'Custom') {
            result.errorMessage = 'segmentType must be Annual or Custom.';
            return result;
        }
        if (durationMonths == null || durationMonths < 1) {
            result.errorMessage = 'durationMonths is required and must be at least 1.';
            return result;
        }
        if (segmentType == 'Annual' && durationMonths < 12) {
            result.errorMessage = 'Annual ramps need at least 12 months.';
            return result;
        }
        String proration = String.isBlank(prorationRaw) ? 'End' : prorationRaw.trim();
        if (proration != 'End' && proration != 'Beginning') {
            result.errorMessage = 'prorationPosition must be End or Beginning.';
            return result;
        }
        Boolean trial = trialFlag == true;
        String trialUnit = String.isBlank(trialUnitRaw) ? 'Days' : trialUnitRaw.trim();
        if (trial) {
            if (trialDuration == null || trialDuration < 1) {
                result.errorMessage = 'trialDuration is required when trial is true.';
                return result;
            }
            if (trialUnit != 'Days' && trialUnit != 'Months') {
                result.errorMessage = 'trialUnit must be Days or Months.';
                return result;
            }
        }
        List<Integer> paidLengths = segmentType == 'Custom'
            ? customSegmentLengths(durationMonths, customSegmentCount)
            : annualSegmentLengths(durationMonths, proration);
        if (paidLengths.isEmpty()) {
            result.errorMessage = 'Could not build paid segments from those inputs.';
            return result;
        }
        if (paidLengths.size() > MAX_PAID_SEGMENTS) {
            result.errorMessage = 'A ramp schedule can have at most '
                + String.valueOf(MAX_PAID_SEGMENTS)
                + ' segments excluding the trial.';
            return result;
        }
        Date cursor = start;
        if (trial) {
            Date trialEnd = trialUnit == 'Months'
                ? cursor.addMonths(trialDuration).addDays(-1)
                : cursor.addDays(trialDuration - 1);
            Decimal disc = trialDiscount == null ? 100 : trialDiscount;
            result.segments.add(makeSegment(
                'trial',
                'Trial',
                'Trial',
                'FreeTrial',
                cursor,
                trialEnd,
                trialDuration,
                trialUnit,
                disc,
                0
            ));
            cursor = trialEnd.addDays(1);
        }
        Integer yearNumber = 1;
        for (Integer months : paidLengths) {
            Date segEnd = cursor.addMonths(months).addDays(-1);
            Boolean isProrated = segmentType == 'Annual' && months != 12;
            String name = segmentType == 'Custom'
                ? 'Segment ' + String.valueOf(yearNumber)
                : (isProrated
                    ? 'Year ' + String.valueOf(yearNumber) + ' - Pro-rated'
                    : 'Year ' + String.valueOf(yearNumber));
            result.segments.add(makeSegment(
                's' + String.valueOf(yearNumber - 1),
                name,
                isProrated ? 'Prorated' : (segmentType == 'Annual' ? 'Yearly' : 'Custom'),
                isProrated ? 'Prorated' : (segmentType == 'Annual' ? 'Yearly' : 'Custom'),
                cursor,
                segEnd,
                months,
                'Months',
                0,
                0
            ));
            cursor = segEnd.addDays(1);
            yearNumber++;
        }
        assertContiguous(result);
        if (String.isNotBlank(result.errorMessage)) {
            return result;
        }
        result.scheduleName = String.isBlank(scheduleName)
            ? defaultScheduleName(segmentType, durationMonths, paidLengths)
            : scheduleName.trim();
        return result;
    }

    @TestVisible
    static List<Integer> annualSegmentLengths(Integer paidMonths, String prorationPosition) {
        List<Integer> yearly = new List<Integer>();
        Integer fullYears = paidMonths / 12;
        Integer remainder = Math.mod(paidMonths, 12);
        for (Integer i = 0; i < fullYears; i++) {
            yearly.add(12);
        }
        if (remainder > 0) {
            if (prorationPosition == 'Beginning') {
                yearly.add(0, remainder);
            } else {
                yearly.add(remainder);
            }
        }
        return yearly;
    }

    @TestVisible
    static List<Integer> customSegmentLengths(Integer paidMonths, Integer customSegmentCount) {
        Integer total = paidMonths < 1 ? 1 : paidMonths;
        Integer requested = customSegmentCount == null ? 1 : customSegmentCount;
        Integer count = requested < 1 ? 1 : requested;
        if (count > total) {
            count = total;
        }
        if (count > MAX_PAID_SEGMENTS) {
            count = MAX_PAID_SEGMENTS;
        }
        Integer base = total / count;
        Integer extra = Math.mod(total, count);
        List<Integer> lengths = new List<Integer>();
        for (Integer i = 0; i < count; i++) {
            lengths.add(base + (i >= count - extra ? 1 : 0));
        }
        return lengths;
    }

    private static void assertContiguous(GenerateResult result) {
        for (Integer i = 1; i < result.segments.size(); i++) {
            Date expected = result.segments[i - 1].endDate.addDays(1);
            if (result.segments[i].startDate != expected) {
                result.errorMessage = 'Generated segments are not contiguous.';
                result.segments.clear();
                return;
            }
        }
    }

    private static Segment makeSegment(
        String key,
        String name,
        String typeLabel,
        String segmentType,
        Date startDate,
        Date endDate,
        Integer lengthValue,
        String lengthUnit,
        Decimal discount,
        Decimal uplift
    ) {
        Segment seg = new Segment();
        seg.key = key;
        seg.name = name;
        seg.typeLabel = typeLabel;
        seg.segmentType = segmentType;
        seg.startDate = startDate;
        seg.endDate = endDate;
        seg.lengthValue = lengthValue;
        seg.lengthUnit = lengthUnit;
        seg.discount = discount;
        seg.uplift = uplift;
        return seg;
    }

    private static String persistViaPlace(
        Id quoteId,
        String scheduleName,
        List<Segment> segments
    ) {
        List<RevSalesTrxn.RecordWithReferenceRequest> records =
            new List<RevSalesTrxn.RecordWithReferenceRequest>();
        RevSalesTrxn.RecordResource header = new RevSalesTrxn.RecordResource(
            Quote.getSObjectType(), 'PATCH', quoteId
        );
        header.fieldValues = new Map<String, Object>{ 'Status' => 'Draft' };
        records.add(new RevSalesTrxn.RecordWithReferenceRequest('refRampQuote', header));
        RevSalesTrxn.RecordResource root = new RevSalesTrxn.RecordResource(
            QuoteLineGroup.getSObjectType(), 'POST'
        );
        root.fieldValues = new Map<String, Object>{
            'QuoteId' => quoteId,
            'Name' => scheduleName,
            'Type' => 'RampScheduleGroup'
        };
        records.add(new RevSalesTrxn.RecordWithReferenceRequest('refRoot', root));
        Integer sortOrder = 1;
        for (Segment seg : segments) {
            RevSalesTrxn.RecordResource rec = new RevSalesTrxn.RecordResource(
                QuoteLineGroup.getSObjectType(), 'POST'
            );
            rec.fieldValues = new Map<String, Object>{
                'QuoteId' => quoteId,
                'Name' => seg.name,
                'StartDate' => String.valueOf(seg.startDate),
                'EndDate' => String.valueOf(seg.endDate),
                'Discount' => seg.discount,
                'IsRamped' => true,
                'SortOrder' => sortOrder,
                'SegmentType' => seg.segmentType,
                'ParentQuoteLineGroupId' => '@{refRoot.id}'
            };
            records.add(new RevSalesTrxn.RecordWithReferenceRequest(
                'refSeg' + String.valueOf(sortOrder), rec));
            sortOrder++;
        }
        RevSalesTrxn.ConfigurationOptionsInput options =
            new RevSalesTrxn.ConfigurationOptionsInput();
        options.executeConfigurationRules = false;
        options.validateProductCatalog = false;
        options.validateAmendRenewCancel = false;
        options.addDefaultConfiguration = false;
        RevSalesTrxn.GraphRequest graph = new RevSalesTrxn.GraphRequest(
            'McpCreateRampSchedule', records);
        RevSalesTrxn.PlaceSalesTransactionResponse resp =
            RevSalesTrxn.PlaceSalesTransactionExecutor.execute(
                graph,
                RevSalesTrxn.PricingPreferenceEnum.SKIP,
                RevSalesTrxn.ConfigurationExecutionEnum.SKIP,
                options,
                null
            );
        if (resp == null || !resp.isSuccess) {
            return resp == null || resp.errorResponse == null
                ? 'Could not create the ramp schedule.'
                : String.valueOf(resp.errorResponse);
        }
        return repairStructure(quoteId, scheduleName);
    }

    @TestVisible
    static String persistForTest(Id quoteId, String scheduleName, List<Segment> segments) {
        QuoteLineGroup root = new QuoteLineGroup(
            QuoteId = quoteId,
            Name = scheduleName,
            Type = 'RampScheduleGroup'
        );
        insert as user root;
        List<QuoteLineGroup> children = new List<QuoteLineGroup>();
        Integer sortOrder = 1;
        for (Segment seg : segments) {
            children.add(new QuoteLineGroup(
                QuoteId = quoteId,
                Name = seg.name,
                StartDate = seg.startDate,
                EndDate = seg.endDate,
                Discount = seg.discount,
                IsRamped = true,
                SortOrder = sortOrder,
                SegmentType = seg.segmentType,
                ParentQuoteLineGroupId = root.Id
            ));
            sortOrder++;
        }
        insert as user children;
        return null;
    }

    private static String repairStructure(Id quoteId, String scheduleName) {
        List<QuoteLineGroup> groups = [
            SELECT Id, Type, IsRamped, ParentQuoteLineGroupId
            FROM QuoteLineGroup
            WHERE QuoteId = :quoteId
            WITH USER_MODE
        ];
        QuoteLineGroup root = null;
        List<QuoteLineGroup> segments = new List<QuoteLineGroup>();
        for (QuoteLineGroup grp : groups) {
            if (grp.Type == 'RampScheduleGroup') {
                root = grp;
            } else {
                segments.add(grp);
            }
        }
        if (root == null) {
            root = new QuoteLineGroup(
                QuoteId = quoteId,
                Name = scheduleName,
                Type = 'RampScheduleGroup'
            );
            insert as user root;
        }
        List<QuoteLineGroup> updates = new List<QuoteLineGroup>();
        for (QuoteLineGroup seg : segments) {
            updates.add(new QuoteLineGroup(
                Id = seg.Id,
                Type = null,
                IsRamped = true,
                ParentQuoteLineGroupId = root.Id
            ));
        }
        if (!updates.isEmpty()) {
            Database.SaveResult[] saves = Database.update(updates, false, AccessLevel.USER_MODE);
            for (Database.SaveResult save : saves) {
                if (!save.isSuccess()) {
                    return save.getErrors()[0].getMessage();
                }
            }
        }
        return null;
    }

    private static String previewTable(String scheduleName, List<Segment> segments) {
        List<String> rows = new List<String>{
            'Preview — ' + scheduleName + ' (Create Ramp Schedule, not Ramp Builder)',
            '| # | Segment | Duration | Type | Start | End | Discount | Uplift |',
            '|---|---|---|---|---|---|---|---|'
        };
        Integer n = 1;
        for (Segment seg : segments) {
            rows.add('| ' + String.valueOf(n)
                + ' | ' + seg.name
                + ' | ' + String.valueOf(seg.lengthValue) + ' ' + seg.lengthUnit
                + ' | ' + seg.typeLabel
                + ' | ' + String.valueOf(seg.startDate)
                + ' | ' + String.valueOf(seg.endDate)
                + ' | ' + RLM_MCP_RecordLinks.formatNumber(seg.discount)
                + ' | ' + RLM_MCP_RecordLinks.formatNumber(seg.uplift)
                + ' |');
            n++;
        }
        return String.join(rows, '\n');
    }

    private static String confirmPrompt(String scheduleName, Integer segmentCount) {
        return String.join(
            new List<String>{
                'AE note (chat only): this is a preview. The quote is unchanged.',
                'Create **' + scheduleName + '** with '
                    + String.valueOf(segmentCount)
                    + ' empty segments? Products are added after create.',
                '1. Create this ramp schedule',
                '2. Adjust the inputs and preview again',
                '3. Skip',
                'Which option? Click a suggestion or reply with a number. If they said create, call again with confirm=true.'
            },
            '\n'
        );
    }

    private static Date parseStart(String raw, Date quoteStart) {
        if (String.isBlank(raw)) {
            return quoteStart == null ? Date.today() : quoteStart;
        }
        try {
            return Date.valueOf(raw.trim());
        } catch (Exception e) {
            return null;
        }
    }

    private static String normalizeType(String raw) {
        if (String.isBlank(raw) || raw.trim().equalsIgnoreCase('Annual')
            || raw.trim().equalsIgnoreCase('Yearly')) {
            return 'Annual';
        }
        if (raw.trim().equalsIgnoreCase('Custom')) {
            return 'Custom';
        }
        return raw.trim();
    }

    private static String defaultScheduleName(
        String segmentType,
        Integer durationMonths,
        List<Integer> paidLengths
    ) {
        if (segmentType == 'Custom') {
            return String.valueOf(durationMonths) + ' Month Ramp Schedule';
        }
        Integer years = 0;
        for (Integer months : paidLengths) {
            if (months == 12) {
                years++;
            }
        }
        if (years == 0) {
            years = 1;
        }
        return String.valueOf(years) + ' Year Ramp Schedule';
    }
}
