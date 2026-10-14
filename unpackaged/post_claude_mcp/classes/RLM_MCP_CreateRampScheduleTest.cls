@IsTest
private class RLM_MCP_CreateRampScheduleTest {
    @TestSetup
    static void setup() {
        Id pbId = Test.getStandardPricebookId();
        update new Pricebook2(Id = pbId, IsActive = true);
        Account account = new Account(Name = 'MCP Create Ramp Acme');
        insert account;
        Opportunity opp = new Opportunity(
            Name = 'MCP Create Ramp Opp',
            AccountId = account.Id,
            StageName = 'Proposal/Quote',
            CloseDate = Date.today().addDays(30)
        );
        insert opp;
        insert new Quote(
            Name = 'MCP Create Ramp Quote',
            OpportunityId = opp.Id,
            Pricebook2Id = pbId,
            Status = 'Draft',
            StartDate = Date.newInstance(2026, 10, 15)
        );
    }

    private static RLM_MCP_CreateRampSchedule.CreateOutput run(
        RLM_MCP_CreateRampSchedule.CreateInput input
    ) {
        return RLM_MCP_CreateRampSchedule.createSchedule(
            new List<RLM_MCP_CreateRampSchedule.CreateInput>{ input }
        )[0];
    }

    @IsTest
    static void requiresQuoteId() {
        RLM_MCP_CreateRampSchedule.CreateOutput out =
            run(new RLM_MCP_CreateRampSchedule.CreateInput());
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('Quote Id'), '' + out.errorMessage);
    }

    @IsTest
    static void screenshotFixtureGeneratesTrialYearsAndProratedEnd() {
        RLM_MCP_CreateRampSchedule.GenerateResult generated =
            RLM_MCP_CreateRampSchedule.generate(
                Date.newInstance(2026, 10, 15),
                40,
                'Annual',
                'End',
                true,
                30,
                'Days',
                null,
                100,
                '3 Year Ramp Schedule'
            );
        System.assert(String.isBlank(generated.errorMessage), 'generate failed');
        System.assertEquals(5, generated.segments.size());
        System.assertEquals('Trial', generated.segments[0].name);
        System.assertEquals(Date.newInstance(2026, 10, 15), generated.segments[0].startDate);
        System.assertEquals(Date.newInstance(2026, 11, 13), generated.segments[0].endDate);
        System.assertEquals('FreeTrial', generated.segments[0].segmentType);
        System.assertEquals(100, generated.segments[0].discount);
        System.assertEquals('Year 1', generated.segments[1].name);
        System.assertEquals(Date.newInstance(2026, 11, 14), generated.segments[1].startDate);
        System.assertEquals(Date.newInstance(2027, 11, 13), generated.segments[1].endDate);
        System.assertEquals('Yearly', generated.segments[1].segmentType);
        System.assertEquals('Year 2', generated.segments[2].name);
        System.assertEquals(Date.newInstance(2027, 11, 14), generated.segments[2].startDate);
        System.assertEquals(Date.newInstance(2028, 11, 13), generated.segments[2].endDate);
        System.assertEquals('Year 3', generated.segments[3].name);
        System.assertEquals(Date.newInstance(2028, 11, 14), generated.segments[3].startDate);
        System.assertEquals(Date.newInstance(2029, 11, 13), generated.segments[3].endDate);
        System.assertEquals('Year 4 - Pro-rated', generated.segments[4].name);
        System.assertEquals(Date.newInstance(2029, 11, 14), generated.segments[4].startDate);
        System.assertEquals(Date.newInstance(2030, 3, 13), generated.segments[4].endDate);
        System.assertEquals('Prorated', generated.segments[4].segmentType);
        System.assertEquals(4, generated.segments[4].lengthValue);
        for (Integer i = 1; i < generated.segments.size(); i++) {
            System.assertEquals(
                generated.segments[i - 1].endDate.addDays(1),
                generated.segments[i].startDate
            );
        }
    }

    @IsTest
    static void previewDoesNotWriteGroups() {
        Id quoteId = [SELECT Id FROM Quote WHERE Name = 'MCP Create Ramp Quote'].Id;
        RLM_MCP_CreateRampSchedule.CreateInput input =
            new RLM_MCP_CreateRampSchedule.CreateInput();
        input.quoteId = String.valueOf(quoteId);
        input.durationMonths = 40;
        input.segmentType = 'Annual';
        input.prorationPosition = 'End';
        input.trial = true;
        input.trialDuration = 30;
        input.trialUnit = 'Days';
        input.startDate = '2026-10-15';
        Test.startTest();
        RLM_MCP_CreateRampSchedule.CreateOutput out = run(input);
        Test.stopTest();
        System.assertEquals(true, out.isSuccess, '' + out.errorMessage);
        System.assertEquals(true, out.needsAction);
        System.assert(out.resultsDisplay.contains('Year 4 - Pro-rated'), out.resultsDisplay);
        System.assert(out.promptDisplay.contains('Create this ramp schedule'), out.promptDisplay);
        System.assertEquals(
            0,
            [SELECT COUNT() FROM QuoteLineGroup WHERE QuoteId = :quoteId]
        );
    }

    @IsTest
    static void confirmPersistsEmptySchedule() {
        Id quoteId = [SELECT Id FROM Quote WHERE Name = 'MCP Create Ramp Quote'].Id;
        RLM_MCP_CreateRampSchedule.CreateInput input =
            new RLM_MCP_CreateRampSchedule.CreateInput();
        input.quoteId = String.valueOf(quoteId);
        input.durationMonths = 40;
        input.segmentType = 'Annual';
        input.prorationPosition = 'End';
        input.trial = true;
        input.trialDuration = 30;
        input.trialUnit = 'Days';
        input.startDate = '2026-10-15';
        input.confirm = true;
        Test.startTest();
        RLM_MCP_CreateRampSchedule.CreateOutput out = run(input);
        Test.stopTest();
        System.assertEquals(true, out.isSuccess, '' + out.errorMessage);
        System.assertEquals(false, out.needsAction);
        System.assertEquals(5, out.segmentCount);
        System.assertEquals(
            1,
            [SELECT COUNT() FROM QuoteLineGroup
             WHERE QuoteId = :quoteId AND Type = 'RampScheduleGroup']
        );
        System.assertEquals(
            5,
            [SELECT COUNT() FROM QuoteLineGroup
             WHERE QuoteId = :quoteId AND IsRamped = true AND Type != 'RampScheduleGroup']
        );
        System.assertEquals(
            0,
            [SELECT COUNT() FROM QuoteLineItem WHERE QuoteId = :quoteId]
        );
    }

    @IsTest
    static void refusesExistingSchedule() {
        Id quoteId = [SELECT Id FROM Quote WHERE Name = 'MCP Create Ramp Quote'].Id;
        insert new QuoteLineGroup(
            QuoteId = quoteId,
            Name = 'Existing',
            Type = 'RampScheduleGroup'
        );
        RLM_MCP_CreateRampSchedule.CreateInput input =
            new RLM_MCP_CreateRampSchedule.CreateInput();
        input.quoteId = String.valueOf(quoteId);
        input.durationMonths = 36;
        input.confirm = true;
        Test.startTest();
        RLM_MCP_CreateRampSchedule.CreateOutput out = run(input);
        Test.stopTest();
        System.assertEquals(false, out.isSuccess);
        System.assert(out.errorMessage.contains('already has a ramp schedule'), out.errorMessage);
    }

    @IsTest
    static void annualShorterThanTwelveFails() {
        RLM_MCP_CreateRampSchedule.GenerateResult generated =
            RLM_MCP_CreateRampSchedule.generate(
                Date.today(), 6, 'Annual', 'End', false, null, null, null, null, null
            );
        System.assert(generated.errorMessage.contains('12 months'), generated.errorMessage);
    }
}
