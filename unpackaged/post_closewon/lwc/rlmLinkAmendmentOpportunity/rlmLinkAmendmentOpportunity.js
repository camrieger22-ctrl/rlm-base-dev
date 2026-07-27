import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue, notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { CloseActionScreenEvent } from 'lightning/actions';
import ensureAmendmentOpportunityForStudio from '@salesforce/apex/RLM_AssetPriceHistoryController.ensureAmendmentOpportunityForStudio';

import OPPORTUNITY_ID from '@salesforce/schema/Quote.OpportunityId';
import ORIGINAL_ACTION_TYPE from '@salesforce/schema/Quote.OriginalActionType';

const FIELDS = [OPPORTUNITY_ID, ORIGINAL_ACTION_TYPE];

export default class RlmLinkAmendmentOpportunity extends LightningElement {
    @api recordId;

    loading = true;
    linking = false;
    error;
    opportunityId;
    originalActionType;

    @wire(getRecord, { recordId: '$recordId', fields: FIELDS })
    wiredQuote({ data, error }) {
        this.loading = false;
        if (error) {
            this.error = this._reduceError(error);
            return;
        }
        if (data) {
            this.opportunityId = getFieldValue(data, OPPORTUNITY_ID);
            this.originalActionType = getFieldValue(data, ORIGINAL_ACTION_TYPE);
            this.error = undefined;
        }
    }

    get busy() {
        return this.loading || this.linking;
    }

    get alreadyLinked() {
        return !this.loading && !!this.opportunityId;
    }

    get notAmendment() {
        return !this.loading && !this.opportunityId && this.originalActionType !== 'Amend';
    }

    get canLink() {
        return !this.loading && !this.opportunityId && this.originalActionType === 'Amend';
    }

    get showDone() {
        return this.alreadyLinked || this.notAmendment;
    }

    handleCancel() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    handleLink() {
        if (!this.recordId || this.linking || !this.canLink) {
            return;
        }
        this.linking = true;
        this.error = undefined;
        ensureAmendmentOpportunityForStudio({ quoteId: this.recordId })
            .then((oppId) => {
                if (!oppId) {
                    throw new Error(
                        'Could not create an Opportunity for this Quote. Check Account and amendment type.'
                    );
                }
                this.opportunityId = oppId;
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Opportunity linked',
                        message:
                            'Draft Opportunity created and linked. You can Sync Quote and Create Order when ready.',
                        variant: 'success'
                    })
                );
                // Update LDS without a full-page RefreshEvent (keeps Instant Pricing on).
                return notifyRecordUpdateAvailable([{ recordId: this.recordId }]).then(() => {
                    this.dispatchEvent(new CloseActionScreenEvent());
                });
            })
            .catch((e) => {
                this.error = this._reduceError(e);
            })
            .finally(() => {
                this.linking = false;
            });
    }

    _reduceError(e) {
        if (!e) {
            return 'Unknown error';
        }
        if (typeof e === 'string') {
            return e;
        }
        if (Array.isArray(e.body)) {
            return e.body.map((b) => b.message).filter(Boolean).join(' ');
        }
        if (e.body?.message) {
            return e.body.message;
        }
        if (e.message) {
            return e.message;
        }
        return 'Unknown error';
    }
}
