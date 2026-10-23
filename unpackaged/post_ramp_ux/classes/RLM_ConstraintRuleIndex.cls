/**
 * Server2 CML run-time messages used by Slackbot constraint cards.
 * Regenerated from datasets/constraints/qb/Server2/blobs/ESDV_Server2_V1.ffxblob:
 *   python scripts/cml/extract_constraint_rules.py
 */
public with sharing class RLM_ConstraintRuleIndex {

    public class Rule {
        public String kind;
        public String ruleText;
        public List<String> attributes;
        public List<String> relations;
        public List<String> types;
        public String match;
        public List<String> flips;
        public String violating;
    }

    public class IndexPayload {
        public String model;
        public String source;
        public List<Rule> rules;
    }

    // BEGIN RULES_JSON
    @TestVisible
    static final String RULES_JSON =
        '{"model":"Server2","source":"datasets/constraints/qb/Server2/blobs/ESDV_Server2_V1.ffxblob","rules":[{"kind":"constraint","ruleText":"RDIMM does not support 128GB modules. Pick 8, 16, 32, or 64GB RAM,' +
        ' or switch DIMM Type to LRDIMM.","attributes":["DIMMType","RDIMMs"],"relations":["ram128"],"types":["RAM128"],"match":null,"flips":["dimmLrdimm"],"violating":null},{"kind":"constraint","ruleText":"LRD' +
        'IMM only works with 128GB RAM. Remove 8, 16, 32, or 64GB modules, or switch DIMM Type to RDIMM.","attributes":["DIMMType","LRDIMMs"],"relations":["ram16","ram32","ram64","ram8"],"types":["RAM16","RAM3' +
        '2","RAM64","RAM8"],"match":null,"flips":["dimmRdimm"],"violating":null},{"kind":"constraint","ruleText":"Requires a quantity of 2,4,6,or 8 for 8GB RAM.","attributes":[],"relations":["ram8"],"types":["' +
        'RAM8"],"match":null,"flips":[],"violating":null},{"kind":"constraint","ruleText":"Dual sockets need Workload AI or High Performance Computing. General workload needs a single socket.","attributes":["W' +
        'orkload","SocketConfiguration"],"relations":[],"types":[],"match":"dualWorkload","flips":["workloadAiHpc","workloadGeneral","socketSingle","socketDual"],"violating":"Socket and Workload must stay pair' +
        'ed (Dual with AI/HPC, Single with General)."},{"kind":"constraint","ruleText":"Dual cannot use a Gold CPU. Pick a Platinum, or switch Socket to Single.","attributes":["SocketConfiguration"],"relations' +
        '":["gold21ghz","gold22ghz","gold3ghz"],"types":["Gold_21Ghz_24C48T","Gold_22Ghz_28C56T","Gold_3Ghz_18C36T"],"match":"dualGold","flips":["platinum","socketSingle"],"violating":"Dual requires Gold quant' +
        'ity 0."},{"kind":"constraint","ruleText":"Front Storage and Rear Storage do not match. Pick a listed pair, such as 12x3.5 inch Drives with Rear N/A.","attributes":["FrontStorage","RearStorage"],"relat' +
        'ions":[],"types":[],"match":null,"flips":[],"violating":null},{"kind":"constraint","ruleText":"12x3.5 inch front bays with no rear storage cannot take 2.5 inch drives. Remove those drives, or add Rear' +
        ' Storage.","attributes":["FrontStorage","RearStorage"],"relations":[],"types":["HDD1_Small","HDD3_Small"],"match":null,"flips":[],"violating":null},{"kind":"constraint","ruleText":"2.5 inch front bays' +
        ' cannot take 3.5 inch drives. Remove those drives, or set Front Storage to 12x3.5 inch Drives.","attributes":["FrontStorage"],"relations":[],"types":["HDD1_Big","HDD20_Big","HDD4_Big","HDD8_Big"],"mat' +
        'ch":null,"flips":["frontStorage35"],"violating":null},{"kind":"constraint","ruleText":"High Availability cannot use a single PSU. Pick a dual PowerSafe supply, or set Redundancy to Basic Uptime.","att' +
        'ributes":["Redundancy"],"relations":["pwr1600s","pwr500s","pwr800s"],"types":["QBPowerCore1600S","QBPowerCore500S","QBPowerCore800S"],"match":null,"flips":["redundancyBasic"],"violating":null},{"kind"' +
        ':"require","ruleText":"Dual needs two liquid coolers. Add them, or set Socket back to Single.","attributes":["Workload","SocketConfiguration"],"relations":["liquidcooler"],"types":["LiquidCooler"],"ma' +
        'tch":"dualLiquid","flips":["socketSingle","liquidQty2"],"violating":"Dual requires two liquid coolers."},{"kind":"require","ruleText":"RAID needs a RAID 500 card. Add it, or set RAID to N/A.","attribu' +
        'tes":["RAID"],"relations":["raid500"],"types":["RAID500"],"match":"raidCard","flips":["raidNa","raidCard"],"violating":"RAID requires a RAID 500 card."},{"kind":"message","ruleText":"Do not edit x16 L' +
        'anes. Dual with this Performance Tier adds a GPU. Set Performance Tier to Entry, or set Socket to Single.","attributes":["SocketConfiguration","Workload","PerformanceTier"],"relations":[],"types":[],"' +
        'match":"x16Lanes","flips":["socketSingle","tierEntry"],"violating":"Dual with this Performance Tier adds a GPU; x16 Lanes is read-only."},{"kind":"message","ruleText":"Too many drives for this bay. 12' +
        'x3.5 inch front holds 12 large drives; add Rear Storage or lower the quantity.","attributes":["FrontStorage"],"relations":[],"types":[],"match":null,"flips":[],"violating":null},{"kind":"message","rul' +
        'eText":"Add Rear Storage for additional 2.5 inch drive space","attributes":["FrontStorage","RearStorage"],"relations":[],"types":[],"match":null,"flips":[],"violating":null},{"kind":"message","ruleTex' +
        't":"Too many drives for the selected Front and Rear Storage. Lower the HDD quantity to fit the bay.","attributes":["FrontStorage","RearStorage"],"relations":[],"types":[],"match":null,"flips":[],"viol' +
        'ating":null},{"kind":"message","ruleText":"A maximum of 6 SSD\'s are supported with the Q-Rack 750","attributes":[],"relations":[],"types":[],"match":null,"flips":[],"violating":null},{"kind":"message' +
        '","ruleText":"Out of PCIe Slots. There are only 6 slots available.","attributes":["AvailablePCIeSlots"],"relations":[],"types":[],"match":null,"flips":[],"violating":null}]}';
    // END RULES_JSON

    static List<Rule> cached;

    public static List<Rule> rules() {
        if (cached == null) {
            IndexPayload payload = (IndexPayload) JSON.deserialize(
                RULES_JSON, IndexPayload.class);
            cached = payload == null || payload.rules == null
                ? new List<Rule>()
                : payload.rules;
        }
        return cached;
    }

    @TestVisible
    static void resetCache() {
        cached = null;
    }

    public static Rule byMatch(String matchKey) {
        if (String.isBlank(matchKey)) {
            return null;
        }
        for (Rule rule : rules()) {
            if (rule != null && matchKey.equals(rule.match)) {
                return rule;
            }
        }
        return null;
    }

    public static Rule matchText(String text) {
        if (String.isBlank(text)) {
            return null;
        }
        String stripped = text.trim();
        if (stripped.toLowerCase().startsWith('constraint:')) {
            stripped = stripped.substring(11).trim();
        }
        for (Rule rule : rules()) {
            if (rule != null && String.isNotBlank(rule.ruleText)
                && rule.ruleText.equalsIgnoreCase(stripped)) {
                return rule;
            }
        }
        if (stripped.containsIgnoreCase('Gold CPU')
            || stripped.containsIgnoreCase('only available for Platinum')) {
            return byMatch('dualGold');
        }
        if (stripped.containsIgnoreCase('Dual sockets need Workload')) {
            return byMatch('dualWorkload');
        }
        if (stripped.containsIgnoreCase('two liquid coolers')) {
            return byMatch('dualLiquid');
        }
        if (stripped.containsIgnoreCase('x16 Lanes')
            || stripped.containsIgnoreCase('x16Lanes')) {
            return byMatch('x16Lanes');
        }
        if (stripped.containsIgnoreCase('RAID 500')
            || stripped.containsIgnoreCase('RAID needs a RAID')) {
            return byMatch('raidCard');
        }
        for (Rule rule : rules()) {
            if (rule == null || String.isBlank(rule.ruleText)) {
                continue;
            }
            if (stripped.containsIgnoreCase(rule.ruleText)
                || rule.ruleText.containsIgnoreCase(stripped)) {
                return rule;
            }
        }
        return null;
    }
}
