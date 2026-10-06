import { LightningElement, api } from 'lwc';

export default class RlmOpenRampBuilder extends LightningElement {
    @api recordId;

    @api invoke() {
        const quoteId = this.recordId;
        if (!quoteId) {
            return;
        }
        window.location.assign(
            '/lightning/cmp/c__rlmRampBuilder?c__recordId=' + encodeURIComponent(quoteId)
        );
    }
}
