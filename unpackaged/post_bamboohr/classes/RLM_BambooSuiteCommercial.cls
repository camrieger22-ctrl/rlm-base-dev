/**
 * Single commercial operation gateway for Bamboo Revenue Suite.
 * LWC maps UI events here; Place+FORCE mutators go through RLM_BambooSuitePlace.
 */
public with sharing class RLM_BambooSuiteCommercial {
    public class OperationRequest {
        @AuraEnabled
        public String operation;
        @AuraEnabled
        public String quoteId;
        @AuraEnabled
        public String opportunityId;
        @AuraEnabled
        public String payloadJson;
    }

    public class OperationResult {
        @AuraEnabled
        public String operation;
        @AuraEnabled
        public RLM_BambooRevenueSuite.OptionDetailDTO option;
        @AuraEnabled
        public RLM_BambooRevenueSuite.AddLineResultDTO addResult;
        @AuraEnabled
        public String summary;
    }

    /**
     * Supported operations (case-insensitive):
     * Reprice, UpdateQty, UpdateDisc, UpdateLines, UpdateOptionDisc,
     * UpdateSeats, RemoveLines, ApplyTerm, ApplyTermAll, ApplyBillingAll,
     * AddLinesBySku, AddWorkforcePackage
     */
    @AuraEnabled
    public static OperationResult run(OperationRequest request) {
        if (request == null || String.isBlank(request.operation)) {
            throw new RLM_BambooRevenueSuite.SuiteException('operation is required.');
        }
        String op = request.operation.trim().toLowerCase();
        Map<String, Object> payload = String.isBlank(request.payloadJson)
            ? new Map<String, Object>()
            : (Map<String, Object>) JSON.deserializeUntyped(request.payloadJson);

        OperationResult result = new OperationResult();
        result.operation = request.operation;

        if (op == 'reprice') {
            result.option = RLM_BambooSuitePlace.repriceOption(reqQuote(request, payload));
            result.summary = 'Repriced.';
        } else if (op == 'updateqty') {
            result.option = RLM_BambooSuitePlace.updateLineQuantity(
                reqQuote(request, payload),
                str(payload, 'lineId'),
                dec(payload, 'quantity')
            );
            result.summary = 'Quantity updated.';
        } else if (op == 'updatedisc') {
            result.option = RLM_BambooSuitePlace.updateLineDiscount(
                reqQuote(request, payload),
                str(payload, 'lineId'),
                dec(payload, 'discountPercent')
            );
            result.summary = 'Discount updated.';
        } else if (op == 'updatelines') {
            result.option = RLM_BambooSuitePlace.updateLines(
                reqQuote(request, payload),
                lineEdits(payload, 'edits')
            );
            result.summary = 'Line edits applied.';
        } else if (op == 'updateoptiondisc') {
            result.option = RLM_BambooSuitePlace.updateOptionDiscount(
                reqQuote(request, payload),
                dec(payload, 'discountPercent')
            );
            result.summary = 'Option discount updated.';
        } else if (op == 'updateseats') {
            result.option = RLM_BambooSuitePlace.updateOptionSeatCount(
                reqQuote(request, payload),
                dec(payload, 'seats')
            );
            result.summary = 'Seats updated.';
        } else if (op == 'removelines') {
            List<String> lineIds = strList(payload, 'lineIds');
            if (lineIds.isEmpty() && String.isNotBlank(str(payload, 'lineId'))) {
                lineIds.add(str(payload, 'lineId'));
            }
            result.option = RLM_BambooSuitePlace.removeLines(
                reqQuote(request, payload),
                lineIds
            );
            result.summary = 'Line(s) removed.';
        } else if (op == 'applyterm') {
            result.option = RLM_BambooSuitePlace.applyTermToOption(
                reqQuote(request, payload),
                intVal(payload, 'termMonths'),
                str(payload, 'startDateIso'),
                str(payload, 'billingFrequency')
            );
            result.summary = 'Term applied.';
        } else if (op == 'applytermall') {
            String oppId = firstNonBlank(
                request.opportunityId,
                str(payload, 'opportunityId')
            );
            result.option = RLM_BambooSuitePlace.applyTermToAllOptions(
                oppId,
                firstNonBlank(request.quoteId, str(payload, 'selectedQuoteId')),
                intVal(payload, 'termMonths'),
                str(payload, 'startDateIso'),
                strList(payload, 'quoteIds')
            );
            result.summary = 'Term applied to all options.';
        } else if (op == 'applybillingall') {
            String oppId = firstNonBlank(
                request.opportunityId,
                str(payload, 'opportunityId')
            );
            result.option = RLM_BambooSuitePlace.applyBillingToAllOptions(
                oppId,
                firstNonBlank(request.quoteId, str(payload, 'selectedQuoteId')),
                str(payload, 'billingFrequency'),
                intMap(payload, 'termMonthsByQuoteId'),
                strMap(payload, 'startDateByQuoteId'),
                strList(payload, 'quoteIds')
            );
            result.summary = 'Billing applied to all options.';
        } else if (op == 'addlinesbysku') {
            result.addResult = RLM_BambooSuitePlace.addProductLinesBySku(
                reqQuote(request, payload),
                strList(payload, 'skus'),
                decList(payload, 'quantities'),
                intVal(payload, 'termMonths'),
                str(payload, 'startDateIso'),
                str(payload, 'billingFrequency')
            );
            if (result.addResult != null) {
                result.option = result.addResult.option;
            }
            result.summary = 'Products added.';
        } else if (op == 'addworkforcepackage') {
            result.addResult = RLM_BambooSuitePlace.addWorkforcePackage(
                reqQuote(request, payload),
                str(payload, 'planSku'),
                dec(payload, 'quantity'),
                intVal(payload, 'termMonths'),
                str(payload, 'startDateIso'),
                str(payload, 'billingFrequency')
            );
            if (result.addResult != null) {
                result.option = result.addResult.option;
            }
            result.summary = 'Workforce package added.';
        } else {
            throw new RLM_BambooRevenueSuite.SuiteException(
                'Unknown commercial operation: ' + request.operation
            );
        }
        return result;
    }

    private static String reqQuote(OperationRequest request, Map<String, Object> payload) {
        String q = firstNonBlank(request.quoteId, str(payload, 'quoteId'));
        if (String.isBlank(q)) {
            throw new RLM_BambooRevenueSuite.SuiteException('quoteId is required.');
        }
        return q;
    }

    private static String firstNonBlank(String a, String b) {
        return String.isNotBlank(a) ? a : b;
    }

    private static String str(Map<String, Object> payload, String key) {
        if (payload == null || !payload.containsKey(key) || payload.get(key) == null) {
            return null;
        }
        return String.valueOf(payload.get(key));
    }

    private static Decimal dec(Map<String, Object> payload, String key) {
        String raw = str(payload, key);
        if (String.isBlank(raw)) {
            return null;
        }
        return Decimal.valueOf(raw);
    }

    private static Integer intVal(Map<String, Object> payload, String key) {
        String raw = str(payload, key);
        if (String.isBlank(raw)) {
            return null;
        }
        return Integer.valueOf(raw);
    }

    /** Parse the LWC's coalesced [{ lineId, quantity, discountPercent }] batch. */
    private static List<RLM_BambooSuitePlace.LineEditInput> lineEdits(
        Map<String, Object> payload,
        String key
    ) {
        List<RLM_BambooSuitePlace.LineEditInput> out =
            new List<RLM_BambooSuitePlace.LineEditInput>();
        if (payload == null || !payload.containsKey(key) || payload.get(key) == null) {
            return out;
        }
        Object raw = payload.get(key);
        if (!(raw instanceof List<Object>)) {
            return out;
        }
        for (Object row : (List<Object>) raw) {
            if (!(row instanceof Map<String, Object>)) {
                continue;
            }
            Map<String, Object> fields = (Map<String, Object>) row;
            RLM_BambooSuitePlace.LineEditInput edit =
                new RLM_BambooSuitePlace.LineEditInput();
            edit.lineId = str(fields, 'lineId');
            edit.quantity = dec(fields, 'quantity');
            edit.discountPercent = dec(fields, 'discountPercent');
            out.add(edit);
        }
        return out;
    }

    private static List<String> strList(Map<String, Object> payload, String key) {
        List<String> out = new List<String>();
        if (payload == null || !payload.containsKey(key) || payload.get(key) == null) {
            return out;
        }
        Object raw = payload.get(key);
        if (raw instanceof List<Object>) {
            for (Object o : (List<Object>) raw) {
                if (o != null) {
                    out.add(String.valueOf(o));
                }
            }
        }
        return out;
    }

    private static List<Decimal> decList(Map<String, Object> payload, String key) {
        List<Decimal> out = new List<Decimal>();
        if (payload == null || !payload.containsKey(key) || payload.get(key) == null) {
            return out;
        }
        Object raw = payload.get(key);
        if (raw instanceof List<Object>) {
            for (Object o : (List<Object>) raw) {
                if (o == null) {
                    out.add(null);
                } else {
                    out.add(Decimal.valueOf(String.valueOf(o)));
                }
            }
        }
        return out;
    }

    private static Map<String, Integer> intMap(Map<String, Object> payload, String key) {
        Map<String, Integer> out = new Map<String, Integer>();
        if (payload == null || !payload.containsKey(key) || payload.get(key) == null) {
            return out;
        }
        Object raw = payload.get(key);
        if (raw instanceof Map<String, Object>) {
            for (String k : ((Map<String, Object>) raw).keySet()) {
                Object v = ((Map<String, Object>) raw).get(k);
                if (v != null) {
                    out.put(k, Integer.valueOf(String.valueOf(v)));
                }
            }
        }
        return out;
    }

    private static Map<String, String> strMap(Map<String, Object> payload, String key) {
        Map<String, String> out = new Map<String, String>();
        if (payload == null || !payload.containsKey(key) || payload.get(key) == null) {
            return out;
        }
        Object raw = payload.get(key);
        if (raw instanceof Map<String, Object>) {
            for (String k : ((Map<String, Object>) raw).keySet()) {
                Object v = ((Map<String, Object>) raw).get(k);
                if (v != null) {
                    out.put(k, String.valueOf(v));
                }
            }
        }
        return out;
    }
}
