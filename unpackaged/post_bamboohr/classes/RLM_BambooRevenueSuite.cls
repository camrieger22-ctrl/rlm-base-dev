/**
 * BambooHR AE Revenue Suite — Phase 0–1 bootstrap, catalog, add-line, RC reprice.
 * Native RC: each suite option = one Quote. Catalog mirrors Get Pricing PBE rules
 * (BAMBOO-% Standard PB, Months PSM, Evergreen vs TermDefined by termMonths).
 * Line add / qty / reprice go through RevSalesTrxn PlaceSalesTransactionExecutor
 * (FORCE pricing) — thin Apex adapter, no custom pricing math.
 */
public with sharing class RLM_BambooRevenueSuite {
    public class SuiteException extends Exception {
    }

    public class SessionDTO {
        @AuraEnabled
        public Id opportunityId;
        @AuraEnabled
        public String opportunityName;
        @AuraEnabled
        public Id accountId;
        @AuraEnabled
        public String accountName;
        @AuraEnabled
        public Id quoteId;
        @AuraEnabled
        public String quoteName;
        @AuraEnabled
        public String quoteNumber;
        @AuraEnabled
        public Date closeDate;
        @AuraEnabled
        public String currencyIsoCode;
        @AuraEnabled
        public Integer termMonths;
        @AuraEnabled
        public String billingFrequency;
        @AuraEnabled
        public Boolean evergreen;
        @AuraEnabled
        public String optionLabel;
        /** Opportunity.SyncedQuoteId when set (winning option for forecasting). */
        @AuraEnabled
        public Id syncedQuoteId;
    }

    public class CatalogProductDTO {
        @AuraEnabled
        public String sku;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String badge;
        @AuraEnabled
        public Boolean frequent;
        @AuraEnabled
        public Decimal listPrice;
        @AuraEnabled
        public String currencyIsoCode;
        @AuraEnabled
        public Id product2Id;
        @AuraEnabled
        public String description;
    }

    public class OptionLineDTO {
        @AuraEnabled
        public Id lineId;
        @AuraEnabled
        public String sku;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public Decimal quantity;
        @AuraEnabled
        public Decimal unitPrice;
        @AuraEnabled
        public Decimal listUnitPrice;
        /** List line total (monthly): listUnit × qty. */
        @AuraEnabled
        public Decimal listTotal;
        @AuraEnabled
        public Decimal netTotal;
        @AuraEnabled
        public Decimal discountPercent;
        @AuraEnabled
        public String startDate;
        @AuraEnabled
        public String endDate;
        /** Inclusive day count between start and end; null when evergreen / open-ended. */
        @AuraEnabled
        public Integer dayCount;
        @AuraEnabled
        public Boolean priced;
        /** Parent bundle QLI when this row is a bundle component. */
        @AuraEnabled
        public Id parentLineId;
        @AuraEnabled
        public Boolean isBundleRoot;
        @AuraEnabled
        public Boolean isBundleChild;
    }

    public class OptionDetailDTO {
        @AuraEnabled
        public Id quoteId;
        @AuraEnabled
        public String optionLabel;
        @AuraEnabled
        public Decimal mrr;
        @AuraEnabled
        public Decimal arr;
        /** RC Quote header rollup (contract value); matches synced Opp Amount. */
        @AuraEnabled
        public Decimal grandTotal;
        /**
         * Suite approval chip: Draft | Pending | Approved | Rejected | Recalled.
         * Sourced from Quote.RLM_Approval_Status__c (null → Draft).
         */
        @AuraEnabled
        public String approvalStatus;
        @AuraEnabled
        public Integer termMonths;
        @AuraEnabled
        public Boolean evergreen;
        @AuraEnabled
        public Boolean priced;
        @AuraEnabled
        public String startDate;
        @AuraEnabled
        public String endDate;
        @AuraEnabled
        public String billingFrequency;
        @AuraEnabled
        public List<OptionLineDTO> lines;
    }

    public class AddLineResultDTO {
        @AuraEnabled
        public Id lineId;
        /** All line Ids created in this Place (single or multi-add). */
        @AuraEnabled
        public List<Id> lineIds;
        @AuraEnabled
        public OptionDetailDTO option;
    }

    /** Inbound from LWC — properties need get/set for Aura deserialization. */
    public class LineInputDTO {
        @AuraEnabled
        public String sku { get; set; }
        @AuraEnabled
        public Decimal quantity { get; set; }
    }

    /** One suite option = one Draft Quote named "… — Option X". */
    public class OptionSummaryDTO {
        @AuraEnabled
        public Id quoteId;
        @AuraEnabled
        public String quoteName;
        @AuraEnabled
        public String quoteNumber;
        @AuraEnabled
        public String optionLabel;
        @AuraEnabled
        public String status;
        @AuraEnabled
        public Integer lineCount;
        @AuraEnabled
        public Decimal mrr;
        @AuraEnabled
        public Decimal arr;
        /** RC Quote header rollup (contract value); matches synced Opp Amount. */
        @AuraEnabled
        public Decimal grandTotal;
        @AuraEnabled
        public Boolean priced;
        @AuraEnabled
        public Boolean selected;
        /** True when this option Quote is Opportunity.SyncedQuoteId. */
        @AuraEnabled
        public Boolean syncedToOpportunity;
        /**
         * Suite approval chip: Draft | Pending | Approved | Rejected | Recalled.
         * Sourced from Quote.RLM_Approval_Status__c (null → Draft).
         */
        @AuraEnabled
        public String approvalStatus;
    }

    /** Result of Start Sync / Stop Sync against the suite Opportunity. */
    public class SyncOpportunityResultDTO {
        @AuraEnabled
        public Id syncedQuoteId;
        @AuraEnabled
        public List<OptionSummaryDTO> options;
    }

    public class AddOptionResultDTO {
        @AuraEnabled
        public OptionSummaryDTO created;
        @AuraEnabled
        public List<OptionSummaryDTO> options;
        @AuraEnabled
        public SessionDTO session;
    }

    public class PreviewResultDTO {
        @AuraEnabled
        public Id processId;
        @AuraEnabled
        public String status;
        @AuraEnabled
        public Id contentVersionId;
        @AuraEnabled
        public Id contentDocumentId;
        @AuraEnabled
        public String downloadUrl;
        @AuraEnabled
        public String title;
        @AuraEnabled
        public String message;
    }

    /** Slice 5 — submit / refresh approval status for one suite option. */
    public class ApprovalResultDTO {
        @AuraEnabled
        public Id quoteId;
        @AuraEnabled
        public String approvalStatus;
        @AuraEnabled
        public String summary;
        @AuraEnabled
        public OptionDetailDTO option;
        @AuraEnabled
        public List<OptionSummaryDTO> options;
    }

    /** Opp Contact row for Send to customer picker. */
    public class ContactOptionDTO {
        @AuraEnabled
        public Id contactId;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String email;
    }

    /** Slice 5 — email option quote (+ optional DocGen PDF). */
    public class SendResultDTO {
        @AuraEnabled
        public Boolean success;
        @AuraEnabled
        public String message;
        @AuraEnabled
        public String toAddress;
        @AuraEnabled
        public Id quoteId;
        @AuraEnabled
        public Id contentVersionId;
    }

    /** Good / Better / Best option quotes prepared for the AE agent rail. */
    public class TierOptionsResultDTO {
        @AuraEnabled
        public List<OptionSummaryDTO> options;
        @AuraEnabled
        public SessionDTO session;
        @AuraEnabled
        public Id goodQuoteId;
        @AuraEnabled
        public Id betterQuoteId;
        @AuraEnabled
        public Id bestQuoteId;
        @AuraEnabled
        public String summary;
    }

    private static final Set<Integer> ALLOWED_TERMS = new Set<Integer>{ 1, 12, 24, 36 };
    private static final String OPTION_NAME_MARKER = ' — Option ';
    private static final Integer MAX_OPTIONS = 6;
    private static final Set<String> FREQUENT_SKUS = new Set<String>{
        'BAMBOO-CORE',
        'BAMBOO-PRO',
        'BAMBOO-ELITE',
        'BAMBOO-ADD-PAYROLL'
    };
    private static final String WORKFORCE_PKG_SKU = 'BAMBOO-PKG-WORKFORCE';
    private static final Set<String> WORKFORCE_PLAN_SKUS = new Set<String>{
        'BAMBOO-CORE',
        'BAMBOO-PRO',
        'BAMBOO-ELITE'
    };
    private static final String WORKFORCE_DEFAULT_PLAN = 'BAMBOO-PRO';
    private static final String PROPOSAL_TEMPLATE_NAME = 'RLM_Bamboo_QuoteProposal';

    @AuraEnabled
    public static SessionDTO openFromOpportunity(String opportunityId) {
        Id oppId = parseId(opportunityId, 'Opportunity');
        Opportunity opp = [
            SELECT
                Id,
                Name,
                AccountId,
                Account.Name,
                CloseDate,
                Pricebook2Id,
                CurrencyIsoCode,
                SyncedQuoteId
            FROM Opportunity
            WHERE Id = :oppId
            WITH USER_MODE
            LIMIT 1
        ];

        Quote draft = findOptionADraft(opp.Id);
        if (draft == null) {
            draft = createOptionAQuote(opp);
        }
        return toSession(opp, draft);
    }

    @AuraEnabled(cacheable=true)
    public static SessionDTO getSession(String quoteId) {
        Id qId = parseId(quoteId, 'Quote');
        Quote q = [
            SELECT
                Id,
                Name,
                QuoteNumber,
                OpportunityId,
                Opportunity.Name,
                Opportunity.AccountId,
                Opportunity.Account.Name,
                Opportunity.CloseDate,
                Opportunity.CurrencyIsoCode,
                Opportunity.SyncedQuoteId,
                CurrencyIsoCode,
                Status
            FROM Quote
            WHERE Id = :qId
            WITH USER_MODE
            LIMIT 1
        ];
        SessionDTO dto = new SessionDTO();
        dto.opportunityId = q.OpportunityId;
        dto.opportunityName = q.Opportunity.Name;
        dto.accountId = q.Opportunity.AccountId;
        dto.accountName = q.Opportunity.Account.Name;
        dto.closeDate = q.Opportunity.CloseDate;
        dto.currencyIsoCode = String.isNotBlank(q.CurrencyIsoCode)
            ? q.CurrencyIsoCode
            : q.Opportunity.CurrencyIsoCode;
        dto.quoteId = q.Id;
        dto.quoteName = q.Name;
        dto.quoteNumber = q.QuoteNumber;
        Integer months = inferTermMonths(q.Id);
        dto.termMonths = months;
        dto.billingFrequency = 'Monthly';
        dto.evergreen = isEvergreen(months);
        dto.optionLabel = optionLabelFromName(q.Name);
        dto.syncedQuoteId = q.Opportunity.SyncedQuoteId;
        return dto;
    }

    /**
     * All suite options on the Opportunity (Draft Quotes named "… — Option X").
     * selectedQuoteId marks the active card; blank selects none.
     */
    @AuraEnabled
    public static List<OptionSummaryDTO> listOptions(
        String opportunityId,
        String selectedQuoteId
    ) {
        Id oppId = parseId(opportunityId, 'Opportunity');
        Id selectedId = String.isBlank(selectedQuoteId)
            ? null
            : parseId(selectedQuoteId, 'Quote');
        return buildOptionSummaries(oppId, selectedId);
    }

    /**
     * Creates the next empty option Quote (B, C, …) under the Opportunity.
     * Native RC: each option is a real Quote — no shadow cart.
     */
    @AuraEnabled
    public static AddOptionResultDTO addOption(String opportunityId) {
        Id oppId = parseId(opportunityId, 'Opportunity');
        Opportunity opp = [
            SELECT
                Id,
                Name,
                AccountId,
                Account.Name,
                CloseDate,
                Pricebook2Id,
                CurrencyIsoCode,
                SyncedQuoteId
            FROM Opportunity
            WHERE Id = :oppId
            WITH USER_MODE
            LIMIT 1
        ];

        List<OptionSummaryDTO> existing = buildOptionSummaries(oppId, null);
        if (existing.size() >= MAX_OPTIONS) {
            throw new SuiteException(
                'Maximum of ' + MAX_OPTIONS + ' options per opportunity.'
            );
        }
        String nextLetter = nextOptionLetter(existing);
        Quote created = createOptionQuote(opp, nextLetter);
        AddOptionResultDTO result = new AddOptionResultDTO();
        Boolean synced =
            opp.SyncedQuoteId != null && created.Id == opp.SyncedQuoteId;
        result.created = toSummary(
            created,
            buildOptionDetail(created.Id),
            true,
            synced
        );
        result.options = buildOptionSummaries(oppId, created.Id);
        result.session = toSession(opp, created);
        return result;
    }

    /**
     * Delete a suite option Quote (and its lines). Keeps at least one option.
     * If the deleted quote was selected, session switches to another remaining option.
     */
    @AuraEnabled
    public static AddOptionResultDTO deleteOption(String quoteId) {
        Id qId = parseId(quoteId, 'Quote');
        Quote q = [
            SELECT
                Id,
                Name,
                Status,
                OpportunityId,
                Opportunity.Name,
                Opportunity.AccountId,
                Opportunity.Account.Name,
                Opportunity.CloseDate,
                Opportunity.Pricebook2Id,
                Opportunity.CurrencyIsoCode,
                Opportunity.SyncedQuoteId,
                CurrencyIsoCode
            FROM Quote
            WHERE Id = :qId
            WITH USER_MODE
            LIMIT 1
        ];
        if (optionLetterFromName(q.Name) == null) {
            throw new SuiteException('Only suite option quotes can be deleted from the Revenue Suite.');
        }
        if (q.Status != null && q.Status != 'Draft') {
            throw new SuiteException('Only Draft options can be deleted.');
        }

        Id oppId = q.OpportunityId;
        List<OptionSummaryDTO> existing = buildOptionSummaries(oppId, null);
        if (existing.size() <= 1) {
            throw new SuiteException('Keep at least one option. Add another before deleting this one.');
        }

        List<QuoteLineItem> lines = [
            SELECT Id
            FROM QuoteLineItem
            WHERE QuoteId = :qId
            WITH USER_MODE
        ];
        if (!lines.isEmpty()) {
            Database.DeleteResult[] lineDrs = Database.delete(lines, false, AccessLevel.USER_MODE);
            for (Database.DeleteResult dr : lineDrs) {
                if (!dr.isSuccess()) {
                    throw new SuiteException(firstError(dr));
                }
            }
        }
        Database.DeleteResult qDr = Database.delete(q, false, AccessLevel.USER_MODE);
        if (!qDr.isSuccess()) {
            throw new SuiteException(firstError(qDr));
        }

        List<OptionSummaryDTO> remaining = buildOptionSummaries(oppId, null);
        if (remaining.isEmpty()) {
            throw new SuiteException('Option delete left no remaining options.');
        }
        Id nextQuoteId = remaining[0].quoteId;
        Quote nextQuote = [
            SELECT Id, Name, QuoteNumber, CurrencyIsoCode, Status
            FROM Quote
            WHERE Id = :nextQuoteId
            WITH USER_MODE
            LIMIT 1
        ];
        Opportunity opp = q.Opportunity;
        AddOptionResultDTO result = new AddOptionResultDTO();
        result.created = null;
        result.options = buildOptionSummaries(oppId, nextQuoteId);
        result.session = toSession(opp, nextQuote);
        return result;
    }

    /**
     * Start Quote→Opportunity sync for a suite option (sets Opportunity.SyncedQuoteId).
     * Same effect as Quote UI Start Sync — Opp products/Amount track this Quote for forecasting.
     */
    @AuraEnabled
    public static SyncOpportunityResultDTO syncOptionToOpportunity(String quoteId) {
        Id qId = parseId(quoteId, 'Quote');
        Quote q = [
            SELECT
                Id,
                Name,
                OpportunityId,
                GrandTotal,
                TotalPrice
            FROM Quote
            WHERE Id = :qId
            WITH USER_MODE
            LIMIT 1
        ];
        if (q.OpportunityId == null) {
            throw new SuiteException('Quote is not linked to an Opportunity.');
        }
        if (optionLetterFromName(q.Name) == null) {
            throw new SuiteException(
                'Only Bamboo Revenue Suite option quotes can sync to the Opportunity.'
            );
        }
        OptionDetailDTO detail = buildOptionDetail(q.Id);
        if (detail == null || detail.priced != true) {
            throw new SuiteException(
                'Price the option before syncing it to the Opportunity.'
            );
        }

        Opportunity opp = [
            SELECT Id, Amount, SyncedQuoteId
            FROM Opportunity
            WHERE Id = :q.OpportunityId
            WITH USER_MODE
            LIMIT 1
        ];
        if (opp.SyncedQuoteId != q.Id) {
            try {
                setOpportunitySyncedQuote(opp.Id, q.Id);
            } catch (SuiteException e) {
                throw wrapLockException(e);
            }
        }

        Opportunity afterSync = [
            SELECT Id, Amount, SyncedQuoteId
            FROM Opportunity
            WHERE Id = :opp.Id
            WITH USER_MODE
            LIMIT 1
        ];
        if (afterSync.Amount == null) {
            Decimal total = q.GrandTotal != null ? q.GrandTotal : q.TotalPrice;
            if (total != null) {
                Database.update(
                    new Opportunity(Id = afterSync.Id, Amount = total.setScale(2)),
                    false,
                    AccessLevel.USER_MODE
                );
            }
        }

        SyncOpportunityResultDTO result = new SyncOpportunityResultDTO();
        result.syncedQuoteId = q.Id;
        result.options = buildOptionSummaries(q.OpportunityId, q.Id);
        return result;
    }

    /**
     * Stop Quote→Opportunity sync (clears Opportunity.SyncedQuoteId).
     */
    @AuraEnabled
    public static SyncOpportunityResultDTO unsyncOpportunity(String opportunityId) {
        Id oppId = parseId(opportunityId, 'Opportunity');
        Opportunity opp = [
            SELECT Id, SyncedQuoteId
            FROM Opportunity
            WHERE Id = :oppId
            WITH USER_MODE
            LIMIT 1
        ];
        if (opp.SyncedQuoteId != null) {
            try {
                setOpportunitySyncedQuote(opp.Id, null);
            } catch (SuiteException e) {
                throw wrapLockException(e);
            }
        }
        SyncOpportunityResultDTO result = new SyncOpportunityResultDTO();
        result.syncedQuoteId = null;
        result.options = buildOptionSummaries(oppId, null);
        return result;
    }

    @AuraEnabled(cacheable=true)
    public static List<CatalogProductDTO> getCatalog(String currencyIsoCode) {
        String ccy = String.isBlank(currencyIsoCode) ? 'USD' : currencyIsoCode.trim();
        List<PricebookEntry> rows = [
            SELECT
                Id,
                UnitPrice,
                CurrencyIsoCode,
                Product2Id,
                Product2.Name,
                Product2.StockKeepingUnit,
                Product2.Description,
                Product2.Type,
                ProductSellingModel.SellingModelType,
                ProductSellingModel.PricingTermUnit
            FROM PricebookEntry
            WHERE
                Pricebook2.IsStandard = TRUE
                AND IsActive = TRUE
                AND Product2.IsActive = TRUE
                AND Product2.StockKeepingUnit LIKE 'BAMBOO-%'
                AND CurrencyIsoCode = :ccy
                AND ProductSellingModel.PricingTermUnit = 'Months'
                AND ProductSellingModel.SellingModelType = 'TermDefined'
            WITH SYSTEM_MODE
            ORDER BY Product2.StockKeepingUnit
        ];

        Map<String, CatalogProductDTO> bySku = new Map<String, CatalogProductDTO>();
        for (PricebookEntry pbe : rows) {
            String sku = pbe.Product2.StockKeepingUnit;
            if (String.isBlank(sku) || bySku.containsKey(sku)) {
                continue;
            }
            CatalogProductDTO dto = new CatalogProductDTO();
            dto.sku = sku;
            dto.name = pbe.Product2.Name;
            dto.description = pbe.Product2.Description;
            dto.listPrice = pbe.UnitPrice;
            dto.currencyIsoCode = pbe.CurrencyIsoCode;
            dto.product2Id = pbe.Product2Id;
            dto.badge = badgeForSku(sku, pbe.Product2.Type);
            dto.frequent = FREQUENT_SKUS.contains(sku);
            bySku.put(sku, dto);
        }
        return bySku.values();
    }

    @AuraEnabled
    public static OptionDetailDTO getOptionDetail(String quoteId) {
        Id qId = parseId(quoteId, 'Quote');
        return buildOptionDetail(qId);
    }

    @AuraEnabled
    public static AddLineResultDTO addProductLine(
        String quoteId,
        String sku,
        Decimal quantity,
        Integer termMonths,
        String startDateIso,
        String billingFrequency
    ) {
        LineInputDTO line = new LineInputDTO();
        line.sku = sku;
        line.quantity = quantity;
        return addProductLines(
            quoteId,
            new List<LineInputDTO>{ line },
            termMonths,
            startDateIso,
            billingFrequency
        );
    }

    /**
     * LWC-friendly multi-add with per-SKU quantities (parallel lists avoid nested
     * DTO deserialization gaps from the client).
     * skus[i] pairs with quantities[i]; missing/blank qty defaults to 1.
     */
    @AuraEnabled
    public static AddLineResultDTO addProductLinesBySku(
        String quoteId,
        List<String> skus,
        List<Decimal> quantities,
        Integer termMonths,
        String startDateIso,
        String billingFrequency
    ) {
        if (skus == null || skus.isEmpty()) {
            throw new SuiteException('At least one product line is required.');
        }
        List<LineInputDTO> lines = new List<LineInputDTO>();
        for (Integer i = 0; i < skus.size(); i++) {
            String sku = skus[i];
            if (String.isBlank(sku)) {
                continue;
            }
            Decimal qty = 1;
            if (quantities != null && i < quantities.size() && quantities[i] != null) {
                qty = quantities[i];
            }
            LineInputDTO line = new LineInputDTO();
            line.sku = sku.trim();
            line.quantity = qty;
            lines.add(line);
        }
        return addProductLines(
            quoteId,
            lines,
            termMonths,
            startDateIso,
            billingFrequency
        );
    }

    /**
     * Add one or more catalog lines in a single Place + FORCE. Shared term/billing
     * apply to every line in the request.
     */
    @AuraEnabled
    public static AddLineResultDTO addProductLines(
        String quoteId,
        List<LineInputDTO> lines,
        Integer termMonths,
        String startDateIso,
        String billingFrequency
    ) {
        Id qId = parseId(quoteId, 'Quote');
        if (lines == null || lines.isEmpty()) {
            throw new SuiteException('At least one product line is required.');
        }

        Integer months = normalizeTerm(termMonths);
        Quote q = [
            SELECT Id, Pricebook2Id, CurrencyIsoCode, Opportunity.CurrencyIsoCode
            FROM Quote
            WHERE Id = :qId
            WITH USER_MODE
            LIMIT 1
        ];
        String ccy = String.isNotBlank(q.CurrencyIsoCode)
            ? q.CurrencyIsoCode
            : q.Opportunity.CurrencyIsoCode;
        if (String.isBlank(ccy)) {
            ccy = 'USD';
        }

        Date startDate = parseStartDate(startDateIso);
        Date endDate = computeEndDate(startDate, months);
        String billing = normalizeBilling(billingFrequency);
        Id treatmentId = resolveBillingTreatmentId(ccy);

        Set<Id> beforeIds = existingLineIds(qId);

        List<RevSalesTrxn.RecordWithReferenceRequest> nodes =
            new List<RevSalesTrxn.RecordWithReferenceRequest>();
        nodes.add(
            new RevSalesTrxn.RecordWithReferenceRequest(
                'refQuote',
                new RevSalesTrxn.RecordResource(Quote.getSObjectType(), 'PATCH', q.Id)
            )
        );

        Integer i = 0;
        for (LineInputDTO raw : lines) {
            if (raw == null || String.isBlank(raw.sku)) {
                throw new SuiteException('SKU is required for every line.');
            }
            Decimal qty = raw.quantity == null || raw.quantity <= 0 ? 1 : raw.quantity;
            PricebookEntry pbe = resolvePbe(raw.sku.trim(), ccy, months);
            Map<String, Object> lineFields = new Map<String, Object>{
                'QuoteId' => String.valueOf(q.Id),
                'Product2Id' => pbe.Product2Id,
                'PricebookEntryId' => pbe.Id,
                'Quantity' => qty,
                'UnitPrice' => pbe.UnitPrice != null ? pbe.UnitPrice : 0,
                'StartDate' => String.valueOf(startDate),
                'BillingFrequency' => billing,
                'BillingTreatmentId' => String.valueOf(treatmentId),
                'PeriodBoundary' => 'Anniversary'
            };
            if (endDate != null) {
                lineFields.put('EndDate', String.valueOf(endDate));
            }
            RevSalesTrxn.RecordResource lineNode = new RevSalesTrxn.RecordResource(
                QuoteLineItem.getSObjectType(),
                'POST'
            );
            lineNode.fieldValues = lineFields;
            nodes.add(
                new RevSalesTrxn.RecordWithReferenceRequest('refLine' + i, lineNode)
            );
            i++;
        }

        executePlaceForce(qId, nodes);

        List<Id> created = new List<Id>();
        for (QuoteLineItem qi : [
            SELECT Id
            FROM QuoteLineItem
            WHERE QuoteId = :qId
            WITH USER_MODE
            ORDER BY CreatedDate ASC
        ]) {
            if (beforeIds == null || !beforeIds.contains(qi.Id)) {
                created.add(qi.Id);
            }
        }
        if (created.isEmpty()) {
            throw new SuiteException('Lines were priced but could not be resolved on the quote.');
        }

        AddLineResultDTO result = new AddLineResultDTO();
        result.lineIds = created;
        result.lineId = created[created.size() - 1];
        result.option = buildOptionDetail(qId);
        return result;
    }

    /**
     * Path A Workforce package: Place package root with configurator default
     * expand (System + addDefaultConfiguration), then swap the base-plan child
     * when the AE picked Core or Elite instead of default Pro.
     */
    @AuraEnabled
    public static AddLineResultDTO addWorkforcePackage(
        String quoteId,
        String planSku,
        Decimal quantity,
        Integer termMonths,
        String startDateIso,
        String billingFrequency
    ) {
        Id qId = parseId(quoteId, 'Quote');
        String plan = String.isBlank(planSku)
            ? WORKFORCE_DEFAULT_PLAN
            : planSku.trim().toUpperCase();
        if (!WORKFORCE_PLAN_SKUS.contains(plan)) {
            throw new SuiteException(
                'Workforce plan must be BAMBOO-CORE, BAMBOO-PRO, or BAMBOO-ELITE.'
            );
        }
        // Default expand always selects Pro (IsDefaultComponent). Place cannot swap
        // Product2/PBE on configured children or POST ParentQuoteLineItemId — Core/Elite
        // under the package needs configurator user selection (follow-up).
        if (plan != WORKFORCE_DEFAULT_PLAN) {
            throw new SuiteException(
                'Workforce Path A currently expands with Pro (catalog default). ' +
                    'Core/Elite under the package needs configurator plan selection — ' +
                    'add those plans a-la-carte with Payroll + Benefits for Path B, or pick Pro.'
            );
        }
        Decimal qty = quantity == null || quantity <= 0 ? 1 : quantity;
        Integer months = normalizeTerm(termMonths);

        Quote q = [
            SELECT Id, Pricebook2Id, CurrencyIsoCode, Opportunity.CurrencyIsoCode
            FROM Quote
            WHERE Id = :qId
            WITH USER_MODE
            LIMIT 1
        ];
        String ccy = String.isNotBlank(q.CurrencyIsoCode)
            ? q.CurrencyIsoCode
            : q.Opportunity.CurrencyIsoCode;
        if (String.isBlank(ccy)) {
            ccy = 'USD';
        }

        Date startDate = parseStartDate(startDateIso);
        Date endDate = computeEndDate(startDate, months);
        String billing = normalizeBilling(billingFrequency);
        Id treatmentId = resolveBillingTreatmentId(ccy);
        PricebookEntry pkgPbe = resolvePbe(WORKFORCE_PKG_SKU, ccy, months);

        Set<Id> beforeIds = existingLineIds(qId);

        List<RevSalesTrxn.RecordWithReferenceRequest> nodes =
            new List<RevSalesTrxn.RecordWithReferenceRequest>();
        nodes.add(
            new RevSalesTrxn.RecordWithReferenceRequest(
                'refQuote',
                new RevSalesTrxn.RecordResource(Quote.getSObjectType(), 'PATCH', q.Id)
            )
        );

        Map<String, Object> pkgFields = new Map<String, Object>{
            'QuoteId' => String.valueOf(q.Id),
            'Product2Id' => pkgPbe.Product2Id,
            'PricebookEntryId' => pkgPbe.Id,
            'Quantity' => qty,
            'UnitPrice' => pkgPbe.UnitPrice != null ? pkgPbe.UnitPrice : 0,
            'StartDate' => String.valueOf(startDate),
            'BillingFrequency' => billing,
            'BillingTreatmentId' => String.valueOf(treatmentId),
            'PeriodBoundary' => 'Anniversary'
        };
        if (endDate != null) {
            pkgFields.put('EndDate', String.valueOf(endDate));
        }
        RevSalesTrxn.RecordResource pkgNode = new RevSalesTrxn.RecordResource(
            QuoteLineItem.getSObjectType(),
            'POST'
        );
        pkgNode.fieldValues = pkgFields;
        nodes.add(new RevSalesTrxn.RecordWithReferenceRequest('refPkg', pkgNode));

        executePlaceConfigure(qId, nodes);

        // Configurator expand creates child components with platform defaults
        // (often Monthly + ~1-month EndDate). Re-stamp commercial terms onto
        // every line so package children match the parent term/billing.
        stampCommercialTermsOnAllLines(qId, startDate, endDate, billing, treatmentId);

        Id pkgLineId = null;
        for (QuoteLineItem qi : [
            SELECT Id, Product2.StockKeepingUnit, ParentQuoteLineItemId
            FROM QuoteLineItem
            WHERE QuoteId = :qId
            WITH USER_MODE
            ORDER BY CreatedDate ASC
        ]) {
            if (beforeIds != null && beforeIds.contains(qi.Id)) {
                continue;
            }
            if (
                qi.Product2 != null &&
                qi.Product2.StockKeepingUnit == WORKFORCE_PKG_SKU &&
                qi.ParentQuoteLineItemId == null
            ) {
                pkgLineId = qi.Id;
                break;
            }
        }
        if (pkgLineId == null) {
            throw new SuiteException(
                'Workforce package line was not created. Check PCM / configurator setup.'
            );
        }

        AddLineResultDTO result = new AddLineResultDTO();
        result.lineId = pkgLineId;
        result.lineIds = new List<Id>{ pkgLineId };
        result.option = buildOptionDetail(qId);
        return result;
    }

    /**
     * Start DocGen for the active option Quote using RLM_Bamboo_QuoteProposal.
     * Returns a process Id; poll {@link #getProposalStatus} until Completed.
     */
    @AuraEnabled
    public static PreviewResultDTO previewProposal(String quoteId) {
        Id qId = parseId(quoteId, 'Quote');
        Quote q = [
            SELECT Id, Name, QuoteNumber
            FROM Quote
            WHERE Id = :qId
            WITH USER_MODE
            LIMIT 1
        ];

        List<DocumentTemplate> templates = [
            SELECT Id, Name, TokenMappingMethodType
            FROM DocumentTemplate
            WHERE Name = :PROPOSAL_TEMPLATE_NAME AND IsActive = TRUE
            WITH USER_MODE
            ORDER BY VersionNumber DESC
            LIMIT 1
        ];
        if (templates.isEmpty()) {
            throw new SuiteException(
                'Document template ' +
                    PROPOSAL_TEMPLATE_NAME +
                    ' is not active in this org.'
            );
        }
        DocumentTemplate tmpl = templates[0];

        String title =
            'BambooHR Proposal — ' +
            (String.isNotBlank(q.QuoteNumber) ? q.QuoteNumber : q.Name);

        Map<String, Object> requestText = new Map<String, Object>{
            'keepIntermediate' => true,
            'title' => title
        };
        Id templateCvId = resolveTemplateContentVersionId(tmpl.Name);
        if (templateCvId != null) {
            requestText.put('templateContentVersionId', String.valueOf(templateCvId));
        }

        DocumentGenerationProcess process = new DocumentGenerationProcess();
        process.Type = 'GenerateAndConvert';
        process.ReferenceObject = q.Id;
        process.DocumentTemplateId = tmpl.Id;
        process.RequestText = JSON.serialize(requestText);
        process.DocGenApiVersionType = 'Advanced';
        process.DocumentInputType = 'DocumentTemplate';
        if (tmpl.TokenMappingMethodType == 'ContextService') {
            process.DocGenAdditionalInputType = 'ContextService';
            process.DocGenAdditionalInput = String.valueOf(q.Id);
        } else {
            process.DataRaptorInput = JSON.serialize(
                new Map<String, Object>{ 'Id' => q.Id }
            );
        }
        insert as user process;

        PreviewResultDTO out = new PreviewResultDTO();
        out.processId = process.Id;
        out.status = 'InProgress';
        out.title = title;
        out.message = 'Generating proposal…';
        return out;
    }

    /** Poll DocGen process; when Completed, prefer the PDF ContentVersion. */
    @AuraEnabled
    public static PreviewResultDTO getProposalStatus(String processId) {
        Id pId = parseId(processId, 'DocumentGenerationProcess');
        List<DocumentGenerationProcess> rows = [
            SELECT Id, Status, ResponseText, ReferenceObject
            FROM DocumentGenerationProcess
            WHERE Id = :pId
            WITH USER_MODE
            LIMIT 1
        ];
        if (rows.isEmpty()) {
            throw new SuiteException('Document generation process not found.');
        }
        DocumentGenerationProcess dgp = rows[0];
        PreviewResultDTO out = new PreviewResultDTO();
        out.processId = dgp.Id;
        out.status = dgp.Status;
        if (dgp.Status == 'Failed' || dgp.Status == 'Error') {
            out.message = String.isNotBlank(dgp.ResponseText)
                ? dgp.ResponseText
                : 'Document generation failed.';
            return out;
        }
        if (dgp.Status != 'Completed' && dgp.Status != 'Success') {
            out.message = 'Generating proposal…';
            return out;
        }

        List<Id> versionIds = parseContentVersionIds(dgp.ResponseText);
        if (versionIds.isEmpty()) {
            out.message = 'Generation completed but no file was returned.';
            return out;
        }
        List<ContentVersion> pdfs = [
            SELECT Id, ContentDocumentId, Title, FileType
            FROM ContentVersion
            WHERE Id IN :versionIds AND FileType = 'PDF'
            WITH USER_MODE
            LIMIT 1
        ];
        List<ContentVersion> files = pdfs;
        if (files.isEmpty()) {
            files = [
                SELECT Id, ContentDocumentId, Title, FileType
                FROM ContentVersion
                WHERE Id IN :versionIds
                WITH USER_MODE
                ORDER BY CreatedDate DESC
                LIMIT 1
            ];
        }
        if (files.isEmpty()) {
            out.message = 'Generation completed but no readable file was found.';
            return out;
        }
        ContentVersion file = files[0];
        out.contentVersionId = file.Id;
        out.contentDocumentId = file.ContentDocumentId;
        out.title = file.Title;
        out.downloadUrl = '/sfc/servlet.shepherd/version/download/' + file.Id;
        out.message = 'Proposal ready';
        return out;
    }

    /**
     * Submit a suite option Quote into RLM Quote Smart Approval (orchestration).
     * Sets RLM_Approval_Status__c to Pending first; orchestration may move it to
     * Approved immediately when no discount / payment-terms criteria apply.
     * If the orchestration Apex cannot start, falls back to Approved for demo orgs.
     */
    @AuraEnabled
    public static ApprovalResultDTO submitOptionForApproval(
        String quoteId,
        String comments
    ) {
        Id qId = parseId(quoteId, 'Quote');
        Quote q = [
            SELECT
                Id,
                Name,
                OpportunityId,
                RLM_Approval_Status__c,
                RLM_Approval_Level__c
            FROM Quote
            WHERE Id = :qId
            WITH USER_MODE
            LIMIT 1
        ];
        if (optionLetterFromName(q.Name) == null) {
            throw new SuiteException(
                'Only Bamboo Revenue Suite option quotes can be submitted for approval.'
            );
        }
        OptionDetailDTO detail = buildOptionDetail(qId);
        if (detail == null || detail.priced != true) {
            throw new SuiteException('Price the option before submitting for approval.');
        }
        String current = normalizeApprovalStatus(q.RLM_Approval_Status__c);
        if (current == 'Pending') {
            throw new SuiteException(
                'This option is already pending approval. Refresh options to check status.'
            );
        }
        if (current == 'Approved') {
            ApprovalResultDTO already = new ApprovalResultDTO();
            already.quoteId = qId;
            already.approvalStatus = 'Approved';
            already.summary = 'Option is already approved.';
            already.option = detail;
            already.options = buildOptionSummaries(q.OpportunityId, qId);
            return already;
        }

        setQuoteApprovalStatus(qId, 'Pending');

        String summary;
        try {
            RLM_AA_Submit_Approval.svcParameter param =
                new RLM_AA_Submit_Approval.svcParameter();
            param.flowName = 'RLM_Quote_Smart_Approval';
            param.recordId = String.valueOf(qId);
            param.approvalLevel = q.RLM_Approval_Level__c == null
                ? null
                : String.valueOf(q.RLM_Approval_Level__c);
            param.comments = String.isBlank(comments)
                ? 'Submitted from BambooHR Revenue Suite'
                : comments.trim();
            RLM_AA_Submit_Approval.callFlow(
                new List<RLM_AA_Submit_Approval.svcParameter>{ param }
            );
            summary =
                'Submitted for Smart Approval. Refresh options if status stays Pending.';
        } catch (Exception e) {
            // Orchestration may be unavailable for the running user — demo fallback.
            setQuoteApprovalStatus(qId, 'Approved');
            String detailMsg = e.getMessage();
            summary =
                'Marked Approved (Smart Approval did not start' +
                (String.isBlank(detailMsg) ? '' : ': ' + detailMsg) +
                ').';
        }

        ApprovalResultDTO result = new ApprovalResultDTO();
        result.quoteId = qId;
        result.option = buildOptionDetail(qId);
        result.approvalStatus = result.option != null
            ? result.option.approvalStatus
            : normalizeApprovalStatus(null);
        result.summary = summary;
        result.options = buildOptionSummaries(q.OpportunityId, qId);
        return result;
    }

    /** Contacts on the suite Opportunity Account (email required) for Send picker. */
    @AuraEnabled(cacheable=true)
    public static List<ContactOptionDTO> listOpportunityContacts(String opportunityId) {
        Id oppId = parseId(opportunityId, 'Opportunity');
        Opportunity opp = [
            SELECT AccountId
            FROM Opportunity
            WHERE Id = :oppId
            WITH USER_MODE
            LIMIT 1
        ];
        List<ContactOptionDTO> out = new List<ContactOptionDTO>();
        if (opp.AccountId == null) {
            return out;
        }
        for (Contact c : [
            SELECT Id, Name, Email
            FROM Contact
            WHERE AccountId = :opp.AccountId AND Email != NULL
            WITH USER_MODE
            ORDER BY Name ASC
            LIMIT 50
        ]) {
            ContactOptionDTO row = new ContactOptionDTO();
            row.contactId = c.Id;
            row.name = c.Name;
            row.email = c.Email;
            out.add(row);
        }
        return out;
    }

    /**
     * Email the active option to an Opp Contact (or toAddress override).
     * Allowed when priced and not Pending. Attaches latest proposal PDF when
     * present; optionally starts DocGen first when generatePdfIfMissing=true.
     */
    @AuraEnabled
    public static SendResultDTO sendOptionToCustomer(
        String quoteId,
        String contactId,
        String toAddress,
        Boolean attachPdf,
        Boolean generatePdfIfMissing
    ) {
        Id qId = parseId(quoteId, 'Quote');
        Quote q = [
            SELECT
                Id,
                Name,
                OpportunityId,
                ContactId,
                RLM_Approval_Status__c
            FROM Quote
            WHERE Id = :qId
            WITH USER_MODE
            LIMIT 1
        ];
        if (optionLetterFromName(q.Name) == null) {
            throw new SuiteException(
                'Only Bamboo Revenue Suite option quotes can be sent from the suite.'
            );
        }
        OptionDetailDTO detail = buildOptionDetail(qId);
        if (detail == null || detail.priced != true) {
            throw new SuiteException('Price the option before sending to the customer.');
        }
        String approval = normalizeApprovalStatus(q.RLM_Approval_Status__c);
        if (approval == 'Pending') {
            throw new SuiteException(
                'Cannot send while approval is Pending. Wait for Approved or recall first.'
            );
        }

        Id cvId = null;
        if (attachPdf != false) {
            cvId = findLatestProposalContentVersionId(qId);
            if (cvId == null && generatePdfIfMissing == true) {
                // LWC should call previewProposal + poll first; do not busy-wait here.
                throw new SuiteException(
                    'No proposal PDF found. Click Preview to generate one, then Send again.'
                );
            }
        }

        if (String.isNotBlank(contactId)) {
            Id cId = parseId(contactId, 'Contact');
            if (q.ContactId != cId) {
                Database.update(
                    new Quote(Id = qId, ContactId = cId),
                    false,
                    AccessLevel.USER_MODE
                );
            }
        }

        RLM_BambooQuoteEmail.Request req = new RLM_BambooQuoteEmail.Request();
        req.quoteId = qId;
        req.contentVersionId = cvId;
        if (String.isNotBlank(toAddress)) {
            req.toAddress = toAddress.trim();
        }
        RLM_BambooQuoteEmail.Result emailed = RLM_BambooQuoteEmail.sendOne(req);

        SendResultDTO out = new SendResultDTO();
        out.success = emailed.success == true;
        out.message = emailed.message;
        out.toAddress = emailed.toAddress;
        out.quoteId = qId;
        out.contentVersionId = cvId;
        if (!out.success) {
            throw new SuiteException(
                String.isNotBlank(out.message) ? out.message : 'Send email failed.'
            );
        }
        return out;
    }

    private static void setQuoteApprovalStatus(Id quoteId, String status) {
        Database.SaveResult sr = Database.update(
            new Quote(Id = quoteId, RLM_Approval_Status__c = status),
            false,
            AccessLevel.USER_MODE
        );
        if (!sr.isSuccess()) {
            throw new SuiteException(firstError(sr));
        }
    }

    @TestVisible
    static String normalizeApprovalStatus(String raw) {
        if (String.isBlank(raw)) {
            return 'Draft';
        }
        String v = raw.trim();
        if (v.equalsIgnoreCase('Pending')) {
            return 'Pending';
        }
        if (v.equalsIgnoreCase('Approved')) {
            return 'Approved';
        }
        if (v.equalsIgnoreCase('Rejected')) {
            return 'Rejected';
        }
        if (v.equalsIgnoreCase('Recalled')) {
            return 'Recalled';
        }
        return v;
    }

    private static Id findLatestProposalContentVersionId(Id quoteId) {
        List<ContentDocumentLink> links = [
            SELECT ContentDocumentId
            FROM ContentDocumentLink
            WHERE LinkedEntityId = :quoteId
            WITH USER_MODE
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
        List<ContentVersion> versions = [
            SELECT Id, Title, FileType
            FROM ContentVersion
            WHERE
                ContentDocumentId IN :docIds
                AND IsLatest = TRUE
                AND FileType = 'PDF'
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 10
        ];
        for (ContentVersion cv : versions) {
            if (
                String.isNotBlank(cv.Title) &&
                cv.Title.toLowerCase().contains('proposal')
            ) {
                return cv.Id;
            }
        }
        return versions.isEmpty() ? null : versions[0].Id;
    }

    /**
     * BotDefinition Id for Quoting Assistant (Quinn) — used by suite rail
     * lightning/accApi open/execute. Null when the agent is not published in the org.
     */
    @AuraEnabled(cacheable=true)
    public static String getQuotingAssistantBotId() {
        List<BotDefinition> bots = [
            SELECT Id
            FROM BotDefinition
            WHERE DeveloperName = 'RLM_Quoting_Assistant'
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        return bots.isEmpty() ? null : String.valueOf(bots[0].Id);
    }

    /**
     * Ensure Option A/B/C exist for the Opportunity (create empty B/C as needed).
     * Does not clear or fill lines — call {@link #fillTierOption} per tier.
     */
    @AuraEnabled
    public static TierOptionsResultDTO ensureGoodBetterBestOptions(String opportunityId) {
        Id oppId = parseId(opportunityId, 'Opportunity');
        Opportunity opp = [
            SELECT
                Id,
                Name,
                AccountId,
                Account.Name,
                CloseDate,
                Pricebook2Id,
                CurrencyIsoCode,
                SyncedQuoteId
            FROM Opportunity
            WHERE Id = :oppId
            WITH USER_MODE
            LIMIT 1
        ];

        List<OptionSummaryDTO> options = buildOptionSummaries(oppId, null);
        while (options.size() < 3) {
            if (options.size() >= MAX_OPTIONS) {
                throw new SuiteException(
                    'Need Options A–C for Good/Better/Best, but the opportunity already has ' +
                        MAX_OPTIONS +
                        ' options.'
                );
            }
            String nextLetter = nextOptionLetter(options);
            createOptionQuote(opp, nextLetter);
            options = buildOptionSummaries(oppId, null);
        }

        Id goodId = quoteIdForLetter(options, 'A');
        Id betterId = quoteIdForLetter(options, 'B');
        Id bestId = quoteIdForLetter(options, 'C');
        if (goodId == null || betterId == null || bestId == null) {
            throw new SuiteException(
                'Could not resolve Option A/B/C for Good/Better/Best.'
            );
        }

        Quote goodQuote = [
            SELECT Id, Name, QuoteNumber, CurrencyIsoCode, Status
            FROM Quote
            WHERE Id = :goodId
            WITH USER_MODE
            LIMIT 1
        ];

        TierOptionsResultDTO result = new TierOptionsResultDTO();
        result.options = buildOptionSummaries(oppId, goodId);
        result.session = toSession(opp, goodQuote);
        result.goodQuoteId = goodId;
        result.betterQuoteId = betterId;
        result.bestQuoteId = bestId;
        result.summary =
            'Ready to fill Good (A), Better (B), and Best (C) for ' + opp.Name + '.';
        return result;
    }

    /**
     * Clear existing lines on a suite option and fill Good / Better / Best catalog.
     * Good = Path B Core+Payroll+Benefits; Better = Workforce Pro package;
     * Best = Path B Elite+Payroll+Benefits+Time.
     */
    @AuraEnabled
    public static OptionDetailDTO fillTierOption(
        String quoteId,
        String tierKey,
        Decimal seats,
        Integer termMonths,
        String startDateIso,
        String billingFrequency
    ) {
        Id qId = parseId(quoteId, 'Quote');
        String tier = String.isBlank(tierKey) ? '' : tierKey.trim().toLowerCase();
        Decimal qty = seats == null || seats <= 0 ? 50 : seats;
        Integer months = normalizeTerm(termMonths);
        String startIso = String.isBlank(startDateIso)
            ? String.valueOf(Date.today())
            : startDateIso.trim();
        String billing = normalizeBilling(billingFrequency);

        clearAllLinesOnQuote(qId);

        if (tier == 'good' || tier == 'a' || tier == 'core') {
            addProductLinesBySku(
                String.valueOf(qId),
                new List<String>{
                    'BAMBOO-CORE',
                    'BAMBOO-ADD-PAYROLL',
                    'BAMBOO-ADD-BENEFITS'
                },
                new List<Decimal>{ qty, qty, qty },
                months,
                startIso,
                billing
            );
        } else if (tier == 'better' || tier == 'b' || tier == 'pro') {
            addWorkforcePackage(
                String.valueOf(qId),
                WORKFORCE_DEFAULT_PLAN,
                qty,
                months,
                startIso,
                billing
            );
        } else if (tier == 'best' || tier == 'c' || tier == 'elite') {
            addProductLinesBySku(
                String.valueOf(qId),
                new List<String>{
                    'BAMBOO-ELITE',
                    'BAMBOO-ADD-PAYROLL',
                    'BAMBOO-ADD-BENEFITS',
                    'BAMBOO-ADD-TIME'
                },
                new List<Decimal>{ qty, qty, qty, qty },
                months,
                startIso,
                billing
            );
        } else {
            throw new SuiteException(
                'Unknown tier "' +
                    tierKey +
                    '". Use Good, Better, or Best.'
            );
        }
        return buildOptionDetail(qId);
    }

    private static Id quoteIdForLetter(List<OptionSummaryDTO> options, String letter) {
        if (options == null || String.isBlank(letter)) {
            return null;
        }
        for (OptionSummaryDTO opt : options) {
            if (opt != null && optionLetter(opt.optionLabel) == letter) {
                return opt.quoteId;
            }
        }
        return null;
    }

    private static void clearAllLinesOnQuote(Id quoteId) {
        List<QuoteLineItem> lines = [
            SELECT Id
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
            WITH USER_MODE
        ];
        if (lines.isEmpty()) {
            return;
        }
        List<String> ids = new List<String>();
        for (QuoteLineItem qi : lines) {
            ids.add(String.valueOf(qi.Id));
        }
        removeLines(String.valueOf(quoteId), ids);
    }

    private static Id resolveTemplateContentVersionId(String templateName) {
        List<ContentWorkspace> libs = [
            SELECT Id
            FROM ContentWorkspace
            WHERE DeveloperName = 'DocgenDocumentTemplateLibrary'
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (libs.isEmpty()) {
            return null;
        }
        List<ContentDocument> docs = [
            SELECT Id
            FROM ContentDocument
            WHERE
                Title = :templateName
                AND Id IN (
                    SELECT ContentDocumentId
                    FROM ContentWorkspaceDoc
                    WHERE ContentWorkspaceId = :libs[0].Id
                )
            WITH SYSTEM_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (docs.isEmpty()) {
            return null;
        }
        List<ContentVersion> versions = [
            SELECT Id
            FROM ContentVersion
            WHERE ContentDocumentId = :docs[0].Id
            WITH SYSTEM_MODE
            ORDER BY VersionNumber DESC
            LIMIT 1
        ];
        return versions.isEmpty() ? null : versions[0].Id;
    }

    private static List<Id> parseContentVersionIds(String responseText) {
        List<Id> ids = new List<Id>();
        if (String.isBlank(responseText)) {
            return ids;
        }
        String text = responseText.trim();
        if (text.startsWith('{') || text.startsWith('[')) {
            return ids;
        }
        for (String token : text.split(',')) {
            String trimmed = token.trim();
            if (String.isBlank(trimmed)) {
                continue;
            }
            try {
                ids.add((Id) trimmed);
            } catch (Exception e) {
                // skip non-Id tokens
            }
        }
        return ids;
    }

    /**
     * Persist quantity via Place Sales Transaction + FORCE pricing (RC engine).
     * LWC should debounce (300–500ms); not every keystroke.
     */
    @AuraEnabled
    public static OptionDetailDTO updateLineQuantity(
        String quoteId,
        String lineId,
        Decimal quantity
    ) {
        Id qId = parseId(quoteId, 'Quote');
        Id lId = parseId(lineId, 'QuoteLineItem');
        Decimal qty = quantity == null || quantity <= 0 ? 1 : quantity;

        List<QuoteLineItem> owned = [
            SELECT Id
            FROM QuoteLineItem
            WHERE Id = :lId AND QuoteId = :qId
            WITH USER_MODE
            LIMIT 1
        ];
        if (owned.isEmpty()) {
            throw new SuiteException('Line does not belong to this option quote.');
        }

        List<RevSalesTrxn.RecordWithReferenceRequest> nodes =
            new List<RevSalesTrxn.RecordWithReferenceRequest>();
        nodes.add(
            new RevSalesTrxn.RecordWithReferenceRequest(
                'refQuote',
                new RevSalesTrxn.RecordResource(Quote.getSObjectType(), 'PATCH', qId)
            )
        );

        RevSalesTrxn.RecordResource lineNode = new RevSalesTrxn.RecordResource(
            QuoteLineItem.getSObjectType(),
            'PATCH',
            lId
        );
        lineNode.fieldValues = new Map<String, Object>{ 'Quantity' => qty };
        nodes.add(new RevSalesTrxn.RecordWithReferenceRequest('refLine', lineNode));

        executePlaceForce(qId, nodes);
        return buildOptionDetail(qId);
    }

    /**
     * Persist AE line discount % via PartnerDiscountPercent + FORCE pricing.
     * Null / blank clears the partner discount.
     */
    @AuraEnabled
    public static OptionDetailDTO updateLineDiscount(
        String quoteId,
        String lineId,
        Decimal discountPercent
    ) {
        Id qId = parseId(quoteId, 'Quote');
        Id lId = parseId(lineId, 'QuoteLineItem');
        Decimal pct = discountPercent == null ? 0 : discountPercent;
        if (pct < 0) {
            pct = 0;
        }
        if (pct > 100) {
            pct = 100;
        }

        List<QuoteLineItem> owned = [
            SELECT Id
            FROM QuoteLineItem
            WHERE Id = :lId AND QuoteId = :qId
            WITH USER_MODE
            LIMIT 1
        ];
        if (owned.isEmpty()) {
            throw new SuiteException('Line does not belong to this option quote.');
        }

        List<RevSalesTrxn.RecordWithReferenceRequest> nodes =
            new List<RevSalesTrxn.RecordWithReferenceRequest>();
        nodes.add(
            new RevSalesTrxn.RecordWithReferenceRequest(
                'refQuote',
                new RevSalesTrxn.RecordResource(Quote.getSObjectType(), 'PATCH', qId)
            )
        );

        RevSalesTrxn.RecordResource lineNode = new RevSalesTrxn.RecordResource(
            QuoteLineItem.getSObjectType(),
            'PATCH',
            lId
        );
        lineNode.fieldValues = new Map<String, Object>{ 'PartnerDiscountPercent' => pct };
        nodes.add(new RevSalesTrxn.RecordWithReferenceRequest('refLine', lineNode));

        executePlaceForce(qId, nodes);
        return buildOptionDetail(qId);
    }

    /** Re-run System pricing on the option quote (FORCE) without structural changes. */
    @AuraEnabled
    public static OptionDetailDTO repriceOption(String quoteId) {
        Id qId = parseId(quoteId, 'Quote');
        List<QuoteLineItem> lines = [
            SELECT Id, Quantity
            FROM QuoteLineItem
            WHERE QuoteId = :qId
            WITH USER_MODE
        ];
        if (lines.isEmpty()) {
            return buildOptionDetail(qId);
        }

        List<RevSalesTrxn.RecordWithReferenceRequest> nodes =
            new List<RevSalesTrxn.RecordWithReferenceRequest>();
        nodes.add(
            new RevSalesTrxn.RecordWithReferenceRequest(
                'refQuote',
                new RevSalesTrxn.RecordResource(Quote.getSObjectType(), 'PATCH', qId)
            )
        );
        Integer i = 0;
        for (QuoteLineItem qi : lines) {
            // Re-assert quantity so FORCE pricing recalculates nets on each line.
            RevSalesTrxn.RecordResource lineNode = new RevSalesTrxn.RecordResource(
                QuoteLineItem.getSObjectType(),
                'PATCH',
                qi.Id
            );
            lineNode.fieldValues = new Map<String, Object>{
                'Quantity' => qi.Quantity != null ? qi.Quantity : 1
            };
            nodes.add(
                new RevSalesTrxn.RecordWithReferenceRequest('refLine' + i++, lineNode)
            );
        }
        executePlaceForce(qId, nodes);
        return buildOptionDetail(qId);
    }

    /**
     * Remove a line via Place Sales Transaction DELETE + FORCE reprice.
     */
    @AuraEnabled
    public static OptionDetailDTO removeLine(String quoteId, String lineId) {
        return removeLines(quoteId, new List<String>{ lineId });
    }

    /**
     * Remove one or more lines in a single Place DELETE + FORCE reprice.
     */
    @AuraEnabled
    public static OptionDetailDTO removeLines(String quoteId, List<String> lineIds) {
        Id qId = parseId(quoteId, 'Quote');
        if (lineIds == null || lineIds.isEmpty()) {
            throw new SuiteException('Select at least one line to delete.');
        }
        Set<Id> requested = new Set<Id>();
        for (String raw : lineIds) {
            if (String.isBlank(raw)) {
                continue;
            }
            requested.add(parseId(raw, 'QuoteLineItem'));
        }
        if (requested.isEmpty()) {
            throw new SuiteException('Select at least one line to delete.');
        }

        List<QuoteLineItem> owned = [
            SELECT Id
            FROM QuoteLineItem
            WHERE Id IN :requested AND QuoteId = :qId
            WITH USER_MODE
        ];
        if (owned.size() != requested.size()) {
            throw new SuiteException('One or more lines do not belong to this option quote.');
        }

        requested = expandBundleDeleteIds(qId, requested);

        List<RevSalesTrxn.RecordWithReferenceRequest> nodes =
            new List<RevSalesTrxn.RecordWithReferenceRequest>();
        nodes.add(
            new RevSalesTrxn.RecordWithReferenceRequest(
                'refQuote',
                new RevSalesTrxn.RecordResource(Quote.getSObjectType(), 'PATCH', qId)
            )
        );
        owned = [
            SELECT Id
            FROM QuoteLineItem
            WHERE Id IN :requested AND QuoteId = :qId
            WITH USER_MODE
        ];

        Integer i = 0;
        for (QuoteLineItem qi : owned) {
            nodes.add(
                new RevSalesTrxn.RecordWithReferenceRequest(
                    'refDelete' + i,
                    new RevSalesTrxn.RecordResource(
                        QuoteLineItem.getSObjectType(),
                        'DELETE',
                        qi.Id
                    )
                )
            );
            i++;
        }
        executePlaceForce(qId, nodes);
        return buildOptionDetail(qId);
    }

    /**
     * Apply term length (+ optional start date) to the active option: restamp every
     * line onto the matching Evergreen / TermDefined PBE with Start/End dates via
     * Place DELETE+POST + FORCE. Empty options are a no-op (UI keeps ribbon until add).
     * End date = start + termMonths − 1 day (Neocol-style inclusive term).
     */
    @AuraEnabled
    public static OptionDetailDTO applyTermToOption(
        String quoteId,
        Integer termMonths,
        String startDateIso,
        String billingFrequency
    ) {
        Id qId = parseId(quoteId, 'Quote');
        Integer months = normalizeTerm(termMonths);
        String billing = normalizeBilling(billingFrequency);

        Quote q = [
            SELECT Id, CurrencyIsoCode, Opportunity.CurrencyIsoCode
            FROM Quote
            WHERE Id = :qId
            WITH USER_MODE
            LIMIT 1
        ];
        String ccy = String.isNotBlank(q.CurrencyIsoCode)
            ? q.CurrencyIsoCode
            : q.Opportunity.CurrencyIsoCode;
        if (String.isBlank(ccy)) {
            ccy = 'USD';
        }

        List<QuoteLineItem> lines = [
            SELECT
                Id,
                Quantity,
                PartnerDiscountPercent,
                ParentQuoteLineItemId,
                Product2.StockKeepingUnit
            FROM QuoteLineItem
            WHERE QuoteId = :qId
            WITH USER_MODE
            ORDER BY CreatedDate ASC
        ];
        if (lines.isEmpty()) {
            // Nothing to restamp; ribbon term is UI-only until first line.
            OptionDetailDTO empty = buildOptionDetail(qId);
            Date startDate = parseStartDate(startDateIso);
            empty.termMonths = months;
            empty.evergreen = isEvergreen(months);
            empty.startDate = String.valueOf(startDate);
            Date endDate = computeEndDate(startDate, months);
            empty.endDate = endDate == null ? null : String.valueOf(endDate);
            empty.billingFrequency = billing;
            return empty;
        }

        Date startDate = parseStartDate(startDateIso);
        Date endDate = computeEndDate(startDate, months);
        Id treatmentId = resolveBillingTreatmentId(ccy);

        // PATCH (not DELETE+POST) so Workforce package ParentQuoteLineItemId
        // hierarchy survives term/billing restamps. Also swap PricebookEntryId
        // so Evergreen ↔ TermDefined selling-model changes stick without
        // flattening the bundle.
        List<RevSalesTrxn.RecordWithReferenceRequest> nodes =
            new List<RevSalesTrxn.RecordWithReferenceRequest>();
        nodes.add(
            new RevSalesTrxn.RecordWithReferenceRequest(
                'refQuote',
                new RevSalesTrxn.RecordResource(Quote.getSObjectType(), 'PATCH', qId)
            )
        );

        Integer i = 0;
        for (QuoteLineItem qi : lines) {
            String sku = qi.Product2 != null ? qi.Product2.StockKeepingUnit : null;
            if (String.isBlank(sku)) {
                throw new SuiteException('Cannot restamp a line without a product SKU.');
            }
            PricebookEntry pbe = resolvePbe(sku, ccy, months);
            Map<String, Object> lineFields = new Map<String, Object>{
                'PricebookEntryId' => pbe.Id,
                'Product2Id' => pbe.Product2Id,
                'UnitPrice' => pbe.UnitPrice != null ? pbe.UnitPrice : 0,
                'StartDate' => String.valueOf(startDate),
                'BillingFrequency' => billing,
                'BillingTreatmentId' => String.valueOf(treatmentId),
                'PeriodBoundary' => 'Anniversary',
                'Quantity' => qi.Quantity == null || qi.Quantity <= 0 ? 1 : qi.Quantity
            };
            if (endDate != null) {
                lineFields.put('EndDate', String.valueOf(endDate));
            }
            if (qi.PartnerDiscountPercent != null) {
                lineFields.put('PartnerDiscountPercent', qi.PartnerDiscountPercent);
            }
            RevSalesTrxn.RecordResource lineNode = new RevSalesTrxn.RecordResource(
                QuoteLineItem.getSObjectType(),
                'PATCH',
                qi.Id
            );
            lineNode.fieldValues = lineFields;
            nodes.add(
                new RevSalesTrxn.RecordWithReferenceRequest('refTerm' + i++, lineNode)
            );
        }

        executePlaceForce(qId, nodes);
        OptionDetailDTO detail = buildOptionDetail(qId);
        detail.termMonths = months;
        detail.evergreen = isEvergreen(months);
        detail.startDate = String.valueOf(startDate);
        detail.endDate = endDate == null ? null : String.valueOf(endDate);
        detail.billingFrequency = billing;
        return detail;
    }

    /**
     * Place FORCE PATCH of StartDate / EndDate / BillingFrequency onto every
     * QuoteLineItem (parent and children). Used after Workforce configurator
     * expand and by applyTermToOption so commercial terms stay consistent.
     */
    private static void stampCommercialTermsOnAllLines(
        Id quoteId,
        Date startDate,
        Date endDate,
        String billingFrequency,
        Id treatmentId
    ) {
        List<QuoteLineItem> lines = [
            SELECT Id, Quantity
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
            WITH USER_MODE
        ];
        if (lines.isEmpty()) {
            return;
        }
        String billing = normalizeBilling(billingFrequency);
        List<RevSalesTrxn.RecordWithReferenceRequest> nodes =
            new List<RevSalesTrxn.RecordWithReferenceRequest>();
        nodes.add(
            new RevSalesTrxn.RecordWithReferenceRequest(
                'refQuote',
                new RevSalesTrxn.RecordResource(Quote.getSObjectType(), 'PATCH', quoteId)
            )
        );
        Integer i = 0;
        for (QuoteLineItem qi : lines) {
            Map<String, Object> lineFields = new Map<String, Object>{
                'StartDate' => String.valueOf(startDate),
                'BillingFrequency' => billing,
                'BillingTreatmentId' => String.valueOf(treatmentId),
                'PeriodBoundary' => 'Anniversary',
                'Quantity' => qi.Quantity == null || qi.Quantity <= 0 ? 1 : qi.Quantity
            };
            if (endDate != null) {
                lineFields.put('EndDate', String.valueOf(endDate));
            }
            RevSalesTrxn.RecordResource lineNode = new RevSalesTrxn.RecordResource(
                QuoteLineItem.getSObjectType(),
                'PATCH',
                qi.Id
            );
            lineNode.fieldValues = lineFields;
            nodes.add(
                new RevSalesTrxn.RecordWithReferenceRequest('refStamp' + i++, lineNode)
            );
        }
        executePlaceForce(quoteId, nodes);
    }

    /**
     * Apply term start + length to suite options on the Opportunity.
     * When quoteIds is null/empty, all options are updated; otherwise only the
     * listed quote Ids (Shared-scope options). Preserves each option's billing.
     * Returns the selected option's detail (for the active card refresh).
     */
    @AuraEnabled
    public static OptionDetailDTO applyTermToAllOptions(
        String opportunityId,
        String selectedQuoteId,
        Integer termMonths,
        String startDateIso,
        List<String> quoteIds
    ) {
        Id oppId = parseId(opportunityId, 'Opportunity');
        Id selectedId = String.isBlank(selectedQuoteId)
            ? null
            : parseId(selectedQuoteId, 'Quote');
        List<OptionSummaryDTO> options = buildOptionSummaries(oppId, selectedId);
        if (options.isEmpty()) {
            throw new SuiteException('No quote options found on this opportunity.');
        }

        Set<Id> onlyIds = null;
        if (quoteIds != null && !quoteIds.isEmpty()) {
            onlyIds = new Set<Id>();
            for (String raw : quoteIds) {
                if (String.isBlank(raw)) {
                    continue;
                }
                onlyIds.add(parseId(raw, 'Quote'));
            }
        }

        OptionDetailDTO selectedDetail = null;
        Boolean touchedSelected = false;
        for (OptionSummaryDTO opt : options) {
            if (onlyIds != null && !onlyIds.contains(opt.quoteId)) {
                continue;
            }
            String billing = billingFrequencyForOption(opt.quoteId);
            OptionDetailDTO detail = applyTermToOption(
                opt.quoteId,
                termMonths,
                startDateIso,
                billing
            );
            if (selectedId != null && opt.quoteId == selectedId) {
                selectedDetail = detail;
                touchedSelected = true;
            }
        }
        if (selectedId != null && !touchedSelected) {
            selectedDetail = buildOptionDetail(selectedId);
        } else if (selectedDetail == null && selectedId != null) {
            selectedDetail = buildOptionDetail(selectedId);
        } else if (selectedDetail == null) {
            selectedDetail = buildOptionDetail(options[0].quoteId);
        }
        return selectedDetail;
    }

    /**
     * Apply billing frequency to suite options, preserving each option's
     * current term start / length. When quoteIds is null/empty, all options
     * are updated; otherwise only the listed quote Ids (Shared-scope billing).
     * Empty options (no QLIs) use the optional per-quote maps from the LWC.
     * Returns the selected option's detail.
     */
    @AuraEnabled
    public static OptionDetailDTO applyBillingToAllOptions(
        String opportunityId,
        String selectedQuoteId,
        String billingFrequency,
        Map<String, Integer> termMonthsByQuoteId,
        Map<String, String> startDateByQuoteId,
        List<String> quoteIds
    ) {
        Id oppId = parseId(opportunityId, 'Opportunity');
        Id selectedId = String.isBlank(selectedQuoteId)
            ? null
            : parseId(selectedQuoteId, 'Quote');
        String billing = normalizeBilling(billingFrequency);
        List<OptionSummaryDTO> options = buildOptionSummaries(oppId, selectedId);
        if (options.isEmpty()) {
            throw new SuiteException('No quote options found on this opportunity.');
        }

        Set<Id> onlyIds = null;
        if (quoteIds != null && !quoteIds.isEmpty()) {
            onlyIds = new Set<Id>();
            for (String raw : quoteIds) {
                if (String.isBlank(raw)) {
                    continue;
                }
                onlyIds.add(parseId(raw, 'Quote'));
            }
        }

        OptionDetailDTO selectedDetail = null;
        Boolean touchedSelected = false;
        for (OptionSummaryDTO opt : options) {
            if (onlyIds != null && !onlyIds.contains(opt.quoteId)) {
                continue;
            }
            OptionDetailDTO current = buildOptionDetail(opt.quoteId);
            Boolean hasLines = current.lines != null && !current.lines.isEmpty();
            Integer months;
            String startIso;
            String key = String.valueOf(opt.quoteId);
            if (hasLines) {
                months = current.termMonths != null
                    ? current.termMonths
                    : 12;
                startIso = String.isNotBlank(current.startDate)
                    ? current.startDate
                    : String.valueOf(Date.today());
            } else {
                months = (termMonthsByQuoteId != null &&
                    termMonthsByQuoteId.containsKey(key))
                    ? normalizeTerm(termMonthsByQuoteId.get(key))
                    : 12;
                startIso = (startDateByQuoteId != null &&
                    String.isNotBlank(startDateByQuoteId.get(key)))
                    ? startDateByQuoteId.get(key)
                    : String.valueOf(Date.today());
            }
            OptionDetailDTO detail = applyTermToOption(
                opt.quoteId,
                months,
                startIso,
                billing
            );
            if (selectedId != null && opt.quoteId == selectedId) {
                selectedDetail = detail;
                touchedSelected = true;
            }
        }
        if (selectedId != null && !touchedSelected) {
            selectedDetail = buildOptionDetail(selectedId);
        } else if (selectedDetail == null && selectedId != null) {
            selectedDetail = buildOptionDetail(selectedId);
        } else if (selectedDetail == null) {
            selectedDetail = buildOptionDetail(options[0].quoteId);
        }
        return selectedDetail;
    }

    private static String billingFrequencyForOption(Id quoteId) {
        List<QuoteLineItem> lines = [
            SELECT BillingFrequency
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
            WITH USER_MODE
            ORDER BY CreatedDate ASC
            LIMIT 1
        ];
        if (!lines.isEmpty() && String.isNotBlank(lines[0].BillingFrequency)) {
            return normalizeBilling(lines[0].BillingFrequency);
        }
        return 'Monthly';
    }

    /** Slice 4d Phase A — immediate retries on Opp row lock. */
    @TestVisible
    private static final Integer LOCK_RETRY_ATTEMPTS = 3;

    /**
     * PST locks the parent Opportunity when SyncedQuoteId is set (even for a sibling
     * option quote). Clear sync before Place, verify pricing while still unsynced, then
     * restore SyncedQuoteId asynchronously (Queueable) so PST and Opp DML do not race.
     */
    private static void executePlaceForce(
        Id quoteId,
        List<RevSalesTrxn.RecordWithReferenceRequest> nodes
    ) {
        runPlaceWithOpportunitySyncSuspended(
            quoteId,
            nodes,
            RevSalesTrxn.PricingPreferenceEnum.FORCE,
            RevSalesTrxn.ConfigurationExecutionEnum.SKIP,
            new RevSalesTrxn.ConfigurationOptionsInput()
        );
    }

    /** Place with configurator expand (Workforce Path A default components). */
    private static void executePlaceConfigure(
        Id quoteId,
        List<RevSalesTrxn.RecordWithReferenceRequest> nodes
    ) {
        RevSalesTrxn.ConfigurationOptionsInput opts =
            new RevSalesTrxn.ConfigurationOptionsInput();
        opts.addDefaultConfiguration = true;
        opts.executeConfigurationRules = true;
        opts.validateProductCatalog = true;
        opts.validateAmendRenewCancel = true;
        runPlaceWithOpportunitySyncSuspended(
            quoteId,
            nodes,
            RevSalesTrxn.PricingPreferenceEnum.FORCE,
            RevSalesTrxn.ConfigurationExecutionEnum.SYSTEM,
            opts
        );
    }

    private static void runPlaceWithOpportunitySyncSuspended(
        Id quoteId,
        List<RevSalesTrxn.RecordWithReferenceRequest> nodes,
        RevSalesTrxn.PricingPreferenceEnum pricingPref,
        RevSalesTrxn.ConfigurationExecutionEnum configExec,
        RevSalesTrxn.ConfigurationOptionsInput configOpts
    ) {
        Id oppId = opportunityIdForQuote(quoteId);
        Id syncedQuoteId = syncedQuoteIdForOpportunity(oppId);
        if (syncedQuoteId != null) {
            setOpportunitySyncedQuote(oppId, null);
        }
        try {
            executePlace(nodes, pricingPref, configExec, configOpts);
            ensureQuotePricedWhileSyncSuspended(quoteId);
        } finally {
            if (syncedQuoteId != null) {
                enqueueRestoreSyncedQuote(oppId, syncedQuoteId);
            }
        }
    }

    /**
     * After Place FORCE: if the quote still looks unpriced / invalid, run one
     * quantity-assert reprice while SyncedQuoteId is still cleared (reduces
     * platform automatic-reprice jobs that lock the Opportunity).
     */
    private static void ensureQuotePricedWhileSyncSuspended(Id quoteId) {
        if (!quoteNeedsForceReprice(quoteId)) {
            return;
        }
        List<QuoteLineItem> lines = [
            SELECT Id, Quantity
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
            WITH USER_MODE
        ];
        if (lines.isEmpty()) {
            return;
        }
        List<RevSalesTrxn.RecordWithReferenceRequest> nodes =
            new List<RevSalesTrxn.RecordWithReferenceRequest>();
        nodes.add(
            new RevSalesTrxn.RecordWithReferenceRequest(
                'refQuote',
                new RevSalesTrxn.RecordResource(Quote.getSObjectType(), 'PATCH', quoteId)
            )
        );
        Integer i = 0;
        for (QuoteLineItem qi : lines) {
            RevSalesTrxn.RecordResource lineNode = new RevSalesTrxn.RecordResource(
                QuoteLineItem.getSObjectType(),
                'PATCH',
                qi.Id
            );
            lineNode.fieldValues = new Map<String, Object>{
                'Quantity' => qi.Quantity != null ? qi.Quantity : 1
            };
            nodes.add(
                new RevSalesTrxn.RecordWithReferenceRequest('refVerify' + i++, lineNode)
            );
        }
        // Direct Place — do not nest executePlaceForce (would suspend/restore again).
        executePlace(
            nodes,
            RevSalesTrxn.PricingPreferenceEnum.FORCE,
            RevSalesTrxn.ConfigurationExecutionEnum.SKIP,
            new RevSalesTrxn.ConfigurationOptionsInput()
        );
    }

    @TestVisible
    public static Boolean quoteNeedsForceReprice(Id quoteId) {
        if (quoteId == null) {
            return false;
        }
        List<Quote> headers = [
            SELECT Id, CalculationStatus, ValidationResult
            FROM Quote
            WHERE Id = :quoteId
            WITH USER_MODE
            LIMIT 1
        ];
        if (headers.isEmpty()) {
            return false;
        }
        Quote header = headers[0];
        if (String.isNotBlank(header.ValidationResult)) {
            return true;
        }
        String status = header.CalculationStatus;
        if (String.isNotBlank(status)) {
            String s = status.toLowerCase();
            if (
                s.contains('fail') ||
                s.contains('inprogress') ||
                s.contains('incomplete') ||
                s.contains('error')
            ) {
                return true;
            }
        }
        List<QuoteLineItem> lines = [
            SELECT Id, NetUnitPrice, ParentQuoteLineItemId
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
            WITH USER_MODE
        ];
        if (lines.isEmpty()) {
            return false;
        }
        Set<Id> bundleParentIds = new Set<Id>();
        for (QuoteLineItem row : lines) {
            if (row.ParentQuoteLineItemId != null) {
                bundleParentIds.add(row.ParentQuoteLineItemId);
            }
        }
        Boolean anyBillable = false;
        Boolean anyPriced = false;
        for (QuoteLineItem qi : lines) {
            if (bundleParentIds.contains(qi.Id)) {
                continue;
            }
            anyBillable = true;
            if (qi.NetUnitPrice != null) {
                anyPriced = true;
            }
        }
        return anyBillable && !anyPriced;
    }

    private static Id opportunityIdForQuote(Id quoteId) {
        List<Quote> rows = [
            SELECT OpportunityId
            FROM Quote
            WHERE Id = :quoteId
            WITH USER_MODE
            LIMIT 1
        ];
        if (rows.isEmpty() || rows[0].OpportunityId == null) {
            throw new SuiteException('Quote is not linked to an Opportunity.');
        }
        return rows[0].OpportunityId;
    }

    private static Id syncedQuoteIdForOpportunity(Id opportunityId) {
        List<Opportunity> rows = [
            SELECT SyncedQuoteId
            FROM Opportunity
            WHERE Id = :opportunityId
            WITH USER_MODE
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0].SyncedQuoteId;
    }

    @TestVisible
    public static void enqueueRestoreSyncedQuote(Id opportunityId, Id quoteId) {
        if (opportunityId == null || quoteId == null) {
            return;
        }
        System.enqueueJob(
            new RLM_BambooSuiteRestoreOppSync(opportunityId, quoteId, 0)
        );
    }

    /**
     * Restore SyncedQuoteId with lock retries. Used by Queueable and tests.
     */
    public static void restoreOpportunitySyncedQuote(Id opportunityId, Id quoteId) {
        setOpportunitySyncedQuote(opportunityId, quoteId);
    }

    private static void setOpportunitySyncedQuote(Id opportunityId, Id quoteId) {
        SuiteException last = null;
        for (Integer attempt = 0; attempt < LOCK_RETRY_ATTEMPTS; attempt++) {
            Database.SaveResult sr = Database.update(
                new Opportunity(Id = opportunityId, SyncedQuoteId = quoteId),
                false,
                AccessLevel.USER_MODE
            );
            if (sr.isSuccess()) {
                return;
            }
            String msg = firstError(sr);
            if (!isLockError(msg)) {
                throw new SuiteException(msg);
            }
            last = new SuiteException(msg);
        }
        throw wrapLockException(last);
    }

    private static void executePlace(
        List<RevSalesTrxn.RecordWithReferenceRequest> nodes,
        RevSalesTrxn.PricingPreferenceEnum pricingPref,
        RevSalesTrxn.ConfigurationExecutionEnum configExec,
        RevSalesTrxn.ConfigurationOptionsInput configOpts
    ) {
        SuiteException last = null;
        for (Integer attempt = 0; attempt < LOCK_RETRY_ATTEMPTS; attempt++) {
            RevSalesTrxn.GraphRequest graph = new RevSalesTrxn.GraphRequest(
                'BambooRevenueSuite',
                nodes
            );
            RevSalesTrxn.PlaceSalesTransactionResponse resp = RevSalesTrxn.PlaceSalesTransactionExecutor.execute(
                graph,
                pricingPref,
                configExec,
                configOpts == null
                    ? new RevSalesTrxn.ConfigurationOptionsInput()
                    : configOpts,
                null
            );
            if (resp != null && resp.isSuccess) {
                return;
            }
            String msg = pstError(resp);
            if (!isLockError(msg)) {
                throw new SuiteException(msg);
            }
            last = new SuiteException(msg);
        }
        throw wrapLockException(last);
    }

    @TestVisible
    public static Boolean isLockError(String message) {
        if (String.isBlank(message)) {
            return false;
        }
        String m = message.toUpperCase();
        return m.contains('UNABLE_TO_LOCK_ROW') || m.contains('UNABLE TO LOCK ROW');
    }

    @TestVisible
    public static String lockRecoveryMessage() {
        return 'Opportunity is busy (row lock). Wait a moment and retry, or open this ' +
            'option Quote and click Reprice All, then Refresh options in the suite.';
    }

    private static SuiteException wrapLockException(SuiteException e) {
        if (e == null) {
            return new SuiteException(lockRecoveryMessage());
        }
        String msg = e.getMessage();
        if (String.isNotBlank(msg) && msg.startsWith('Opportunity is busy')) {
            return e;
        }
        if (isLockError(msg)) {
            return new SuiteException(lockRecoveryMessage() + ' (' + msg + ')');
        }
        return e;
    }

    private static String pstError(RevSalesTrxn.PlaceSalesTransactionResponse resp) {
        if (resp == null) {
            return 'Place Sales Transaction returned no response.';
        }
        if (resp.errorResponse == null || resp.errorResponse.isEmpty()) {
            return 'Place Sales Transaction failed.';
        }
        List<String> parts = new List<String>();
        for (Object err : resp.errorResponse) {
            parts.add(String.valueOf(err));
        }
        return String.join(parts, '; ');
    }

    private static Set<Id> existingLineIds(Id quoteId) {
        Set<Id> ids = new Set<Id>();
        for (QuoteLineItem qi : [
            SELECT Id
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
            WITH USER_MODE
        ]) {
            ids.add(qi.Id);
        }
        return ids;
    }

    private static Id newestLineId(Id quoteId, Set<Id> beforeIds) {
        for (QuoteLineItem qi : [
            SELECT Id
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 20
        ]) {
            if (beforeIds == null || !beforeIds.contains(qi.Id)) {
                return qi.Id;
            }
        }
        throw new SuiteException('Line was priced but could not be resolved on the quote.');
    }

    private static OptionDetailDTO buildOptionDetail(Id quoteId) {
        Quote header = [
            SELECT Id, Name, GrandTotal, TotalPrice, RLM_Approval_Status__c
            FROM Quote
            WHERE Id = :quoteId
            WITH USER_MODE
            LIMIT 1
        ];
        Integer months = inferTermMonths(quoteId);
        List<QuoteLineItem> qlis = [
            SELECT
                Id,
                ParentQuoteLineItemId,
                Quantity,
                UnitPrice,
                ListPrice,
                NetUnitPrice,
                NetTotalPrice,
                TotalPrice,
                Discount,
                PartnerDiscountPercent,
                StartDate,
                EndDate,
                BillingFrequency,
                Product2.Name,
                Product2.StockKeepingUnit
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId
            WITH USER_MODE
            ORDER BY CreatedDate ASC
        ];

        Set<Id> bundleParentIds = new Set<Id>();
        for (QuoteLineItem row : qlis) {
            if (row.ParentQuoteLineItemId != null) {
                bundleParentIds.add(row.ParentQuoteLineItemId);
            }
        }

        OptionDetailDTO dto = new OptionDetailDTO();
        dto.quoteId = quoteId;
        dto.optionLabel = optionLabelFromName(header.Name);
        dto.termMonths = months;
        dto.evergreen = isEvergreen(months);
        dto.billingFrequency = billingFrequencyForOption(quoteId);
        dto.lines = new List<OptionLineDTO>();
        dto.priced = false;
        if (!qlis.isEmpty() && qlis[0].StartDate != null) {
            dto.startDate = String.valueOf(qlis[0].StartDate);
            dto.endDate = qlis[0].EndDate == null
                ? null
                : String.valueOf(qlis[0].EndDate);
        }
        Decimal mrr = 0;
        for (QuoteLineItem qi : qlis) {
            OptionLineDTO line = new OptionLineDTO();
            line.lineId = qi.Id;
            line.parentLineId = qi.ParentQuoteLineItemId;
            line.isBundleChild = qi.ParentQuoteLineItemId != null;
            line.isBundleRoot = bundleParentIds.contains(qi.Id);
            line.sku = qi.Product2 != null ? qi.Product2.StockKeepingUnit : null;
            line.name = qi.Product2 != null ? qi.Product2.Name : null;
            line.quantity = qi.Quantity;
            Decimal listUnit = qi.ListPrice != null ? qi.ListPrice : qi.UnitPrice;
            line.listUnitPrice = listUnit;
            Decimal qty = qi.Quantity == null ? 0 : qi.Quantity;
            line.listTotal = listUnit == null ? 0 : listUnit * qty;
            Boolean hasNet = qi.NetUnitPrice != null;
            line.priced = hasNet;
            if (hasNet) {
                dto.priced = true;
            }
            // Prefer RC-priced net unit (monthly PEPM/flat after FORCE).
            Decimal pricedUnit = hasNet ? qi.NetUnitPrice : qi.UnitPrice;
            line.unitPrice = pricedUnit;
            Decimal net = qi.NetTotalPrice != null
                ? qi.NetTotalPrice
                : (qi.TotalPrice != null
                      ? qi.TotalPrice
                      : (pricedUnit == null || qi.Quantity == null
                            ? 0
                            : pricedUnit * qi.Quantity));
            line.netTotal = net;
            if (qi.PartnerDiscountPercent != null) {
                line.discountPercent = qi.PartnerDiscountPercent;
            } else if (qi.Discount != null) {
                line.discountPercent = qi.Discount;
            } else {
                line.discountPercent = 0;
            }
            if (qi.StartDate != null) {
                line.startDate = String.valueOf(qi.StartDate);
            }
            if (qi.EndDate != null) {
                line.endDate = String.valueOf(qi.EndDate);
                if (qi.StartDate != null) {
                    line.dayCount = qi.StartDate.daysBetween(qi.EndDate) + 1;
                }
            }
            // Bundle roots with children are $0 containers — MRR lives on components.
            if (!line.isBundleRoot) {
                Decimal lineMrr = (pricedUnit == null || qi.Quantity == null)
                    ? 0
                    : pricedUnit * qi.Quantity;
                mrr += lineMrr;
            }
            dto.lines.add(line);
        }
        dto.mrr = mrr;
        dto.arr = mrr * 12;
        dto.grandTotal = header.GrandTotal != null
            ? header.GrandTotal
            : (header.TotalPrice != null ? header.TotalPrice : 0);
        dto.approvalStatus = normalizeApprovalStatus(header.RLM_Approval_Status__c);
        return dto;
    }

    private static List<OptionSummaryDTO> buildOptionSummaries(
        Id opportunityId,
        Id selectedQuoteId
    ) {
        Id syncedQuoteId = null;
        List<Opportunity> opps = [
            SELECT SyncedQuoteId
            FROM Opportunity
            WHERE Id = :opportunityId
            WITH USER_MODE
            LIMIT 1
        ];
        if (!opps.isEmpty()) {
            syncedQuoteId = opps[0].SyncedQuoteId;
        }

        List<Quote> quotes = [
            SELECT Id, Name, QuoteNumber, Status
            FROM Quote
            WHERE
                OpportunityId = :opportunityId
                AND Name LIKE '%Option %'
            WITH USER_MODE
            ORDER BY CreatedDate ASC
        ];
        Map<String, OptionSummaryDTO> byLetter = new Map<String, OptionSummaryDTO>();
        for (Quote q : quotes) {
            String letter = optionLetterFromName(q.Name);
            if (letter == null) {
                continue;
            }
            OptionDetailDTO detail = buildOptionDetail(q.Id);
            Boolean selected = selectedQuoteId != null && q.Id == selectedQuoteId;
            Boolean synced = syncedQuoteId != null && q.Id == syncedQuoteId;
            byLetter.put(letter, toSummary(q, detail, selected, synced));
        }
        List<OptionSummaryDTO> out = new List<OptionSummaryDTO>();
        for (Integer i = 0; i < MAX_OPTIONS; i++) {
            String letter = String.fromCharArray(new List<Integer>{ 65 + i });
            if (byLetter.containsKey(letter)) {
                out.add(byLetter.get(letter));
            }
        }
        return out;
    }

    private static OptionSummaryDTO toSummary(
        Quote q,
        OptionDetailDTO detail,
        Boolean selected,
        Boolean syncedToOpportunity
    ) {
        OptionSummaryDTO s = new OptionSummaryDTO();
        s.quoteId = q.Id;
        s.quoteName = q.Name;
        s.quoteNumber = q.QuoteNumber;
        s.optionLabel = detail != null
            ? detail.optionLabel
            : optionLabelFromName(q.Name);
        s.status = q.Status;
        s.lineCount = detail != null && detail.lines != null
            ? detail.lines.size()
            : 0;
        s.mrr = detail != null ? detail.mrr : 0;
        s.arr = detail != null ? detail.arr : 0;
        s.grandTotal = detail != null ? detail.grandTotal : 0;
        s.priced = detail != null ? detail.priced : false;
        s.selected = selected == true;
        s.syncedToOpportunity = syncedToOpportunity == true;
        s.approvalStatus = detail != null
            ? detail.approvalStatus
            : normalizeApprovalStatus(null);
        return s;
    }

    private static String nextOptionLetter(List<OptionSummaryDTO> existing) {
        Set<String> used = new Set<String>();
        if (existing != null) {
            for (OptionSummaryDTO s : existing) {
                String letter = optionLetter(s.optionLabel);
                if (letter != null) {
                    used.add(letter);
                }
            }
        }
        for (Integer i = 0; i < MAX_OPTIONS; i++) {
            String letter = String.fromCharArray(new List<Integer>{ 65 + i });
            if (!used.contains(letter)) {
                return letter;
            }
        }
        throw new SuiteException('No option letters remaining.');
    }

    private static String optionLabelFromName(String quoteName) {
        String letter = optionLetterFromName(quoteName);
        return letter == null ? 'Option A' : 'Option ' + letter;
    }

    private static String optionLetter(String optionLabel) {
        if (String.isBlank(optionLabel) || !optionLabel.startsWith('Option ')) {
            return null;
        }
        String rest = optionLabel.substring(7).trim();
        return String.isBlank(rest) ? null : rest.substring(0, 1).toUpperCase();
    }

    private static String optionLetterFromName(String quoteName) {
        if (String.isBlank(quoteName)) {
            return null;
        }
        Integer idx = quoteName.indexOf('Option ');
        if (idx < 0) {
            return null;
        }
        String rest = quoteName.substring(idx + 7).trim();
        if (String.isBlank(rest)) {
            return null;
        }
        String ch = rest.substring(0, 1).toUpperCase();
        if (ch < 'A' || ch > 'Z') {
            return null;
        }
        return ch;
    }

    /**
     * TermDefined/Evergreen lines require BillingFrequency AND a BillingTreatment
     * with CanChangeBillingFrequency=true. Prefer Advance treatments for the
     * quote currency (Bamboo products use Billing Policy - Advance).
     */
    private static Id resolveBillingTreatmentId(String currencyIsoCode) {
        String ccy = String.isBlank(currencyIsoCode) ? 'USD' : currencyIsoCode.trim();
        List<BillingTreatment> rows = [
            SELECT Id, Name, CanChangeBillingFrequency
            FROM BillingTreatment
            WHERE Status = 'Active' AND CurrencyIsoCode = :ccy
            WITH SYSTEM_MODE
            ORDER BY Name
        ];
        if (rows.isEmpty()) {
            throw new SuiteException(
                'No active Billing Treatment for ' +
                    ccy +
                    '. Load qb-billing (or enable CanChangeBillingFrequency).'
            );
        }
        BillingTreatment preferred = null;
        for (BillingTreatment t : rows) {
            if (
                t.CanChangeBillingFrequency == true &&
                t.Name != null &&
                t.Name.containsIgnoreCase('Advance')
            ) {
                return t.Id;
            }
            if (preferred == null && t.CanChangeBillingFrequency == true) {
                preferred = t;
            }
        }
        if (preferred != null) {
            return preferred.Id;
        }
        throw new SuiteException(
            'Billing Treatment for ' +
                ccy +
                ' exists but CanChangeBillingFrequency is false. ' +
                'Update the treatment (qb-billing sets this to true) so Monthly / ' +
                'Quarterly / Annual can be selected on quote lines.'
        );
    }

    private static PricebookEntry resolvePbe(String sku, String ccy, Integer termMonths) {
        String smt = isEvergreen(termMonths) ? 'Evergreen' : 'TermDefined';
        List<PricebookEntry> rows = [
            SELECT
                Id,
                UnitPrice,
                ProductSellingModelId,
                Product2Id,
                Product2.StockKeepingUnit
            FROM PricebookEntry
            WHERE
                Pricebook2.IsStandard = TRUE
                AND IsActive = TRUE
                AND Product2.IsActive = TRUE
                AND Product2.StockKeepingUnit = :sku
                AND CurrencyIsoCode = :ccy
                AND ProductSellingModel.PricingTermUnit = 'Months'
                AND ProductSellingModel.SellingModelType = :smt
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (rows.isEmpty() && smt == 'Evergreen') {
            // Fall back to Term Monthly twin if Evergreen PBE missing on org.
            rows = [
                SELECT
                    Id,
                    UnitPrice,
                    ProductSellingModelId,
                    Product2Id,
                    Product2.StockKeepingUnit
                FROM PricebookEntry
                WHERE
                    Pricebook2.IsStandard = TRUE
                    AND IsActive = TRUE
                    AND Product2.IsActive = TRUE
                    AND Product2.StockKeepingUnit = :sku
                    AND CurrencyIsoCode = :ccy
                    AND ProductSellingModel.PricingTermUnit = 'Months'
                    AND ProductSellingModel.SellingModelType = 'TermDefined'
                WITH SYSTEM_MODE
                LIMIT 1
            ];
        }
        if (rows.isEmpty()) {
            throw new SuiteException(
                'No active Standard Price Book entry for ' +
                    sku +
                    ' (' +
                    smt +
                    ', ' +
                    ccy +
                    ').'
            );
        }
        return rows[0];
    }

    private static Integer inferTermMonths(Id quoteId) {
        List<QuoteLineItem> dated = [
            SELECT StartDate, EndDate
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId AND EndDate != NULL
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (dated.isEmpty()) {
            List<QuoteLineItem> anyLine = [
                SELECT Id
                FROM QuoteLineItem
                WHERE QuoteId = :quoteId
                WITH USER_MODE
                LIMIT 1
            ];
            // Lines with blank EndDate → evergreen M2M; no lines → default 12.
            return anyLine.isEmpty() ? 12 : 1;
        }
        QuoteLineItem qi = dated[0];
        if (qi.StartDate == null || qi.EndDate == null) {
            return 12;
        }
        Integer months =
            qi.StartDate.monthsBetween(qi.EndDate.addDays(1));
        if (!ALLOWED_TERMS.contains(months)) {
            return 12;
        }
        return months;
    }

    private static Integer normalizeTerm(Integer termMonths) {
        Integer months = termMonths == null ? 12 : termMonths;
        if (!ALLOWED_TERMS.contains(months)) {
            throw new SuiteException('termMonths must be 1, 12, 24, or 36.');
        }
        return months;
    }

    private static Boolean isEvergreen(Integer termMonths) {
        return termMonths != null && termMonths == 1;
    }

    /** Inclusive term end: start + N months − 1 day (matches Neocol ribbon). */
    private static Date computeEndDate(Date startDate, Integer termMonths) {
        if (startDate == null || isEvergreen(termMonths)) {
            return null;
        }
        return startDate.addMonths(termMonths).addDays(-1);
    }

    private static Date parseStartDate(String startDateIso) {
        if (String.isBlank(startDateIso)) {
            return Date.today();
        }
        try {
            return Date.valueOf(startDateIso.trim());
        } catch (Exception e) {
            throw new SuiteException('Invalid term start date. Use YYYY-MM-DD.');
        }
    }

    private static String normalizeBilling(String billingFrequency) {
        if (String.isBlank(billingFrequency)) {
            return 'Monthly';
        }
        String v = billingFrequency.trim();
        if (v.equalsIgnoreCase('Quarterly')) {
            return 'Quarterly';
        }
        if (v.equalsIgnoreCase('Annual') || v.equalsIgnoreCase('Annually')) {
            return 'Annual';
        }
        return 'Monthly';
    }

    private static String badgeForSku(String sku, String productType) {
        if (String.isNotBlank(productType) && productType.equalsIgnoreCase('Bundle')) {
            return 'BUNDLE';
        }
        if (sku == null) {
            return 'FLAT';
        }
        if (sku.startsWith('BAMBOO-PKG-')) {
            return 'BUNDLE';
        }
        if (sku.contains('-FLAT-')) {
            return 'FLAT';
        }
        if (
            sku == 'BAMBOO-CORE' ||
            sku == 'BAMBOO-PRO' ||
            sku == 'BAMBOO-ELITE'
        ) {
            return 'TIERED';
        }
        return 'FLAT';
    }

    private static Quote findOptionADraft(Id opportunityId) {
        List<Quote> rows = [
            SELECT Id, Name, QuoteNumber, CurrencyIsoCode, Status
            FROM Quote
            WHERE
                OpportunityId = :opportunityId
                AND Status = 'Draft'
                AND Name LIKE '%Option A%'
            WITH USER_MODE
            ORDER BY LastModifiedDate DESC
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    private static Quote createOptionAQuote(Opportunity opp) {
        return createOptionQuote(opp, 'A');
    }

    private static Quote createOptionQuote(Opportunity opp, String letter) {
        Id pricebookId = opp.Pricebook2Id;
        if (pricebookId == null) {
            pricebookId = Test.isRunningTest()
                ? Test.getStandardPricebookId()
                : resolveStandardPricebookId();
        }
        String name = truncateName(opp.Name + OPTION_NAME_MARKER + letter);
        Quote q = new Quote(
            Name = name,
            OpportunityId = opp.Id,
            Pricebook2Id = pricebookId,
            Status = 'Draft'
        );
        if (String.isNotBlank(opp.CurrencyIsoCode)) {
            q.CurrencyIsoCode = opp.CurrencyIsoCode;
        }
        Database.SaveResult sr = Database.insert(q, false, AccessLevel.USER_MODE);
        if (!sr.isSuccess()) {
            throw new SuiteException(firstError(sr));
        }
        return [
            SELECT Id, Name, QuoteNumber, CurrencyIsoCode, Status
            FROM Quote
            WHERE Id = :sr.getId()
            WITH USER_MODE
            LIMIT 1
        ];
    }

    private static SessionDTO toSession(Opportunity opp, Quote q) {
        SessionDTO dto = new SessionDTO();
        dto.opportunityId = opp.Id;
        dto.opportunityName = opp.Name;
        dto.accountId = opp.AccountId;
        dto.accountName = opp.Account != null ? opp.Account.Name : null;
        dto.closeDate = opp.CloseDate;
        dto.currencyIsoCode = String.isNotBlank(q.CurrencyIsoCode)
            ? q.CurrencyIsoCode
            : opp.CurrencyIsoCode;
        dto.quoteId = q.Id;
        dto.quoteName = q.Name;
        dto.quoteNumber = q.QuoteNumber;
        Integer months = inferTermMonths(q.Id);
        dto.termMonths = months;
        dto.billingFrequency = 'Monthly';
        dto.evergreen = isEvergreen(months);
        dto.optionLabel = optionLabelFromName(q.Name);
        dto.syncedQuoteId = opp.SyncedQuoteId;
        return dto;
    }

    private static Id resolveStandardPricebookId() {
        List<Pricebook2> pbs = [
            SELECT Id
            FROM Pricebook2
            WHERE IsStandard = TRUE
            WITH USER_MODE
            LIMIT 1
        ];
        if (pbs.isEmpty()) {
            throw new SuiteException('Standard Price Book not found.');
        }
        return pbs[0].Id;
    }

    /** When deleting a bundle root, include all configured child lines. */
    private static Set<Id> expandBundleDeleteIds(Id quoteId, Set<Id> requested) {
        Set<Id> expanded = new Set<Id>(requested);
        for (QuoteLineItem child : [
            SELECT Id
            FROM QuoteLineItem
            WHERE QuoteId = :quoteId AND ParentQuoteLineItemId IN :requested
            WITH USER_MODE
        ]) {
            expanded.add(child.Id);
        }
        return expanded;
    }

    private static Id parseId(String raw, String label) {
        if (String.isBlank(raw)) {
            throw new SuiteException(label + ' Id is required.');
        }
        try {
            return Id.valueOf(raw.trim());
        } catch (Exception e) {
            throw new SuiteException('Invalid ' + label + ' Id.');
        }
    }

    private static String truncateName(String value) {
        if (value == null) {
            return 'Option A';
        }
        return value.length() > 120 ? value.substring(0, 120) : value;
    }

    private static String firstError(Database.SaveResult sr) {
        if (sr == null || sr.getErrors().isEmpty()) {
            return 'Unable to save record.';
        }
        return sr.getErrors()[0].getMessage();
    }

    private static String firstError(Database.DeleteResult dr) {
        if (dr == null || dr.getErrors().isEmpty()) {
            return 'Unable to delete record.';
        }
        return dr.getErrors()[0].getMessage();
    }
}
