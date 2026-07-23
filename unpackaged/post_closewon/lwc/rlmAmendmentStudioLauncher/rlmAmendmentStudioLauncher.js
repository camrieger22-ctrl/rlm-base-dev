import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';

export default class RlmAmendmentStudioLauncher extends NavigationMixin(LightningElement) {
    @api recordId;

    get disabled() {
        return !this.recordId;
    }

    handleOpen() {
        if (!this.recordId) {
            return;
        }
        this[NavigationMixin.Navigate]({
            type: 'standard__navItemPage',
            attributes: {
                apiName: 'RLM_Amendment_Studio'
            },
            state: {
                c__quoteId: this.recordId
            }
        });
    }
}
