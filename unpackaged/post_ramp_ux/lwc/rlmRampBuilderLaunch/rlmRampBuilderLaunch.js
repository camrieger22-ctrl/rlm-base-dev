import { LightningElement, api, wire } from 'lwc';
import { CurrentPageReference } from 'lightning/navigation';

export default class RlmRampBuilderLaunch extends LightningElement {
    _recordId;
    opened = false;
    pageRef;

    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        this._recordId = value;
        this.tryOpen();
    }

    @wire(CurrentPageReference)
    handlePageRef(ref) {
        this.pageRef = ref;
        this.tryOpen();
    }

    renderedCallback() {
        this.tryOpen();
    }

    quoteId() {
        if (this._recordId) {
            return this._recordId;
        }
        const fromPage = this.pageRef?.attributes?.recordId
            || this.pageRef?.state?.recordId;
        if (fromPage) {
            return fromPage;
        }
        const match = window.location.pathname.match(/\/Quote\/([a-zA-Z0-9]{15,18})/);
        return match ? match[1] : null;
    }

    tryOpen() {
        const quoteId = this.quoteId();
        if (this.opened || !quoteId) {
            return;
        }
        this.opened = true;
        // Do not use NavigationMixin.Navigate + CloseActionScreenEvent.
        // The screen action tears down on close and cancels that navigation
        // on the first click. A real URL assign always leaves the page.
        window.location.assign(
            '/lightning/cmp/c__rlmRampBuilder?c__recordId=' + encodeURIComponent(quoteId)
        );
    }
}
