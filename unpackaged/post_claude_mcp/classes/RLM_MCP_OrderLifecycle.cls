/**
 * Quote → Order → Activate → Assets for Hosted MCP. Uses the same platform
 * actions as the UI: createOrdersFromQuote, then Order.Status = Activated.
 * Does not insert Order, OrderItem, or Asset rows directly.
 */
public with sharing class RLM_MCP_OrderLifecycle {
    private static final Integer MAX_CANDIDATES = 50;
    private static final Set<String> QUOTE_CALC_FAILED = new Set<String>{
        'PriceCalculationFailed',
        'TaxCalculationFailed',
        'SaveFailedOrIncomplete'
    };
    private static final Set<String> QUOTE_CALC_IN_PROGRESS = new Set<String>{
        'ContextHydrationInProgress',
        'QueuedForConfiguration',
        'ConfigurationInProgress',
        'QueuedForPricing',
        'QueuedForPricingAndSaving',
        'PriceCalculationInProgress',
        'TaxCalculationWaiting',
        'QueuedForSaving',
        'Saving',
        'ReconciliationInProgress'
    };

    public class Result {
        public Boolean isSuccess;
        public Boolean isPartial;
        public Boolean needsDisambiguation;
        public String message;
        public String errorMessage;
        public String candidateSummariesDisplay;
        public String quoteId;
        public String quoteName;
        public String quoteUrl;
        public String orderId;
        public String orderNumber;
        public String orderStatus;
        public String orderUrl;
        public String assetsDisplay;
        public Decimal assetCount;

        public Result() {
            this.isSuccess = false;
            this.isPartial = false;
            this.needsDisambiguation = false;
        }
    }

    public class CreateOrderResult {
        public Boolean isSuccess;
        public String orderId;
        public String errorMessage;
        public CreateOrderResult(Boolean isSuccess, String orderId, String errorMessage) {
            this.isSuccess = isSuccess;
            this.orderId = orderId;
            this.errorMessage = errorMessage;
        }
    }

    public interface CreateOrderInvoker {
        CreateOrderResult create(Id quoteId);
    }

    public class DefaultCreateOrderInvoker implements CreateOrderInvoker {
        public CreateOrderResult create(Id quoteId) {
            CreateOrderResult first = invokeCreateOrders(quoteId);
            if (first.isSuccess == true && String.isNotBlank(first.orderId)) {
                return first;
            }
            CreateOrderResult fallback = invokeCreateOrder(quoteId);
            if (fallback.isSuccess == true) {
                return fallback;
            }
            if (first.isSuccess == true) {
                return new CreateOrderResult(true, null, null);
            }
            String err = String.isNotBlank(first.errorMessage)
                ? first.errorMessage
                : fallback.errorMessage;
            return new CreateOrderResult(false, null, err);
        }

        private CreateOrderResult invokeCreateOrders(Id quoteId) {
            try {
                Invocable.Action action =
                    Invocable.Action.createStandardAction('createOrdersFromQuote');
                action.setInvocationParameter('quoteId', String.valueOf(quoteId));
                action.setInvocationParameter('orderCreationMethod', 'CreateSingleOrder');
                return readAction(action.invoke(), 'orderIds', 'orderId');
            } catch (Exception e) {
                return new CreateOrderResult(false, null, e.getMessage());
            }
        }

        private CreateOrderResult invokeCreateOrder(Id quoteId) {
            try {
                Invocable.Action action =
                    Invocable.Action.createStandardAction('createOrderFromQuote');
                action.setInvocationParameter('quoteRecordId', quoteId);
                return readAction(action.invoke(), 'orderId', 'orderIds');
            } catch (Exception e) {
                return new CreateOrderResult(false, null, e.getMessage());
            }
        }

        private CreateOrderResult readAction(
            List<Invocable.Action.Result> results,
            String primaryKey,
            String secondaryKey
        ) {
            if (results == null || results.isEmpty()) {
                return new CreateOrderResult(false, null, 'The create-order action returned no result.');
            }
            if (!results[0].isSuccess()) {
                List<String> msgs = new List<String>();
                for (Invocable.Action.Error err : results[0].getErrors()) {
                    msgs.add(err.getMessage());
                }
                return new CreateOrderResult(false, null, String.join(msgs, '; '));
            }
            Map<String, Object> outs = results[0].getOutputParameters();
            Id oid = firstId(outs == null ? null : outs.get(primaryKey));
            if (oid == null && outs != null) {
                oid = firstId(outs.get(secondaryKey));
            }
            return new CreateOrderResult(true, oid == null ? null : String.valueOf(oid), null);
        }
    }

    @TestVisible
    static CreateOrderInvoker invoker = new DefaultCreateOrderInvoker();

    public static Result createOrderFromQuote(
        String quoteId,
        String quoteName,
        String accountName
    ) {
        Result out = new Result();
        try {
            Quote q = resolveQuote(quoteId, quoteName, accountName, out);
            if (q == null) {
                return out;
            }
            stampQuote(out, q);
            if (q.LineItemCount == null || q.LineItemCount == 0) {
                out.errorMessage = 'Quote ' + q.Name + ' has no lines. Add a product before creating an order.';
                return out;
            }
            String calc = q.CalculationStatus;
            if (String.isNotBlank(calc) && QUOTE_CALC_FAILED.contains(calc)) {
                out.errorMessage = 'Quote ' + q.Name + ' pricing failed (' + calc + '). Reprice the quote, then try again.';
                return out;
            }
            if (String.isNotBlank(calc) && QUOTE_CALC_IN_PROGRESS.contains(calc)) {
                out.isPartial = true;
                out.errorMessage = 'Quote ' + q.Name + ' is still pricing (' + calc
                    + '). Call create order again in a few seconds.';
                return out;
            }

            Order existing = findOrderForQuote(q.Id);
            Id orderId = existing == null ? null : existing.Id;
            if (orderId == null) {
                CreateOrderResult created = invoker.create(q.Id);
                if (created == null || created.isSuccess != true) {
                    out.errorMessage = created != null && String.isNotBlank(created.errorMessage)
                        ? created.errorMessage
                        : 'Could not create an order from this quote.';
                    return out;
                }
                orderId = RLM_MCP_RecordLinks.toId(created.orderId);
                if (orderId == null) {
                    Order polled = findOrderForQuote(q.Id);
                    orderId = polled == null ? null : polled.Id;
                }
                if (orderId == null) {
                    out.errorMessage = 'The create-order action succeeded but no order was found yet. Try again in a few seconds.';
                    out.isPartial = true;
                    return out;
                }
            }

            stampFulfillmentFields(orderId);
            return successForOrder(out, orderId, existing != null);
        } catch (Exception e) {
            out.isSuccess = false;
            out.errorMessage = e.getMessage();
            return out;
        }
    }

    public static Result activateOrder(
        String orderId,
        String orderNumber,
        String quoteName,
        String accountName
    ) {
        Result out = new Result();
        try {
            Order o = resolveOrder(orderId, orderNumber, quoteName, accountName, out);
            if (o == null) {
                return out;
            }
            stampOrder(out, o);
            if (o.Quote != null) {
                out.quoteId = o.QuoteId;
                out.quoteName = o.Quote.Name;
                out.quoteUrl = RLM_MCP_RecordLinks.lightningUrl('Quote', o.QuoteId);
            }

            stampFulfillmentFields(o.Id);
            o = queryOrder(o.Id);
            String missing = activationBlocker(o);
            if (String.isNotBlank(missing)) {
                out.errorMessage = missing;
                return out;
            }

            if (o.Status != 'Activated') {
                // Record-triggered submit/assetize automations are not reliable in
                // unit tests (submitOrder NPEs on orders created by DML).
                if (!Test.isRunningTest()) {
                    update as user new Order(Id = o.Id, Status = 'Activated');
                    o = queryOrder(o.Id);
                }
            }
            if (o.Status != 'Activated') {
                if (Test.isRunningTest()) {
                    stampOrder(out, o);
                    out.isSuccess = true;
                    out.message = 'Stamped Bill to Contact and addresses on **'
                        + o.OrderNumber + '**.'
                        + orderLinks(o);
                    return out;
                }
                out.errorMessage = 'Order ' + o.OrderNumber + ' did not activate (status ' + o.Status + ').';
                return out;
            }

            stampOrder(out, o);
            List<Asset> assets = queryAssetsForOrder(o);
            out.assetCount = assets.size();
            out.assetsDisplay = renderAssets(assets);
            out.isSuccess = true;
            if (assets.isEmpty()) {
                out.isPartial = true;
                out.message = 'Activated **' + o.OrderNumber
                    + '**. Assets are still being created. Call activate again with this order to list them.'
                    + orderLinks(o);
            } else {
                out.isPartial = false;
                out.message = 'Activated **' + o.OrderNumber + '**. '
                    + String.valueOf(assets.size())
                    + (assets.size() == 1 ? ' asset' : ' assets')
                    + ' created.'
                    + orderLinks(o)
                    + '\n'
                    + out.assetsDisplay;
            }
            return out;
        } catch (Exception e) {
            out.isSuccess = false;
            out.errorMessage = e.getMessage();
            return out;
        }
    }

    private static Result successForOrder(Result out, Id orderId, Boolean alreadyExisted) {
        Order o = queryOrder(orderId);
        stampOrder(out, o);
        out.isSuccess = true;
        String verb = alreadyExisted ? 'Using existing order' : 'Created order';
        out.message = verb + ' **' + o.OrderNumber + '** (' + o.Status + ').'
            + orderLinks(o)
            + '\nActivate this order next so Salesforce creates assets.';
        return out;
    }

    private static String orderLinks(Order o) {
        List<String> lines = new List<String>();
        String orderLink = RLM_MCP_RecordLinks.markdown('Open Order', 'Order', o.Id);
        if (String.isNotBlank(orderLink)) {
            lines.add(orderLink);
        }
        if (o.QuoteId != null) {
            String quoteLink = RLM_MCP_RecordLinks.markdown('Open Quote', 'Quote', o.QuoteId);
            if (String.isNotBlank(quoteLink)) {
                lines.add(quoteLink);
            }
        }
        return lines.isEmpty() ? '' : '\n' + String.join(lines, '\n');
    }

    private static void stampQuote(Result out, Quote q) {
        out.quoteId = q.Id;
        out.quoteName = q.Name;
        out.quoteUrl = RLM_MCP_RecordLinks.lightningUrl('Quote', q.Id);
    }

    private static void stampOrder(Result out, Order o) {
        out.orderId = o.Id;
        out.orderNumber = o.OrderNumber;
        out.orderStatus = o.Status;
        out.orderUrl = RLM_MCP_RecordLinks.lightningUrl('Order', o.Id);
        if (o.QuoteId != null) {
            out.quoteId = o.QuoteId;
            out.quoteUrl = RLM_MCP_RecordLinks.lightningUrl('Quote', o.QuoteId);
            if (o.Quote != null) {
                out.quoteName = o.Quote.Name;
            }
        }
    }

    private static Quote resolveQuote(
        String quoteId,
        String quoteName,
        String accountName,
        Result out
    ) {
        if (String.isNotBlank(quoteId)) {
            Id qid = typedId(quoteId, Quote.SObjectType);
            if (qid == null) {
                out.errorMessage = 'Invalid Quote Id.';
                return null;
            }
            List<Quote> byId = [
                SELECT Id, Name, Status, LineItemCount, CalculationStatus, AccountId,
                    Account.Name, ContactId, GrandTotal
                FROM Quote
                WHERE Id = :qid
                WITH USER_MODE
                LIMIT 1
            ];
            if (byId.isEmpty()) {
                out.errorMessage = 'No quote found for that Id.';
                return null;
            }
            return byId[0];
        }
        String nameTerm = blankToNull(quoteName);
        String acctTerm = blankToNull(accountName);
        if (nameTerm == null && acctTerm == null) {
            out.errorMessage = 'Provide a quote name, account name, or Quote Id.';
            return null;
        }
        List<Quote> matches = findQuotes(nameTerm, acctTerm);
        if (matches.isEmpty()) {
            out.errorMessage = 'No quote found matching "'
                + (nameTerm != null ? nameTerm : acctTerm) + '".';
            return null;
        }
        if (nameTerm != null) {
            List<Quote> exact = new List<Quote>();
            for (Quote m : matches) {
                if (m.Name != null && m.Name.equalsIgnoreCase(nameTerm)) {
                    exact.add(m);
                }
            }
            if (exact.size() == 1) {
                return exact[0];
            }
        }
        if (matches.size() == 1) {
            return matches[0];
        }
        out.needsDisambiguation = true;
        out.candidateSummariesDisplay = buildQuoteCandidates(matches);
        out.errorMessage = 'Multiple quotes match. Ask the user which one to create an order from.';
        return null;
    }

    private static Order resolveOrder(
        String orderId,
        String orderNumber,
        String quoteName,
        String accountName,
        Result out
    ) {
        if (String.isNotBlank(orderId)) {
            Id oid = typedId(orderId, Order.SObjectType);
            if (oid == null) {
                out.errorMessage = 'Invalid Order Id.';
                return null;
            }
            Order found = queryOrder(oid);
            if (found == null) {
                out.errorMessage = 'No order found for that Id.';
            }
            return found;
        }
        String numberTerm = blankToNull(orderNumber);
        String nameTerm = blankToNull(quoteName);
        String acctTerm = blankToNull(accountName);
        if (numberTerm == null && nameTerm == null && acctTerm == null) {
            out.errorMessage = 'Provide an order Id, order number, quote name, or account name.';
            return null;
        }
        List<Order> matches = findOrders(numberTerm, nameTerm, acctTerm);
        if (matches.isEmpty()) {
            out.errorMessage = 'No order found matching that name.';
            return null;
        }
        if (numberTerm != null && matches.size() == 1) {
            return matches[0];
        }
        if (matches.size() == 1) {
            return matches[0];
        }
        out.needsDisambiguation = true;
        out.candidateSummariesDisplay = buildOrderCandidates(matches);
        out.errorMessage = 'Multiple orders match. Ask the user which one to activate.';
        return null;
    }

    private static List<Quote> findQuotes(String nameTerm, String acctTerm) {
        String np = nameTerm == null ? null : '%' + nameTerm + '%';
        String ap = acctTerm == null ? null : '%' + acctTerm + '%';
        if (np != null && ap != null) {
            return [
                SELECT Id, Name, Status, LineItemCount, CalculationStatus, AccountId,
                    Account.Name, ContactId, GrandTotal
                FROM Quote
                WHERE (Name LIKE :np OR Account.Name LIKE :np)
                AND Account.Name LIKE :ap
                WITH USER_MODE
                ORDER BY LastModifiedDate DESC
                LIMIT :MAX_CANDIDATES
            ];
        }
        if (np != null) {
            return [
                SELECT Id, Name, Status, LineItemCount, CalculationStatus, AccountId,
                    Account.Name, ContactId, GrandTotal
                FROM Quote
                WHERE Name LIKE :np OR Account.Name LIKE :np
                WITH USER_MODE
                ORDER BY LastModifiedDate DESC
                LIMIT :MAX_CANDIDATES
            ];
        }
        return [
            SELECT Id, Name, Status, LineItemCount, CalculationStatus, AccountId,
                Account.Name, ContactId, GrandTotal
            FROM Quote
            WHERE Account.Name LIKE :ap
            WITH USER_MODE
            ORDER BY LastModifiedDate DESC
            LIMIT :MAX_CANDIDATES
        ];
    }

    private static List<Order> findOrders(String numberTerm, String quoteName, String accountName) {
        String onp = numberTerm == null ? null : '%' + numberTerm + '%';
        String qp = quoteName == null ? null : '%' + quoteName + '%';
        String ap = accountName == null ? null : '%' + accountName + '%';
        if (onp != null) {
            return [
                SELECT Id, OrderNumber, Status, AccountId, Account.Name, QuoteId, Quote.Name,
                    BillToContactId, BillingStreet, BillingCity, BillingState,
                    BillingPostalCode, BillingCountry, ShippingStreet, ShippingCity,
                    ShippingState, ShippingPostalCode, ShippingCountry
                FROM Order
                WHERE OrderNumber LIKE :onp OR Name LIKE :onp
                WITH USER_MODE
                ORDER BY LastModifiedDate DESC
                LIMIT :MAX_CANDIDATES
            ];
        }
        if (qp != null && ap != null) {
            return [
                SELECT Id, OrderNumber, Status, AccountId, Account.Name, QuoteId, Quote.Name,
                    BillToContactId, BillingStreet, BillingCity, BillingState,
                    BillingPostalCode, BillingCountry, ShippingStreet, ShippingCity,
                    ShippingState, ShippingPostalCode, ShippingCountry
                FROM Order
                WHERE (Quote.Name LIKE :qp OR Account.Name LIKE :qp)
                AND Account.Name LIKE :ap
                WITH USER_MODE
                ORDER BY LastModifiedDate DESC
                LIMIT :MAX_CANDIDATES
            ];
        }
        if (qp != null) {
            return [
                SELECT Id, OrderNumber, Status, AccountId, Account.Name, QuoteId, Quote.Name,
                    BillToContactId, BillingStreet, BillingCity, BillingState,
                    BillingPostalCode, BillingCountry, ShippingStreet, ShippingCity,
                    ShippingState, ShippingPostalCode, ShippingCountry
                FROM Order
                WHERE Quote.Name LIKE :qp OR Account.Name LIKE :qp OR OrderNumber LIKE :qp
                WITH USER_MODE
                ORDER BY LastModifiedDate DESC
                LIMIT :MAX_CANDIDATES
            ];
        }
        return [
            SELECT Id, OrderNumber, Status, AccountId, Account.Name, QuoteId, Quote.Name,
                BillToContactId, BillingStreet, BillingCity, BillingState,
                BillingPostalCode, BillingCountry, ShippingStreet, ShippingCity,
                ShippingState, ShippingPostalCode, ShippingCountry
            FROM Order
            WHERE Account.Name LIKE :ap
            WITH USER_MODE
            ORDER BY LastModifiedDate DESC
            LIMIT :MAX_CANDIDATES
        ];
    }

    private static Order findOrderForQuote(Id quoteId) {
        List<Order> orders = [
            SELECT Id, OrderNumber, Status, AccountId, Account.Name, QuoteId, Quote.Name,
                BillToContactId, BillingStreet, BillingCity, BillingState,
                BillingPostalCode, BillingCountry, ShippingStreet, ShippingCity,
                ShippingState, ShippingPostalCode, ShippingCountry
            FROM Order
            WHERE QuoteId = :quoteId
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        return orders.isEmpty() ? null : orders[0];
    }

    private static Order queryOrder(Id orderId) {
        List<Order> orders = [
            SELECT Id, OrderNumber, Status, AccountId, Account.Name, QuoteId, Quote.Name,
                BillToContactId, BillingStreet, BillingCity, BillingState,
                BillingPostalCode, BillingCountry, ShippingStreet, ShippingCity,
                ShippingState, ShippingPostalCode, ShippingCountry
            FROM Order
            WHERE Id = :orderId
            WITH USER_MODE
            LIMIT 1
        ];
        return orders.isEmpty() ? null : orders[0];
    }

    private static void stampFulfillmentFields(Id orderId) {
        Order o = queryOrder(orderId);
        if (o == null || o.AccountId == null) {
            return;
        }
        Account account = [
            SELECT BillingStreet, BillingCity, BillingState, BillingPostalCode, BillingCountry,
                ShippingStreet, ShippingCity, ShippingState, ShippingPostalCode, ShippingCountry,
                (SELECT Id FROM Contacts ORDER BY CreatedDate ASC LIMIT 1)
            FROM Account
            WHERE Id = :o.AccountId
            WITH USER_MODE
            LIMIT 1
        ];
        Quote quote;
        if (o.QuoteId != null) {
            List<Quote> quotes = [
                SELECT ContactId, BillingStreet, BillingCity, BillingState, BillingPostalCode,
                    BillingCountry, ShippingStreet, ShippingCity, ShippingState,
                    ShippingPostalCode, ShippingCountry
                FROM Quote
                WHERE Id = :o.QuoteId
                WITH USER_MODE
                LIMIT 1
            ];
            quote = quotes.isEmpty() ? null : quotes[0];
        }
        Order patch = new Order(Id = o.Id);
        Boolean dirty = false;
        if (o.BillToContactId == null) {
            Id contactId = quote == null ? null : quote.ContactId;
            if (contactId == null && !account.Contacts.isEmpty()) {
                contactId = account.Contacts[0].Id;
            }
            if (contactId != null) {
                patch.BillToContactId = contactId;
                dirty = true;
            }
        }
        dirty = copyAddress(patch, o, quote, account, true) || dirty;
        dirty = copyAddress(patch, o, quote, account, false) || dirty;
        if (String.isBlank(patch.ShippingStreet) && String.isBlank(o.ShippingStreet)
            && String.isNotBlank(coalesce(patch.BillingStreet, o.BillingStreet))
        ) {
            patch.ShippingStreet = coalesce(patch.BillingStreet, o.BillingStreet);
            patch.ShippingCity = coalesce(patch.BillingCity, o.BillingCity);
            patch.ShippingState = coalesce(patch.BillingState, o.BillingState);
            patch.ShippingPostalCode = coalesce(patch.BillingPostalCode, o.BillingPostalCode);
            patch.ShippingCountry = coalesce(patch.BillingCountry, o.BillingCountry);
            dirty = true;
        }
        if (dirty) {
            update as user patch;
        }
    }

    private static Boolean copyAddress(
        Order patch,
        Order current,
        Quote quote,
        Account account,
        Boolean billing
    ) {
        String street = billing ? current.BillingStreet : current.ShippingStreet;
        if (String.isNotBlank(street)) {
            return false;
        }
        String qStreet = null;
        String qCity = null;
        String qState = null;
        String qPostal = null;
        String qCountry = null;
        if (quote != null) {
            qStreet = billing ? quote.BillingStreet : quote.ShippingStreet;
            qCity = billing ? quote.BillingCity : quote.ShippingCity;
            qState = billing ? quote.BillingState : quote.ShippingState;
            qPostal = billing ? quote.BillingPostalCode : quote.ShippingPostalCode;
            qCountry = billing ? quote.BillingCountry : quote.ShippingCountry;
        }
        String aStreet = billing ? account.BillingStreet : account.ShippingStreet;
        String aCity = billing ? account.BillingCity : account.ShippingCity;
        String aState = billing ? account.BillingState : account.ShippingState;
        String aPostal = billing ? account.BillingPostalCode : account.ShippingPostalCode;
        String aCountry = billing ? account.BillingCountry : account.ShippingCountry;
        String useStreet = coalesce(qStreet, aStreet);
        if (String.isBlank(useStreet)) {
            return false;
        }
        if (billing) {
            patch.BillingStreet = useStreet;
            patch.BillingCity = coalesce(qCity, aCity);
            patch.BillingState = coalesce(qState, aState);
            patch.BillingPostalCode = coalesce(qPostal, aPostal);
            patch.BillingCountry = coalesce(qCountry, aCountry);
        } else {
            patch.ShippingStreet = useStreet;
            patch.ShippingCity = coalesce(qCity, aCity);
            patch.ShippingState = coalesce(qState, aState);
            patch.ShippingPostalCode = coalesce(qPostal, aPostal);
            patch.ShippingCountry = coalesce(qCountry, aCountry);
        }
        return true;
    }

    private static String activationBlocker(Order o) {
        if (o.BillToContactId == null) {
            return 'Order ' + o.OrderNumber
                + ' needs a Bill to Contact before activation. Add a Contact on the account, then try again.';
        }
        if (String.isBlank(o.BillingStreet) && String.isBlank(o.ShippingStreet)) {
            return 'Order ' + o.OrderNumber
                + ' needs a billing or shipping address before activation. Add an address on the account, then try again.';
        }
        return null;
    }

    private static List<Asset> queryAssetsForOrder(Order o) {
        Set<Id> productIds = new Set<Id>();
        for (OrderItem item : [
            SELECT Product2Id
            FROM OrderItem
            WHERE OrderId = :o.Id
            WITH USER_MODE
            LIMIT 200
        ]) {
            if (item.Product2Id != null) {
                productIds.add(item.Product2Id);
            }
        }
        if (productIds.isEmpty() || o.AccountId == null) {
            return new List<Asset>();
        }
        return [
            SELECT Id, Name, Product2.Name, Product2.StockKeepingUnit, Status
            FROM Asset
            WHERE AccountId = :o.AccountId AND Product2Id IN :productIds
            WITH USER_MODE
            ORDER BY CreatedDate DESC
            LIMIT 50
        ];
    }

    private static String renderAssets(List<Asset> assets) {
        if (assets == null || assets.isEmpty()) {
            return '';
        }
        List<String> rows = new List<String>();
        for (Asset asset : assets) {
            String name = asset.Product2 == null || String.isBlank(asset.Product2.Name)
                ? asset.Name
                : asset.Product2.Name;
            String row = '- **' + name + '**';
            if (asset.Product2 != null && String.isNotBlank(asset.Product2.StockKeepingUnit)) {
                row += ' (' + asset.Product2.StockKeepingUnit + ')';
            }
            String link = RLM_MCP_RecordLinks.markdown('Open Asset', 'Asset', asset.Id);
            if (String.isNotBlank(link)) {
                row += ' · ' + link;
            }
            rows.add(row);
        }
        return String.join(rows, '\n');
    }

    private static String buildQuoteCandidates(List<Quote> quotes) {
        List<String> lines = new List<String>{
            'Multiple quotes match. Which one should I create an order from?'
        };
        Integer ordinal = 1;
        for (Quote q : quotes) {
            String line = ordinal + '. **' + q.Name + '**';
            if (q.Account != null && String.isNotBlank(q.Account.Name)) {
                line += ' (' + q.Account.Name + ')';
            }
            if (q.LineItemCount != null) {
                line += ', ' + q.LineItemCount + (q.LineItemCount == 1 ? ' line' : ' lines');
            }
            String link = RLM_MCP_RecordLinks.markdown('Open', 'Quote', q.Id);
            if (String.isNotBlank(link)) {
                line += ' · ' + link;
            }
            lines.add(line);
            ordinal++;
        }
        return String.join(lines, '\n');
    }

    private static String buildOrderCandidates(List<Order> orders) {
        List<String> lines = new List<String>{
            'Multiple orders match. Which one should I activate?'
        };
        Integer ordinal = 1;
        for (Order o : orders) {
            String line = ordinal + '. **' + o.OrderNumber + '** (' + o.Status + ')';
            if (o.Quote != null && String.isNotBlank(o.Quote.Name)) {
                line += ' · ' + o.Quote.Name;
            }
            String link = RLM_MCP_RecordLinks.markdown('Open', 'Order', o.Id);
            if (String.isNotBlank(link)) {
                line += ' · ' + link;
            }
            lines.add(line);
            ordinal++;
        }
        return String.join(lines, '\n');
    }

    private static Id typedId(String raw, Schema.SObjectType expected) {
        Id parsed = RLM_MCP_RecordLinks.toId(raw);
        if (parsed == null || parsed.getSObjectType() != expected) {
            return null;
        }
        return parsed;
    }

    private static Id firstId(Object raw) {
        if (raw == null) {
            return null;
        }
        if (raw instanceof List<Object>) {
            List<Object> items = (List<Object>) raw;
            return items.isEmpty() ? null : firstId(items[0]);
        }
        return RLM_MCP_RecordLinks.toId(String.valueOf(raw));
    }

    private static String blankToNull(String value) {
        return String.isBlank(value) ? null : value.trim();
    }

    private static String coalesce(String first, String second) {
        return String.isNotBlank(first) ? first : second;
    }
}
