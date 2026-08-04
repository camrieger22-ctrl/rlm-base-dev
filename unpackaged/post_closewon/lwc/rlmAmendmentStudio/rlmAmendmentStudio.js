import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin, CurrentPageReference } from 'lightning/navigation';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import getStudioPayload from '@salesforce/apex/RLM_AssetPriceHistoryController.getStudioPayload';
import getQuotePricingPulse from '@salesforce/apex/RLM_AssetPriceHistoryController.getQuotePricingPulse';
import refreshAmendKpis from '@salesforce/apex/RLM_AssetPriceHistoryController.refreshAmendKpis';
import updateWorkingLineQuantity from '@salesforce/apex/RLM_AssetPriceHistoryController.updateWorkingLineQuantity';
import repriceQuote from '@salesforce/apex/RLM_AssetPriceHistoryController.repriceQuote';
import searchCatalogProducts from '@salesforce/apex/RLM_AssetPriceHistoryController.searchCatalogProducts';
import getCatalogBrowseContext from '@salesforce/apex/RLM_AssetPriceHistoryController.getCatalogBrowseContext';
import getCatalogCategories from '@salesforce/apex/RLM_AssetPriceHistoryController.getCatalogCategories';
import addCatalogProductLine from '@salesforce/apex/RLM_AssetPriceHistoryController.addCatalogProductLine';
import removeWorkingLine from '@salesforce/apex/RLM_AssetPriceHistoryController.removeWorkingLine';
import getLinePricingWaterfall from '@salesforce/apex/RLM_AssetPriceHistoryController.getLinePricingWaterfall';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LightningConfirm from 'lightning/confirm';

export default class RlmAmendmentStudio extends NavigationMixin(LightningElement) {
    quoteId;
    quoteNumber;
    quoteName;
    accountName;
    grandTotal;
    quoteStatus;
    history;
    workingLines = [];
    calculationStatus;
    validationResult;
    loaded = false;
    error;
    saving = false;
    draftQtyByLineId = {};
    draftDiscountByLineId = {};
    draftStartByLineId = {};
    /** Local draft rows from + — search catalog before committing a QLI. */
    pendingAddRows = [];
    _pendingSeq = 0;
    _searchTimers = {};
    _requestSeq = 0;
    _pageRefQuoteId;
    _recordId;
    /** Left-rail catalog search state. */
    catalogSearchTerm = '';
    catalogResults = [];
    catalogSearching = false;
    catalogError;
    catalogAdding = false;
    /** True while results are the default common list (not a typed search). */
    catalogShowingCommon = true;
    _catalogSearchTimer;
    /** Discovery taxonomy (C+A): catalogs → categories → search/browse. */
    catalogNodes = [];
    categoryNodes = [];
    selectedCatalogId;
    selectedCategoryId;
    taxonomyLoading = false;
    /** Installed ledger slide-over. */
    installedDrawerOpen = false;
    /** lineId → { steps, source, loading, error, identifier } for OOTB waterfall. */
    platformWaterfallByLineId = {};
    _waterfallInflight = {};
    /** Opportunity on this amend Quote (auto-created when missing). */
    opportunityId;
    /** Poll TLE/PST pricing so KPIs refresh without a full page reload. */
    _pricingPollTimer;
    _softReloadTimer;
    _pricingPollInFlight = false;
    _lmdNotifyInFlight = false;
    _kpiStampInFlight = false;
    _lastPolledCalcStatus;
    _lastPolledGrandTotal;
    _lastPolledLmd;
    _stableLmdCount = 0;
    pricingInProgress = false;
    /** True until pricing is terminal and Quote LMD has been stable for 2 polls. */
    quoteSettling = false;
    /** Collapsed-by-default By product panels under KPI cards. */
    currentBreakdownOpen = false;
    thisAddBreakdownOpen = true;
    finalizedBreakdownOpen = false;


    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        this._recordId = value;
        this._resolveQuoteId();
    }

    @wire(CurrentPageReference)
    handlePageRef(pageRef) {
        const fromState = pageRef?.state?.c__quoteId || pageRef?.state?.c__recordId;
        this._pageRefQuoteId = fromState || undefined;
        this._resolveQuoteId();
    }

    connectedCallback() {
        // Do not registerRefreshHandler — Progress Indicator / QLE RefreshEvents
        // during Instant Pricing would soft-reload Studio and participate in the
        // page refresh that turns Instant Pricing off ("outdated quote").
        this._resolveQuoteId();
        this._startPricingPoll();
    }

    disconnectedCallback() {
        this._stopPricingPoll();
    }

    @api
    get effectiveRecordId() {
        return this.quoteId;
    }

    get isLoading() {
        return !this.loaded;
    }

    get hasQuote() {
        return !!this.quoteId;
    }

    get isAmendment() {
        return this.history?.isAmendmentQuote === true;
    }

    get showNonAmendBanner() {
        return this.loaded && this.hasQuote && !this.isAmendment;
    }

    get showPricingAttentionBanner() {
        return this.loaded && this.hasQuote && !!this.validationResult;
    }

    get showPricingInProgressBanner() {
        return (
            this.loaded &&
            this.hasQuote &&
            !this.validationResult &&
            (this.pricingInProgress || this.quoteSettling)
        );
    }

    get pricingInProgressMessage() {
        if (this.pricingInProgress) {
            const calc = this.calculationStatus || 'Pricing';
            return (
                `${calc} — Instant Pricing is still updating this Quote. ` +
                'Wait until this clears before editing or saving Quote Lines, or Save will fail with “refresh and try again”.'
            );
        }
        return (
            'Quote is settling after create. Wait a few seconds until this clears before editing Quote Lines.'
        );
    }

    get pricingAttentionMessage() {
        const vr = this.validationResult;
        const calc = this.calculationStatus;
        const statusBits = [vr, calc].filter(Boolean).join(' · ');
        // Match OOTB Create Order / Path remediation language.
        if (vr === 'TransactionIncomplete') {
            return (
                `Pricing needs attention (${statusBits}). ` +
                'Use Reprice All, or edit the line in Quote Lines / Configure if financial and non-financial fields were mixed.'
            );
        }
        if (statusBits) {
            return (
                `Pricing needs attention (${statusBits}). ` +
                'Use Reprice All to refresh platform prices before Create Order.'
            );
        }
        return '';
    }

    get headerSubtitle() {
        if (this.quoteNumber && this.quoteName) {
            return `Quote ${this.quoteNumber} · ${this.quoteName}`;
        }
        if (this.quoteNumber) {
            return `Quote ${this.quoteNumber}`;
        }
        return 'Amendment workspace';
    }

    get chromeQuoteLabel() {
        return this.quoteNumber ? `Quote ${this.quoteNumber}` : 'Amendment Studio';
    }

    get chromeStatusLabel() {
        return this.quoteStatus || 'Draft';
    }

    get hasChromeGrandTotal() {
        return this.grandTotal != null && Number.isFinite(Number(this.grandTotal));
    }

    get hasChromeAccount() {
        return !!this.accountName;
    }

    get summary() {
        return this.history?.summary;
    }

    get projection() {
        return this.history?.projection;
    }

    get hasSummary() {
        return this.summary != null;
    }

    get hasHistoryRows() {
        return this.hasAssetHistoryCards || (Array.isArray(this.history?.rows) && this.history.rows.length > 0);
    }

    get hasAssetHistoryCards() {
        return Array.isArray(this.history?.assets) && this.history.assets.length > 0;
    }

    /**
     * Per-Source-Asset commercial history for the Installed drawer.
     * Falls back to a single synthetic card from flat rows if assets[] is empty.
     */
    get assetHistoryCards() {
        const assets = this.history?.assets;
        if (Array.isArray(assets) && assets.length > 0) {
            return assets.map((card, idx) => this._mapAssetHistoryCard(card, idx));
        }
        if (Array.isArray(this.history?.rows) && this.history.rows.length > 0) {
            return [
                this._mapAssetHistoryCard(
                    {
                        assetId: 'flat',
                        assetName: this.summary?.assetName || 'Installed products',
                        timeline: this.history.rows,
                        counts: null,
                        summary: this.summary,
                        installedQuantity: this.summary?.totalQuantity,
                        installedMrr: this.summary?.currentMrr
                    },
                    0
                )
            ];
        }
        return [];
    }

    _mapAssetHistoryCard(card, idx) {
        const counts = card.counts || {};
        const countParts = [];
        if (counts.initialSale) {
            countParts.push(`${counts.initialSale} initial`);
        }
        if (counts.addOn) {
            countParts.push(`${counts.addOn} add-on${counts.addOn === 1 ? '' : 's'}`);
        }
        if (counts.decrease) {
            countParts.push(`${counts.decrease} decrease${counts.decrease === 1 ? '' : 's'}`);
        }
        if (counts.renew) {
            countParts.push(`${counts.renew} renew${counts.renew === 1 ? '' : 's'}`);
        }
        if (counts.other) {
            countParts.push(`${counts.other} other`);
        }
        const timeline = (card.timeline || []).map((row, rowIdx) => {
            const typeBits = [row.changeKind, row.category, row.actionType].filter(Boolean);
            const lineQty = row.quantity != null ? row.quantity : row.quantityChange;
            return {
                ...row,
                key: `${card.assetId || 'asset'}-${row.actionId || 'evt'}-${rowIdx}`,
                typeLabel: typeBits.join(' · ') || 'Installed period',
                startDateLabel: this._formatDateOnly(row.periodStart) || '—',
                endDateLabel: this._formatDateOnly(row.periodEnd) || '—',
                lineQty,
                hasDiscount:
                    row.discountPercent != null && Number(row.discountPercent) !== 0,
                qtyDeltaLabel:
                    row.quantityChange != null && Number.isFinite(Number(row.quantityChange))
                        ? (Number(row.quantityChange) > 0 ? '+' : '') +
                          String(Number(row.quantityChange))
                        : null
            };
        });
        const summary = card.summary || {};
        const assetId = card.assetId;
        const canOpenAsset =
            typeof assetId === 'string' &&
            assetId !== 'flat' &&
            /^[a-zA-Z0-9]{15}([a-zA-Z0-9]{3})?$/.test(assetId);
        const isAmending = card.isAmending === true;
        return {
            key: assetId || `asset-${idx}`,
            assetId,
            canOpenAsset,
            isAmending,
            assetName: card.assetName || `Asset ${idx + 1}`,
            countLabel: countParts.length ? countParts.join(' · ') : 'No classified events yet',
            hasTimeline: timeline.length > 0,
            timeline,
            averagePaid: summary.averagePaid,
            currentQty: card.installedQuantity != null ? card.installedQuantity : summary.totalQuantity,
            currentMrr: card.installedMrr != null ? card.installedMrr : summary.currentMrr,
            currentArr: summary.currentArr,
            hasAveragePaid: summary.averagePaid != null,
            hasCurrentQty: (card.installedQuantity != null ? card.installedQuantity : summary.totalQuantity) != null,
            hasCurrentMrr: (card.installedMrr != null ? card.installedMrr : summary.currentMrr) != null,
            hasCurrentArr: summary.currentArr != null,
            cardClass:
                'asset-history-card' + (isAmending ? ' asset-history-card_amending' : '')
        };
    }

    get historyRows() {
        return (this.history?.rows || []).map((row, idx) => {
            const typeBits = [row.category, row.actionType].filter(Boolean);
            const lineQty =
                row.quantity != null ? row.quantity : row.quantityChange;
            return {
                ...row,
                key: `${row.actionId || 'hist'}-${idx}`,
                typeLabel: typeBits.join(' · ') || 'Installed period',
                startDateLabel: this._formatDateOnly(row.periodStart) || '—',
                endDateLabel: this._formatDateOnly(row.periodEnd) || '—',
                lineQty,
                hasDiscount:
                    row.discountPercent != null && Number(row.discountPercent) !== 0
            };
        });
    }

    get showAddProjection() {
        return this.projection && this.projection.mode === 'Add' && this.projection.projected;
    }

    get kpiCurrentArr() {
        return this.summary?.currentArr;
    }
    get kpiCurrentMrr() {
        return this.summary?.currentMrr;
    }
    get kpiCurrentQty() {
        return this.summary?.totalQuantity;
    }

    /** Sticky "This add" — live draft from Working lines (falls back to projection Δ). */
    get _thisAddRollup() {
        let qty = 0;
        let mrr = 0;
        let arr = 0;
        let prorated = 0;
        const rows = this.workingLineRows || [];
        for (const r of rows) {
            const q = Number(r.draftQuantity);
            if (!Number.isFinite(q) || q <= 0) {
                continue;
            }
            qty += q;
            mrr += Number(r.previewMrr) || 0;
            arr += Number(r.previewArr) || 0;
            prorated += Number(r.previewProrated) || 0;
        }
        if (qty > 0) {
            return { qty, mrr, arr, prorated };
        }
        if (this.showAddProjection) {
            return {
                qty: this.projection.deltaQuantity || 0,
                mrr: this.projection.deltaMrr || 0,
                arr: this.projection.deltaArr || 0,
                prorated: 0
            };
        }
        return { qty: 0, mrr: 0, arr: 0, prorated: 0 };
    }

    get thisAddQty() {
        return this._thisAddRollup.qty;
    }
    get thisAddMrr() {
        return this._thisAddRollup.mrr;
    }
    get thisAddArr() {
        return this._thisAddRollup.arr;
    }
    get thisAddProrated() {
        return this._thisAddRollup.prorated;
    }

    /**
     * Per-product / Source Asset contributors to This add (Subscription vs Gen AI, etc.).
     */
    get thisAddBreakdown() {
        const byKey = new Map();
        const addRow = (key, name, qty, arr, mrr, prorated) => {
            const q = Number(qty) || 0;
            const a = Number(arr) || 0;
            if (q <= 0 && a <= 0) {
                return;
            }
            const prev = byKey.get(key) || {
                key,
                productName: name || 'Product',
                qty: 0,
                arr: 0,
                mrr: 0,
                prorated: 0
            };
            prev.qty += q;
            prev.arr += a;
            prev.mrr += Number(mrr) || 0;
            prev.prorated += Number(prorated) || 0;
            byKey.set(key, prev);
        };

        for (const r of this.workingLineRows || []) {
            const q = Number(r.draftQuantity);
            if (!Number.isFinite(q) || q <= 0) {
                continue;
            }
            addRow(
                r.sourceAssetId || r.productName || r.id || r.key,
                r.productName,
                q,
                r.previewArr,
                r.previewMrr,
                r.previewProrated
            );
        }

        // Fallback when working-line previews are empty but Apex asset cards have This add.
        if (byKey.size === 0) {
            for (const card of this.history?.assets || []) {
                if (!(Number(card.thisAddQty) > 0) && !(Number(card.thisAddArr) > 0)) {
                    continue;
                }
                addRow(
                    card.assetId || card.assetName,
                    card.assetName,
                    card.thisAddQty,
                    card.thisAddArr,
                    card.thisAddMrr,
                    card.thisAddProrated
                );
            }
        }

        return Array.from(byKey.values())
            .map((row) => ({
                ...row,
                arr: Number(row.arr.toFixed(2)),
                mrr: Number(row.mrr.toFixed(2)),
                prorated: Number(row.prorated.toFixed(2))
            }))
            .sort((a, b) => b.arr - a.arr || a.productName.localeCompare(b.productName));
    }

    get hasThisAddBreakdown() {
        return this.thisAddBreakdown.length > 0;
    }

    get showThisAddBreakdown() {
        // Always offer when This add has any product contribution (incl. single-asset amends).
        return this.thisAddBreakdown.length > 0;
    }

    get thisAddBreakdownExpanded() {
        return this.thisAddBreakdownOpen ? 'true' : 'false';
    }

    get thisAddBreakdownToggleLabel() {
        const n = this.thisAddBreakdown.length;
        return this.thisAddBreakdownOpen
            ? 'Hide by product'
            : `By product (${n})`;
    }

    /**
     * Per Source Asset contributors to Current (installed Subscription vs Gen AI, etc.).
     */
    get currentBreakdown() {
        return (this.assetHistoryCards || [])
            .filter((card) => card.assetId && card.assetId !== 'flat')
            .map((card) => {
                const qty = Number(card.currentQty);
                let mrr = Number(card.currentMrr);
                let arr = Number(card.currentArr);
                if (!Number.isFinite(arr) && Number.isFinite(mrr)) {
                    arr = mrr * 12;
                }
                if (!Number.isFinite(mrr) && Number.isFinite(arr)) {
                    mrr = arr / 12;
                }
                const isAmending = card.isAmending === true;
                return {
                    key: card.key || card.assetId,
                    productName: card.assetName || 'Asset',
                    qty: Number.isFinite(qty) ? qty : 0,
                    arr: Number.isFinite(arr) ? Number(arr.toFixed(2)) : 0,
                    mrr: Number.isFinite(mrr) ? Number(mrr.toFixed(2)) : 0,
                    hasAvgPaid: card.hasAveragePaid === true,
                    averagePaid: card.averagePaid,
                    isAmending,
                    rowClass:
                        'kpi-breakdown__row' +
                        (isAmending ? ' kpi-breakdown__row_amending' : '')
                };
            })
            .filter((row) => row.qty > 0 || row.arr > 0 || row.mrr > 0)
            // Amending assets first, then highest ARR — singles out the change against the footprint.
            .sort(
                (a, b) =>
                    Number(b.isAmending) - Number(a.isAmending) ||
                    b.arr - a.arr ||
                    a.productName.localeCompare(b.productName)
            );
    }

    get showCurrentBreakdown() {
        return this.currentBreakdown.length > 1;
    }

    get currentBreakdownExpanded() {
        return this.currentBreakdownOpen ? 'true' : 'false';
    }

    get currentBreakdownToggleLabel() {
        const n = this.currentBreakdown.length;
        return this.currentBreakdownOpen
            ? 'Hide by product'
            : `By product (${n})`;
    }

    /**
     * Per-product Finalized = Current + This add (live drafts), with Δ columns.
     */
    get finalizedBreakdown() {
        const byKey = new Map();
        const ensure = (key, productName) => {
            if (!byKey.has(key)) {
                byKey.set(key, {
                    key,
                    productName: productName || 'Product',
                    qty: 0,
                    arr: 0,
                    mrr: 0,
                    deltaQty: 0,
                    deltaArr: 0,
                    deltaMrr: 0
                });
            }
            return byKey.get(key);
        };
        const findByName = (name) => {
            for (const row of byKey.values()) {
                if (row.productName === name) {
                    return row;
                }
            }
            return null;
        };

        for (const row of this.currentBreakdown) {
            const dest = ensure(row.key, row.productName);
            dest.qty = row.qty;
            dest.arr = row.arr;
            dest.mrr = row.mrr;
        }
        for (const row of this.thisAddBreakdown) {
            let dest = byKey.get(row.key) || findByName(row.productName);
            if (!dest) {
                dest = ensure(row.key, row.productName);
            }
            dest.deltaQty = row.qty;
            dest.deltaArr = row.arr;
            dest.deltaMrr = row.mrr;
            dest.qty = Number(dest.qty || 0) + Number(row.qty || 0);
            dest.arr = Number(dest.arr || 0) + Number(row.arr || 0);
            dest.mrr = Number(dest.mrr || 0) + Number(row.mrr || 0);
        }

        return Array.from(byKey.values())
            .map((row) => ({
                ...row,
                qty: Number(row.qty) || 0,
                arr: Number((Number(row.arr) || 0).toFixed(2)),
                mrr: Number((Number(row.mrr) || 0).toFixed(2)),
                deltaQty: Number(row.deltaQty) || 0,
                deltaArr: Number((Number(row.deltaArr) || 0).toFixed(2)),
                deltaMrr: Number((Number(row.deltaMrr) || 0).toFixed(2)),
                deltaArrClass: this._deltaClass(row.deltaArr),
                deltaMrrClass: this._deltaClass(row.deltaMrr),
                deltaQtyClass: this._deltaClass(row.deltaQty)
            }))
            .filter((row) => row.qty > 0 || row.arr > 0 || row.deltaQty > 0 || row.deltaArr > 0)
            .sort((a, b) => b.arr - a.arr || a.productName.localeCompare(b.productName));
    }

    get showFinalizedBreakdown() {
        return this.showFinalizedImpact && this.finalizedBreakdown.length > 1;
    }

    get finalizedBreakdownExpanded() {
        return this.finalizedBreakdownOpen ? 'true' : 'false';
    }

    get finalizedBreakdownToggleLabel() {
        const n = this.finalizedBreakdown.length;
        return this.finalizedBreakdownOpen
            ? 'Hide by product'
            : `By product (${n})`;
    }

    handleToggleCurrentBreakdown() {
        this.currentBreakdownOpen = !this.currentBreakdownOpen;
    }

    handleToggleThisAddBreakdown() {
        this.thisAddBreakdownOpen = !this.thisAddBreakdownOpen;
    }

    handleToggleFinalizedBreakdown() {
        this.finalizedBreakdownOpen = !this.finalizedBreakdownOpen;
    }

    get installedAssetName() {
        const n = this.assetHistoryCards.length;
        const amending = (this.assetHistoryCards || []).filter((c) => c.isAmending).length;
        if (n > 1) {
            return amending > 0 && amending < n
                ? `${n} installed assets · amending ${amending}`
                : `${n} installed assets`;
        }
        if (n === 1) {
            return this.assetHistoryCards[0].assetName;
        }
        return this.summary?.assetName || 'Installed products';
    }

    get historyMessage() {
        return this.history?.message || 'No installed transactions for this amendment.';
    }

    get installedDrawerExpanded() {
        return this.installedDrawerOpen ? 'true' : 'false';
    }

    get hasCatalogResults() {
        return Array.isArray(this.catalogResults) && this.catalogResults.length > 0;
    }

    get catalogResultViews() {
        return (this.catalogResults || []).map((h) => {
            const desc = h.description && h.description !== h.productName ? h.description : '';
            return {
                ...h,
                key: h.pricebookEntryId,
                metaLine: [h.productCode, h.sellingModelName].filter(Boolean).join(' · '),
                descriptionLine: desc
            };
        });
    }

    get catalogChipViews() {
        const allSelected = !this.selectedCatalogId;
        const chips = [
            {
                id: 'all',
                name: 'All',
                chipClass: 'catalog-chip' + (allSelected ? ' catalog-chip_selected' : ''),
                isSelected: allSelected
            }
        ];
        for (const c of this.catalogNodes || []) {
            const selected = this.selectedCatalogId === c.id;
            chips.push({
                id: c.id,
                name: this._shortCatalogName(c.name),
                chipClass: 'catalog-chip' + (selected ? ' catalog-chip_selected' : ''),
                isSelected: selected
            });
        }
        return chips;
    }

    get categoryChipViews() {
        if (!this.selectedCatalogId) {
            return [];
        }
        const chips = [
            {
                id: 'all-cat',
                name: 'All',
                chipClass:
                    'catalog-chip catalog-chip_category' +
                    (!this.selectedCategoryId ? ' catalog-chip_selected' : ''),
                isSelected: !this.selectedCategoryId
            }
        ];
        for (const c of this.categoryNodes || []) {
            const selected = this.selectedCategoryId === c.id;
            chips.push({
                id: c.id,
                name: c.name,
                chipClass:
                    'catalog-chip catalog-chip_category' +
                    (selected ? ' catalog-chip_selected' : ''),
                isSelected: selected
            });
        }
        return chips;
    }

    get hasCategoryChips() {
        return this.categoryChipViews.length > 1;
    }

    get catalogListHeading() {
        if (this.catalogShowingCommon) {
            return this.selectedCatalogId || this.selectedCategoryId
                ? 'Browse'
                : 'Product Discovery';
        }
        return this.catalogFromDiscovery ? 'Product Discovery' : 'Search results';
    }

    get catalogFromDiscovery() {
        const rows = this.catalogResults || [];
        return rows.some((h) => h.source === 'Discovery');
    }

    get showCatalogEmptyHint() {
        return (
            !this.catalogSearching &&
            !this.catalogError &&
            !this.hasCatalogResults &&
            this.catalogShowingCommon
        );
    }

    get showCatalogNoHits() {
        return (
            !this.catalogSearching &&
            !this.catalogError &&
            !this.hasCatalogResults &&
            !this.catalogShowingCommon
        );
    }

    get hasPendingAddRows() {
        return this.pendingAddRows && this.pendingAddRows.length > 0;
    }

    get pendingAddRowViews() {
        return (this.pendingAddRows || []).map((row) => ({
            ...row,
            hasResults: Array.isArray(row.results) && row.results.length > 0
        }));
    }

    get hasWorkingLines() {
        return this.workingLines && this.workingLines.length > 0;
    }

    get workingLineCount() {
        return (this.workingLines || []).length;
    }

    get workingLineCountLabel() {
        const n = this.workingLineCount;
        return n === 1 ? '1 item' : `${n} items`;
    }

    get isBusy() {
        return this.isLoading || this.saving;
    }

    get impactMetaLabel() {
        const bits = [];
        if (this.quoteNumber) {
            bits.push(`Quote ${this.quoteNumber}`);
        }
        if (this.quoteName) {
            bits.push(this.quoteName);
        }
        if (this.workingLineCount) {
            bits.push(
                this.workingLineCount === 1
                    ? '1 line'
                    : `${this.workingLineCount} lines`
            );
        }
        return bits.join(' · ') || 'This amendment';
    }

    get showFinalizedImpact() {
        return this.impactDeltas.length > 0;
    }

    get workingLineRows() {
        return this._buildWorkingLineRows(this.workingLines || []);
    }

    _buildWorkingLineRows(lines) {
        return (lines || []).map((line, idx) => {
            const hasQtyDraft = this._hasDraft(this.draftQtyByLineId, line.id);
            const hasDiscDraft = this._hasDraft(this.draftDiscountByLineId, line.id);
            const hasStartDraft = this._hasDraft(this.draftStartByLineId, line.id);

            // Keep draft as string so clearing / mid-edit ("5" → "50" / "40") is not
            // overwritten by falling back to the saved number when value is empty.
            const draftQtyRaw = hasQtyDraft
                ? this.draftQtyByLineId[line.id]
                : line.quantity != null
                  ? String(line.quantity)
                  : '0';
            const draftDiscountRaw = hasDiscDraft
                ? this.draftDiscountByLineId[line.id]
                : line.discountPercent != null
                  ? String(line.discountPercent)
                  : '0';
            const draftStart = hasStartDraft
                ? this.draftStartByLineId[line.id]
                : this._toDateInput(line.startDate);

            const draftQtyNum =
                draftQtyRaw === '' || draftQtyRaw == null
                    ? NaN
                    : Number(draftQtyRaw);
            const draftDiscountNum =
                draftDiscountRaw === '' || draftDiscountRaw == null
                    ? NaN
                    : Number(draftDiscountRaw);

            const qtyDirty =
                hasQtyDraft &&
                (draftQtyRaw === '' ||
                    !Number.isFinite(draftQtyNum) ||
                    draftQtyNum !== Number(line.quantity));
            const discDirty =
                hasDiscDraft &&
                (draftDiscountRaw === '' ||
                    !Number.isFinite(draftDiscountNum) ||
                    draftDiscountNum !== Number(line.discountPercent || 0));
            const startDirty =
                (draftStart || '') !== (this._toDateInput(line.startDate) || '');
            const dirty = qtyDirty || discDirty || startDirty;
            const installed = Number(line.installedQuantity);
            const hasInstalledQty = Number.isFinite(installed);
            const addQty = Number.isFinite(draftQtyNum) ? draftQtyNum : 0;
            const proposedTotal =
                hasInstalledQty && Number.isFinite(draftQtyNum)
                    ? installed + draftQtyNum
                    : null;
            // Live preview: list×(1-disc%). Empty / invalid draft uses saved %.
            let unit = Number(line.netUnitPrice);
            const list = Number(line.listPrice);
            const discPct = Number.isFinite(draftDiscountNum)
                ? draftDiscountNum
                : Number(line.discountPercent || 0);
            if (
                Number.isFinite(list) &&
                list > 0 &&
                Number.isFinite(discPct)
            ) {
                unit = list * (1 - discPct / 100);
            }
            if (!Number.isFinite(unit)) {
                unit = 0;
            }
            const previewArr =
                Number.isFinite(addQty) && addQty > 0 && Number.isFinite(unit)
                    ? addQty * unit
                    : 0;
            const startIso = draftStart || this._toDateInput(line.startDate);
            const endIso = this._toDateInput(line.endDate);
            const frac = this._prorationFraction(startIso, endIso);
            // After reprice, TotalPrice is platform truth for term billing.
            // While drafting, estimate annualized × remaining-term fraction.
            let previewProrated = previewArr * frac;
            if (
                !dirty &&
                line.totalPrice != null &&
                Number.isFinite(Number(line.totalPrice))
            ) {
                previewProrated = Number(line.totalPrice);
            }
            // Waterfall popover = OOTB Connect only (no custom List→Discount→Net).
            const platformWf = this.platformWaterfallByLineId[line.id];
            let waterfallSteps = [];
            let waterfallTitle = 'Salesforce Pricing waterfall';
            let waterfallNote;
            if (dirty) {
                waterfallNote =
                    'Update / Reprice to load the Salesforce Pricing procedure waterfall.';
            } else if (!line.priceWaterfallIdentifier) {
                waterfallNote =
                    'No persisted waterfall yet — Update / Reprice this line first.';
            } else if (platformWf?.loading) {
                waterfallNote = 'Loading Salesforce Pricing procedure waterfall…';
            } else if (platformWf?.steps?.length) {
                waterfallSteps = platformWf.steps.map((s, sIdx) => ({
                    key: s.key || `pwf-${sIdx}`,
                    label: s.label,
                    valueLabel: s.valueLabel,
                    rowClass:
                        'waterfall-step' +
                        (s.isAdjustment ? ' waterfall-step_adj' : '') +
                        (sIdx === platformWf.steps.length - 1
                            ? ' waterfall-step_total'
                            : '')
                }));
                waterfallNote = 'Salesforce Pricing procedure';
            } else if (platformWf?.error) {
                waterfallNote = `Platform waterfall unavailable — ${platformWf.error}`;
            } else {
                waterfallNote =
                    'Hover again or wait — loading Salesforce Pricing procedure waterfall.';
            }
            const draftIncomplete =
                (hasQtyDraft &&
                    (draftQtyRaw === '' || !Number.isFinite(draftQtyNum))) ||
                (hasDiscDraft &&
                    (draftDiscountRaw === '' ||
                        !Number.isFinite(draftDiscountNum)));
            return {
                ...line,
                key: line.id || `line-${idx}`,
                typeLabel: line.quoteActionType || 'Line',
                draftQuantity: draftQtyRaw,
                draftDiscount: draftDiscountRaw,
                draftStartDate: draftStart,
                endDateLabel: this._formatDateOnly(line.endDate) || '—',
                isDirty: dirty,
                dirtyFlag: dirty ? 'true' : 'false',
                updateDisabled: this.saving || !dirty || draftIncomplete,
                hasInstalledQty,
                installedQtyLabel: hasInstalledQty
                    ? `Installed ${this._formatInteger(installed)}${
                          proposedTotal != null
                              ? ` → ${this._formatInteger(proposedTotal)}`
                              : ''
                      }`
                    : '',
                proposedTotal,
                previewNetUnit: unit,
                previewArr,
                previewMrr: previewArr / 12,
                previewProrated,
                previewNetTotal:
                    Number.isFinite(addQty) && Number.isFinite(unit)
                        ? addQty * unit
                        : 0,
                rowClass: 'tle-row' + (dirty ? ' tle-row_dirty' : ''),
                isCatalogAdd: line.isCatalogAdd === true,
                hasQuoteLineDetails: line.hasQuoteLineDetails === true,
                removeLabel:
                    line.isCatalogAdd === true
                        ? 'Remove this product line'
                        : 'Clear amendment (set qty to 0)',
                waterfallId: `wf-${line.id || idx}`,
                waterfallTitle,
                waterfallSteps,
                waterfallNote,
                priceWaterfallIdentifier: line.priceWaterfallIdentifier
            };
        });
    }

    get impactDeltas() {
        const add = this._thisAddRollup;
        const hasLiveAdd = (Number(add.qty) || 0) > 0 || (Number(add.arr) || 0) > 0;
        if (!hasLiveAdd && !this.showAddProjection) {
            return [];
        }
        const currentArr = Number(this.kpiCurrentArr) || 0;
        const currentMrr = Number(this.kpiCurrentMrr) || 0;
        const currentQty = Number(this.kpiCurrentQty) || 0;
        // Prefer live Working-line drafts so Finalized tracks This add before reprice.
        const deltaArr = hasLiveAdd
            ? Number(add.arr) || 0
            : Number(this.projection?.deltaArr) || 0;
        const deltaMrr = hasLiveAdd
            ? Number(add.mrr) || 0
            : Number(this.projection?.deltaMrr) || 0;
        const deltaQty = hasLiveAdd
            ? Number(add.qty) || 0
            : Number(this.projection?.deltaQuantity) || 0;
        return [
            {
                key: 'arr',
                label: 'ARR',
                current: currentArr,
                proposed: currentArr + deltaArr,
                delta: deltaArr,
                deltaClass: this._deltaClass(deltaArr),
                format: 'currency'
            },
            {
                key: 'mrr',
                label: 'MRR',
                current: currentMrr,
                proposed: currentMrr + deltaMrr,
                delta: deltaMrr,
                deltaClass: this._deltaClass(deltaMrr),
                format: 'currency'
            },
            {
                key: 'qty',
                label: 'Qty',
                current: currentQty,
                proposed: currentQty + deltaQty,
                delta: deltaQty,
                deltaClass: this._deltaClass(deltaQty),
                format: 'qty'
            }
        ].map((row) => ({
            ...row,
            formatCurrency: row.format === 'currency',
            formatQty: row.format === 'qty'
        }));
    }

    handleRefresh() {
        // Manual Studio KPI reload only — never fire RefreshEvent (kills Instant Pricing).
        this._load({ silent: true });
    }

    _startPricingPoll() {
        this._stopPricingPoll();
        if (!this.quoteId) {
            return;
        }
        // Fast poll while a new amend Quote is still being priced (~10–20s).
        this._pricingPollTimer = setInterval(() => {
            this._tickPricingPulse();
        }, 1500);
        this._tickPricingPulse();
    }

    _stopPricingPoll() {
        if (this._pricingPollTimer) {
            clearInterval(this._pricingPollTimer);
            this._pricingPollTimer = undefined;
        }
    }

    _isPricingTerminal(status) {
        if (!status) {
            return true;
        }
        const s = String(status);
        return (
            s.startsWith('Completed') ||
            s.includes('Failed') ||
            s.includes('Error') ||
            s === 'NotRequired'
        );
    }

    /**
     * Instant Pricing / PST rewrite Quote.LastModifiedDate after page open.
     * QLE still holds the old version → Save fails with “couldn't save… refresh”.
     * notifyRecordUpdateAvailable refreshes LDS without a full-page RefreshEvent
     * (which would turn Instant Pricing off).
     */
    _notifyQuoteRecordUpdated() {
        if (!this.quoteId || this._lmdNotifyInFlight) {
            return;
        }
        this._lmdNotifyInFlight = true;
        notifyRecordUpdateAvailable([{ recordId: this.quoteId }])
            .catch(() => {
                // Best-effort; next pulse can retry if LMD moves again.
            })
            .finally(() => {
                this._lmdNotifyInFlight = false;
            });
    }

    /**
     * Re-stamp Quote KPIs and Amend Breakdown rows that feed the DocGen proposal.
     *
     * User-initiated only. This writes the Quote, and any Quote DML from outside
     * the Quote Line Editor invalidates the version the editor is holding, so the
     * next QLE save fails with "refresh and try again". Never call this from the
     * pricing poll or any other timer — the user must be done editing lines.
     */
    handleRefreshProposalFigures() {
        if (!this.quoteId || this._kpiStampInFlight) {
            return;
        }
        this._kpiStampInFlight = true;
        refreshAmendKpis({ quoteId: this.quoteId })
            .then((data) => {
                // Stamping bumps LastModifiedDate; re-baseline so the next pulse
                // does not read its own write as a fresh external change.
                const stampedLmd = data?.lastModifiedDate
                    ? String(data.lastModifiedDate)
                    : undefined;
                if (stampedLmd) {
                    this._lastPolledLmd = stampedLmd;
                }
                this._applyPayload(data);
                this._notifyQuoteRecordUpdated();
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Proposal figures updated',
                        message:
                            'Generate the proposal now. Editing Quote Lines again means reloading the page before you save.',
                        variant: 'success'
                    })
                );
            })
            .catch((e) => {
                this.error = this._reduceError(e);
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Could not update proposal figures',
                        message: this.error,
                        variant: 'error'
                    })
                );
            })
            .finally(() => {
                this._kpiStampInFlight = false;
            });
    }

    get refreshProposalDisabled() {
        return this.isBusy || this._kpiStampInFlight || this.pricingInProgress;
    }

    get refreshProposalLabel() {
        return this._kpiStampInFlight
            ? 'Updating…'
            : 'Update proposal figures';
    }

    _tickPricingPulse() {
        if (!this.quoteId || this._pricingPollInFlight) {
            return;
        }
        this._pricingPollInFlight = true;
        getQuotePricingPulse({ quoteId: this.quoteId })
            .then((pulse) => {
                const status = pulse?.calculationStatus || '';
                const terminal = this._isPricingTerminal(status);
                const prevStatus = this._lastPolledCalcStatus;
                const nextTotal =
                    pulse?.grandTotal != null ? Number(pulse.grandTotal) : null;
                const nextLmd = pulse?.lastModifiedDate
                    ? String(pulse.lastModifiedDate)
                    : null;

                this._lastPolledCalcStatus = status;
                if (nextTotal != null && Number.isFinite(nextTotal)) {
                    this._lastPolledGrandTotal = nextTotal;
                    this.grandTotal = nextTotal;
                }
                if (Object.prototype.hasOwnProperty.call(pulse || {}, 'validationResult')) {
                    this.validationResult = pulse.validationResult;
                }
                if (status) {
                    this.calculationStatus = status;
                }

                const wasInProgress = prevStatus
                    ? !this._isPricingTerminal(prevStatus)
                    : false;
                this.pricingInProgress = !terminal;

                const lmdChanged =
                    nextLmd &&
                    this._lastPolledLmd &&
                    nextLmd !== this._lastPolledLmd;
                if (nextLmd) {
                    this._lastPolledLmd = nextLmd;
                }

                // LMD moved (or pricing just finished) → LDS/QLE still hold old version.
                if (lmdChanged || (wasInProgress && terminal)) {
                    this._notifyQuoteRecordUpdated();
                }

                if (!terminal || lmdChanged) {
                    this.quoteSettling = true;
                    this._stableLmdCount = 0;
                } else if (nextLmd) {
                    this._stableLmdCount += 1;
                    // Two consecutive identical LMD samples at terminal = safe to edit.
                    if (this._stableLmdCount >= 2) {
                        this.quoteSettling = false;
                    }
                }

                if (wasInProgress && terminal) {
                    this._load({ silent: true });
                }
            })
            .catch(() => {
                // Transient pulse failures are non-fatal; next interval retries.
            })
            .finally(() => {
                this._pricingPollInFlight = false;
            });
    }

    handleQtyInput(event) {
        const lineId = event.currentTarget.dataset.id;
        const raw = event.detail?.value;
        // Persist '' while clearing so the field does not snap back to saved qty.
        this.draftQtyByLineId = {
            ...this.draftQtyByLineId,
            [lineId]: raw == null ? '' : String(raw)
        };
    }

    handleDiscountInput(event) {
        const lineId = event.currentTarget.dataset.id;
        const raw = event.detail?.value;
        this.draftDiscountByLineId = {
            ...this.draftDiscountByLineId,
            [lineId]: raw == null ? '' : String(raw)
        };
    }

    handleStartDateInput(event) {
        const lineId = event.currentTarget.dataset.id;
        const raw = event.detail?.value || null;
        this.draftStartByLineId = {
            ...this.draftStartByLineId,
            [lineId]: raw
        };
    }

    handleQtyStep(event) {
        const lineId = event.currentTarget.dataset.id;
        const delta = Number(event.currentTarget.dataset.delta);
        const row = this._findLineRow(lineId);
        if (!row) {
            return;
        }
        const current = Number(row.draftQuantity);
        const next = (Number.isFinite(current) ? current : 0) + delta;
        this.draftQtyByLineId = {
            ...this.draftQtyByLineId,
            [lineId]: String(next >= 0 ? next : 0)
        };
    }

    _findLineRow(lineId) {
        return this.workingLineRows.find((r) => r.id === lineId);
    }

    handleQtyApply(event) {
        const lineId = event.currentTarget.dataset.id;
        const quoteId = event.currentTarget.dataset.quoteId || this.quoteId;
        const row = this._findLineRow(lineId);
        if (!row || !quoteId) {
            return;
        }
        const qty = Number(row.draftQuantity);
        const discount = Number(row.draftDiscount);
        const startDate = row.draftStartDate || null;
        if (!Number.isFinite(qty) || qty < 0) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Invalid quantity',
                    message: 'Enter an add quantity of zero or more.',
                    variant: 'error'
                })
            );
            return;
        }
        if (!Number.isFinite(discount) || discount < 0 || discount > 100) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Invalid discount',
                    message: 'Enter a discount between 0 and 100%.',
                    variant: 'error'
                })
            );
            return;
        }
        const qtyChanged = Number(qty) !== Number(row.quantity);
        const discChanged = Number(discount) !== Number(row.discountPercent || 0);
        const startChanged =
            (startDate || '') !== (this._toDateInput(row.startDate) || '');
        this.saving = true;
        this.error = undefined;
        updateWorkingLineQuantity({
            quoteId,
            lineItemId: lineId,
            newQuantity: qtyChanged ? qty : null,
            discountPercent: discChanged ? discount : null,
            startDate: startChanged ? startDate : null
        })
            .then((data) => {
                const nextQty = { ...this.draftQtyByLineId };
                const nextDisc = { ...this.draftDiscountByLineId };
                const nextStart = { ...this.draftStartByLineId };
                delete nextQty[lineId];
                delete nextDisc[lineId];
                delete nextStart[lineId];
                this.draftQtyByLineId = nextQty;
                this.draftDiscountByLineId = nextDisc;
                this.draftStartByLineId = nextStart;
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Line updated',
                        message: 'Quote repriced — This add and Finalized refreshed.',
                        variant: 'success'
                    })
                );
                if (quoteId === this.quoteId) {
                    this._applyPayload(data);
                }
                this._requestQuietPageSync();
            })
            .catch((e) => {
                this.error = this._reduceError(e);
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Update failed',
                        message: this.error,
                        variant: 'error'
                    })
                );
            })
            .finally(() => {
                this.saving = false;
            });
    }

    /** Keep Studio KPIs current without refreshing the page.
     * RefreshEvent reloads QLE and turns Instant Pricing off (platform behavior),
     * which immediately surfaces the outdated-quote / Refresh Prices warning.
     */
    _requestQuietPageSync() {
        this._load({ silent: true });
        this._tickPricingPulse();
    }

    async handleRemoveLine(event) {
        const lineId = event.currentTarget.dataset.id;
        const isCatalogAdd = event.currentTarget.dataset.catalogAdd === 'true';
        if (!lineId || !this.quoteId) {
            return;
        }
        const confirmed = await LightningConfirm.open({
            message: isCatalogAdd
                ? 'Remove this product line from the amendment quote?'
                : 'Clear this amendment line (quantity → 0 / No Change)? The installed asset line stays on the quote.',
            label: isCatalogAdd ? 'Remove line' : 'Clear amendment',
            theme: 'warning'
        });
        if (!confirmed) {
            return;
        }
        this.saving = true;
        this.error = undefined;
        removeWorkingLine({ quoteId: this.quoteId, lineItemId: lineId })
            .then((data) => {
                const nextQty = { ...this.draftQtyByLineId };
                const nextDisc = { ...this.draftDiscountByLineId };
                const nextStart = { ...this.draftStartByLineId };
                delete nextQty[lineId];
                delete nextDisc[lineId];
                delete nextStart[lineId];
                this.draftQtyByLineId = nextQty;
                this.draftDiscountByLineId = nextDisc;
                this.draftStartByLineId = nextStart;
                this._applyPayload(data);
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: isCatalogAdd ? 'Line removed' : 'Amendment cleared',
                        message: 'Quote repriced.',
                        variant: 'success'
                    })
                );
                this._requestQuietPageSync();
            })
            .catch((e) => {
                this.error = this._reduceError(e);
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Remove failed',
                        message: this.error,
                        variant: 'error'
                    })
                );
            })
            .finally(() => {
                this.saving = false;
            });
    }

    /** Row + / Add Product — insert a blank line with inline catalog search (no modal). */
    handleAddLineBelow() {
        this._pendingSeq += 1;
        const key = `pending-${this._pendingSeq}`;
        this.pendingAddRows = [
            ...this.pendingAddRows,
            {
                key,
                searchTerm: '',
                results: [],
                searching: false,
                selecting: false,
                error: null
            }
        ];
    }

    handleOpenInstalledDrawer() {
        this.installedDrawerOpen = true;
        // Focus close control after the drawer paints.
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            const closeBtn = this.template.querySelector('.installed-drawer lightning-button-icon');
            if (closeBtn) {
                closeBtn.focus();
            }
        }, 0);
    }

    handleWaterfallEnter(event) {
        const root = event.currentTarget;
        const lineId = root.dataset.id;
        const isDirty = root.dataset.dirty === 'true';
        const identifier = root.dataset.pwf || '';
        if (lineId && !isDirty) {
            this._ensurePlatformWaterfall(lineId, identifier);
        }
        const pop = root.querySelector('.waterfall-popover');
        if (!pop) {
            return;
        }
        // Close any other open waterfall first.
        this.template.querySelectorAll('.waterfall-popover.is-open').forEach((el) => {
            if (el !== pop) {
                el.classList.remove('is-open', 'waterfall-popover_below', 'waterfall-popover_above');
            }
        });
        pop.classList.add('is-open');
        pop.classList.remove('waterfall-popover_below', 'waterfall-popover_above');
        // Measure after paint so we can flip above/below the viewport edge.
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        requestAnimationFrame(() => {
            this._positionWaterfallPopover(root, pop);
        });
    }

    _positionWaterfallPopover(root, pop) {
        if (!root || !pop || !pop.classList.contains('is-open')) {
            return;
        }
        const rect = root.getBoundingClientRect();
        const popRect = pop.getBoundingClientRect();
        const gap = 10;
        const width = popRect.width || 264;
        let left = rect.left;
        if (left + width > window.innerWidth - 8) {
            left = Math.max(8, window.innerWidth - width - 8);
        }
        let top = rect.bottom + gap;
        let placement = 'below';
        if (top + popRect.height > window.innerHeight - 8) {
            top = Math.max(8, rect.top - popRect.height - gap);
            placement = 'above';
        }
        pop.style.left = `${Math.round(left)}px`;
        pop.style.top = `${Math.round(top)}px`;
        pop.classList.add(
            placement === 'below' ? 'waterfall-popover_below' : 'waterfall-popover_above'
        );
    }

    _ensurePlatformWaterfall(lineId, identifier) {
        const cached = this.platformWaterfallByLineId[lineId];
        if (
            cached &&
            (cached.loading ||
                (cached.identifier === identifier &&
                    (cached.steps?.length || cached.error)))
        ) {
            return;
        }
        if (this._waterfallInflight[lineId]) {
            return;
        }
        this._waterfallInflight[lineId] = true;
        this.platformWaterfallByLineId = {
            ...this.platformWaterfallByLineId,
            [lineId]: {
                loading: true,
                identifier,
                steps: cached?.steps || [],
                error: undefined
            }
        };
        getLinePricingWaterfall({ lineItemId: lineId })
            .then((resp) => {
                this.platformWaterfallByLineId = {
                    ...this.platformWaterfallByLineId,
                    [lineId]: {
                        loading: false,
                        identifier,
                        steps: resp?.success ? resp.steps || [] : [],
                        error: resp?.success ? undefined : resp?.message || 'Unavailable',
                        source: resp?.source
                    }
                };
                // Reposition open popover after content grows.
                // eslint-disable-next-line @lwc/lwc/no-async-operation
                requestAnimationFrame(() => {
                    const root = this.template.querySelector(
                        `.waterfall-trigger[data-id="${lineId}"]`
                    );
                    const pop = root?.querySelector('.waterfall-popover.is-open');
                    if (root && pop) {
                        this._positionWaterfallPopover(root, pop);
                    }
                });
            })
            .catch((e) => {
                this.platformWaterfallByLineId = {
                    ...this.platformWaterfallByLineId,
                    [lineId]: {
                        loading: false,
                        identifier,
                        steps: [],
                        error: this._reduceError(e)
                    }
                };
            })
            .finally(() => {
                delete this._waterfallInflight[lineId];
            });
    }

    handleWaterfallLeave(event) {
        // focusout bubbles — ignore when focus stays inside the trigger.
        if (event.type === 'focusout') {
            const next = event.relatedTarget;
            if (next && event.currentTarget.contains(next)) {
                return;
            }
        }
        const pop = event.currentTarget.querySelector('.waterfall-popover');
        if (!pop) {
            return;
        }
        pop.classList.remove('is-open', 'waterfall-popover_below', 'waterfall-popover_above');
        pop.style.left = '';
        pop.style.top = '';
    }

    handleCloseInstalledDrawer() {
        this.installedDrawerOpen = false;
    }

    handleInstalledDrawerKeydown(event) {
        if (event.key === 'Escape') {
            event.stopPropagation();
            this.handleCloseInstalledDrawer();
        }
    }

    handleCatalogSearchInput(event) {
        const term = event.detail?.value != null ? String(event.detail.value) : '';
        this.catalogSearchTerm = term;
        this.catalogError = undefined;
        if (this._catalogSearchTimer) {
            clearTimeout(this._catalogSearchTimer);
            this._catalogSearchTimer = undefined;
        }
        // Blank / short → browse / common; 2+ chars → Discovery search.
        if (term.trim().length < 2) {
            this._loadCommonCatalog();
            return;
        }
        this._catalogSearchTimer = setTimeout(() => {
            this._runRailCatalogSearch(term.trim());
        }, 250);
    }

    handleCatalogChipClick(event) {
        const id = event.currentTarget.dataset.id;
        if (id === 'all') {
            this.selectedCatalogId = undefined;
            this.selectedCategoryId = undefined;
            this.categoryNodes = [];
            this._refreshCatalogRail();
            return;
        }
        if (this.selectedCatalogId === id) {
            return;
        }
        this.selectedCatalogId = id;
        this.selectedCategoryId = undefined;
        this._loadCategoriesForCatalog(id).then(() => this._refreshCatalogRail());
    }

    handleCategoryChipClick(event) {
        const id = event.currentTarget.dataset.id;
        const next = id === 'all-cat' ? undefined : id;
        if (this.selectedCategoryId === next) {
            return;
        }
        this.selectedCategoryId = next;
        this._refreshCatalogRail();
    }

    _refreshCatalogRail() {
        const term = (this.catalogSearchTerm || '').trim();
        if (term.length >= 2) {
            this._runRailCatalogSearch(term);
        } else {
            this._loadCommonCatalog();
        }
    }

    _loadCatalogTaxonomy() {
        if (!this.quoteId) {
            return Promise.resolve();
        }
        this.taxonomyLoading = true;
        return getCatalogBrowseContext({ quoteId: this.quoteId })
            .then((ctx) => {
                this.catalogNodes = ctx?.catalogs || [];
                // Default into Software (or platform default) so search is scoped.
                if (!this.selectedCatalogId && ctx?.defaultCatalogId) {
                    this.selectedCatalogId = ctx.defaultCatalogId;
                    this.categoryNodes = ctx?.categories || [];
                } else if (this.selectedCatalogId) {
                    this.categoryNodes = ctx?.categories || [];
                }
            })
            .catch(() => {
                // Taxonomy is progressive enhancement; search still works unscoped.
                this.catalogNodes = [];
                this.categoryNodes = [];
            })
            .finally(() => {
                this.taxonomyLoading = false;
            });
    }

    _loadCategoriesForCatalog(catalogId) {
        if (!this.quoteId || !catalogId) {
            this.categoryNodes = [];
            return Promise.resolve();
        }
        return getCatalogCategories({ quoteId: this.quoteId, catalogId })
            .then((nodes) => {
                this.categoryNodes = nodes || [];
            })
            .catch(() => {
                this.categoryNodes = [];
            });
    }

    _shortCatalogName(name) {
        if (!name) {
            return 'Catalog';
        }
        return name.replace(/^QuantumBit\s+/i, '');
    }

    _catalogScopeParams() {
        return {
            catalogId: this.selectedCatalogId || null,
            categoryId: this.selectedCategoryId || null
        };
    }

    _loadCommonCatalog() {
        if (!this.quoteId) {
            this.catalogResults = [];
            this.catalogShowingCommon = true;
            this.catalogSearching = false;
            return;
        }
        this.catalogSearching = true;
        this.catalogShowingCommon = true;
        const scope = this._catalogScopeParams();
        searchCatalogProducts({
            quoteId: this.quoteId,
            searchTerm: '',
            catalogId: scope.catalogId,
            categoryId: scope.categoryId
        })
            .then((hits) => {
                if (this.catalogSearchTerm.trim().length >= 2) {
                    return;
                }
                this.catalogResults = hits || [];
                this.catalogShowingCommon = true;
                this.catalogSearching = false;
            })
            .catch((e) => {
                if (this.catalogSearchTerm.trim().length >= 2) {
                    return;
                }
                this.catalogResults = [];
                this.catalogSearching = false;
                this.catalogError = this._reduceError(e);
            });
    }

    _runRailCatalogSearch(term) {
        if (!this.quoteId) {
            return;
        }
        this.catalogSearching = true;
        this.catalogShowingCommon = false;
        const scope = this._catalogScopeParams();
        searchCatalogProducts({
            quoteId: this.quoteId,
            searchTerm: term,
            catalogId: scope.catalogId,
            categoryId: scope.categoryId
        })
            .then((hits) => {
                // Ignore stale responses if the user kept typing.
                if (this.catalogSearchTerm.trim() !== term) {
                    return;
                }
                this.catalogResults = hits || [];
                this.catalogShowingCommon = false;
                this.catalogSearching = false;
            })
            .catch((e) => {
                if (this.catalogSearchTerm.trim() !== term) {
                    return;
                }
                this.catalogResults = [];
                this.catalogSearching = false;
                this.catalogError = this._reduceError(e);
            });
    }

    handleSelectRailCatalogProduct(event) {
        const pbeId = event.currentTarget.dataset.pbeId;
        if (!pbeId || !this.quoteId || this.catalogAdding) {
            return;
        }
        this.catalogAdding = true;
        this.catalogError = undefined;
        addCatalogProductLine({ quoteId: this.quoteId, pricebookEntryId: pbeId })
            .then((data) => {
                this._applyPayload(data);
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Product added',
                        message: 'New line created and repriced.',
                        variant: 'success'
                    })
                );
                this._requestQuietPageSync();
            })
            .catch((e) => {
                const msg = this._reduceError(e);
                this.catalogError = msg;
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Could not add product',
                        message: msg,
                        variant: 'error'
                    })
                );
            })
            .finally(() => {
                this.catalogAdding = false;
            });
    }

    handlePendingSearchInput(event) {
        const key = event.currentTarget.dataset.key;
        const term = event.detail?.value != null ? String(event.detail.value) : '';
        this.pendingAddRows = this.pendingAddRows.map((row) =>
            row.key === key
                ? { ...row, searchTerm: term, error: null, results: term.trim().length < 2 ? [] : row.results }
                : row
        );
        if (this._searchTimers[key]) {
            clearTimeout(this._searchTimers[key]);
        }
        if (!this.quoteId || term.trim().length < 2) {
            return;
        }
        this._searchTimers[key] = setTimeout(() => {
            this._runCatalogSearch(key, term.trim());
        }, 250);
    }

    _runCatalogSearch(key, term) {
        this.pendingAddRows = this.pendingAddRows.map((row) =>
            row.key === key ? { ...row, searching: true } : row
        );
        const scope = this._catalogScopeParams();
        searchCatalogProducts({
            quoteId: this.quoteId,
            searchTerm: term,
            catalogId: scope.catalogId,
            categoryId: scope.categoryId
        })
            .then((hits) => {
                this.pendingAddRows = this.pendingAddRows.map((row) =>
                    row.key === key
                        ? {
                              ...row,
                              searching: false,
                              results: (hits || []).map((h) => ({
                                  ...h,
                                  key: h.pricebookEntryId
                              }))
                          }
                        : row
                );
            })
            .catch((e) => {
                this.pendingAddRows = this.pendingAddRows.map((row) =>
                    row.key === key
                        ? {
                              ...row,
                              searching: false,
                              results: [],
                              error: this._reduceError(e)
                          }
                        : row
                );
            });
    }

    handleSelectCatalogProduct(event) {
        const key = event.currentTarget.dataset.key;
        const pbeId = event.currentTarget.dataset.pbeId;
        if (!key || !pbeId || !this.quoteId) {
            return;
        }
        this.pendingAddRows = this.pendingAddRows.map((row) =>
            row.key === key ? { ...row, selecting: true, error: null } : row
        );
        addCatalogProductLine({ quoteId: this.quoteId, pricebookEntryId: pbeId })
            .then((data) => {
                this.pendingAddRows = this.pendingAddRows.filter((row) => row.key !== key);
                this._applyPayload(data);
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Product added',
                        message: 'New line created and repriced.',
                        variant: 'success'
                    })
                );
                this._requestQuietPageSync();
            })
            .catch((e) => {
                const msg = this._reduceError(e);
                this.pendingAddRows = this.pendingAddRows.map((row) =>
                    row.key === key ? { ...row, selecting: false, error: msg } : row
                );
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Could not add product',
                        message: msg,
                        variant: 'error'
                    })
                );
            });
    }

    handleCancelPendingRow(event) {
        const key = event.currentTarget.dataset.key;
        if (this._searchTimers[key]) {
            clearTimeout(this._searchTimers[key]);
            delete this._searchTimers[key];
        }
        this.pendingAddRows = this.pendingAddRows.filter((row) => row.key !== key);
    }

    handleRepriceAll(event) {
        const quoteId =
            event?.currentTarget?.dataset?.quoteId || this.quoteId;
        if (!quoteId) {
            return;
        }
        this.saving = true;
        this.error = undefined;
        repriceQuote({ quoteId })
            .then((data) => {
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Repriced',
                        message: 'Quote force-repriced — KPIs and prorated amounts refreshed.',
                        variant: 'success'
                    })
                );
                this._applyPayload(data);
                this._requestQuietPageSync();
            })
            .catch((e) => {
                this.error = this._reduceError(e);
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Reprice failed',
                        message: this.error,
                        variant: 'error'
                    })
                );
            })
            .finally(() => {
                this.saving = false;
            });
    }

    /**
     * Escape hatch to the standard Quote Line Items related list (header
     * adjustment, bulk tools, etc.). Not a fake Instant Pricing / TLE toolbar.
     */
    handleOpenAdvancedEditor(event) {
        const quoteId =
            event?.currentTarget?.dataset?.quoteId || this.quoteId;
        if (!quoteId) {
            return;
        }
        this.dispatchEvent(
            new ShowToastEvent({
                title: 'Advanced line editor',
                message:
                    'Opening Quote Line Items. For Manage Header Adjustment, use that action on the Quote highlights.',
                variant: 'info',
                mode: 'dismissible'
            })
        );
        this[NavigationMixin.Navigate]({
            type: 'standard__recordRelationshipPage',
            attributes: {
                recordId: quoteId,
                objectApiName: 'Quote',
                relationshipApiName: 'QuoteLineItems',
                actionName: 'view'
            }
        });
    }

    _resolveQuoteId() {
        const next = this.recordId || this._pageRefQuoteId;
        if (next !== this.quoteId) {
            this.quoteId = next;
            this.draftQtyByLineId = {};
            this.draftDiscountByLineId = {};
            this.draftStartByLineId = {};
            this._lastPolledCalcStatus = undefined;
            this._lastPolledGrandTotal = undefined;
            this._lastPolledLmd = undefined;
            this._stableLmdCount = 0;
            this.quoteSettling = true;
            this._load();
            this._startPricingPoll();
        } else if (!this.loaded && next) {
            this._load();
        } else if (!next) {
            this.loaded = true;
            this._stopPricingPoll();
        }
    }

    _load(options = {}) {
        if (!this.quoteId) {
            this.loaded = true;
            return;
        }
        const silent = options.silent === true && this.loaded;
        const seq = ++this._requestSeq;
        if (!silent) {
            this.loaded = false;
        }
        getStudioPayload({ quoteId: this.quoteId })
            .then((data) => {
                if (seq !== this._requestSeq) {
                    return;
                }
                this.loaded = true;
                this.error = undefined;
                this._applyPayload(data);
            })
            .catch((e) => {
                if (seq !== this._requestSeq) {
                    return;
                }
                this.loaded = true;
                this.error = this._reduceError(e);
                this.history = undefined;
                this.workingLines = [];
            });
    }

    _applyPayload(data) {
        this.history = data.history;
        this.workingLines = data.workingLines || [];
        this.quoteNumber = data.quoteNumber;
        this.quoteName = data.quoteName;
        this.accountName = data.accountName;
        this.grandTotal = data.grandTotal;
        this.quoteStatus = data.status;
        this.opportunityId = data.opportunityId;
        this.calculationStatus = data.calculationStatus;
        this.validationResult = data.validationResult;
        this.pricingInProgress = !this._isPricingTerminal(data.calculationStatus);
        if (this.pricingInProgress) {
            this.quoteSettling = true;
            this._stableLmdCount = 0;
        }
        this._lastPolledCalcStatus = data.calculationStatus || '';
        this._lastPolledGrandTotal =
            data.grandTotal != null ? Number(data.grandTotal) : this._lastPolledGrandTotal;
        if (data.opportunityAutoCreated && data.opportunityId) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Opportunity ready',
                    message:
                        'Created an Opportunity for this amendment so you can sync and Create Order.',
                    variant: 'success',
                    mode: 'dismissable'
                })
            );
        }
        // Do not auto-link Opportunity on page load — Quote DML races QLE and
        // Instant Pricing. Create Opp from Sync / scenario actions when needed.
        // Invalidate waterfall cache when identifiers change after reprice.
        const nextCache = { ...this.platformWaterfallByLineId };
        for (const line of this.workingLines) {
            const cached = nextCache[line.id];
            if (cached && cached.identifier !== line.priceWaterfallIdentifier) {
                delete nextCache[line.id];
            }
        }
        this.platformWaterfallByLineId = nextCache;
        // Seed taxonomy once, then browse/search the rail.
        const seedRail = () => {
            if (!this.catalogSearchTerm || this.catalogSearchTerm.trim().length < 2) {
                this._loadCommonCatalog();
            }
        };
        if (!this.catalogNodes.length && !this.taxonomyLoading) {
            this._loadCatalogTaxonomy().then(seedRail);
        } else {
            seedRail();
        }
    }

    _deltaClass(value) {
        const n = Number(value);
        if (!Number.isFinite(n) || n === 0) {
            return 'kpi-metric__delta delta delta_neutral';
        }
        return n > 0
            ? 'kpi-metric__delta delta delta_up'
            : 'kpi-metric__delta delta delta_down';
    }

    _prorationFraction(startIso, endIso) {
        const s = startIso ? new Date(`${startIso}T00:00:00`) : null;
        const e = endIso ? new Date(`${endIso}T00:00:00`) : null;
        if (!s || !e || Number.isNaN(s.getTime()) || Number.isNaN(e.getTime())) {
            return 1;
        }
        if (e < s) {
            return 0;
        }
        const days = Math.round((e - s) / 86400000) + 1;
        return Math.min(1, Math.max(0, days / 365));
    }

    _hasDraft(map, lineId) {
        return Object.prototype.hasOwnProperty.call(map || {}, lineId);
    }

    _formatCurrency(value) {
        const n = Number(value);
        if (!Number.isFinite(n)) {
            return '—';
        }
        try {
            return new Intl.NumberFormat(undefined, {
                style: 'currency',
                currency: 'USD'
            }).format(n);
        } catch (e) {
            return `$${n.toFixed(2)}`;
        }
    }

    _formatInteger(value) {
        const n = Number(value);
        if (!Number.isFinite(n)) {
            return '—';
        }
        try {
            return new Intl.NumberFormat(undefined, {
                maximumFractionDigits: 0
            }).format(n);
        } catch (e) {
            return String(Math.round(n));
        }
    }

    _toDateInput(value) {
        if (!value) {
            return '';
        }
        if (typeof value === 'string') {
            return value.length >= 10 ? value.slice(0, 10) : value;
        }
        try {
            const d = new Date(value);
            if (Number.isNaN(d.getTime())) {
                return '';
            }
            return d.toISOString().slice(0, 10);
        } catch (e) {
            return '';
        }
    }

    _formatDateOnly(value) {
        const iso = this._toDateInput(value);
        if (!iso) {
            return '';
        }
        try {
            const d = new Date(iso + 'T00:00:00');
            return d.toLocaleDateString(undefined, {
                year: 'numeric',
                month: 'short',
                day: 'numeric'
            });
        } catch (e) {
            return iso;
        }
    }

    _formatDateRange(start, end) {
        const a = this._formatDateOnly(start);
        const b = this._formatDateOnly(end);
        if (a && b) {
            return `${a} → ${b}`;
        }
        return a || b || '';
    }

    _reduceError(error) {
        if (Array.isArray(error?.body)) {
            return error.body.map((e) => e.message).join(', ');
        }
        if (typeof error?.body?.message === 'string') {
            return error.body.message;
        }
        return error?.message || 'Unable to load Amendment Studio.';
    }
}