/**
 * After an AE confirm: add a Contact on an existing Account from the
 * Gmail/Outlook From address, or set that address on a name-matched Contact.
 * Never creates an Account. Optional quoteId stamps Quote.ContactId.
 */
global with sharing class RLM_MCP_AddAccountContact {
    global class AddInput {
        @InvocableVariable(
            required=true
            label='Account Name'
            description='Existing account, e.g. Bryce Majors Incorporated. Do not create a new Account.'
        )
        global String accountName;

        @InvocableVariable(
            required=true
            label='Contact Email'
            description='Mailbox From address. Never invent. Never take a guessed address from the body.'
        )
        global String contactEmail;

        @InvocableVariable(label='Contact First Name')
        global String contactFirstName;

        @InvocableVariable(label='Contact Last Name')
        global String contactLastName;

        @InvocableVariable(
            label='Title'
            description='Job title from the email signature or body only. Omit if not present. Never invent.'
        )
        global String title;

        @InvocableVariable(
            label='Phone'
            description='Phone from the email signature or body only. Omit if not present. Never invent.'
        )
        global String phone;

        @InvocableVariable(
            label='Mailing Street'
            description='Street from the email signature or body only. Omit if not present. Never invent.'
        )
        global String mailingStreet;

        @InvocableVariable(label='Mailing City')
        global String mailingCity;

        @InvocableVariable(label='Mailing State')
        global String mailingState;

        @InvocableVariable(label='Mailing Postal Code')
        global String mailingPostalCode;

        @InvocableVariable(label='Mailing Country')
        global String mailingCountry;

        @InvocableVariable(
            label='Action'
            description='add (default) or setEmail. setEmail writes From onto a name-matched Contact. Skip is chat-only — do not call this tool.'
        )
        global String action;

        @InvocableVariable(
            label='Quote Id'
            description='Optional Draft to stamp ContactId so Bill-to and the customer pack use this person.'
        )
        global String quoteId;
    }

    global class AddOutput {
        @InvocableVariable(label='Is Success')
        global Boolean isSuccess;
        @InvocableVariable(label='Contact Created')
        global Boolean contactCreated;
        @InvocableVariable(label='Email Updated')
        global Boolean emailUpdated;
        @InvocableVariable(label='Contact Id')
        global String contactId;
        @InvocableVariable(label='Contact Url')
        global String contactUrl;
        @InvocableVariable(label='Account Url')
        global String accountUrl;
        @InvocableVariable(label='Quote Url')
        global String quoteUrl;
        @InvocableVariable(label='Results Display')
        global String resultsDisplay;
        @InvocableVariable(label='Needs Disambiguation')
        global Boolean needsDisambiguation;
        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    @InvocableMethod(
        label='Add Revenue Cloud Account Contact'
        description='Adds a Contact on an existing Account from the mail From address. Pass title, phone, and mailing address from the email signature when present. Never invent. Confirm first. Never creates an Account. Optional quoteId stamps Quote.ContactId.'
    )
    global static List<AddOutput> addContact(List<AddInput> inputs) {
        List<AddOutput> results = new List<AddOutput>();
        if (inputs == null || inputs.isEmpty()) {
            return results;
        }
        for (AddInput input : inputs) {
            results.add(addOne(input));
        }
        return results;
    }

    private static AddOutput addOne(AddInput input) {
        AddOutput out = new AddOutput();
        out.isSuccess = false;
        out.contactCreated = false;
        out.emailUpdated = false;
        out.needsDisambiguation = false;
        if (input == null || String.isBlank(input.accountName)) {
            out.errorMessage = 'Account name is required.';
            return out;
        }
        String email = blankToNull(input.contactEmail);
        if (email == null) {
            out.errorMessage =
                'Contact email is required. Use the Gmail/Outlook From address. Do not invent one.';
            return out;
        }
        String action = String.isBlank(input.action) ? 'add' : input.action.trim().toLowerCase();
        if (action != 'add' && action != 'setemail') {
            out.errorMessage = 'action must be add or setEmail.';
            return out;
        }
        Account account = findAccount(input.accountName.trim(), out);
        if (account == null) {
            return out;
        }
        out.accountUrl = RLM_MCP_RecordLinks.lightningUrl('Account', account.Id);
        Contact contact;
        try {
            contact = applyContact(account, input, email, action, out);
        } catch (Exception e) {
            out.errorMessage = String.isBlank(e.getMessage())
                ? 'Could not add the contact.'
                : e.getMessage();
            return out;
        }
        if (contact == null) {
            return out;
        }
        out.contactId = String.valueOf(contact.Id);
        out.contactUrl = RLM_MCP_RecordLinks.lightningUrl('Contact', contact.Id);
        Id quoteId = stampQuote(input.quoteId, account.Id, contact.Id, out);
        out.isSuccess = true;
        List<String> rows = new List<String>();
        if (out.contactCreated == true) {
            rows.add('Added **' + contactLabel(contact) + '** on ' + account.Name + '.');
        } else if (out.emailUpdated == true) {
            rows.add(
                'Set email on **'
                + contactLabel(contact)
                + '** at '
                + account.Name
                + ' to '
                + email
                + '.'
            );
        } else {
            rows.add('Reused **' + contactLabel(contact) + '** on ' + account.Name + '.');
        }
        if (out.contactCreated == true || out.emailUpdated == true) {
            String extras = gleanedRecap(contact);
            if (String.isNotBlank(extras)) {
                rows.add(extras);
            }
        }
        String cLink = RLM_MCP_RecordLinks.markdown('Open Contact', 'Contact', contact.Id);
        if (String.isNotBlank(cLink)) {
            rows.add(cLink);
        }
        String aLink = RLM_MCP_RecordLinks.markdown('Open Account', 'Account', account.Id);
        if (String.isNotBlank(aLink)) {
            rows.add(aLink);
        }
        if (quoteId != null) {
            String qLink = RLM_MCP_RecordLinks.markdown('Open Quote', 'Quote', quoteId);
            if (String.isNotBlank(qLink)) {
                rows.add(qLink);
            }
        }
        rows.add('Do not create another quote. Do not create another Account.');
        out.resultsDisplay = String.join(rows, '\n');
        return out;
    }

    private static Account findAccount(String name, AddOutput out) {
        List<Account> exact = [
            SELECT Id, Name
            FROM Account
            WHERE Name = :name
            WITH USER_MODE
            LIMIT 2
        ];
        if (exact.size() == 1) {
            return exact[0];
        }
        if (exact.size() > 1) {
            out.needsDisambiguation = true;
            out.errorMessage = 'Multiple accounts named "' + name + '". Ask which one.';
            return null;
        }
        String fuzzy = '%' + name + '%';
        List<Account> likes = [
            SELECT Id, Name
            FROM Account
            WHERE Name LIKE :fuzzy
            WITH USER_MODE
            ORDER BY Name
            LIMIT 10
        ];
        if (likes.size() == 1) {
            return likes[0];
        }
        if (likes.size() > 1) {
            out.needsDisambiguation = true;
            List<String> rows = new List<String>{
                'Multiple accounts match "' + name + '". Which one?'
            };
            Integer n = 1;
            for (Account account : likes) {
                rows.add(String.valueOf(n) + '. ' + account.Name);
                n++;
            }
            out.errorMessage = String.join(rows, '\n');
            return null;
        }
        out.errorMessage =
            'No account matched "'
            + name
            + '". Do not create one here. If this is a new company, use createRevenueCloudQuote.';
        return null;
    }

    private static Contact applyContact(
        Account account,
        AddInput input,
        String email,
        String action,
        AddOutput out
    ) {
        List<Contact> byEmail = [
            SELECT Id, FirstName, LastName, Email, AccountId, Title, Phone,
                MailingStreet, MailingCity, MailingState, MailingPostalCode,
                MailingCountry
            FROM Contact
            WHERE Email = :email
            WITH USER_MODE
            LIMIT 2
        ];
        if (byEmail.size() > 1) {
            out.needsDisambiguation = true;
            out.errorMessage = 'That From address matches more than one Contact. Ask which one.';
            return null;
        }
        if (byEmail.size() == 1) {
            if (byEmail[0].AccountId != account.Id) {
                out.needsDisambiguation = true;
                out.errorMessage =
                    'That From address is already on another account. Ask which account to use.';
                return null;
            }
            return byEmail[0];
        }
        String firstName = blankToNull(input.contactFirstName);
        String lastName = blankToNull(input.contactLastName);
        List<Contact> byName = findByName(account.Id, firstName, lastName);
        if (action == 'setemail') {
            if (byName.isEmpty()) {
                out.errorMessage =
                    'No Contact named '
                    + displayName(firstName, lastName)
                    + ' on this account. Pick Add Contact, or skip.';
                return null;
            }
            if (byName.size() > 1) {
                out.needsDisambiguation = true;
                out.errorMessage =
                    'More than one Contact matches that name. Ask which one to set the email on.';
                return null;
            }
            return setEmail(byName[0], email, input, out);
        }
        if (!byName.isEmpty()) {
            if (byName.size() > 1) {
                out.needsDisambiguation = true;
                out.errorMessage =
                    'More than one Contact matches that name. Ask which one, or skip.';
                return null;
            }
            Contact named = byName[0];
            if (String.isBlank(named.Email)) {
                return setEmail(named, email, input, out);
            }
            if (!email.equalsIgnoreCase(named.Email)) {
                out.needsDisambiguation = true;
                out.errorMessage =
                    displayName(named.FirstName, named.LastName)
                    + ' already has '
                    + named.Email
                    + '. Pick setEmail to replace it, add as a new Contact only if this is a different person, or skip.';
                return null;
            }
            return named;
        }
        if (lastName == null) {
            lastName = lastNameFromEmail(email);
        }
        if (lastName == null) {
            lastName = firstName;
            firstName = null;
        }
        if (lastName == null) {
            out.errorMessage = 'Contact needs a last name or the From address.';
            return null;
        }
        Contact created = new Contact(
            AccountId = account.Id,
            FirstName = firstName,
            LastName = lastName,
            Email = email
        );
        applyGleaned(created, input, false);
        insert as user created;
        out.contactCreated = true;
        return created;
    }

    private static List<Contact> findByName(Id accountId, String firstName, String lastName) {
        if (lastName == null && firstName == null) {
            return new List<Contact>();
        }
        if (lastName != null && firstName != null) {
            return [
                SELECT Id, FirstName, LastName, Email, AccountId, Title, Phone,
                    MailingStreet, MailingCity, MailingState, MailingPostalCode,
                    MailingCountry
                FROM Contact
                WHERE AccountId = :accountId
                AND FirstName = :firstName
                AND LastName = :lastName
                WITH USER_MODE
                LIMIT 5
            ];
        }
        String wanted = lastName != null ? lastName : firstName;
        return [
            SELECT Id, FirstName, LastName, Email, AccountId, Title, Phone,
                MailingStreet, MailingCity, MailingState, MailingPostalCode,
                MailingCountry
            FROM Contact
            WHERE AccountId = :accountId
            AND LastName = :wanted
            WITH USER_MODE
            LIMIT 5
        ];
    }

    private static Contact setEmail(
        Contact contact,
        String email,
        AddInput input,
        AddOutput out
    ) {
        contact.Email = email;
        applyGleaned(contact, input, true);
        update as user contact;
        out.emailUpdated = true;
        return contact;
    }

    private static void applyGleaned(Contact contact, AddInput input, Boolean blanksOnly) {
        if (contact == null || input == null) {
            return;
        }
        String title = blankToNull(input.title);
        if (title != null && (!blanksOnly || String.isBlank(contact.Title))) {
            contact.Title = title;
        }
        String phone = blankToNull(input.phone);
        if (phone != null && (!blanksOnly || String.isBlank(contact.Phone))) {
            contact.Phone = phone;
        }
        String street = blankToNull(input.mailingStreet);
        if (street != null && (!blanksOnly || String.isBlank(contact.MailingStreet))) {
            contact.MailingStreet = street;
        }
        String city = blankToNull(input.mailingCity);
        if (city != null && (!blanksOnly || String.isBlank(contact.MailingCity))) {
            contact.MailingCity = city;
        }
        String state = blankToNull(input.mailingState);
        if (state != null && (!blanksOnly || String.isBlank(contact.MailingState))) {
            contact.MailingState = state;
        }
        String postal = blankToNull(input.mailingPostalCode);
        if (postal != null && (!blanksOnly || String.isBlank(contact.MailingPostalCode))) {
            contact.MailingPostalCode = postal;
        }
        String country = blankToNull(input.mailingCountry);
        if (country != null && (!blanksOnly || String.isBlank(contact.MailingCountry))) {
            contact.MailingCountry = country;
        }
    }

    private static Id stampQuote(String quoteIdStr, Id accountId, Id contactId, AddOutput out) {
        if (String.isBlank(quoteIdStr) || contactId == null) {
            return null;
        }
        Id quoteId = RLM_MCP_RecordLinks.toId(quoteIdStr);
        if (quoteId == null) {
            return null;
        }
        List<Quote> quotes = [
            SELECT Id, AccountId
            FROM Quote
            WHERE Id = :quoteId
            WITH USER_MODE
            LIMIT 1
        ];
        if (quotes.isEmpty() || quotes[0].AccountId != accountId) {
            return null;
        }
        Quote patch = new Quote(Id = quoteId, ContactId = contactId);
        update as user patch;
        out.quoteUrl = RLM_MCP_RecordLinks.lightningUrl('Quote', quoteId);
        return quoteId;
    }

    private static String lastNameFromEmail(String email) {
        if (String.isBlank(email) || !email.contains('@')) {
            return null;
        }
        String local = email.substringBefore('@').trim();
        return String.isBlank(local) ? null : local;
    }

    private static String gleanedRecap(Contact contact) {
        if (contact == null) {
            return null;
        }
        List<String> bits = new List<String>();
        if (String.isNotBlank(contact.Title)) {
            bits.add(contact.Title);
        }
        if (String.isNotBlank(contact.Phone)) {
            bits.add(contact.Phone);
        }
        List<String> addr = new List<String>();
        if (String.isNotBlank(contact.MailingStreet)) {
            addr.add(contact.MailingStreet);
        }
        if (String.isNotBlank(contact.MailingCity)) {
            addr.add(contact.MailingCity);
        }
        if (String.isNotBlank(contact.MailingState)) {
            addr.add(contact.MailingState);
        }
        if (String.isNotBlank(contact.MailingPostalCode)) {
            addr.add(contact.MailingPostalCode);
        }
        if (String.isNotBlank(contact.MailingCountry)) {
            addr.add(contact.MailingCountry);
        }
        if (!addr.isEmpty()) {
            bits.add(String.join(addr, ', '));
        }
        return bits.isEmpty() ? null : 'From the email: ' + String.join(bits, ' · ');
    }

    private static String contactLabel(Contact contact) {
        String name = displayName(contact.FirstName, contact.LastName);
        if (String.isNotBlank(contact.Email)) {
            name += ' (' + contact.Email + ')';
        }
        return name;
    }

    private static String displayName(String firstName, String lastName) {
        List<String> parts = new List<String>();
        if (String.isNotBlank(firstName)) {
            parts.add(firstName);
        }
        if (String.isNotBlank(lastName)) {
            parts.add(lastName);
        }
        return parts.isEmpty() ? 'Contact' : String.join(parts, ' ');
    }

    private static String blankToNull(String value) {
        return String.isBlank(value) ? null : value.trim();
    }
}
