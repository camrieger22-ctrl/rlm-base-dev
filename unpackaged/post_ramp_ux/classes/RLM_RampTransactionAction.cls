/**
 * One invocable for the Ramp Builder flow. Builds the Place Sales Transaction
 * graph from flow inputs and calls PlaceSalesTransactionExecutor.
 *
 * Does not price, compute discounts, or evaluate approvals. Does not write
 * QuoteLineItem rows with direct DML — every line write goes through PST.
 *
 * ApplyPlan also repairs the group tree the platform's groupRampAction leaves
 * unactivatable (missing RampScheduleGroup root, segment Type still set).
 */
public with sharing class RLM_RampTransactionAction {

    private static final Map<String, String> TERM_TO_FREQUENCY = new Map<String, String>{
        'Months' => 'Monthly',
        'Annual' => 'Annual',
        'Quarterly' => 'Quarterly',
        'Semi-Annual' => 'Semi-Annual'
    };

    public class Request {
        @InvocableVariable(required=true label='Action')
        public String action;
        @InvocableVariable(required=true label='Quote Id')
        public String quoteId;
        @InvocableVariable(label='Plan JSON')
        public String planJson;
        @InvocableVariable(label='Graph JSON')
        public String graphJson;
        @InvocableVariable(label='Group Ramp Action')
        public String groupRampAction;
    }

    public class Result {
        @InvocableVariable(label='Success')
        public Boolean success;
        @InvocableVariable(label='Message')
        public String message;
        @InvocableVariable(label='Error Response')
        public String errorResponse;
    }

    public class Plan {
        public String scheduleName;
        public String segmentType;
        public String startDate;
        public Integer durationMonths;
        public String prorationPosition;
        public Boolean trial;
        public Integer trialDays;
        public Decimal trialDiscount;
        public List<PlanSegment> segments;
        public List<PlanProduct> products;
    }

    public class PlanSegment {
        public String key;
        public String name;
        public String type;
        public String startDate;
        public String endDate;
        public Decimal discount;
        public Decimal uplift;
    }

    public class PlanProduct {
        public String pricebookEntryId;
        public String product2Id;
        public Boolean persisted;
        public Map<String, PlanCell> cells;
    }

    public class PlanCell {
        public Decimal quantity;
        public Decimal adjustment;
        public String adjustmentKind;
    }

    public class CatalogOption {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
    }

    public class CatalogSellingModel {
        @AuraEnabled public String pricebookEntryId;
        @AuraEnabled public String productSellingModelId;
        @AuraEnabled public String name;
        @AuraEnabled public String sellingModelType;
        @AuraEnabled public String frequency;
        @AuraEnabled public Decimal listPrice;
        @AuraEnabled public Boolean isDefault;
    }

    public class CatalogProduct {
        @AuraEnabled public String pricebookEntryId;
        @AuraEnabled public String product2Id;
        @AuraEnabled public String name;
        @AuraEnabled public String sku;
        @AuraEnabled public String displayUrl;
        @AuraEnabled public Decimal listPrice;
        @AuraEnabled public Boolean qualified;
        @AuraEnabled public String sellingModel;
        @AuraEnabled public String nodeType;
        @AuraEnabled public String configureDuringSale;
        @AuraEnabled public Boolean configurable;
        @AuraEnabled public List<CatalogSellingModel> sellingModels;
    }

    public class ConfigureResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String message;
        @AuraEnabled public String quoteLineItemId;
        @AuraEnabled public String parentName;
    }

    public class CatalogResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String message;
        @AuraEnabled public String catalogId;
        @AuraEnabled public String catalogName;
        @AuraEnabled public List<CatalogOption> catalogs;
        @AuraEnabled public List<CatalogProduct> products;
    }

    @AuraEnabled
    public static Result savePlan(String quoteId, String planJson) {
        Request req = new Request();
        req.action = 'ApplyPlan';
        req.quoteId = quoteId;
        req.planJson = planJson;
        return run(req);
    }

    /**
     * Persist the parent bundle line (needed by Product Configurator), then
     * return the QuoteLineItem Id so Ramp Builder can host ProductConfig.
     */
    @AuraEnabled
    public static ConfigureResult startConfiguration(
        String quoteId,
        String pricebookEntryId,
        String quoteLineItemId,
        String planJson
    ) {
        ConfigureResult out = new ConfigureResult();
        out.success = false;
        Id qId = toId(quoteId);
        if (qId == null) {
            out.message = 'Quote Id is required.';
            return out;
        }
        Quote quote = [
            SELECT Id, Name, QuoteNumber, Pricebook2Id
            FROM Quote
            WHERE Id = :qId
            LIMIT 1
        ];
        out.parentName = String.isBlank(quote.Name) ? quote.QuoteNumber : quote.Name;

        Id existingLine = toId(quoteLineItemId);
        if (existingLine != null) {
            List<QuoteLineItem> owned = [
                SELECT Id
                FROM QuoteLineItem
                WHERE Id = :existingLine
                AND QuoteId = :qId
                LIMIT 1
            ];
            if (owned.isEmpty()) {
                out.message = 'That line is not on this quote.';
                return out;
            }
            out.success = true;
            out.quoteLineItemId = owned[0].Id;
            out.message = 'Reconfigure the bundle on the quote.';
            return out;
        }

        Id pbeId = toId(pricebookEntryId);
        if (pbeId == null) {
            out.message = 'Price book entry is required.';
            return out;
        }

        List<QuoteLineItem> already = [
            SELECT Id
            FROM QuoteLineItem
            WHERE QuoteId = :qId
            AND PricebookEntryId = :pbeId
            AND ParentQuoteLineItemId = null
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (!already.isEmpty()) {
            out.success = true;
            out.quoteLineItemId = already[0].Id;
            out.message = 'Reconfigure the bundle on the quote.';
            return out;
        }

        List<QuoteLineGroup> segments = [
            SELECT Id
            FROM QuoteLineGroup
            WHERE QuoteId = :qId
            AND Type != 'RampScheduleGroup'
            ORDER BY SortOrder ASC NULLS LAST
            LIMIT 1
        ];
        if (segments.isEmpty() && String.isNotBlank(planJson)) {
            Plan scheduleOnly = parsePlan(planJson);
            if (scheduleOnly != null) {
                scheduleOnly.products = new List<PlanProduct>();
                Result scheduled = applyPlan(qId, JSON.serialize(scheduleOnly));
                if (!scheduled.success) {
                    out.message = scheduled.message;
                    return out;
                }
                segments = [
                    SELECT Id
                    FROM QuoteLineGroup
                    WHERE QuoteId = :qId
                    AND Type != 'RampScheduleGroup'
                    ORDER BY SortOrder ASC NULLS LAST
                    LIMIT 1
                ];
            }
        }

        Map<Id, PricebookEntry> pbes = new Map<Id, PricebookEntry>([
            SELECT Id, Product2Id, UnitPrice,
                   ProductSellingModel.SellingModelType,
                   ProductSellingModel.PricingTermUnit
            FROM PricebookEntry
            WHERE Id = :pbeId
            AND (Pricebook2Id = :quote.Pricebook2Id OR Pricebook2.IsStandard = true)
            LIMIT 1
        ]);
        PricebookEntry pbe = pbes.get(pbeId);
        if (pbe == null) {
            out.message = 'That selling model is not in the quote price book.';
            return out;
        }

        PlanSegment first = new PlanSegment();
        first.startDate = String.valueOf(Date.today());
        first.endDate = String.valueOf(Date.today().addYears(1).addDays(-1));
        PlanCell cell = new PlanCell();
        cell.quantity = 1;
        cell.adjustment = 0;
        cell.adjustmentKind = 'Discount';

        List<RevSalesTrxn.RecordWithReferenceRequest> records =
            new List<RevSalesTrxn.RecordWithReferenceRequest>();
        RevSalesTrxn.RecordResource header = new RevSalesTrxn.RecordResource(
            Quote.getSObjectType(), 'PATCH', qId);
        header.fieldValues = new Map<String, Object>();
        records.add(new RevSalesTrxn.RecordWithReferenceRequest('refQuote', header));
        RevSalesTrxn.RecordResource line = new RevSalesTrxn.RecordResource(
            QuoteLineItem.getSObjectType(), 'POST');
        Map<String, Object> fields = lineFields(
            qId,
            segments.isEmpty() ? null : String.valueOf(segments[0].Id),
            pbe,
            cell,
            first,
            newRampId(),
            newSegId()
        );
        if (segments.isEmpty()) {
            fields.remove('QuoteLineGroupId');
        }
        line.fieldValues = fields;
        records.add(new RevSalesTrxn.RecordWithReferenceRequest('refLine', line));
        Result placed = executeGraph(records, null);
        if (!placed.success) {
            out.message = placed.message;
            return out;
        }

        List<QuoteLineItem> created = [
            SELECT Id
            FROM QuoteLineItem
            WHERE QuoteId = :qId
            AND PricebookEntryId = :pbeId
            AND ParentQuoteLineItemId = null
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (created.isEmpty()) {
            out.message = 'The bundle was not added to the quote.';
            return out;
        }
        out.success = true;
        out.quoteLineItemId = created[0].Id;
        out.message = 'Bundle added to the quote. Configure add-ons next.';
        return out;
    }

    /**
     * Browse / search the Product Discovery catalog the same way the quote
     * Browse Catalog action does: Discover Products resolves ProductCatalog,
     * then getProducts (browse) or findProducts (search) with the quote as
     * transactionId so qualification and pricing run against that deal.
     */
    @AuraEnabled
    public static CatalogResult browseCatalog(
        String quoteId,
        String searchTerm,
        String catalogId
    ) {
        CatalogResult out = new CatalogResult();
        out.success = false;
        out.catalogs = new List<CatalogOption>();
        out.products = new List<CatalogProduct>();
        Id qId = toId(quoteId);
        if (qId == null) {
            out.message = 'Quote Id is required.';
            return out;
        }

        List<Quote> quotes = [
            SELECT Id, Pricebook2Id
            FROM Quote
            WHERE Id = :qId
            LIMIT 1
        ];
        if (quotes.isEmpty()) {
            out.message = 'Quote was not found.';
            return out;
        }
        Id pricebookId = quotes[0].Pricebook2Id;

        List<ProductCatalog> catalogs = [
            SELECT Id, Name
            FROM ProductCatalog
            ORDER BY Name
            LIMIT 50
        ];
        for (ProductCatalog catalog : catalogs) {
            CatalogOption option = new CatalogOption();
            option.id = catalog.Id;
            option.name = catalog.Name;
            out.catalogs.add(option);
        }

        Id selectedCatalog = toId(catalogId);
        if (selectedCatalog == null && !catalogs.isEmpty()) {
            selectedCatalog = catalogs[0].Id;
        }
        if (selectedCatalog != null) {
            out.catalogId = selectedCatalog;
            for (CatalogOption option : out.catalogs) {
                if (option.id == String.valueOf(selectedCatalog)) {
                    out.catalogName = option.name;
                    break;
                }
            }
        }

        try {
            Boolean searching = String.isNotBlank(searchTerm);
            Invocable.Action action = Invocable.Action.createStandardAction(
                searching ? 'findProducts' : 'getProducts');
            if (searching) {
                action.setInvocationParameter('searchTerm', searchTerm.trim());
            }
            if (selectedCatalog != null) {
                action.setInvocationParameter('catalogId', String.valueOf(selectedCatalog));
            }
            action.setInvocationParameter('transactionId', String.valueOf(qId));
            action.setInvocationParameter('enableQualification', true);
            action.setInvocationParameter('enablePricing', true);
            action.setInvocationParameter('executeConfigurationRules', false);
            action.setInvocationParameter('limit', 50);
            action.setInvocationParameter('orderBy', new List<String>{ 'name:asc' });
            if (pricebookId != null) {
                action.setInvocationParameter('priceBookId', String.valueOf(pricebookId));
            }
            List<Invocable.Action.Result> results = action.invoke();
            if (results == null || results.isEmpty()) {
                out.message = 'Product Discovery returned no response.';
                return out;
            }
            Invocable.Action.Result res = results[0];
            if (!res.isSuccess()) {
                out.message = firstError(res);
                return out;
            }
            out.products = parseDiscoveryResults(
                res.getOutputParameters(), pricebookId);
            out.success = true;
            out.message = out.products.isEmpty()
                ? 'No products matched.'
                : 'Loaded ' + String.valueOf(out.products.size()) + ' products.';
            return out;
        } catch (Exception e) {
            out.message = e.getMessage();
            return out;
        }
    }

    @InvocableMethod(
        label='Ramp Transaction Action'
        description='Place Sales Transaction with optional groupRampAction. Use ApplyPlan to save a Ramp Builder plan.'
        category='Revenue Cloud'
    )
    public static List<Result> execute(List<Request> requests) {
        List<Result> out = new List<Result>();
        if (requests == null || requests.isEmpty()) {
            out.add(fail('No input.'));
            return out;
        }
        for (Request req : requests) {
            out.add(run(req));
        }
        return out;
    }

    @TestVisible
    static Result run(Request req) {
        Result r = new Result();
        r.success = false;
        Id quoteId = toId(req == null ? null : req.quoteId);
        if (quoteId == null) {
            r.message = 'Quote Id is required.';
            return r;
        }
        String action = req.action == null ? '' : req.action.trim();
        try {
            if (action == 'ApplyPlan') {
                return applyPlan(quoteId, req.planJson);
            }
            if (String.isBlank(req.graphJson)) {
                r.message = 'Graph JSON is required for ' + action + '.';
                return r;
            }
            return place(
                req.graphJson,
                String.isBlank(req.groupRampAction) ? action : req.groupRampAction
            );
        } catch (Exception e) {
            r.message = e.getMessage();
            return r;
        }
    }

    static Result applyPlan(Id quoteId, String planJson) {
        Result r = new Result();
        r.success = false;
        Plan plan = parsePlan(planJson);
        if (plan == null || plan.segments == null || plan.segments.isEmpty()) {
            r.message = 'The plan needs at least one segment.';
            return r;
        }

        Quote quote = [
            SELECT Id, Pricebook2Id
            FROM Quote
            WHERE Id = :quoteId
            LIMIT 1
        ];

        List<QuoteLineGroup> existing = [
            SELECT Id, Name, Type, IsRamped, ParentQuoteLineGroupId, SortOrder
            FROM QuoteLineGroup
            WHERE QuoteId = :quoteId
        ];
        QuoteLineGroup root = null;
        List<QuoteLineGroup> orphans = new List<QuoteLineGroup>();
        for (QuoteLineGroup g : existing) {
            if (g.Type == 'RampScheduleGroup') {
                root = g;
            } else {
                orphans.add(g);
            }
        }

        Map<Id, PricebookEntry> pbes = loadPbes(plan, quote.Pricebook2Id);
        List<RevSalesTrxn.RecordWithReferenceRequest> records =
            new List<RevSalesTrxn.RecordWithReferenceRequest>();

        RevSalesTrxn.RecordResource header = new RevSalesTrxn.RecordResource(
            Quote.getSObjectType(), 'PATCH', quoteId);
        header.fieldValues = new Map<String, Object>();
        records.add(new RevSalesTrxn.RecordWithReferenceRequest('refQuote', header));

        String rootRef;
        if (root == null) {
            RevSalesTrxn.RecordResource rootRec = new RevSalesTrxn.RecordResource(
                QuoteLineGroup.getSObjectType(), 'POST');
            rootRec.fieldValues = new Map<String, Object>{
                'QuoteId' => quoteId,
                'Name' => String.isBlank(plan.scheduleName) ? 'Ramp Schedule' : plan.scheduleName,
                'Type' => 'RampScheduleGroup'
            };
            records.add(new RevSalesTrxn.RecordWithReferenceRequest('refRoot', rootRec));
            rootRef = '@{refRoot.id}';
        } else {
            rootRef = String.valueOf(root.Id);
            RevSalesTrxn.RecordResource rootRec = new RevSalesTrxn.RecordResource(
                QuoteLineGroup.getSObjectType(), 'PATCH', root.Id);
            rootRec.fieldValues = new Map<String, Object>{
                'Name' => String.isBlank(plan.scheduleName) ? root.Name : plan.scheduleName
            };
            records.add(new RevSalesTrxn.RecordWithReferenceRequest('refRoot', rootRec));
        }

        Map<String, String> segmentRefs = new Map<String, String>();
        Integer sortOrder = 1;
        for (PlanSegment seg : plan.segments) {
            String ref = 'refSeg' + String.valueOf(sortOrder);
            Boolean reuse = sortOrder - 1 < orphans.size();
            Id reuseId = reuse ? orphans[sortOrder - 1].Id : null;
            RevSalesTrxn.RecordResource rec = reuse
                ? new RevSalesTrxn.RecordResource(QuoteLineGroup.getSObjectType(), 'PATCH', reuseId)
                : new RevSalesTrxn.RecordResource(QuoteLineGroup.getSObjectType(), 'POST');
            Map<String, Object> fields = new Map<String, Object>{
                'Name' => seg.name,
                'StartDate' => seg.startDate,
                'EndDate' => seg.endDate,
                'Discount' => seg.discount,
                'UnitPriceUplift' => seg.uplift,
                'IsRamped' => true,
                'SortOrder' => sortOrder,
                'SegmentType' => segmentTypeValue(seg.type, plan.segmentType),
                'ParentQuoteLineGroupId' => rootRef
            };
            if (reuse) {
                segmentRefs.put(seg.key, String.valueOf(reuseId));
            } else {
                fields.put('QuoteId', quoteId);
                segmentRefs.put(seg.key, '@{' + ref + '.id}');
            }
            rec.fieldValues = fields;
            records.add(new RevSalesTrxn.RecordWithReferenceRequest(ref, rec));
            sortOrder++;
        }

        Integer lineN = 0;
        Map<String, String> rampIds = new Map<String, String>();
        Map<String, String> segIds = new Map<String, String>();
        if (plan.products != null) {
            for (PlanProduct product : plan.products) {
                if (product == null || product.cells == null || product.persisted == true) {
                    continue;
                }
                String rampId = rampIds.get(product.pricebookEntryId);
                if (rampId == null) {
                    rampId = newRampId();
                    rampIds.put(product.pricebookEntryId, rampId);
                }
                PricebookEntry pbe = pbes.get((Id) product.pricebookEntryId);
                if (pbe == null) {
                    continue;
                }
                for (PlanSegment seg : plan.segments) {
                    PlanCell cell = product.cells.get(seg.key);
                    if (cell == null || cell.quantity == null || cell.quantity <= 0) {
                        continue;
                    }
                    if (!segIds.containsKey(seg.key)) {
                        segIds.put(seg.key, newSegId());
                    }
                    lineN++;
                    RevSalesTrxn.RecordResource line = new RevSalesTrxn.RecordResource(
                        QuoteLineItem.getSObjectType(), 'POST');
                    line.fieldValues = lineFields(
                        quoteId,
                        segmentRefs.get(seg.key),
                        pbe,
                        cell,
                        seg,
                        rampId,
                        segIds.get(seg.key)
                    );
                    records.add(new RevSalesTrxn.RecordWithReferenceRequest(
                        'refLine' + String.valueOf(lineN), line));
                }
            }
        }

        Result placed = executeGraph(records, null);
        if (!placed.success) {
            return placed;
        }
        repairStructure(quoteId, plan.scheduleName);
        r.success = true;
        r.message = 'Saved the ramp to the quote.';
        return r;
    }

    static Map<String, Object> lineFields(
        Id quoteId,
        String groupRef,
        PricebookEntry pbe,
        PlanCell cell,
        PlanSegment seg,
        String rampId,
        String segmentId
    ) {
        String sellingModelType = pbe.ProductSellingModel != null
            ? String.valueOf(pbe.ProductSellingModel.SellingModelType) : null;
        String term = pbe.ProductSellingModel != null
            ? String.valueOf(pbe.ProductSellingModel.PricingTermUnit) : null;
        String frequency = TERM_TO_FREQUENCY.containsKey(term) ? TERM_TO_FREQUENCY.get(term) : null;
        Decimal adj = cell.adjustment == null ? 0 : cell.adjustment;
        Map<String, Object> fields = new Map<String, Object>{
            'QuoteId' => quoteId,
            'QuoteLineGroupId' => groupRef,
            'Product2Id' => pbe.Product2Id,
            'PricebookEntryId' => pbe.Id,
            'Quantity' => cell.quantity,
            'UnitPrice' => pbe.UnitPrice == null ? 0 : pbe.UnitPrice,
            'RampIdentifier' => rampId,
            'SegmentIdentifier' => segmentId
        };
        if (adj != 0 && cell.adjustmentKind != 'Markup') {
            fields.put('Discount', adj);
        }
        if (sellingModelType == 'TermDefined' && String.isNotBlank(frequency)) {
            fields.put('StartDate', iso(seg.startDate));
            fields.put('EndDate', iso(seg.endDate));
            fields.put('PeriodBoundary', 'Anniversary');
            fields.put('BillingFrequency', frequency);
        } else if (sellingModelType == 'Evergreen' && String.isNotBlank(frequency)) {
            fields.put('StartDate', iso(seg.startDate));
            fields.put('PeriodBoundary', 'Anniversary');
            fields.put('BillingFrequency', frequency);
        }
        return fields;
    }

    static Result place(String graphJson, String groupRampAction) {
        List<Object> raw = (List<Object>) JSON.deserializeUntyped(graphJson);
        List<RevSalesTrxn.RecordWithReferenceRequest> records =
            new List<RevSalesTrxn.RecordWithReferenceRequest>();
        Integer i = 0;
        for (Object row : raw) {
            Map<String, Object> item = (Map<String, Object>) row;
            String typeName = String.valueOf(item.get('type'));
            String method = item.containsKey('method') ? String.valueOf(item.get('method')) : 'PATCH';
            String ref = item.containsKey('referenceId')
                ? String.valueOf(item.get('referenceId')) : 'ref' + String.valueOf(i);
            SObjectType sot = typeName == 'QuoteLineItem'
                ? QuoteLineItem.getSObjectType()
                : (typeName == 'QuoteLineGroup'
                    ? QuoteLineGroup.getSObjectType()
                    : Quote.getSObjectType());
            Map<String, Object> fields = (Map<String, Object>) item.get('fields');
            RevSalesTrxn.RecordResource rec;
            if ((method == 'PATCH' || method == 'DELETE') && fields != null && fields.get('Id') != null) {
                rec = new RevSalesTrxn.RecordResource(sot, method, (Id) fields.get('Id'));
                fields = new Map<String, Object>(fields);
                fields.remove('Id');
            } else {
                rec = new RevSalesTrxn.RecordResource(sot, method);
            }
            rec.fieldValues = fields;
            records.add(new RevSalesTrxn.RecordWithReferenceRequest(ref, rec));
            i++;
        }
        return executeGraph(records, groupRampAction);
    }

    static Result executeGraph(
        List<RevSalesTrxn.RecordWithReferenceRequest> records,
        String groupRampAction
    ) {
        RevSalesTrxn.GraphRequest graph = new RevSalesTrxn.GraphRequest(
            'RampTransactionAction', records);
        RevSalesTrxn.PricingPreferenceEnum pricingPref =
            RevSalesTrxn.PricingPreferenceEnum.FORCE;
        RevSalesTrxn.ConfigurationExecutionEnum configPref =
            RevSalesTrxn.ConfigurationExecutionEnum.SKIP;
        RevSalesTrxn.ConfigurationOptionsInput options =
            new RevSalesTrxn.ConfigurationOptionsInput();
        RevSalesTrxn.PlaceSalesTransactionResponse resp;
        if (String.isBlank(groupRampAction) || groupRampAction == 'ApplyPlan') {
            resp = RevSalesTrxn.PlaceSalesTransactionExecutor.execute(
                graph, pricingPref, configPref, options, null);
        } else {
            RevSalesTrxn.GroupRampActionEnum rampEnum = rampEnumOf(groupRampAction);
            RevSalesTrxn.TaxPreferenceEnum taxPref = RevSalesTrxn.TaxPreferenceEnum.Skip;
            resp = RevSalesTrxn.PlaceSalesTransactionExecutor.execute(
                graph, pricingPref, configPref, options, null, taxPref, null, rampEnum);
        }
        Result r = new Result();
        if (resp != null && resp.isSuccess) {
            r.success = true;
            r.message = 'Done.';
            return r;
        }
        r.success = false;
        r.errorResponse = resp == null ? null : String.valueOf(resp.errorResponse);
        r.message = String.isBlank(r.errorResponse)
            ? 'Place Sales Transaction failed.'
            : r.errorResponse;
        return r;
    }

    static void repairStructure(Id quoteId, String scheduleName) {
        List<QuoteLineGroup> groups = [
            SELECT Id, Type, IsRamped, ParentQuoteLineGroupId
            FROM QuoteLineGroup
            WHERE QuoteId = :quoteId
        ];
        QuoteLineGroup root = null;
        List<QuoteLineGroup> segments = new List<QuoteLineGroup>();
        for (QuoteLineGroup g : groups) {
            if (g.Type == 'RampScheduleGroup') {
                root = g;
            } else {
                segments.add(g);
            }
        }
        if (root == null) {
            root = new QuoteLineGroup(
                QuoteId = quoteId,
                Name = String.isBlank(scheduleName) ? 'Ramp Schedule' : scheduleName,
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
            update as user updates;
        }
    }

    static Map<Id, PricebookEntry> loadPbes(Plan plan, Id pricebookId) {
        Set<Id> ids = new Set<Id>();
        if (plan.products != null) {
            for (PlanProduct p : plan.products) {
                if (p != null && String.isNotBlank(p.pricebookEntryId)) {
                    ids.add((Id) p.pricebookEntryId);
                }
            }
        }
        if (ids.isEmpty()) {
            return new Map<Id, PricebookEntry>();
        }
        return new Map<Id, PricebookEntry>([
            SELECT Id, Product2Id, UnitPrice,
                   ProductSellingModel.SellingModelType,
                   ProductSellingModel.PricingTermUnit
            FROM PricebookEntry
            WHERE Id IN :ids
            AND (Pricebook2Id = :pricebookId OR Pricebook2.IsStandard = true)
        ]);
    }

    @TestVisible
    static Plan parsePlan(String planJson) {
        if (String.isBlank(planJson)) {
            return null;
        }
        return (Plan) JSON.deserialize(planJson, Plan.class);
    }

    @TestVisible
    static String segmentTypeValue(String type, String scheduleType) {
        if (type == 'Yearly' || type == 'Annual') {
            return 'Yearly';
        }
        return 'Custom';
    }

    static RevSalesTrxn.GroupRampActionEnum rampEnumOf(String name) {
        if (name == 'AddProducts') return RevSalesTrxn.GroupRampActionEnum.AddProducts;
        if (name == 'DeleteProducts') return RevSalesTrxn.GroupRampActionEnum.DeleteProducts;
        if (name == 'EditRampSchedule') return RevSalesTrxn.GroupRampActionEnum.EditRampSchedule;
        if (name == 'DeleteSegment') return RevSalesTrxn.GroupRampActionEnum.DeleteSegment;
        if (name == 'ConvertToNonRampedGroup') {
            return RevSalesTrxn.GroupRampActionEnum.ConvertToNonRampedGroup;
        }
        return RevSalesTrxn.GroupRampActionEnum.EditGroup;
    }

    static String iso(String ymd) {
        if (String.isBlank(ymd)) {
            return null;
        }
        return ymd.length() >= 10 ? ymd.substring(0, 10) + 'T00:00:00.000Z' : ymd;
    }

    @TestVisible
    static List<CatalogProduct> parseDiscoveryResults(
        Map<String, Object> output,
        Id pricebookId
    ) {
        List<CatalogProduct> products = new List<CatalogProduct>();
        if (output == null) {
            return products;
        }
        Object raw = output.get('results');
        if (raw == null) {
            return products;
        }
        Object parsed = JSON.deserializeUntyped(JSON.serialize(raw));
        List<Object> rows = new List<Object>();
        if (parsed instanceof List<Object>) {
            rows = (List<Object>) parsed;
        } else if (parsed instanceof Map<String, Object>) {
            Map<String, Object> wrap = (Map<String, Object>) parsed;
            if (wrap.get('products') instanceof List<Object>) {
                rows = (List<Object>) wrap.get('products');
            } else {
                rows.add(wrap);
            }
        }
        for (Object rowObj : rows) {
            if (!(rowObj instanceof Map<String, Object>)) {
                continue;
            }
            CatalogProduct product = toCatalogProduct(
                (Map<String, Object>) rowObj, pricebookId);
            if (product != null && String.isNotBlank(product.pricebookEntryId)) {
                products.add(product);
            }
        }
        return products;
    }

    static CatalogProduct toCatalogProduct(Map<String, Object> row, Id pricebookId) {
        CatalogProduct product = new CatalogProduct();
        product.product2Id = asString(row.get('id'));
        product.name = asString(row.get('name'));
        product.sku = asString(row.get('productCode'));
        product.displayUrl = asString(row.get('displayUrl'));
        product.nodeType = asString(row.get('nodeType'));
        product.configureDuringSale = asString(row.get('configureDuringSale'));
        product.configurable = product.nodeType == 'bundleProduct';
        product.sellingModels = toSellingModels(row.get('prices'), pricebookId);
        Object qualObj = row.get('qualificationContext');
        product.qualified = true;
        if (qualObj instanceof Map<String, Object>) {
            product.qualified = ((Map<String, Object>) qualObj).get('isQualified') == true;
        }
        CatalogSellingModel selected;
        for (CatalogSellingModel model : product.sellingModels) {
            if (selected == null) {
                selected = model;
            }
            if (model.isDefault == true) {
                selected = model;
                break;
            }
        }
        if (selected == null) {
            return product;
        }
        product.pricebookEntryId = selected.pricebookEntryId;
        product.listPrice = selected.listPrice;
        product.sellingModel = selected.name;
        return product;
    }

    static List<CatalogSellingModel> toSellingModels(Object pricesObj, Id pricebookId) {
        List<CatalogSellingModel> models = new List<CatalogSellingModel>();
        if (!(pricesObj instanceof List<Object>)) {
            return models;
        }
        for (Object item : (List<Object>) pricesObj) {
            if (!(item instanceof Map<String, Object>)) {
                continue;
            }
            Map<String, Object> price = (Map<String, Object>) item;
            if (String.isBlank(asString(price.get('priceBookEntryId')))) {
                continue;
            }
            Boolean sameBook = pricebookId == null
                || asString(price.get('priceBookId')) == String.valueOf(pricebookId);
            if (!sameBook) {
                continue;
            }
            CatalogSellingModel model = new CatalogSellingModel();
            model.pricebookEntryId = asString(price.get('priceBookEntryId'));
            Object amount = price.get('price');
            model.listPrice = amount == null ? 0 : Decimal.valueOf(String.valueOf(amount));
            model.isDefault = price.get('isDefault') == true;
            Object modelObj = price.get('pricingModel');
            if (modelObj instanceof Map<String, Object>) {
                Map<String, Object> pricing = (Map<String, Object>) modelObj;
                model.productSellingModelId = asString(pricing.get('id'));
                model.name = asString(pricing.get('name'));
                model.sellingModelType = asString(pricing.get('pricingModelType'));
                model.frequency = asString(pricing.get('frequency'));
            }
            models.add(model);
        }
        return models;
    }

    static String asString(Object value) {
        return value == null ? null : String.valueOf(value);
    }

    static String firstError(Invocable.Action.Result res) {
        List<Invocable.Action.Error> errors = res.getErrors();
        if (errors != null && !errors.isEmpty() && errors[0] != null) {
            return errors[0].getMessage();
        }
        return 'Product Discovery failed.';
    }

    @TestVisible
    static Id toId(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        try {
            return Id.valueOf(value);
        } catch (Exception e) {
            return null;
        }
    }

    static String newRampId() {
        return 'RDI' + String.valueOf(Crypto.getRandomInteger()).replace('-', '').left(12);
    }

    static String newSegId() {
        return 'SEG' + String.valueOf(Crypto.getRandomInteger()).replace('-', '').left(12);
    }

    static Result fail(String message) {
        Result r = new Result();
        r.success = false;
        r.message = message;
        return r;
    }
}
