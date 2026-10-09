/**
 * Hosted MCP: create or reuse an Account and Contact for a prospect who
 * is not yet in Salesforce, then Create Quote can run.
 */
global with sharing class RLM_MCP_CreateProspect {
    global class ProspectInput {
        @InvocableVariable(
            required=true
            label='Account Name'
            description='Company name from the email or user, e.g. Northwind.'
        )
        global String accountName;

        @InvocableVariable(
            label='Contact First Name'
            description='Sender first name. Optional if last name or email is set.'
        )
        global String contactFirstName;

        @InvocableVariable(
            label='Contact Last Name'
            description='Sender last name. Defaults from email local-part when blank.'
        )
        global String contactLastName;

        @InvocableVariable(
            label='Contact Email'
            description='Sender email from Gmail/Outlook. Used to reuse an existing Contact.'
        )
        global String contactEmail;

        @InvocableVariable(label='Phone')
        global String phone;

        @InvocableVariable(label='Website')
        global String website;

        @InvocableVariable(
            label='Billing Street'
            description='Optional billing street. Needed so activate can stamp the order.'
        )
        global String billingStreet;

        @InvocableVariable(label='Billing City')
        global String billingCity;

        @InvocableVariable(label='Billing State')
        global String billingState;

        @InvocableVariable(label='Billing Postal Code')
        global String billingPostalCode;

        @InvocableVariable(label='Billing Country')
        global String billingCountry;

        @InvocableVariable(
            label='Use Demo Address'
            description='True only after the user confirms a demo billing address. Do not invent a customer HQ.'
        )
        global Boolean useDemoAddress;
    }

    global class ProspectOutput {
        @InvocableVariable(label='Is Success')
        global Boolean isSuccess;
        @InvocableVariable(label='Account Created')
        global Boolean accountCreated;
        @InvocableVariable(label='Contact Created')
        global Boolean contactCreated;
        @InvocableVariable(label='Account Id')
        global String accountId;
        @InvocableVariable(label='Account Name')
        global String accountName;
        @InvocableVariable(label='Account Url')
        global String accountUrl;
        @InvocableVariable(label='Contact Id')
        global String contactId;
        @InvocableVariable(label='Contact Url')
        global String contactUrl;
        @InvocableVariable(label='Results Display')
        global String resultsDisplay;
        @InvocableVariable(label='Needs Disambiguation')
        global Boolean needsDisambiguation;
        @InvocableVariable(label='Candidate Summaries Display')
        global String candidateSummariesDisplay;
        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    @InvocableMethod(
        label='Create Revenue Cloud Prospect'
        description='Creates or reuses an Account and Contact for a prospect not in Salesforce. Confirm with the user first. Then call createRevenueCloudQuote. Never SObject-insert Account.'
    )
    global static List<ProspectOutput> createProspect(List<ProspectInput> inputs) {
        List<ProspectOutput> results = new List<ProspectOutput>();
        if (inputs == null || inputs.isEmpty()) {
            return results;
        }
        for (ProspectInput input : inputs) {
            results.add(createOne(input));
        }
        return results;
    }

    private static ProspectOutput createOne(ProspectInput input) {
        ProspectOutput out = new ProspectOutput();
        out.isSuccess = false;
        out.accountCreated = false;
        out.contactCreated = false;
        out.needsDisambiguation = false;
        try {
            if (input == null || String.isBlank(input.accountName)) {
                out.errorMessage = 'Account name is required.';
                return out;
            }
            String company = input.accountName.trim();
            Account account = findExactAccount(company);
            if (account == null) {
                List<Account> fuzzy = findFuzzyAccounts(company);
                if (fuzzy.size() > 1) {
                    out.needsDisambiguation = true;
                    out.candidateSummariesDisplay = accountChoices(company, fuzzy);
                    out.errorMessage = 'Multiple accounts match "' + company
                        + '". Ask the user which one, or confirm creating a new account.';
                    return out;
                }
                if (fuzzy.size() == 1) {
                    out.needsDisambiguation = true;
                    out.candidateSummariesDisplay =
                        'Found existing account "' + fuzzy[0].Name
                        + '". Reuse it, or confirm creating "' + company + '" as new?';
                    out.errorMessage = 'An existing account is similar. Ask the user before creating.';
                    return out;
                }
                account = new Account(Name = company);
                if (String.isNotBlank(input.website)) {
                    account.Website = input.website.trim();
                }
                if (String.isNotBlank(input.phone)) {
                    account.Phone = input.phone.trim();
                }
                applyAddress(account, input);
                insert as user account;
                out.accountCreated = true;
            } else {
                Account patch = applyAddress(account, input);
                if (patch != null) {
                    update as user patch;
                    account = [
                        SELECT Id, Name, BillingStreet
                        FROM Account
                        WHERE Id = :account.Id
                        WITH USER_MODE
                        LIMIT 1
                    ];
                }
            }

            out.accountId = account.Id;
            out.accountName = account.Name;
            out.accountUrl = RLM_MCP_RecordLinks.lightningUrl('Account', account.Id);

            Contact contact = resolveContact(account, input, out);
            if (String.isNotBlank(out.errorMessage) && out.isSuccess != true) {
                return out;
            }

            out.isSuccess = true;
            List<String> rows = new List<String>();
            rows.add(out.accountCreated
                ? 'Created account ' + account.Name + '.'
                : 'Reused account ' + account.Name + '.');
            if (contact != null) {
                String who = contactLabel(contact);
                rows.add(out.contactCreated
                    ? 'Created contact ' + who + '.'
                    : 'Reused contact ' + who + '.');
                String cLink = RLM_MCP_RecordLinks.markdown('Open Contact', 'Contact', contact.Id);
                if (String.isNotBlank(cLink)) {
                    rows.add(cLink);
                }
            }
            String aLink = RLM_MCP_RecordLinks.markdown('Open Account', 'Account', account.Id);
            if (String.isNotBlank(aLink)) {
                rows.add(aLink);
            }
            if (String.isNotBlank(account.BillingStreet)) {
                rows.add('Billing address is set so order activate can stamp Bill-to.');
            }
            rows.add('Next: createRevenueCloudQuote with this accountName.');
            out.resultsDisplay = String.join(rows, '\n');
        } catch (Exception e) {
            out.isSuccess = false;
            String caused = e.getMessage();
            out.errorMessage = String.isBlank(caused) ? 'Could not create prospect.' : caused;
        }
        return out;
    }

    private static final String DEMO_STREET = '415 Mission St';
    private static final String DEMO_CITY = 'San Francisco';
    private static final String DEMO_STATE = 'CA';
    private static final String DEMO_POSTAL = '94105';
    private static final String DEMO_COUNTRY = 'United States';

    private static Account findExactAccount(String name) {
        List<Account> matches = [
            SELECT Id, Name, BillingStreet, BillingCity, BillingState,
                   BillingPostalCode, BillingCountry
            FROM Account
            WHERE Name = :name
            WITH USER_MODE
            LIMIT 2
        ];
        return matches.isEmpty() ? null : matches[0];
    }

    private static List<Account> findFuzzyAccounts(String name) {
        String fuzzy = '%' + name + '%';
        return [
            SELECT Id, Name
            FROM Account
            WHERE Name LIKE :fuzzy
            WITH USER_MODE
            ORDER BY Name
            LIMIT 10
        ];
    }

    private static String accountChoices(String term, List<Account> accounts) {
        List<String> rows = new List<String>{
            'Multiple accounts match "' + term + '". Which one?'
        };
        Integer n = 1;
        for (Account account : accounts) {
            rows.add(String.valueOf(n) + '. ' + account.Name);
            n++;
        }
        rows.add(String.valueOf(n) + '. Create new account "' + term + '"');
        return String.join(rows, '\n');
    }

    private static Contact resolveContact(
        Account account,
        ProspectInput input,
        ProspectOutput out
    ) {
        String email = blankToNull(input.contactEmail);
        String lastName = blankToNull(input.contactLastName);
        String firstName = blankToNull(input.contactFirstName);
        if (email == null && lastName == null && firstName == null) {
            return null;
        }
        if (email != null) {
            List<Contact> byEmail = [
                SELECT Id, FirstName, LastName, Email, AccountId
                FROM Contact
                WHERE Email = :email
                WITH USER_MODE
                LIMIT 2
            ];
            if (byEmail.size() > 1) {
                out.needsDisambiguation = true;
                out.errorMessage = 'That email matches more than one contact. Ask the user which one.';
                return null;
            }
            if (byEmail.size() == 1) {
                Contact existing = byEmail[0];
                if (existing.AccountId != account.Id) {
                    out.needsDisambiguation = true;
                    out.errorMessage = 'That email is already on another account. Ask the user which account to use.';
                    return null;
                }
                out.contactId = existing.Id;
                out.contactUrl = RLM_MCP_RecordLinks.lightningUrl('Contact', existing.Id);
                return existing;
            }
        }
        if (lastName == null) {
            lastName = lastNameFromEmail(email);
        }
        if (lastName == null) {
            lastName = firstName;
            firstName = null;
        }
        if (lastName == null) {
            out.errorMessage = 'Contact needs a last name or email.';
            return null;
        }
        Contact contact = new Contact(
            AccountId = account.Id,
            FirstName = firstName,
            LastName = lastName,
            Email = email,
            Phone = blankToNull(input.phone)
        );
        insert as user contact;
        out.contactCreated = true;
        out.contactId = contact.Id;
        out.contactUrl = RLM_MCP_RecordLinks.lightningUrl('Contact', contact.Id);
        return contact;
    }

    private static String lastNameFromEmail(String email) {
        if (String.isBlank(email) || !email.contains('@')) {
            return null;
        }
        String local = email.substringBefore('@').trim();
        return String.isBlank(local) ? null : local;
    }

    private static String contactLabel(Contact contact) {
        List<String> parts = new List<String>();
        if (String.isNotBlank(contact.FirstName)) {
            parts.add(contact.FirstName);
        }
        if (String.isNotBlank(contact.LastName)) {
            parts.add(contact.LastName);
        }
        String name = parts.isEmpty() ? 'Contact' : String.join(parts, ' ');
        if (String.isNotBlank(contact.Email)) {
            name += ' (' + contact.Email + ')';
        }
        return name;
    }

    private static String blankToNull(String value) {
        return String.isBlank(value) ? null : value.trim();
    }

    private static Account applyAddress(Account account, ProspectInput input) {
        if (account == null) {
            return null;
        }
        String street = blankToNull(input.billingStreet);
        String city = blankToNull(input.billingCity);
        String state = blankToNull(input.billingState);
        String postal = blankToNull(input.billingPostalCode);
        String country = blankToNull(input.billingCountry);
        if (street == null && input.useDemoAddress == true) {
            street = DEMO_STREET;
            if (city == null) {
                city = DEMO_CITY;
            }
            if (state == null) {
                state = DEMO_STATE;
            }
            if (postal == null) {
                postal = DEMO_POSTAL;
            }
            if (country == null) {
                country = DEMO_COUNTRY;
            }
        }
        if (street == null) {
            return account.Id == null ? account : null;
        }
        if (account.Id != null && String.isNotBlank(account.BillingStreet)) {
            return null;
        }
        account.BillingStreet = street;
        account.BillingCity = city;
        account.BillingState = state;
        account.BillingPostalCode = postal;
        account.BillingCountry = country;
        account.ShippingStreet = street;
        account.ShippingCity = city;
        account.ShippingState = state;
        account.ShippingPostalCode = postal;
        account.ShippingCountry = country;
        return account;
    }
}
