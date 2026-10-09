/**
 * Hosted MCP: read-only installed-base recap from lifecycle Asset,
 * AssetStatePeriod, and AssetAction. MRR comes from the current period.
 * ARR is derived (MRR × 12). Salesforce does not store ARR.
 */
global with sharing class RLM_MCP_GetInstalledBase {
    private static final Integer MAX_ACCOUNTS = 10;
    private static final Integer MAX_ASSETS = 40;
    private static final Integer MAX_ACTIONS = 100;

    global class InstalledInput {
        @InvocableVariable(
            required=true
            label='Account Name'
            description='Account that owns the assets, e.g. Acme.'
        )
        global String accountName;
    }

    global class InstalledOutput {
        @InvocableVariable(label='Is Success')
        global Boolean isSuccess;
        @InvocableVariable(label='Account Name')
        global String accountName;
        @InvocableVariable(
            label='Account Url'
            description='Lightning Account page. Render as [Open Account](accountUrl).'
        )
        global String accountUrl;
        @InvocableVariable(label='Current Mrr')
        global Decimal currentMrr;
        @InvocableVariable(
            label='Arr'
            description='Derived: current period MRR × 12. Not a Salesforce field.'
        )
        global Decimal arr;
        @InvocableVariable(label='Summary Display')
        global String summaryDisplay;
        @InvocableVariable(label='Needs Disambiguation')
        global Boolean needsDisambiguation;
        @InvocableVariable(label='Candidate Summaries Display')
        global String candidateSummariesDisplay;
        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    @InvocableMethod(
        label='Get Revenue Cloud Installed Base'
        description='Read-only recap of what an account owns: current AssetStatePeriod MRR, Discount, derived ARR (MRR×12), and add-ons. Never Asset.CurrentMrr or quote lines for owned discounts.'
    )
    global static List<InstalledOutput> getInstalledBase(List<InstalledInput> inputs) {
        List<InstalledOutput> results = new List<InstalledOutput>();
        if (inputs == null || inputs.isEmpty()) {
            return results;
        }
        for (InstalledInput input : inputs) {
            results.add(describeOne(input));
        }
        return results;
    }

    private static InstalledOutput describeOne(InstalledInput input) {
        InstalledOutput out = new InstalledOutput();
        out.isSuccess = false;
        out.needsDisambiguation = false;
        out.currentMrr = 0;
        out.arr = 0;
        try {
            if (input == null || String.isBlank(input.accountName)) {
                out.errorMessage = 'Account name is required.';
                return out;
            }
            Account account = resolveAccount(input.accountName.trim(), out);
            if (account == null) {
                return out;
            }
            out.accountName = account.Name;
            out.accountUrl = RLM_MCP_RecordLinks.lightningUrl('Account', account.Id);

            List<Asset> assets = [
                SELECT Id, Name, CurrentQuantity, Quantity, Product2.Name
                FROM Asset
                WHERE AccountId = :account.Id
                AND IsCompetitorProduct = false
                ORDER BY Name
                LIMIT :MAX_ASSETS
            ];
            if (assets.isEmpty()) {
                out.isSuccess = true;
                out.summaryDisplay = account.Name
                    + ' has no lifecycle assets.'
                    + accountLink(account);
                return out;
            }

            Set<Id> assetIds = new Map<Id, Asset>(assets).keySet();
            Map<Id, List<AssetStatePeriod>> periodsByAsset = loadPeriods(assetIds);
            Map<Id, List<AssetAction>> actionsByAsset = loadActions(assetIds);

            Datetime now = Datetime.now();
            Decimal totalMrr = 0;
            List<String> ownRows = new List<String>();
            List<String> discountRows = new List<String>();
            List<String> addonRows = new List<String>();
            List<Datetime> addonDates = new List<Datetime>();

            for (Asset asset : assets) {
                List<AssetStatePeriod> periods = periodsByAsset.containsKey(asset.Id)
                    ? periodsByAsset.get(asset.Id)
                    : new List<AssetStatePeriod>();
                AssetStatePeriod current = currentPeriod(periods, now);
                AssetStatePeriod upcoming = nextPeriod(periods, now);
                Decimal mrr = current == null ? 0 : nvl(current.Mrr);
                totalMrr += mrr;
                ownRows.add(ownershipRow(asset, current, upcoming, mrr));
                discountRows.add(discountRow(asset, current, upcoming));

                List<AssetAction> actions = actionsByAsset.containsKey(asset.Id)
                    ? actionsByAsset.get(asset.Id)
                    : new List<AssetAction>();
                for (AssetAction action : actions) {
                    if (!isAddon(action)) {
                        continue;
                    }
                    addonRows.add(addonRow(asset, action));
                    if (action.ActionDate != null) {
                        addonDates.add(action.ActionDate);
                    }
                }
            }

            out.currentMrr = totalMrr.setScale(2);
            out.arr = (totalMrr * 12).setScale(2);
            out.isSuccess = true;
            out.summaryDisplay = String.join(
                buildSummary(account, out.currentMrr, out.arr, ownRows, discountRows, addonRows, addonDates),
                '\n'
            );
        } catch (Exception e) {
            out.isSuccess = false;
            String caused = e.getMessage();
            out.errorMessage = String.isBlank(caused)
                ? 'Installed base lookup failed (' + e.getTypeName() + ').'
                : caused;
        }
        return out;
    }

    private static Account resolveAccount(String term, InstalledOutput out) {
        List<Account> exact = [
            SELECT Id, Name
            FROM Account
            WHERE Name = :term
            ORDER BY Name
            LIMIT :MAX_ACCOUNTS
        ];
        if (exact.size() == 1) {
            return exact[0];
        }
        String fuzzy = '%' + term + '%';
        List<Account> matches = [
            SELECT Id, Name
            FROM Account
            WHERE Name LIKE :fuzzy
            ORDER BY Name
            LIMIT :MAX_ACCOUNTS
        ];
        if (matches.isEmpty()) {
            out.errorMessage = 'No account matched "' + term + '".';
            return null;
        }
        if (matches.size() == 1) {
            return matches[0];
        }
        out.needsDisambiguation = true;
        List<String> names = new List<String>{
            'Multiple accounts match "' + term + '". Which one?'
        };
        Integer n = 1;
        for (Account account : matches) {
            names.add(String.valueOf(n) + '. ' + account.Name);
            n++;
        }
        out.candidateSummariesDisplay = String.join(names, '\n');
        out.errorMessage = 'Multiple accounts match "' + term + '". Ask the user which one.';
        return null;
    }

    private static Map<Id, List<AssetStatePeriod>> loadPeriods(Set<Id> assetIds) {
        Map<Id, List<AssetStatePeriod>> byAsset = new Map<Id, List<AssetStatePeriod>>();
        for (AssetStatePeriod period : [
            SELECT Id, AssetId, StartDate, EndDate, Quantity, Mrr, UnitPrice,
                   Discount, DiscountAmount
            FROM AssetStatePeriod
            WHERE AssetId IN :assetIds
            ORDER BY StartDate ASC
        ]) {
            if (!byAsset.containsKey(period.AssetId)) {
                byAsset.put(period.AssetId, new List<AssetStatePeriod>());
            }
            byAsset.get(period.AssetId).add(period);
        }
        return byAsset;
    }

    private static Map<Id, List<AssetAction>> loadActions(Set<Id> assetIds) {
        Map<Id, List<AssetAction>> byAsset = new Map<Id, List<AssetAction>>();
        for (AssetAction action : [
            SELECT Id, AssetId, Type, CategoryEnum, ActionDate, QuantityChange, MrrChange
            FROM AssetAction
            WHERE AssetId IN :assetIds
            ORDER BY ActionDate ASC
            LIMIT :MAX_ACTIONS
        ]) {
            if (!byAsset.containsKey(action.AssetId)) {
                byAsset.put(action.AssetId, new List<AssetAction>());
            }
            byAsset.get(action.AssetId).add(action);
        }
        return byAsset;
    }

    private static AssetStatePeriod currentPeriod(
        List<AssetStatePeriod> periods,
        Datetime now
    ) {
        AssetStatePeriod best;
        for (AssetStatePeriod period : periods) {
            if (period.StartDate != null && period.StartDate > now) {
                continue;
            }
            if (period.EndDate != null && period.EndDate < now) {
                continue;
            }
            if (best == null || (period.StartDate != null && (best.StartDate == null || period.StartDate > best.StartDate))) {
                best = period;
            }
        }
        return best;
    }

    private static AssetStatePeriod nextPeriod(
        List<AssetStatePeriod> periods,
        Datetime now
    ) {
        AssetStatePeriod best;
        for (AssetStatePeriod period : periods) {
            if (period.StartDate == null || period.StartDate <= now) {
                continue;
            }
            if (best == null || period.StartDate < best.StartDate) {
                best = period;
            }
        }
        return best;
    }

    private static Boolean isAddon(AssetAction action) {
        String category = action.CategoryEnum == null ? '' : action.CategoryEnum.toLowerCase();
        if (category.contains('upsell') || category.contains('cross-sell') || category.contains('upgrade')) {
            return true;
        }
        String actionType = action.Type == null ? '' : action.Type.toLowerCase();
        return actionType == 'change' && action.QuantityChange != null && action.QuantityChange > 0;
    }

    private static String ownershipRow(
        Asset asset,
        AssetStatePeriod current,
        AssetStatePeriod upcoming,
        Decimal mrr
    ) {
        String name = assetLabel(asset);
        Decimal qty = current != null && current.Quantity != null
            ? current.Quantity
            : (asset.CurrentQuantity != null ? asset.CurrentQuantity : asset.Quantity);
        String line = '- ' + name + ' — qty ' + qtyLabel(qty) + ', ' + money(mrr) + ' MRR'
            + discountBit(current);
        String assetLink = RLM_MCP_RecordLinks.markdown('Open Asset', 'Asset', asset.Id);
        if (String.isNotBlank(assetLink)) {
            line += ' · ' + assetLink;
        }
        if (upcoming != null) {
            line += '\n  Next: qty ' + qtyLabel(upcoming.Quantity)
                + ', ' + money(nvl(upcoming.Mrr)) + ' MRR'
                + discountBit(upcoming)
                + ' from ' + dayLabel(upcoming.StartDate);
        }
        return line;
    }

    private static String addonRow(Asset asset, AssetAction action) {
        String qty = action.QuantityChange == null
            ? ''
            : ((action.QuantityChange > 0 ? '+' : '') + String.valueOf(action.QuantityChange.setScale(0)) + ' qty');
        String mrr = action.MrrChange == null ? '' : money(action.MrrChange) + ' MRR';
        String category = String.isBlank(action.CategoryEnum) ? action.Type : action.CategoryEnum;
        List<String> bits = new List<String>();
        if (String.isNotBlank(qty)) {
            bits.add(qty);
        }
        if (String.isNotBlank(mrr)) {
            bits.add(mrr);
        }
        if (String.isNotBlank(category)) {
            bits.add(category);
        }
        return '- ' + dayLabel(action.ActionDate) + ': ' + assetLabel(asset)
            + (bits.isEmpty() ? '' : ' — ' + String.join(bits, ', '));
    }

    private static String discountRow(
        Asset asset,
        AssetStatePeriod current,
        AssetStatePeriod upcoming
    ) {
        String line = '- ' + assetLabel(asset) + ' — ' + discountText(current);
        if (upcoming != null) {
            line += ' (next: ' + discountText(upcoming) + ' from '
                + dayLabel(upcoming.StartDate) + ')';
        }
        return line;
    }

    private static String discountBit(AssetStatePeriod period) {
        String text = discountText(period);
        return text == 'no % off' ? '' : ', ' + text;
    }

    private static String discountText(AssetStatePeriod period) {
        if (period == null) {
            return 'no % off';
        }
        if (period.Discount != null && period.Discount > 0) {
            return formatNumber(period.Discount) + '% off';
        }
        if (period.DiscountAmount != null && period.DiscountAmount > 0) {
            return money(period.DiscountAmount) + ' off';
        }
        return 'no % off';
    }

    private static List<String> buildSummary(
        Account account,
        Decimal mrr,
        Decimal arr,
        List<String> ownRows,
        List<String> discountRows,
        List<String> addonRows,
        List<Datetime> addonDates
    ) {
        List<String> rows = new List<String>();
        rows.add('Installed base for ' + account.Name);
        String acctLink = RLM_MCP_RecordLinks.markdown('Open Account', 'Account', account.Id);
        if (String.isNotBlank(acctLink)) {
            rows.add(acctLink);
        }
        rows.add('');
        rows.add('Current MRR: ' + money(mrr));
        rows.add('ARR (MRR × 12): ' + money(arr));
        rows.add('ARR is derived; Salesforce stores MRR only.');
        rows.add('');
        rows.add('What they own now:');
        rows.addAll(ownRows);
        rows.add('');
        rows.add('Current discounts (from AssetStatePeriod, not quotes):');
        if (discountRows.isEmpty()) {
            rows.add('- None.');
        } else {
            rows.addAll(discountRows);
        }
        rows.add('');
        rows.add('Add-ons:');
        if (addonRows.isEmpty()) {
            rows.add('- None after the initial sale.');
        } else {
            rows.addAll(addonRows);
        }
        rows.add(cadenceLine(addonDates));
        return rows;
    }

    private static String cadenceLine(List<Datetime> addonDates) {
        if (addonDates == null || addonDates.isEmpty()) {
            return 'Cadence: no add-ons after the initial sale.';
        }
        if (addonDates.size() == 1) {
            return 'Cadence: one add-on on ' + dayLabel(addonDates[0]) + '.';
        }
        Datetime first = addonDates[0];
        Datetime last = addonDates[addonDates.size() - 1];
        Long days = first == null || last == null
            ? 0
            : (last.getTime() - first.getTime()) / 86400000L;
        Long span = days < 1 ? 1 : days;
        Decimal avg = Decimal.valueOf(span)
            .divide(Decimal.valueOf(addonDates.size() - 1), 0);
        return 'Cadence: ' + String.valueOf(addonDates.size())
            + ' add-ons; about every ' + String.valueOf(avg) + ' days.';
    }

    private static String assetLabel(Asset asset) {
        if (asset.Product2 != null && String.isNotBlank(asset.Product2.Name)) {
            return asset.Product2.Name;
        }
        return asset.Name;
    }

    private static String qtyLabel(Decimal qty) {
        return formatNumber(qty);
    }

    private static String formatNumber(Decimal value) {
        if (value == null) {
            return '0';
        }
        Decimal rounded = value.setScale(2, RoundingMode.HALF_UP);
        if (rounded == rounded.round(RoundingMode.DOWN)) {
            return String.valueOf(rounded.longValue());
        }
        return String.valueOf(rounded);
    }

    private static String dayLabel(Datetime value) {
        return value == null ? 'unknown date' : String.valueOf(value.date());
    }

    private static String accountLink(Account account) {
        String link = RLM_MCP_RecordLinks.markdown('Open Account', 'Account', account.Id);
        return String.isBlank(link) ? '' : '\n' + link;
    }

    private static Decimal nvl(Decimal value) {
        return value == null ? 0 : value;
    }

    private static String money(Decimal value) {
        Decimal n = value == null ? 0 : value.setScale(2);
        return 'USD ' + n.format();
    }
}
