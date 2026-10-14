/**
 * After a follow-up email: compare Gmail/Outlook From to Contacts on the
 * Account and return an AE picker. Chat only. Does not insert Contact.
 */
global with sharing class RLM_MCP_CheckSenderContact {
    global class CheckInput {
        @InvocableVariable(
            required=true
            label='Account Name'
            description='Existing account from the quote, e.g. Bryce Majors Incorporated.'
        )
        global String accountName;

        @InvocableVariable(
            required=true
            label='From Email'
            description='Mailbox From address on the Gmail/Outlook thread. Never invent. Never take it from the body.'
        )
        global String fromEmail;

        @InvocableVariable(
            label='From Name'
            description='From display name, e.g. Bryce Majors. Used only to match an existing Contact.'
        )
        global String fromName;
    }

    global class CheckOutput {
        @InvocableVariable(label='Is Success')
        global Boolean isSuccess;
        @InvocableVariable(
            label='Needs Action'
            description='True when the AE must pick add / setEmail / skip. Wait. Do not add a Contact until they pick.'
        )
        global Boolean needsAction;
        @InvocableVariable(
            label='Prompt Display'
            description='AE note. Render in Claude chat. If needsAction, this picker is the Next line. Never Gmail.'
        )
        global String promptDisplay;
        @InvocableVariable(label='From Email')
        global String fromEmail;
        @InvocableVariable(label='Matched Contact Id')
        global String matchedContactId;
        @InvocableVariable(label='Account Url')
        global String accountUrl;
        @InvocableVariable(label='Error Message')
        global String errorMessage;
    }

    @InvocableMethod(
        label='Check Revenue Cloud Sender Contact'
        description='Required after a follow-up customer email. Pass Gmail From mailbox + accountName. Returns an AE picker when that address is not a Contact on the account. Never invent email. Do not skip. Never Gmail this note.'
    )
    global static List<CheckOutput> checkSender(List<CheckInput> inputs) {
        List<CheckOutput> results = new List<CheckOutput>();
        if (inputs == null || inputs.isEmpty()) {
            return results;
        }
        for (CheckInput input : inputs) {
            results.add(checkOne(input));
        }
        return results;
    }

    /**
     * Used by update/add so the sender picker is in the same recap Claude
     * already renders. fromEmail = Gmail From. Blank fromEmail still warns
     * that Quote.Contact is not the sender.
     */
    public static CheckOutput forQuote(Id quoteId, String fromEmail, String fromName) {
        CheckOutput out = new CheckOutput();
        out.isSuccess = false;
        out.needsAction = false;
        if (quoteId == null) {
            out.errorMessage = 'Quote Id is required.';
            return out;
        }
        List<Quote> quotes = [
            SELECT Id, AccountId, Account.Name, ContactId,
                Contact.FirstName, Contact.LastName, Contact.Email
            FROM Quote
            WHERE Id = :quoteId
            WITH USER_MODE
            LIMIT 1
        ];
        if (quotes.isEmpty() || quotes[0].AccountId == null) {
            out.errorMessage = 'Quote or account was not found.';
            return out;
        }
        Quote quote = quotes[0];
        String email = blankToNull(fromEmail);
        if (email == null) {
            return omittedFrom(quote);
        }
        CheckInput input = new CheckInput();
        input.accountName = quote.Account.Name;
        input.fromEmail = email;
        input.fromName = fromName;
        return checkOne(input);
    }

    public static String append(String display, CheckOutput check) {
        if (check == null || String.isBlank(check.promptDisplay)) {
            return display;
        }
        if (String.isBlank(display)) {
            return check.promptDisplay;
        }
        return display + '\n\n' + check.promptDisplay;
    }

    private static CheckOutput omittedFrom(Quote quote) {
        CheckOutput out = new CheckOutput();
        out.isSuccess = true;
        out.needsAction = true;
        String quoteContact = quote.ContactId == null
            ? 'not set'
            : displayName(quote.Contact.FirstName, quote.Contact.LastName);
        List<Contact> contacts = [
            SELECT FirstName, LastName, Email
            FROM Contact
            WHERE AccountId = :quote.AccountId
            WITH USER_MODE
            ORDER BY LastName, FirstName
            LIMIT 5
        ];
        List<String> names = new List<String>();
        for (Contact contact : contacts) {
            names.add(displayName(contact.FirstName, contact.LastName));
        }
        String roster = names.isEmpty() ? 'none' : String.join(names, ', ');
        out.promptDisplay = String.join(
            new List<String>{
                'AE note (chat only, never the customer email): Quote Contact is **'
                    + quoteContact
                    + '**. Contacts on '
                    + quote.Account.Name
                    + ': **'
                    + roster
                    + '**. That is not who sent a customer email unless Gmail From matches.',
                'If you just read Gmail/Outlook, you omitted fromEmail. Call this tool again (or checkRevenueCloudSenderContact) with fromEmail = the From mailbox and fromName = the From display. Do not assume '
                    + quoteContact
                    + ' sent it. Do not go to ramp or submit yet.',
                'Ask the rep:',
                '1. Add the email sender (I have the From address — calling again with fromEmail)',
                '2. Sender is already the quote Contact',
                '3. Skip',
                'Which option? Click a suggestion or reply with a number.'
            },
            '\n'
        );
        return out;
    }

    private static CheckOutput checkOne(CheckInput input) {
        CheckOutput out = new CheckOutput();
        out.isSuccess = false;
        out.needsAction = false;
        if (input == null || String.isBlank(input.accountName)) {
            out.errorMessage = 'Account name is required.';
            return out;
        }
        String email = blankToNull(input.fromEmail);
        if (email == null) {
            out.errorMessage =
                'From email is required. Use the Gmail/Outlook From mailbox. Do not invent one from the body.';
            return out;
        }
        out.fromEmail = email;
        List<Account> accounts = [
            SELECT Id, Name
            FROM Account
            WHERE Name = :input.accountName.trim()
            WITH USER_MODE
            LIMIT 2
        ];
        if (accounts.isEmpty()) {
            String fuzzy = '%' + input.accountName.trim() + '%';
            accounts = [
                SELECT Id, Name
                FROM Account
                WHERE Name LIKE :fuzzy
                WITH USER_MODE
                ORDER BY Name
                LIMIT 2
            ];
        }
        if (accounts.size() != 1) {
            out.errorMessage = accounts.isEmpty()
                ? 'No account matched "' + input.accountName + '".'
                : 'Multiple accounts match "' + input.accountName + '". Ask which one.';
            return out;
        }
        Account account = accounts[0];
        out.accountUrl = RLM_MCP_RecordLinks.lightningUrl('Account', account.Id);
        List<Contact> byEmail = [
            SELECT Id, FirstName, LastName, Email
            FROM Contact
            WHERE AccountId = :account.Id
            AND Email = :email
            WITH USER_MODE
            LIMIT 1
        ];
        out.isSuccess = true;
        if (!byEmail.isEmpty()) {
            out.matchedContactId = String.valueOf(byEmail[0].Id);
            out.promptDisplay =
                'From **'
                + email
                + '** is already **'
                + displayName(byEmail[0].FirstName, byEmail[0].LastName)
                + '** on '
                + account.Name
                + '.';
            return out;
        }
        String firstName = firstNameOf(input.fromName);
        String lastName = lastNameOf(input.fromName);
        List<Contact> byName = findByName(account.Id, firstName, lastName);
        String who = String.isBlank(input.fromName)
            ? email
            : input.fromName.trim();
        out.needsAction = true;
        List<String> lines = new List<String>{
            'AE note (chat only, never the customer email): This email is from **'
            + who
            + '** <'
            + email
            + '>. That From address is not a Contact on '
            + account.Name
            + '.',
            'Ask the rep (do not add a Contact yet):'
        };
        if (byName.size() == 1) {
            Contact named = byName[0];
            String current = String.isBlank(named.Email) ? 'no email' : named.Email;
            lines.add(
                displayName(named.FirstName, named.LastName)
                + ' on this Account currently has '
                + current
                + '.'
            );
            lines.add('1. Set this From address on ' + displayName(named.FirstName, named.LastName));
            lines.add('2. Add as a new Contact');
            lines.add('3. Skip');
        } else {
            lines.add('1. Add ' + who + ' as a Contact (email = From)');
            lines.add('2. Skip');
        }
        lines.add('Which option? Click a suggestion or reply with a number.');
        out.promptDisplay = String.join(lines, '\n');
        return out;
    }

    private static List<Contact> findByName(Id accountId, String firstName, String lastName) {
        if (lastName == null && firstName == null) {
            return new List<Contact>();
        }
        if (lastName != null && firstName != null) {
            return [
                SELECT Id, FirstName, LastName, Email
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
            SELECT Id, FirstName, LastName, Email
            FROM Contact
            WHERE AccountId = :accountId
            AND LastName = :wanted
            WITH USER_MODE
            LIMIT 5
        ];
    }

    private static String firstNameOf(String fromName) {
        String trimmed = blankToNull(fromName);
        if (trimmed == null || !trimmed.contains(' ')) {
            return null;
        }
        return trimmed.substringBefore(' ').trim();
    }

    private static String lastNameOf(String fromName) {
        String trimmed = blankToNull(fromName);
        if (trimmed == null) {
            return null;
        }
        if (!trimmed.contains(' ')) {
            return trimmed;
        }
        return trimmed.substringAfterLast(' ').trim();
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
