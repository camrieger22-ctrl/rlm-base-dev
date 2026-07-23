import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin, CurrentPageReference } from 'lightning/navigation';
import {
    RefreshEvent,
    registerRefreshHandler,
    unregisterRefreshHandler
} from 'lightning/refresh';
import getStudioPayload from '@salesforce/apex/RLM_AssetPriceHistoryController.getStudioPayload';
import updateWorkingLineQuantity from '@salesforce/apex/RLM_AssetPriceHistoryController.updateWorkingLineQuantity';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class RlmAmendmentStudio extends NavigationMixin(LightningElement) {
    quoteId;
    quoteNumber;
    quoteName;
    history;
    workingLines = [];
    loaded = false;
    error;
    saving = false;
    draftQtyByLineId = {};
    _requestSeq = 0;
    _refreshHandlerId;
    _pageRefQuoteId;
    _recordId;


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
        this._refreshHandlerId = registerRefreshHandler(this, this.handleRefreshContext);
        this._resolveQuoteId();
    }

    disconnectedCallback() {
        if (this._refreshHandlerId != null) {
            unregisterRefreshHandler(this._refreshHandlerId);
            this._refreshHandlerId = undefined;
        }
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

    get headerSubtitle() {
        if (this.quoteNumber && this.quoteName) {
            return `Quote ${this.quoteNumber} · ${this.quoteName}`;
        }
        if (this.quoteNumber) {
            return `Quote ${this.quoteNumber}`;
        }
        return 'Amendment workspace';
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
    get kpiProposedArr() {
        return this.showAddProjection ? this.projection.projected.currentArr : this.summary?.currentArr;
    }
    get kpiProposedMrr() {
        return this.showAddProjection ? this.projection.projected.currentMrr : this.summary?.currentMrr;
    }
    get kpiProposedQty() {
        return this.showAddProjection ? this.projection.projected.totalQuantity : this.summary?.totalQuantity;
    }
    get kpiNetArr() {
        return this.showAddProjection ? this.projection.deltaArr : 0;
    }
    get kpiNetMrr() {
        return this.showAddProjection ? this.projection.deltaMrr : 0;
    }
    get kpiNetQty() {
        return this.showAddProjection ? this.projection.deltaQuantity : 0;
    }

    get netArrClass() {
        return this._deltaClass(this.kpiNetArr);
    }
    get netMrrClass() {
        return this._deltaClass(this.kpiNetMrr);
    }
    get netQtyClass() {
        return this._deltaClass(this.kpiNetQty);
    }

    get installedAssetName() {
        return this.summary?.assetName || 'Installed products';
    }

    get historyMessage() {
        return this.history?.message;
    }

    get hasWorkingLines() {
        return this.workingLines && this.workingLines.length > 0;
    }

    get isBusy() {
        return this.isLoading || this.saving;
    }

    get workingLineRows() {
        return (this.workingLines || []).map((line, idx) => {
            const draft =
                this.draftQtyByLineId[line.id] != null
                    ? this.draftQtyByLineId[line.id]
                    : line.quantity;
            const dirty = Number(draft) !== Number(line.quantity);
            return {
                ...line,
                key: line.id || `line-${idx}`,
                typeLabel: line.quoteActionType || 'Line',
                draftQuantity: draft,
                isDirty: dirty,
                updateDisabled: this.saving || !dirty
            };
        });
    }

    get impactDeltas() {
        if (!this.showAddProjection) {
            return [];
        }
        const p = this.projection;
        return [
            {
                key: 'qty',
                label: 'Total qty',
                current: this.summary.totalQuantity,
                proposed: p.projected.totalQuantity,
                delta: p.deltaQuantity,
                deltaClass: this._deltaClass(p.deltaQuantity),
                format: 'qty'
            },
            {
                key: 'mrr',
                label: 'MRR',
                current: this.summary.currentMrr,
                proposed: p.projected.currentMrr,
                delta: p.deltaMrr,
                deltaClass: this._deltaClass(p.deltaMrr),
                format: 'currency'
            },
            {
                key: 'arr',
                label: 'ARR',
                current: this.summary.currentArr,
                proposed: p.projected.currentArr,
                delta: p.deltaArr,
                deltaClass: this._deltaClass(p.deltaArr),
                format: 'currency'
            }
        ].map((row) => ({
            ...row,
            formatCurrency: row.format === 'currency',
            formatQty: row.format === 'qty'
        }));
    }

    handleRefresh() {
        this.dispatchEvent(new RefreshEvent());
        this._load();
    }

    handleRefreshContext() {
        this._load();
        return Promise.resolve(true);
    }

    handleQtyInput(event) {
        const lineId = event.currentTarget.dataset.id;
        const raw = event.detail?.value;
        const n = raw === '' || raw == null ? null : Number(raw);
        this.draftQtyByLineId = { ...this.draftQtyByLineId, [lineId]: n };
    }

    handleQtyStep(event) {
        const lineId = event.currentTarget.dataset.id;
        const delta = Number(event.currentTarget.dataset.delta);
        const row = this.workingLineRows.find((r) => r.id === lineId);
        if (!row) {
            return;
        }
        const current = Number(row.draftQuantity);
        const next = (Number.isFinite(current) ? current : 0) + delta;
        this.draftQtyByLineId = {
            ...this.draftQtyByLineId,
            [lineId]: next > 0 ? next : 1
        };
    }

    handleQtyApply(event) {
        const lineId = event.currentTarget.dataset.id;
        const row = this.workingLineRows.find((r) => r.id === lineId);
        if (!row || !this.quoteId) {
            return;
        }
        const qty = Number(row.draftQuantity);
        if (!Number.isFinite(qty) || qty <= 0) {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Invalid quantity',
                    message: 'Enter a quantity greater than zero.',
                    variant: 'error'
                })
            );
            return;
        }
        this.saving = true;
        this.error = undefined;
        updateWorkingLineQuantity({
            quoteId: this.quoteId,
            lineItemId: lineId,
            newQuantity: qty
        })
            .then((data) => {
                this._applyPayload(data);
                const nextDrafts = { ...this.draftQtyByLineId };
                delete nextDrafts[lineId];
                this.draftQtyByLineId = nextDrafts;
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Quantity updated',
                        message: 'Quote repriced and impact refreshed.',
                        variant: 'success'
                    })
                );
                this.dispatchEvent(new RefreshEvent());
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

    handleOpenLineEditor() {
        // Escape hatch only — scroll/focus is not available across page regions;
        // keep a path to the classic Quote surface for advanced TLE work.
        if (!this.quoteId) {
            return;
        }
        this[NavigationMixin.Navigate]({
            type: 'standard__recordRelationshipPage',
            attributes: {
                recordId: this.quoteId,
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
            this._load();
        } else if (!this.loaded && next) {
            this._load();
        } else if (!next) {
            this.loaded = true;
            this.error = undefined;
            this.history = undefined;
            this.workingLines = [];
        }
    }

    _load() {
        if (!this.quoteId) {
            this.loaded = true;
            return;
        }
        const seq = ++this._requestSeq;
        this.loaded = false;
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
    }

    _deltaClass(value) {
        const n = Number(value);
        if (!Number.isFinite(n) || n === 0) {
            return 'delta delta_neutral';
        }
        return n > 0 ? 'delta delta_up' : 'delta delta_down';
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
