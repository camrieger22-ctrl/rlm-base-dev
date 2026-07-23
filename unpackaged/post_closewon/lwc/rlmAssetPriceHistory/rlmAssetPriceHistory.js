import { LightningElement, api } from 'lwc';
import {
    RefreshEvent,
    registerRefreshHandler,
    unregisterRefreshHandler
} from 'lightning/refresh';
import getHistoryForQuote from '@salesforce/apex/RLM_AssetPriceHistoryController.getHistoryForQuote';

const COLUMNS = [
    { label: 'Action', fieldName: 'actionLabel', type: 'text', wrapText: true },
    {
        label: 'Start',
        fieldName: 'periodStart',
        type: 'date',
        typeAttributes: { year: 'numeric', month: 'short', day: '2-digit' }
    },
    {
        label: 'End',
        fieldName: 'periodEnd',
        type: 'date',
        typeAttributes: { year: 'numeric', month: 'short', day: '2-digit' }
    },
    {
        label: 'List',
        fieldName: 'listPrice',
        type: 'currency',
        cellAttributes: { alignment: 'right' }
    },
    {
        label: 'Paid',
        fieldName: 'netUnitPrice',
        type: 'currency',
        cellAttributes: { alignment: 'right' }
    },
    {
        label: 'Discount %',
        fieldName: 'discountPercent',
        type: 'number',
        typeAttributes: { minimumFractionDigits: 0, maximumFractionDigits: 2 },
        cellAttributes: { alignment: 'right' }
    },
    {
        label: 'Qty',
        fieldName: 'quantity',
        type: 'number',
        cellAttributes: { alignment: 'right' }
    },
    {
        label: 'Prorated amount',
        fieldName: 'amount',
        type: 'currency',
        cellAttributes: { alignment: 'right' }
    }
];

export default class RlmAssetPriceHistory extends LightningElement {
    columns = COLUMNS;
    rows = [];
    summary;
    projection;
    isAmendmentQuote = false;
    message;
    error;
    loaded = false;
    _recordId;
    _requestSeq = 0;
    _retryTimer;
    _refreshHandlerId;

    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        this._recordId = value;
        this._load();
    }

    connectedCallback() {
        this._refreshHandlerId = registerRefreshHandler(this, this.handleRefreshContext);
    }

    disconnectedCallback() {
        if (this._retryTimer) {
            clearTimeout(this._retryTimer);
            this._retryTimer = undefined;
        }
        if (this._refreshHandlerId != null) {
            unregisterRefreshHandler(this._refreshHandlerId);
            this._refreshHandlerId = undefined;
        }
    }

    get isLoading() {
        return !this.loaded;
    }

    get hasRows() {
        return this.rows && this.rows.length > 0;
    }

    get hasSummary() {
        return this.summary != null && this.hasRows;
    }

    get showAddProjection() {
        return this.projection && this.projection.mode === 'Add' && this.projection.projected;
    }

    get showParkedProjection() {
        return this.projection && this.projection.mode === 'DecreaseParked';
    }

    get showProjectionHint() {
        return (
            this.projection &&
            this.projection.mode === 'None' &&
            this.hasSummary &&
            this.projection.message
        );
    }

    handleRefresh() {
        this.dispatchEvent(new RefreshEvent());
        this._load();
    }

    handleRefreshContext() {
        this._load();
        return Promise.resolve(true);
    }

    _load() {
        if (!this._recordId) {
            this.loaded = true;
            this.rows = [];
            this.summary = undefined;
            this.projection = undefined;
            this.message = 'No quote Id provided.';
            return;
        }
        const seq = ++this._requestSeq;
        this.loaded = false;
        getHistoryForQuote({ quoteId: this._recordId })
            .then((data) => {
                if (seq !== this._requestSeq) {
                    return;
                }
                this.loaded = true;
                this.isAmendmentQuote = data.isAmendmentQuote;
                this.message = data.message;
                this.error = undefined;
                this.summary = data.summary;
                this.projection = data.projection;
                this.rows = (data.rows || []).map((r, idx) => ({
                    ...r,
                    key: `${r.actionId || 'x'}-${idx}`,
                    actionLabel: this._actionLabel(r)
                }));
                if (
                    data.isAmendmentQuote &&
                    (!data.rows || data.rows.length === 0) &&
                    !this._retryTimer
                ) {
                    this._retryTimer = setTimeout(() => {
                        this._retryTimer = undefined;
                        this._load();
                    }, 1500);
                }
            })
            .catch((e) => {
                if (seq !== this._requestSeq) {
                    return;
                }
                this.loaded = true;
                this.error = this._reduceError(e);
                this.rows = [];
                this.summary = undefined;
                this.projection = undefined;
                this.isAmendmentQuote = false;
            });
    }

    _actionLabel(r) {
        const parts = [];
        if (r.category) parts.push(r.category);
        if (r.actionType && r.actionType !== r.category) parts.push(r.actionType);
        return parts.join(' · ') || 'Asset action';
    }

    _reduceError(error) {
        if (Array.isArray(error?.body)) {
            return error.body.map((e) => e.message).join(', ');
        }
        if (typeof error?.body?.message === 'string') {
            return error.body.message;
        }
        return error?.message || 'Unable to load price history.';
    }
}
