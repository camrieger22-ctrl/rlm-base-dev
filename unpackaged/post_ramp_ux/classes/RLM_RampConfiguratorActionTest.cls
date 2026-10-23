@IsTest
private class RLM_RampConfiguratorActionTest {

    @IsTest
    static void loadRejectsBlankQuote() {
        RLM_RampConfiguratorAction.ConfigResult r =
            RLM_RampConfiguratorAction.loadConfiguration('not-an-id', null);
        System.assertEquals(false, r.success);
        System.assert(r.message.contains('Quote Id'), r.message);
    }

    @IsTest
    static void loadRejectsBlankLine() {
        Account a = new Account(Name = 'Ramp Cfg Acct');
        insert a;
        Opportunity o = new Opportunity(
            Name = 'Ramp Cfg Opp', AccountId = a.Id, StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30));
        insert o;
        Quote q = new Quote(Name = 'Ramp Cfg Quote', OpportunityId = o.Id, Status = 'Draft');
        insert q;
        RLM_RampConfiguratorAction.ConfigResult r =
            RLM_RampConfiguratorAction.loadConfiguration(q.Id, 'not-an-id');
        System.assertEquals(false, r.success);
        System.assert(r.message.contains('Quote line'), r.message);
    }

    @IsTest
    static void saveRejectsBlankSelection() {
        Account a = new Account(Name = 'Ramp Cfg Acct 2');
        insert a;
        Opportunity o = new Opportunity(
            Name = 'Ramp Cfg Opp 2', AccountId = a.Id, StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30));
        insert o;
        Quote q = new Quote(Name = 'Ramp Cfg Quote 2', OpportunityId = o.Id, Status = 'Draft');
        insert q;
        Product2 p = new Product2(Name = 'Bundle', IsActive = true);
        insert p;
        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = Test.getStandardPricebookId(),
            Product2Id = p.Id, UnitPrice = 10, IsActive = true);
        insert pbe;
        q.Pricebook2Id = Test.getStandardPricebookId();
        update q;
        QuoteLineItem qli = new QuoteLineItem(
            QuoteId = q.Id, PricebookEntryId = pbe.Id, Product2Id = p.Id,
            Quantity = 1, UnitPrice = 10);
        insert qli;

        RLM_RampConfiguratorAction.ConfigResult r =
            RLM_RampConfiguratorAction.saveConfiguration(q.Id, qli.Id, '');
        System.assertEquals(false, r.success);
        System.assert(r.message.contains('selection'), r.message);
    }

    @IsTest
    static void parseGroupsReadsRadioAndDefaults() {
        Map<String, Object> catalog = sampleCatalog();
        List<RLM_RampConfiguratorAction.ConfigGroup> groups =
            RLM_RampConfiguratorAction.parseGroups(catalog, new Map<String, QuoteLineItem>(), false);
        System.assertEquals(2, groups.size());
        System.assertEquals('Software', groups[0].name);
        System.assertEquals('multiple', groups[0].selectionMode);
        System.assertEquals(true, groups[0].components[0].selected);
        System.assertEquals(100, groups[0].components[0].quantity);
        System.assertEquals('Maintenance & Support', groups[1].name);
        System.assertEquals('single', groups[1].selectionMode);
        System.assertEquals('Pick 1', groups[1].rangeLabel);
    }

    @IsTest
    static void parseGroupsSelectsExistingChildren() {
        Map<String, Object> catalog = sampleCatalog();
        QuoteLineItem child = new QuoteLineItem();
        child.Quantity = 3;
        Map<String, QuoteLineItem> children = new Map<String, QuoteLineItem>{
            '01t000000000001AAA' => child
        };
        List<RLM_RampConfiguratorAction.ConfigGroup> groups =
            RLM_RampConfiguratorAction.parseGroups(catalog, children, true);
        System.assertEquals(true, groups[0].components[0].selected);
        System.assertEquals(3, groups[0].components[0].quantity);
        System.assertEquals(false, groups[0].components[1].selected);
    }

    @IsTest
    static void parseAttributesAndMessages() {
        Map<String, Object> catalog = sampleCatalog();
        Map<String, RLM_RampConfiguratorAction.ConfigAttribute> values =
            new Map<String, RLM_RampConfiguratorAction.ConfigAttribute>();
        RLM_RampConfiguratorAction.ConfigAttribute current =
            new RLM_RampConfiguratorAction.ConfigAttribute();
        current.value = 'Redhat Enterprise Linux';
        values.put('Operating_System', current);
        List<RLM_RampConfiguratorAction.ConfigAttribute> attrs =
            RLM_RampConfiguratorAction.parseAttributes(catalog, values);
        System.assertEquals(1, attrs.size());
        System.assertEquals('Operating System', attrs[0].label);
        System.assertEquals('0tj000000000001AAA', attrs[0].attributeKey);
        System.assertEquals('Redhat Enterprise Linux', attrs[0].value);
        System.assertEquals(true, attrs[0].priceImpacting);
        System.assertEquals(2, attrs[0].options.size());

        Map<String, Object> response = new Map<String, Object>{
            'messages' => new Map<String, Object>{
                '0QL000000000001AAA' => new List<Object>{
                    new Map<String, Object>{
                        'category' => 'bundlevalidation',
                        'messageType' => 'warning',
                        'message' => 'Pick 1 consumption product.'
                    }
                }
            }
        };
        List<RLM_RampConfiguratorAction.ConfigMessage> msgs =
            RLM_RampConfiguratorAction.parseMessages(response.get('messages'));
        System.assertEquals(1, msgs.size());
        System.assertEquals('warning', msgs[0].messageType);
        System.assert(msgs[0].text.contains('consumption'), msgs[0].text);

        List<RLM_RampConfiguratorAction.ConfigMessage> listed =
            RLM_RampConfiguratorAction.parseMessages(new List<Object>{
                new Map<String, Object>{
                    'severity' => 'Error',
                    'text' => 'Dual CPUs are only available for Platinum CPUs.'
                }
            });
        System.assertEquals(1, listed.size());
        System.assertEquals('Error', listed[0].messageType);
        System.assert(listed[0].text.contains('Platinum'), listed[0].text);
    }

    @IsTest
    static void parseSelectionAndBuildNodes() {
        String json = '{"components":[{"product2Id":"01t000000000002AAA","pricebookEntryId":'
            + '"01u000000000002AAA","productSellingModelId":"0jP000000000001AAA","unitPrice":45,'
            + '"quantity":2,"productRelatedComponentId":"0dS000000000001AAA",'
            + '"productRelationshipTypeId":"0yo000000000001AAA","includedInBundle":false}],'
            + '"attributes":[{"attributeKey":"0tj000000000001AAA","attributeName":"Operating_System",'
            + '"attributeRecordId":"0zu000000000001AAA","value":"Amazon Linux 2",'
            + '"picklistValueId":"0v6000000000001AAA"}]}';
        RLM_RampConfiguratorAction.Selection selection =
            RLM_RampConfiguratorAction.parseSelection(json);
        System.assertEquals(1, selection.components.size());
        System.assertEquals(2, selection.components[0].quantity);
        System.assertEquals(1, selection.attributes.size());

        Id quoteId = (Id) '0Q0000000000001AAA';
        Id parentId = (Id) '0QL000000000001AAA';
        List<Object> added = RLM_RampConfiguratorAction.buildAddedNodes(
            quoteId, parentId, selection.components, new Map<String, QuoteLineItem>());
        System.assertEquals(2, added.size());

        QuoteLineItem existing = new QuoteLineItem();
        existing.Quantity = 1;
        Map<String, QuoteLineItem> children = new Map<String, QuoteLineItem>{
            '01t000000000001AAA' => existing
        };
        List<Object> deleted = RLM_RampConfiguratorAction.buildDeletedNodes(
            quoteId, selection.components, children);
        System.assertEquals(1, deleted.size());

        List<Object> updated = RLM_RampConfiguratorAction.buildUpdatedNodes(
            quoteId, parentId, selection, new Map<String, QuoteLineItem>());
        System.assertEquals(1, updated.size());
        Map<String, Object> attrNode = (Map<String, Object>) updated[0];
        List<Object> attrPath = (List<Object>) attrNode.get('path');
        System.assertEquals(3, attrPath.size());
        System.assertEquals('0zu000000000001AAA', String.valueOf(attrPath[2]));
        Map<String, Object> attrFields = (Map<String, Object>) attrNode.get('updatedAttributes');
        System.assertEquals('Amazon Linux 2', attrFields.get('AttributeValue'));
        System.assertEquals('0v6000000000001AAA', attrFields.get('AttributePicklistValue'));
        System.assertEquals(
            0,
            RLM_RampConfiguratorAction.buildAddedAttributeNodes(quoteId, parentId, selection).size());

        selection.attributes[0].attributeRecordId = null;
        List<Object> addedAttrs =
            RLM_RampConfiguratorAction.buildAddedAttributeNodes(quoteId, parentId, selection);
        System.assertEquals(1, addedAttrs.size());
        Map<String, Object> addedAttr = (Map<String, Object>) ((Map<String, Object>) addedAttrs[0])
            .get('addedObject');
        System.assertEquals('QuoteLineItemAttribute', addedAttr.get('businessObjectType'));
        System.assertEquals('0tj000000000001AAA', addedAttr.get('AttributeKey'));
        System.assertEquals(null, RLM_RampConfiguratorAction.parseSelection(''));
        System.assertEquals('Pick 1', RLM_RampConfiguratorAction.rangeLabel(1, 1));
        System.assertEquals('Maintenance & Support', RLM_RampConfiguratorAction.decodeName('Maintenance &amp; Support'));
        System.assertEquals(null, RLM_RampConfiguratorAction.toId('abc'));
    }

    @IsTest
    static void parseGroupsFlattensChildGroups() {
        Map<String, Object> catalog = new Map<String, Object>{
            'id' => '01t000000000099AAA',
            'name' => 'Q-Rack',
            'productComponentGroups' => new List<Object>{
                new Map<String, Object>{
                    'id' => '0y7000000000PARAAA',
                    'name' => 'Computing',
                    'components' => new List<Object>(),
                    'childGroups' => new List<Object>{
                        new Map<String, Object>{
                            'id' => '0y7000000000CPUAAA',
                            'name' => 'Processor',
                            'minBundleComponents' => 1,
                            'maxBundleComponents' => 1,
                            'components' => new List<Object>{
                                new Map<String, Object>{
                                    'id' => '01t000000000PLTAAA',
                                    'name' => 'Intel Xeon Platinum 8352M',
                                    'productCode' => 'QB-CPU-P8352M',
                                    'productRelatedComponent' => new Map<String, Object>{
                                        'id' => '0dS000000000PLTAAA',
                                        'quantity' => 2
                                    }
                                }
                            }
                        }
                    }
                }
            }
        };
        List<RLM_RampConfiguratorAction.ConfigGroup> groups =
            RLM_RampConfiguratorAction.parseGroups(catalog, new Map<String, QuoteLineItem>(), false);
        System.assertEquals(1, groups.size());
        System.assertEquals('Processor', groups[0].name);
        System.assertEquals(1, groups[0].components.size());
        System.assertEquals('Intel Xeon Platinum 8352M', groups[0].components[0].name);
    }

    @IsTest
    static void parseConfigurationOverlaysCreQuantities() {
        Map<String, Object> response = new Map<String, Object>{
            'success' => true,
            'transactionContextId' => 'ctx-cre',
            'catalogProducts' => new List<Object>{ sampleCatalog() },
            'transactionContext' => new Map<String, Object>{
                'SalesTransaction' => new List<Object>{
                    new Map<String, Object>{
                        'SalesTransactionItem' => new List<Object>{
                            new Map<String, Object>{
                                'id' => '0QL000000000001AAA',
                                'Product' => '01t000000000099AAA',
                                'Quantity' => 1
                            },
                            new Map<String, Object>{
                                'id' => '0QL000000000CREAAA',
                                'Product' => '01t000000000001AAA',
                                'Quantity' => 2
                            }
                        }
                    }
                }
            },
            'messages' => new Map<String, Object>(),
            'errors' => new List<Object>()
        };
        RLM_RampConfiguratorAction.ConfigResult r =
            RLM_RampConfiguratorAction.parseConfiguration(
                response, (Id) '0Q0000000000001AAA', (Id) '0QL000000000001AAA',
                new Map<String, QuoteLineItem>());
        System.assertEquals(true, r.success);
        RLM_RampConfiguratorAction.ConfigComponent api = r.groups[0].components[0];
        System.assertEquals(true, api.selected);
        System.assertEquals(2, api.quantity);
        System.assertEquals(false, r.groups[0].components[1].selected);
    }

    @IsTest
    static void parseConfigurationSuccess() {
        Map<String, Object> response = new Map<String, Object>{
            'success' => true,
            'transactionContextId' => 'ctx-1',
            'catalogProducts' => new List<Object>{ sampleCatalog() },
            'messages' => new Map<String, Object>(),
            'errors' => new List<Object>()
        };
        RLM_RampConfiguratorAction.ConfigResult r =
            RLM_RampConfiguratorAction.parseConfiguration(
                response, (Id) '0Q0000000000001AAA', (Id) '0QL000000000001AAA',
                new Map<String, QuoteLineItem>());
        System.assertEquals(true, r.success);
        System.assertEquals(2, r.groups.size());
        System.assertEquals(1, r.attributes.size());
        System.assertEquals('0tj000000000001AAA', r.attributes[0].attributeKey);
        System.assertEquals(true, r.attributes[0].priceImpacting);
        System.assertEquals('ctx-1', r.transactionContextId);
    }

    @IsTest
    static void parseConfigurationKeepsCatalogOnFailure() {
        Map<String, Object> response = new Map<String, Object>{
            'success' => false,
            'catalogProducts' => new List<Object>{ sampleCatalog() },
            'messages' => new Map<String, Object>{
                '0QL000000000001AAA' => new List<Object>{
                    new Map<String, Object>{
                        'category' => 'bundlevalidation',
                        'messageType' => 'warning',
                        'message' => 'The number of child products selected in Consumption isn\'t in the specified range. Select child products in the range 1-1 and try again.'
                    }
                }
            },
            'errors' => new List<Object>{
                new Map<String, Object>{
                    'message' => 'The specified node path and attribute key Operating_System are invalid.'
                }
            }
        };
        RLM_RampConfiguratorAction.ConfigResult r =
            RLM_RampConfiguratorAction.parseConfiguration(
                response, (Id) '0Q0000000000001AAA', (Id) '0QL000000000001AAA',
                new Map<String, QuoteLineItem>());
        System.assertEquals(false, r.success);
        System.assert(r.message.contains('Operating_System'), r.message);
        System.assertEquals(2, r.groups.size());
        System.assertEquals(1, r.messages.size());
    }

    @IsTest
    static void applyConfigurationAttributesPostsUpdatedNodes() {
        QuoteLineItem qli = insertBundleLine();
        qli = [SELECT Id, QuoteId FROM QuoteLineItem WHERE Id = :qli.Id];
        CaptureMock mock = new CaptureMock(200, mockSuccessBody());
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        RLM_RampConfiguratorAction.ConfigResult r =
            RLM_RampConfiguratorAction.applyConfigurationAttributes(
                qli.QuoteId,
                qli.Id,
                new Map<String, String>{ 'Operating System' => 'Redhat Enterprise Linux' }
            );
        Test.stopTest();
        System.assertNotEquals(null, r, 'applyConfigurationAttributes returned null');
        System.assertEquals(true, r.success, r.message == null ? 'ok' : r.message);
        System.assert(mock.bodies.size() >= 2, 'load then attribute configure');
        String lastBody = mock.bodies[mock.bodies.size() - 1];
        System.assertNotEquals(null, lastBody, 'last configure body');
        System.assert(
            lastBody.contains('updatedNodes') || lastBody.contains('addedNodes'),
            lastBody
        );
    }

    @IsTest
    static void mcpDescribeReturnsLoadingThenCachedResult() {
        QuoteLineItem qli = insertBundleLine();
        qli = [SELECT Id, QuoteId FROM QuoteLineItem WHERE Id = :qli.Id];
        Test.setMock(HttpCalloutMock.class, new ConfigureMock(200, mockSuccessBody()));
        Test.startTest();
        RLM_RampConfiguratorAction.ConfigResult first =
            RLM_RampConfiguratorAction.loadConfigurationForMcp(qli.QuoteId, qli.Id);
        System.assertEquals(false, first.success);
        System.assertEquals(RLM_RampConfiguratorAction.CRE_LOADING, first.message);
        Test.stopTest();
        RLM_RampConfiguratorAction.ConfigResult second =
            RLM_RampConfiguratorAction.loadConfigurationForMcp(qli.QuoteId, qli.Id);
        System.assertNotEquals(null, second, 'cached CRE result missing');
        System.assertEquals(true, second.success, 'cached CRE load failed');
        System.assertNotEquals(null, second.groups, 'cached CRE groups missing');
    }

    @IsTest
    static void mcpApplyAttributesReturnsLoadingThenCachedResult() {
        QuoteLineItem qli = insertBundleLine();
        qli = [SELECT Id, QuoteId FROM QuoteLineItem WHERE Id = :qli.Id];
        RLM_RampConfiguratorAction.ConfigAttribute os =
            new RLM_RampConfiguratorAction.ConfigAttribute();
        os.label = 'Operating System';
        os.attributeName = 'Operating System';
        os.value = 'Windows';
        os.options = new List<RLM_RampConfiguratorAction.ConfigPicklistOption>();
        RLM_RampConfiguratorAction.ConfigPicklistOption windows =
            new RLM_RampConfiguratorAction.ConfigPicklistOption();
        windows.label = 'Windows';
        windows.value = 'Windows';
        windows.picklistValueId = '0v6000000000009AAA';
        RLM_RampConfiguratorAction.ConfigPicklistOption redhat =
            new RLM_RampConfiguratorAction.ConfigPicklistOption();
        redhat.label = 'Redhat Enterprise Linux';
        redhat.value = 'Redhat Enterprise Linux';
        redhat.picklistValueId = '0v6000000000002AAA';
        os.options.add(windows);
        os.options.add(redhat);
        RLM_RampConfiguratorAction.ConfigResult seed =
            new RLM_RampConfiguratorAction.ConfigResult();
        seed.success = true;
        seed.quoteLineItemId = String.valueOf(qli.Id);
        seed.groups = new List<RLM_RampConfiguratorAction.ConfigGroup>();
        seed.attributes = new List<RLM_RampConfiguratorAction.ConfigAttribute>{ os };
        insert new RLM_CreCalloutCache__c(
            Key__c = String.valueOf(qli.Id),
            Line_Id__c = String.valueOf(qli.Id),
            Quote_Id__c = String.valueOf(qli.QuoteId),
            Status__c = 'Success',
            Result_Json__c = JSON.serialize(seed)
        );
        Test.setMock(HttpCalloutMock.class, new ConfigureMock(200, mockSuccessBody()));
        Test.startTest();
        RLM_RampConfiguratorAction.ConfigResult first =
            RLM_RampConfiguratorAction.applyConfigurationAttributesForMcp(
                qli.QuoteId,
                qli.Id,
                new Map<String, String>{ 'Operating System' => 'Redhat Enterprise Linux' }
            );
        System.assertEquals(false, first.success);
        System.assertEquals(
            RLM_RampConfiguratorAction.CRE_LOADING,
            first.message,
            first.message == null ? 'blank apply message' : first.message
        );
        Test.stopTest();
        List<RLM_CreCalloutCache__c> rows = Database.queryWithBinds(
            'SELECT Status__c, Message__c FROM RLM_CreCalloutCache__c WHERE Line_Id__c = :lineKey',
            new Map<String, Object>{ 'lineKey' => String.valueOf(qli.Id) },
            AccessLevel.SYSTEM_MODE
        );
        System.assertEquals(1, rows.size(), 'apply should keep one cache row');
        System.assertEquals(
            'Success',
            rows[0].Status__c,
            rows[0].Message__c == null ? rows[0].Status__c : rows[0].Message__c
        );
    }

    @IsTest
    static void mcpFlagQueuesConfigureWithoutForceAsync() {
        QuoteLineItem qli = insertBundleLine();
        qli = [SELECT Id, QuoteId FROM QuoteLineItem WHERE Id = :qli.Id];
        RLM_RampConfiguratorAction.queueConfigureCallout = true;
        Test.setMock(HttpCalloutMock.class, new ConfigureMock(200, mockSuccessBody()));
        Test.startTest();
        RLM_RampConfiguratorAction.ConfigResult first =
            RLM_RampConfiguratorAction.loadConfiguration(qli.QuoteId, qli.Id);
        Test.stopTest();
        System.assertEquals(false, first.success);
        System.assertEquals(RLM_RampConfiguratorAction.CRE_LOADING, first.message);
        RLM_RampConfiguratorAction.queueConfigureCallout = true;
        RLM_RampConfiguratorAction.ConfigResult second =
            RLM_RampConfiguratorAction.loadConfiguration(qli.QuoteId, qli.Id);
        System.assertNotEquals(null, second, 'cached CRE result missing');
        System.assertEquals(true, second.success, 'cached CRE load failed');
        System.assertNotEquals(null, second.groups, 'cached CRE groups missing');
    }

    @IsTest
    static void asyncConfigureReturnsLoadingThenCachedResult() {
        QuoteLineItem qli = insertBundleLine();
        qli = [SELECT Id, QuoteId FROM QuoteLineItem WHERE Id = :qli.Id];
        RLM_RampConfiguratorAction.forceAsyncConfigure = true;
        Test.setMock(HttpCalloutMock.class, new ConfigureMock(200, mockSuccessBody()));
        Test.startTest();
        RLM_RampConfiguratorAction.ConfigResult first =
            RLM_RampConfiguratorAction.loadConfiguration(qli.QuoteId, qli.Id);
        System.assertEquals(false, first.success, String.valueOf(first.message));
        System.assertEquals(
            RLM_RampConfiguratorAction.CRE_LOADING,
            first.message,
            String.valueOf(first.message)
        );
        Test.stopTest();
        RLM_RampConfiguratorAction.forceAsyncConfigure = true;
        RLM_RampConfiguratorAction.ConfigResult second =
            RLM_RampConfiguratorAction.loadConfiguration(qli.QuoteId, qli.Id);
        System.assertNotEquals(null, second, 'cached CRE result missing');
        System.assertEquals(true, second.success, 'cached CRE load failed');
        System.assertNotEquals(null, second.groups, 'cached CRE groups missing');
        System.assert(second.groups.size() >= 1, 'cached CRE groups missing');
    }

    @IsTest
    static void enqueueFromEventLoadsConfigure() {
        QuoteLineItem qli = insertBundleLine();
        qli = [SELECT Id, QuoteId FROM QuoteLineItem WHERE Id = :qli.Id];
        Test.setMock(HttpCalloutMock.class, new ConfigureMock(200, mockSuccessBody()));
        Map<String, Object> body = new Map<String, Object>{
            'transactionId' => String.valueOf(qli.QuoteId),
            'transactionLineId' => String.valueOf(qli.Id)
        };
        String payload = JSON.serialize(body);
        Test.startTest();
        RLM_RampConfiguratorAction.enqueueFromEvent(new RLM_CreConfigureRequest__e(
            Cache_Key__c = 'evt:' + String.valueOf(qli.Id),
            Quote_Id__c = String.valueOf(qli.QuoteId),
            Line_Id__c = String.valueOf(qli.Id),
            Request_Json__c = payload,
            Session_Id__c = 'test-session'
        ));
        Test.stopTest();
        List<RLM_CreCalloutCache__c> rows = Database.queryWithBinds(
            'SELECT Status__c, Result_Json__c FROM RLM_CreCalloutCache__c '
                + 'WHERE Line_Id__c = :lineKey',
            new Map<String, Object>{ 'lineKey' => String.valueOf(qli.Id) },
            AccessLevel.SYSTEM_MODE
        );
        System.assertEquals(1, rows.size(), 'event should persist one cache row');
        System.assertEquals('Success', rows[0].Status__c, rows[0].Status__c);
        System.assertNotEquals(null, rows[0].Result_Json__c);
    }

    @IsTest
    static void enqueueFromCacheChangeLoadsConfigure() {
        QuoteLineItem qli = insertBundleLine();
        qli = [SELECT Id, QuoteId FROM QuoteLineItem WHERE Id = :qli.Id];
        Test.setMock(HttpCalloutMock.class, new ConfigureMock(200, mockSuccessBody()));
        RLM_CreCalloutCache__c row = new RLM_CreCalloutCache__c(
            Key__c = String.valueOf(qli.Id),
            Line_Id__c = String.valueOf(qli.Id),
            Quote_Id__c = String.valueOf(qli.QuoteId),
            Status__c = 'Pending'
        );
        insert row;
        RLM_RampEnqueueCreLoad.forceEnqueueInTest = true;
        RLM_RampEnqueueCreLoad.Request req = new RLM_RampEnqueueCreLoad.Request();
        req.cacheId = row.Id;
        req.quoteId = String.valueOf(qli.QuoteId);
        req.lineId = String.valueOf(qli.Id);
        Test.startTest();
        RLM_RampEnqueueCreLoad.enqueue(new List<RLM_RampEnqueueCreLoad.Request>{ req });
        Test.stopTest();
        List<RLM_CreCalloutCache__c> rows = Database.queryWithBinds(
            'SELECT Status__c, Result_Json__c FROM RLM_CreCalloutCache__c '
                + 'WHERE Line_Id__c = :lineKey',
            new Map<String, Object>{ 'lineKey' => String.valueOf(qli.Id) },
            AccessLevel.SYSTEM_MODE
        );
        System.assertEquals(1, rows.size(), 'cache change should persist one cache row');
        System.assertEquals('Success', rows[0].Status__c, rows[0].Status__c);
        System.assertNotEquals(null, rows[0].Result_Json__c);
    }

    @IsTest
    static void postConfigureUsesNamedCredentialOutsideLightning() {
        QuoteLineItem qli = insertBundleLine();
        qli = [SELECT Id, QuoteId FROM QuoteLineItem WHERE Id = :qli.Id];
        RetryMock mock = new RetryMock();
        Test.setMock(HttpCalloutMock.class, mock);
        Test.startTest();
        RLM_RampConfiguratorAction.ConfigResult r =
            RLM_RampConfiguratorAction.loadConfiguration(qli.QuoteId, qli.Id);
        Test.stopTest();
        System.assertNotEquals(null, r, 'loadConfiguration returned null');
        System.assertEquals(true, r.success, 'named credential configure failed');
        System.assertEquals(1, mock.endpoints.size(), 'invocable uses named credential only');
        System.assert(
            mock.endpoints[0].contains('callout:' + RLM_RampConfiguratorAction.LOOPBACK_NAMED_CREDENTIAL),
            mock.endpoints[0]
        );
        System.assertEquals(
            null,
            mock.authorizationHeaders[0],
            'NC configure must not send a stored session Bearer'
        );
    }

    @IsTest
    static void mcpLoadRetriesAfter401Cache() {
        QuoteLineItem qli = insertBundleLine();
        qli = [SELECT Id, QuoteId FROM QuoteLineItem WHERE Id = :qli.Id];
        insert new RLM_CreCalloutCache__c(
            Key__c = String.valueOf(qli.Id),
            Line_Id__c = String.valueOf(qli.Id),
            Quote_Id__c = String.valueOf(qli.QuoteId),
            Status__c = 'Error',
            Message__c = 'Configurator HTTP 401: Session expired or invalid'
        );
        Test.setMock(HttpCalloutMock.class, new ConfigureMock(200, mockSuccessBody()));
        Test.startTest();
        RLM_RampConfiguratorAction.ConfigResult first =
            RLM_RampConfiguratorAction.loadConfigurationForMcp(qli.QuoteId, qli.Id);
        System.assertEquals(false, first.success);
        System.assertEquals(RLM_RampConfiguratorAction.CRE_LOADING, first.message);
        Test.stopTest();
        List<RLM_CreCalloutCache__c> rows = Database.queryWithBinds(
            'SELECT Status__c, Message__c FROM RLM_CreCalloutCache__c WHERE Line_Id__c = :lineKey',
            new Map<String, Object>{ 'lineKey' => String.valueOf(qli.Id) },
            AccessLevel.SYSTEM_MODE
        );
        System.assertEquals(1, rows.size());
        System.assertEquals(
            'Success',
            rows[0].Status__c,
            rows[0].Message__c == null ? rows[0].Status__c : rows[0].Message__c
        );
    }

    @IsTest
    static void retryableAuthCacheErrorDoesNotStick() {
        RLM_CreCalloutCache__c row = new RLM_CreCalloutCache__c(
            Status__c = 'Error',
            Message__c = 'Configurator HTTP 401: Session expired or invalid'
        );
        System.assertEquals(true, RLM_RampConfiguratorAction.isRetryableCacheError(row));
        row.Message__c = 'Bundle product is invalid.';
        System.assertEquals(false, RLM_RampConfiguratorAction.isRetryableCacheError(row));
    }

    @IsTest
    static void attachFixGuidanceClassifiesRetryPlatformAndPicks() {
        RLM_RampConfiguratorAction.ConfigResult loading =
            new RLM_RampConfiguratorAction.ConfigResult();
        loading.success = false;
        loading.message = RLM_RampConfiguratorAction.CRE_LOADING;
        RLM_RampConfiguratorAction.attachFixGuidance(loading);
        System.assertEquals('retry', loading.fixKind);
        System.assert(loading.fixHeadline.contains('still running'), loading.fixHeadline);

        RLM_RampConfiguratorAction.ConfigResult auth =
            new RLM_RampConfiguratorAction.ConfigResult();
        auth.success = false;
        auth.message = 'Configurator HTTP 401: Session expired or invalid';
        RLM_RampConfiguratorAction.attachFixGuidance(auth);
        System.assertEquals('platform', auth.fixKind);
        System.assert(auth.fixHeadline.contains('not a rack-option'), auth.fixHeadline);
        System.assertEquals(false, String.join(auth.fixSteps, ' ').contains('Workload'));

        RLM_RampConfiguratorAction.ConfigAttribute workload =
            new RLM_RampConfiguratorAction.ConfigAttribute();
        workload.attributeName = 'Workload';
        workload.label = 'Workload';
        workload.options = new List<RLM_RampConfiguratorAction.ConfigPicklistOption>();
        RLM_RampConfiguratorAction.ConfigPicklistOption ai =
            new RLM_RampConfiguratorAction.ConfigPicklistOption();
        ai.label = 'AI';
        ai.value = 'AI';
        RLM_RampConfiguratorAction.ConfigPicklistOption general =
            new RLM_RampConfiguratorAction.ConfigPicklistOption();
        general.label = 'General';
        general.value = 'General';
        RLM_RampConfiguratorAction.ConfigPicklistOption hpc =
            new RLM_RampConfiguratorAction.ConfigPicklistOption();
        hpc.label = 'High Performance Computing';
        hpc.value = 'High Performance Computing';
        workload.options.add(ai);
        workload.options.add(general);
        workload.options.add(hpc);
        RLM_RampConfiguratorAction.ConfigResult invalid =
            new RLM_RampConfiguratorAction.ConfigResult();
        invalid.success = false;
        invalid.message = '"foo" is not a valid value for Workload.';
        invalid.attributes = new List<RLM_RampConfiguratorAction.ConfigAttribute>{ workload };
        RLM_RampConfiguratorAction.attachFixGuidance(invalid);
        System.assertEquals('change_picks', invalid.fixKind);
        System.assert(invalid.fixSteps[0].contains('Valid values: AI, General, High Performance Computing'),
            invalid.fixSteps[0]);

        RLM_RampConfiguratorAction.ConfigAttribute socket =
            new RLM_RampConfiguratorAction.ConfigAttribute();
        socket.attributeName = 'SocketConfiguration';
        socket.label = 'Socket';
        socket.value = 'Dual';
        RLM_RampConfiguratorAction.ConfigAttribute generalWorkload =
            new RLM_RampConfiguratorAction.ConfigAttribute();
        generalWorkload.attributeName = 'Workload';
        generalWorkload.label = 'Workload';
        generalWorkload.value = 'General';
        RLM_RampConfiguratorAction.ConfigResult coupled =
            new RLM_RampConfiguratorAction.ConfigResult();
        coupled.success = true;
        coupled.attributes = new List<RLM_RampConfiguratorAction.ConfigAttribute>{
            socket, generalWorkload
        };
        RLM_RampConfiguratorAction.attachFixGuidance(coupled);
        System.assertEquals('change_picks', coupled.fixKind);
        System.assert(coupled.fixSteps[0].contains('Dual sockets need Workload'), coupled.fixSteps[0]);

        RLM_RampConfiguratorAction.ConfigMessage gold =
            new RLM_RampConfiguratorAction.ConfigMessage();
        gold.messageType = 'constraint';
        gold.text = 'constraint: Dual CPUs are only available for Platinum CPUs.';
        RLM_RampConfiguratorAction.ConfigResult cre =
            new RLM_RampConfiguratorAction.ConfigResult();
        cre.success = false;
        cre.messages = new List<RLM_RampConfiguratorAction.ConfigMessage>{ gold };
        RLM_RampConfiguratorAction.attachFixGuidance(cre);
        System.assertEquals('change_picks', cre.fixKind);
        System.assertEquals(
            RLM_RampConfiguratorAction.DUAL_GOLD_FIX,
            cre.fixSteps[0]
        );
        System.assertEquals(false, cre.fixSteps[0].toLowerCase().startsWith('constraint:'));

        RLM_RampConfiguratorAction.ConfigAttribute dualSocket =
            new RLM_RampConfiguratorAction.ConfigAttribute();
        dualSocket.attributeName = 'SocketConfiguration';
        dualSocket.label = 'Socket';
        dualSocket.value = 'Dual';
        RLM_RampConfiguratorAction.ConfigAttribute dualHpc =
            new RLM_RampConfiguratorAction.ConfigAttribute();
        dualHpc.attributeName = 'Workload';
        dualHpc.label = 'Workload';
        dualHpc.value = 'High Performance Computing';
        RLM_RampConfiguratorAction.ConfigComponent leftoverGold =
            new RLM_RampConfiguratorAction.ConfigComponent();
        leftoverGold.name = 'Intel Xeon Gold 6330N 2.2GHz, 28C/56T';
        leftoverGold.sku = 'QB-INTEL-GOLD-6330N';
        leftoverGold.selected = true;
        leftoverGold.quantity = 1;
        RLM_RampConfiguratorAction.ConfigComponent platinumCpu =
            new RLM_RampConfiguratorAction.ConfigComponent();
        platinumCpu.name = 'Intel Xeon Platinum 8352M 2.3GHz, 32C/64T';
        platinumCpu.sku = 'QB-INTEL-PLAT-8352M';
        platinumCpu.selected = true;
        platinumCpu.quantity = 2;
        RLM_RampConfiguratorAction.ConfigGroup cpuGroup =
            new RLM_RampConfiguratorAction.ConfigGroup();
        cpuGroup.name = 'CPU';
        cpuGroup.components = new List<RLM_RampConfiguratorAction.ConfigComponent>{
            leftoverGold, platinumCpu
        };
        RLM_RampConfiguratorAction.ConfigResult goldLeft =
            new RLM_RampConfiguratorAction.ConfigResult();
        goldLeft.success = true;
        goldLeft.attributes = new List<RLM_RampConfiguratorAction.ConfigAttribute>{
            dualSocket, dualHpc
        };
        goldLeft.groups = new List<RLM_RampConfiguratorAction.ConfigGroup>{ cpuGroup };
        goldLeft.messages = new List<RLM_RampConfiguratorAction.ConfigMessage>();
        RLM_RampConfiguratorAction.attachFixGuidance(goldLeft);
        System.assertEquals('change_picks', goldLeft.fixKind);
        System.assertEquals(RLM_RampConfiguratorAction.DUAL_GOLD_FIX, goldLeft.fixSteps[0]);
        System.assertEquals(1, goldLeft.fixSteps.size());

        RLM_RampConfiguratorAction.ConfigAttribute singleSocket =
            new RLM_RampConfiguratorAction.ConfigAttribute();
        singleSocket.attributeName = 'SocketConfiguration';
        singleSocket.label = 'Socket';
        singleSocket.value = 'Single';
        RLM_RampConfiguratorAction.ConfigComponent leftoverGpu =
            new RLM_RampConfiguratorAction.ConfigComponent();
        leftoverGpu.name = 'QB-Accel NovaX150';
        leftoverGpu.sku = 'QB-NovaX150';
        leftoverGpu.selected = true;
        leftoverGpu.quantity = 1;
        RLM_RampConfiguratorAction.ConfigGroup gpuGroup =
            new RLM_RampConfiguratorAction.ConfigGroup();
        gpuGroup.name = 'GPU';
        gpuGroup.components = new List<RLM_RampConfiguratorAction.ConfigComponent>{ leftoverGpu };
        RLM_RampConfiguratorAction.ConfigMessage staleGold =
            new RLM_RampConfiguratorAction.ConfigMessage();
        staleGold.messageType = 'constraint';
        staleGold.text = 'Dual cannot use a Gold CPU. Pick a Platinum, or switch Socket to Single.';
        RLM_RampConfiguratorAction.ConfigResult singleLeft =
            new RLM_RampConfiguratorAction.ConfigResult();
        singleLeft.success = true;
        singleLeft.attributes = new List<RLM_RampConfiguratorAction.ConfigAttribute>{
            singleSocket, dualHpc
        };
        leftoverGold.selected = false;
        platinumCpu.quantity = 2;
        RLM_RampConfiguratorAction.ConfigComponent leftoverLiquid =
            new RLM_RampConfiguratorAction.ConfigComponent();
        leftoverLiquid.name = 'QB Liquid Cooler';
        leftoverLiquid.sku = 'QB-LIQUIDCOOL';
        leftoverLiquid.selected = true;
        leftoverLiquid.quantity = 2;
        RLM_RampConfiguratorAction.ConfigGroup coolingGroup =
            new RLM_RampConfiguratorAction.ConfigGroup();
        coolingGroup.name = 'Cooling';
        coolingGroup.components = new List<RLM_RampConfiguratorAction.ConfigComponent>{ leftoverLiquid };
        singleLeft.groups = new List<RLM_RampConfiguratorAction.ConfigGroup>{
            cpuGroup, coolingGroup, gpuGroup
        };
        singleLeft.messages = new List<RLM_RampConfiguratorAction.ConfigMessage>{ staleGold };
        RLM_RampConfiguratorAction.attachFixGuidance(singleLeft);
        System.assertEquals('change_picks', singleLeft.fixKind);
        System.assertEquals(
            RLM_ConstraintRuleIndex.byMatch('dualWorkload').ruleText,
            singleLeft.fixSteps[0]
        );
        System.assertEquals(1, singleLeft.fixSteps.size());
        System.assert(singleLeft.constraintCoachDisplay.contains(
            'Rule: Dual sockets need Workload AI or High Performance Computing.'),
            singleLeft.constraintCoachDisplay);
        System.assertEquals(
            false,
            String.join(singleLeft.fixSteps, ' ').contains('Gold CPU')
        );
        System.assertEquals(
            false,
            String.join(singleLeft.fixSteps, ' ').contains('two CPUs or two liquid coolers')
        );
        System.assertEquals(
            false,
            String.join(singleLeft.fixSteps, ' ').contains('Dual-only GPU')
        );

        RLM_RampConfiguratorAction.ConfigResult domain =
            new RLM_RampConfiguratorAction.ConfigResult();
        domain.success = false;
        domain.message = 'Calculated value int 1 is not in domain of x16Lanes in Server_0';
        RLM_RampConfiguratorAction.attachFixGuidance(domain);
        System.assertEquals('change_picks', domain.fixKind);
        System.assertEquals(
            RLM_ConstraintRuleIndex.byMatch('x16Lanes').ruleText,
            domain.fixSteps[0]
        );
        System.assertEquals(
            false,
            domain.fixSteps[0].contains('A Dual GPU is selected')
        );

        RLM_RampConfiguratorAction.ConfigMessage leftover =
            new RLM_RampConfiguratorAction.ConfigMessage();
        leftover.messageType = 'error';
        leftover.text = 'Calculated value int 1 is not in domain of x16Lanes in Server_0';
        RLM_RampConfiguratorAction.ConfigMessage liquid =
            new RLM_RampConfiguratorAction.ConfigMessage();
        liquid.messageType = 'constraint';
        liquid.text = 'Dual needs two liquid coolers. Add them, or set Socket back to Single.';
        RLM_RampConfiguratorAction.ConfigResult mixed =
            new RLM_RampConfiguratorAction.ConfigResult();
        mixed.success = false;
        mixed.message = leftover.text;
        mixed.messages = new List<RLM_RampConfiguratorAction.ConfigMessage>{ leftover, liquid };
        RLM_RampConfiguratorAction.attachFixGuidance(mixed);
        System.assertEquals('change_picks', mixed.fixKind);
        System.assertEquals(liquid.text, mixed.fixSteps[0]);
        System.assertEquals(false, String.join(mixed.fixSteps, ' ').contains('x16Lanes'));

        RLM_RampConfiguratorAction.ConfigMessage raid =
            new RLM_RampConfiguratorAction.ConfigMessage();
        raid.messageType = 'constraint';
        raid.text = 'RAID needs a RAID 500 card. Add it, or set RAID to N/A.';
        RLM_RampConfiguratorAction.ConfigResult raidResult =
            new RLM_RampConfiguratorAction.ConfigResult();
        raidResult.messages = new List<RLM_RampConfiguratorAction.ConfigMessage>{ raid };
        RLM_RampConfiguratorAction.attachFixGuidance(raidResult);
        System.assertEquals('change_picks', raidResult.fixKind);
        System.assertEquals(raid.text, raidResult.fixSteps[0]);
    }

    @IsTest
    static void attachFixGuidanceBuildsConstraintCoachCard() {
        RLM_RampConfiguratorAction.ConfigAttribute socket =
            new RLM_RampConfiguratorAction.ConfigAttribute();
        socket.attributeName = 'SocketConfiguration';
        socket.label = 'Socket Configuration';
        socket.value = 'Dual';
        RLM_RampConfiguratorAction.ConfigPicklistOption dual =
            new RLM_RampConfiguratorAction.ConfigPicklistOption();
        dual.label = 'Dual';
        dual.value = 'Dual';
        RLM_RampConfiguratorAction.ConfigPicklistOption single =
            new RLM_RampConfiguratorAction.ConfigPicklistOption();
        single.label = 'Single';
        single.value = 'Single';
        socket.options = new List<RLM_RampConfiguratorAction.ConfigPicklistOption>{
            dual, single
        };
        RLM_RampConfiguratorAction.ConfigAttribute workload =
            new RLM_RampConfiguratorAction.ConfigAttribute();
        workload.attributeName = 'Workload';
        workload.label = 'Workload';
        workload.value = 'High Performance Computing';
        RLM_RampConfiguratorAction.ConfigComponent gold =
            new RLM_RampConfiguratorAction.ConfigComponent();
        gold.name = 'Intel Xeon Gold 6330N 2.2GHz, 28C/56T';
        gold.sku = 'QB-INTEL-GOLD-6330N';
        gold.selected = true;
        gold.quantity = 1;
        RLM_RampConfiguratorAction.ConfigComponent platinum =
            new RLM_RampConfiguratorAction.ConfigComponent();
        platinum.name = 'Intel Xeon Platinum 8352M 2.3GHz, 32C/64T';
        platinum.sku = 'QB-INTEL-PLAT-8352M';
        platinum.selected = false;
        platinum.quantity = 1;
        RLM_RampConfiguratorAction.ConfigGroup cpuGroup =
            new RLM_RampConfiguratorAction.ConfigGroup();
        cpuGroup.name = 'CPU';
        cpuGroup.components = new List<RLM_RampConfiguratorAction.ConfigComponent>{
            gold, platinum
        };
        RLM_RampConfiguratorAction.ConfigResult dualGold =
            new RLM_RampConfiguratorAction.ConfigResult();
        dualGold.success = true;
        dualGold.attributes = new List<RLM_RampConfiguratorAction.ConfigAttribute>{
            socket, workload
        };
        dualGold.groups = new List<RLM_RampConfiguratorAction.ConfigGroup>{ cpuGroup };
        dualGold.messages = new List<RLM_RampConfiguratorAction.ConfigMessage>();
        RLM_RampConfiguratorAction.attachFixGuidance(
            dualGold, new Set<String>{ 'socket configuration' });
        System.assertEquals('change_picks', dualGold.fixKind);
        System.assertEquals(RLM_RampConfiguratorAction.DUAL_GOLD_FIX, dualGold.fixSteps[0]);
        System.assert(dualGold.constraintCoachDisplay.startsWith('Constraint'),
            dualGold.constraintCoachDisplay);
        System.assert(dualGold.constraintCoachDisplay.contains(
            'Rule: Dual cannot use a Gold CPU. Pick a Platinum, or switch Socket to Single.'),
            dualGold.constraintCoachDisplay);
        System.assertEquals(
            false,
            dualGold.constraintCoachDisplay.contains('Dual sockets cannot use a Gold CPU.'),
            dualGold.constraintCoachDisplay
        );
        System.assert(dualGold.constraintCoachDisplay.contains(
            'Now: Socket Configuration = Dual; Processor = Intel Xeon Gold 6330N'),
            dualGold.constraintCoachDisplay);
        System.assert(dualGold.constraintCoachDisplay.contains(
            'Violating: Dual requires Gold quantity 0.'),
            dualGold.constraintCoachDisplay);
        System.assert(dualGold.constraintCoachDisplay.contains('Change one of:'),
            dualGold.constraintCoachDisplay);
        System.assert(dualGold.constraintCoachDisplay.contains(
            'Socket Configuration → Single'), dualGold.constraintCoachDisplay);
        System.assert(dualGold.constraintCoachDisplay.contains(
            'Processor → Intel Xeon Platinum 8352M'),
            dualGold.constraintCoachDisplay);
        System.assert(dualGold.constraintCoachDisplay.contains('(Gold quantity 0)'),
            dualGold.constraintCoachDisplay);
        System.assertEquals(
            false,
            dualGold.constraintCoachDisplay.containsIgnoreCase('Gold 6330N (Gold quantity 0)'),
            dualGold.constraintCoachDisplay
        );
        System.assert(dualGold.constraintCoachDisplay.contains(
            'I will not configure until you pick.'), dualGold.constraintCoachDisplay);
        System.assertEquals(
            false,
            dualGold.constraintCoachDisplay.contains('not in domain'),
            dualGold.constraintCoachDisplay
        );

        RLM_RampConfiguratorAction.ConfigAttribute raid =
            new RLM_RampConfiguratorAction.ConfigAttribute();
        raid.attributeName = 'RAID';
        raid.label = 'RAID';
        raid.value = 'RAID 1';
        RLM_RampConfiguratorAction.ConfigPicklistOption raidNa =
            new RLM_RampConfiguratorAction.ConfigPicklistOption();
        raidNa.label = 'N/A';
        raidNa.value = 'N/A';
        RLM_RampConfiguratorAction.ConfigPicklistOption raid1 =
            new RLM_RampConfiguratorAction.ConfigPicklistOption();
        raid1.label = 'RAID 1';
        raid1.value = 'RAID 1';
        RLM_RampConfiguratorAction.ConfigPicklistOption raid5 =
            new RLM_RampConfiguratorAction.ConfigPicklistOption();
        raid5.label = 'RAID 5';
        raid5.value = 'RAID 5';
        raid.options = new List<RLM_RampConfiguratorAction.ConfigPicklistOption>{
            raidNa, raid1, raid5
        };
        RLM_RampConfiguratorAction.ConfigComponent raidCard =
            new RLM_RampConfiguratorAction.ConfigComponent();
        raidCard.name = 'RAID 500 card';
        raidCard.sku = 'QB-RAID-500';
        raidCard.selected = false;
        RLM_RampConfiguratorAction.ConfigGroup controller =
            new RLM_RampConfiguratorAction.ConfigGroup();
        controller.name = 'Controller';
        controller.components = new List<RLM_RampConfiguratorAction.ConfigComponent>{
            raidCard
        };
        RLM_RampConfiguratorAction.ConfigMessage raidMsg =
            new RLM_RampConfiguratorAction.ConfigMessage();
        raidMsg.messageType = 'constraint';
        raidMsg.text = 'RAID 1 requires a RAID 500 card.';
        RLM_RampConfiguratorAction.ConfigResult generic =
            new RLM_RampConfiguratorAction.ConfigResult();
        generic.success = true;
        generic.attributes = new List<RLM_RampConfiguratorAction.ConfigAttribute>{ raid };
        generic.groups = new List<RLM_RampConfiguratorAction.ConfigGroup>{ controller };
        generic.messages = new List<RLM_RampConfiguratorAction.ConfigMessage>{ raidMsg };
        RLM_RampConfiguratorAction.attachFixGuidance(generic);
        System.assertEquals('change_picks', generic.fixKind);
        System.assert(generic.constraintCoachDisplay.contains(
            'Rule: RAID needs a RAID 500 card. Add it, or set RAID to N/A.'),
            generic.constraintCoachDisplay);
        System.assert(generic.constraintCoachDisplay.contains('Now: RAID = RAID 1'),
            generic.constraintCoachDisplay);
        System.assert(generic.constraintCoachDisplay.contains('RAID → N/A'),
            generic.constraintCoachDisplay);
        System.assert(generic.constraintCoachDisplay.contains('Controller → RAID 500 card'),
            generic.constraintCoachDisplay);
        System.assert(generic.constraintCoachDisplay.contains('I will not configure until you pick.'),
            generic.constraintCoachDisplay);

        RLM_RampConfiguratorAction.ConfigResult leftover =
            new RLM_RampConfiguratorAction.ConfigResult();
        leftover.success = false;
        leftover.message = 'Calculated value int 1 is not in domain of FooBar in Server_0';
        RLM_RampConfiguratorAction.attachFixGuidance(leftover);
        System.assertEquals('platform', leftover.fixKind);
        System.assertEquals(null, leftover.constraintCoachDisplay);

        RLM_RampConfiguratorAction.ConfigAttribute laneSocket =
            new RLM_RampConfiguratorAction.ConfigAttribute();
        laneSocket.attributeName = 'SocketConfiguration';
        laneSocket.label = 'Socket Configuration';
        laneSocket.value = 'Dual';
        RLM_RampConfiguratorAction.ConfigPicklistOption laneSingle =
            new RLM_RampConfiguratorAction.ConfigPicklistOption();
        laneSingle.label = 'Single';
        laneSingle.value = 'Single';
        laneSocket.options = new List<RLM_RampConfiguratorAction.ConfigPicklistOption>{
            laneSingle
        };
        RLM_RampConfiguratorAction.ConfigAttribute laneTier =
            new RLM_RampConfiguratorAction.ConfigAttribute();
        laneTier.attributeName = 'PerformanceTier';
        laneTier.label = 'Performance Tier';
        laneTier.value = 'Standard';
        RLM_RampConfiguratorAction.ConfigResult lanes =
            new RLM_RampConfiguratorAction.ConfigResult();
        lanes.success = false;
        lanes.message = 'Calculated value int 1 is not in domain of x16Lanes in Server_0';
        lanes.attributes = new List<RLM_RampConfiguratorAction.ConfigAttribute>{
            laneSocket, laneTier
        };
        RLM_RampConfiguratorAction.attachFixGuidance(lanes);
        System.assertEquals('change_picks', lanes.fixKind);
        System.assert(lanes.constraintCoachDisplay.contains(
            'Rule: Do not edit x16 Lanes. Dual with this Performance Tier adds a GPU. Set Performance Tier to Entry, or set Socket to Single.'),
            lanes.constraintCoachDisplay);
        System.assertEquals(
            false,
            lanes.constraintCoachDisplay.contains('A Dual GPU is selected'),
            lanes.constraintCoachDisplay
        );
        System.assert(lanes.constraintCoachDisplay.contains('Performance Tier → Entry'),
            lanes.constraintCoachDisplay);
        System.assert(lanes.constraintCoachDisplay.contains('Socket Configuration → Single'),
            lanes.constraintCoachDisplay);
        System.assertEquals(
            false,
            lanes.constraintCoachDisplay.contains('Workload →'),
            lanes.constraintCoachDisplay
        );
    }

    @IsTest
    static void loadUsesConfigureMock() {
        QuoteLineItem qli = insertBundleLine();
        qli = [SELECT Id, QuoteId FROM QuoteLineItem WHERE Id = :qli.Id];
        Test.setMock(HttpCalloutMock.class, new ConfigureMock(200, mockSuccessBody()));
        Test.startTest();
        RLM_RampConfiguratorAction.ConfigResult r =
            RLM_RampConfiguratorAction.loadConfiguration(qli.QuoteId, qli.Id);
        Test.stopTest();
        System.assertNotEquals(null, r);
        System.assertEquals(true, r.success);
        System.assertNotEquals(null, r.groups);
        System.assert(r.groups.size() >= 1);
    }

    @IsTest
    static void saveUsesConfigureMock() {
        QuoteLineItem qli = insertBundleLine();
        Test.setMock(HttpCalloutMock.class, new ConfigureMock(200, mockSuccessBody()));
        String json = '{"components":[{"product2Id":"01t000000000001AAA","pricebookEntryId":'
            + '"01u000000000001AAA","quantity":1,"productRelatedComponentId":"0dS000000000001AAA"}],'
            + '"attributes":[]}';
        Test.startTest();
        RLM_RampConfiguratorAction.ConfigResult r =
            RLM_RampConfiguratorAction.saveConfiguration(qli.QuoteId, qli.Id, json);
        Test.stopTest();
        System.assertEquals(true, r.success, String.valueOf(r.message));
        System.assert(String.valueOf(r.message).contains('Add-ons'), r.message);
    }

    @IsTest
    static void selectionFromResultUsesEnginePicks() {
        RLM_RampConfiguratorAction.ConfigResult parsed =
            new RLM_RampConfiguratorAction.ConfigResult();
        parsed.transactionContextId = 'ctx-engine';
        RLM_RampConfiguratorAction.ConfigComponent enginePick =
            new RLM_RampConfiguratorAction.ConfigComponent();
        enginePick.product2Id = '01t000000000ENGAAA';
        enginePick.selected = true;
        enginePick.quantity = 2;
        RLM_RampConfiguratorAction.ConfigComponent skipped =
            new RLM_RampConfiguratorAction.ConfigComponent();
        skipped.product2Id = '01t000000000SKIPAA';
        skipped.selected = false;
        skipped.quantity = 1;
        RLM_RampConfiguratorAction.ConfigGroup optionGroup =
            new RLM_RampConfiguratorAction.ConfigGroup();
        optionGroup.components = new List<RLM_RampConfiguratorAction.ConfigComponent>{
            enginePick, skipped
        };
        parsed.groups = new List<RLM_RampConfiguratorAction.ConfigGroup>{ optionGroup };
        RLM_RampConfiguratorAction.ConfigAttribute attr =
            new RLM_RampConfiguratorAction.ConfigAttribute();
        attr.attributeName = 'Socket Configuration';
        attr.value = 'Dual';
        parsed.attributes = new List<RLM_RampConfiguratorAction.ConfigAttribute>{ attr };

        RLM_RampConfiguratorAction.Selection requested =
            new RLM_RampConfiguratorAction.Selection();
        RLM_RampConfiguratorAction.ConfigComponent requestedPick =
            new RLM_RampConfiguratorAction.ConfigComponent();
        requestedPick.product2Id = '01t000000000REQAAA';
        requestedPick.selected = true;
        requestedPick.quantity = 1;
        requested.components = new List<RLM_RampConfiguratorAction.ConfigComponent>{ requestedPick };

        RLM_RampConfiguratorAction.Selection persisted =
            RLM_RampConfiguratorAction.selectionFromResult(parsed, requested);
        System.assertEquals('ctx-engine', persisted.transactionContextId);
        System.assertEquals(1, persisted.components.size());
        System.assertEquals('01t000000000ENGAAA', persisted.components[0].product2Id);
        System.assertEquals(2, persisted.components[0].quantity);
        System.assertEquals(1, persisted.attributes.size());
        System.assertEquals('Dual', persisted.attributes[0].value);
    }

    @IsTest
    static void loadCatalogRejectsBlankQuote() {
        RLM_RampConfiguratorAction.ConfigResult r =
            RLM_RampConfiguratorAction.loadCatalogConfiguration('not-an-id', null);
        System.assertEquals(false, r.success);
        System.assert(r.message.contains('Quote Id'), r.message);
    }

    @IsTest
    static void loadCatalogReadsEmptyGroups() {
        QuoteLineItem qli = insertBundleLine();
        Test.startTest();
        RLM_RampConfiguratorAction.ConfigResult r =
            RLM_RampConfiguratorAction.loadCatalogConfiguration(qli.QuoteId, qli.Id);
        Test.stopTest();
        System.assertEquals(true, r.success, String.valueOf(r.message));
        System.assertNotEquals(null, r.groups);
        System.assertEquals(0, r.groups.size());
        System.assertNotEquals(null, r.attributes);
        System.assertEquals(0, r.attributes.size());
    }

    @IsTest
    static void overlayPriceImpactingLeavesCatalogFlag() {
        Map<String, Object> catalog = sampleCatalog();
        List<RLM_RampConfiguratorAction.ConfigAttribute> attrs =
            RLM_RampConfiguratorAction.parseAttributes(
                catalog, new Map<String, RLM_RampConfiguratorAction.ConfigAttribute>());
        System.assertEquals(true, attrs[0].priceImpacting);
        QuoteLineItem qli = insertBundleLine();
        RLM_RampConfiguratorAction.overlayPriceImpacting(attrs, qli.Product2Id);
        System.assertEquals(true, attrs[0].priceImpacting);
        attrs[0].priceImpacting = null;
        RLM_RampConfiguratorAction.overlayPriceImpacting(attrs, qli.Product2Id);
        System.assertEquals(null, attrs[0].priceImpacting);
    }

    @IsTest
    static void addAttributePersistNodesSkipsEmptySelection() {
        QuoteLineItem qli = insertBundleLine();
        List<RevSalesTrxn.RecordWithReferenceRequest> records =
            new List<RevSalesTrxn.RecordWithReferenceRequest>();
        RLM_RampConfiguratorAction.Selection selection =
            new RLM_RampConfiguratorAction.Selection();
        selection.attributes = new List<RLM_RampConfiguratorAction.ConfigAttribute>();
        Integer next = RLM_RampConfiguratorAction.addAttributePersistNodes(
            records, qli.Id, selection, 0);
        System.assertEquals(0, next);
        System.assertEquals(0, records.size());

        RLM_RampConfiguratorAction.ConfigAttribute blank =
            new RLM_RampConfiguratorAction.ConfigAttribute();
        blank.attributeName = 'Operating_System';
        selection.attributes.add(blank);
        next = RLM_RampConfiguratorAction.addAttributePersistNodes(
            records, qli.Id, selection, 0);
        System.assertEquals(0, next);
        System.assertEquals(0, records.size());
    }

    @IsTest
    static void addAttributePersistNodesIgnoresForeignRecordId() {
        QuoteLineItem qli = insertBundleLine();
        List<RevSalesTrxn.RecordWithReferenceRequest> records =
            new List<RevSalesTrxn.RecordWithReferenceRequest>();
        RLM_RampConfiguratorAction.Selection selection =
            new RLM_RampConfiguratorAction.Selection();
        RLM_RampConfiguratorAction.ConfigAttribute foreign =
            new RLM_RampConfiguratorAction.ConfigAttribute();
        foreign.attributeName = 'NotARealAttribute_XYZ';
        foreign.value = 'Dual';
        foreign.attributeRecordId = '0zu000000000001AAA';
        selection.attributes = new List<RLM_RampConfiguratorAction.ConfigAttribute>{ foreign };
        Integer next = RLM_RampConfiguratorAction.addAttributePersistNodes(
            records, qli.Id, selection, 0);
        System.assertEquals(0, next, 'Foreign QLIA Ids must not PATCH another year');
        System.assertEquals(0, records.size());
    }

    @IsTest
    static void configurationRulesCrashDetectsConfiguratorException() {
        System.assertEquals(
            true,
            RLM_RampConfiguratorAction.isConfigurationRulesCrash(
                'Something went wrong while running configuration rules. : '
                + 'com.salesforce.configurator.api.exception.ConfiguratorException'));
        System.assertEquals(
            false,
            RLM_RampConfiguratorAction.isConfigurationRulesCrash('Required attribute is blank.'));
        System.assertEquals(false, RLM_RampConfiguratorAction.isConfigurationRulesCrash(null));
    }

    @IsTest
    static void saveCatalogRejectsBlankSelection() {
        QuoteLineItem qli = insertBundleLine();
        RLM_RampConfiguratorAction.ConfigResult r =
            RLM_RampConfiguratorAction.saveCatalogConfiguration(qli.QuoteId, qli.Id, '');
        System.assertEquals(false, r.success);
        System.assert(r.message.contains('selection'), r.message);
    }

    @IsTest
    static void oneTimeChildrenDoNotCopyBillingFrequency() {
        QuoteLineItem parent = new QuoteLineItem(
            StartDate = Date.today(),
            EndDate = Date.today().addYears(1),
            BillingFrequency = 'Monthly',
            PeriodBoundary = 'Anniversary'
        );
        Map<String, Object> oneTime = new Map<String, Object>();
        RLM_RampConfiguratorAction.applyParentTermFields(oneTime, parent, 'OneTime');
        System.assertEquals(String.valueOf(parent.StartDate), oneTime.get('StartDate'));
        System.assertEquals(false, oneTime.containsKey('BillingFrequency'));
        System.assertEquals(false, oneTime.containsKey('PeriodBoundary'));
        System.assertEquals(false, oneTime.containsKey('EndDate'));

        Map<String, Object> term = new Map<String, Object>();
        RLM_RampConfiguratorAction.applyParentTermFields(term, parent, 'TermDefined');
        System.assertEquals('Monthly', term.get('BillingFrequency'));
        System.assertEquals('Anniversary', term.get('PeriodBoundary'));
        System.assertEquals(String.valueOf(parent.EndDate), term.get('EndDate'));
    }

    private static QuoteLineItem insertBundleLine() {
        Account a = new Account(Name = 'Ramp Cfg Acct 3');
        insert a;
        Opportunity o = new Opportunity(
            Name = 'Ramp Cfg Opp 3', AccountId = a.Id, StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30));
        insert o;
        Id std = Test.getStandardPricebookId();
        Quote q = new Quote(
            Name = 'Ramp Cfg Quote 3', OpportunityId = o.Id, Status = 'Draft',
            Pricebook2Id = std);
        insert q;
        Product2 p = new Product2(Name = 'Complete Solution', IsActive = true);
        insert p;
        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = std, Product2Id = p.Id, UnitPrice = 100, IsActive = true);
        insert pbe;
        QuoteLineItem qli = new QuoteLineItem(
            QuoteId = q.Id, PricebookEntryId = pbe.Id, Product2Id = p.Id,
            Quantity = 1, UnitPrice = 100);
        insert qli;
        return qli;
    }

    private static Map<String, Object> sampleCatalog() {
        return new Map<String, Object>{
            'id' => '01t000000000099AAA',
            'name' => 'Complete Solution',
            'attributeCategories' => new List<Object>{
                new Map<String, Object>{
                    'name' => 'Operating System',
                    'attributes' => new List<Object>{
                        new Map<String, Object>{
                            'id' => '0tj000000000001AAA',
                            'developerName' => 'Operating_System',
                            'label' => 'Operating System',
                            'dataType' => 'Picklist',
                            'defaultValue' => 'Amazon Linux 2',
                            'isRequired' => false,
                            'isPriceImpacting' => true,
                            'isHidden' => false,
                            'attributePicklist' => new Map<String, Object>{
                                'values' => new List<Object>{
                                    new Map<String, Object>{
                                        'id' => '0v6000000000001AAA',
                                        'displayValue' => 'Amazon Linux 2',
                                        'textValue' => 'Amazon Linux 2'
                                    },
                                    new Map<String, Object>{
                                        'id' => '0v6000000000002AAA',
                                        'displayValue' => 'Redhat Enterprise Linux',
                                        'textValue' => 'Redhat Enterprise Linux'
                                    }
                                }
                            }
                        }
                    }
                }
            },
            'productComponentGroups' => new List<Object>{
                new Map<String, Object>{
                    'id' => '0y7000000000001AAA',
                    'name' => 'Software',
                    'code' => 'PCG-QB-SOFTWARE',
                    'components' => new List<Object>{
                        new Map<String, Object>{
                            'id' => '01t000000000001AAA',
                            'name' => 'API Access',
                            'productCode' => 'QB-API',
                            'isComponentRequired' => false,
                            'isDefaultComponent' => true,
                            'isQuantityEditable' => true,
                            'productRelatedComponent' => new Map<String, Object>{
                                'id' => '0dS000000000001AAA',
                                'productRelationshipTypeId' => '0yo000000000001AAA',
                                'doesBundlePriceIncludeChild' => false,
                                'quantity' => 100
                            },
                            'prices' => new List<Object>{
                                new Map<String, Object>{
                                    'pricebookEntryId' => '01u000000000001AAA',
                                    'unitPrice' => 45,
                                    'isDefault' => true,
                                    'pricingModel' => new Map<String, Object>{
                                        'id' => '0jP000000000001AAA',
                                        'name' => 'Term Annual'
                                    }
                                }
                            }
                        },
                        new Map<String, Object>{
                            'id' => '01t000000000002AAA',
                            'name' => 'Extra Software',
                            'productCode' => 'QB-X',
                            'isDefaultComponent' => false,
                            'isQuantityEditable' => true,
                            'productRelatedComponent' => new Map<String, Object>{
                                'id' => '0dS000000000002AAA',
                                'quantity' => 1
                            }
                        }
                    }
                },
                new Map<String, Object>{
                    'id' => '0y7000000000002AAA',
                    'name' => 'Maintenance &amp; Support',
                    'code' => 'QB-PCG-USAGE',
                    'minBundleComponents' => 1,
                    'maxBundleComponents' => 1,
                    'components' => new List<Object>{
                        new Map<String, Object>{
                            'id' => '01t000000000003AAA',
                            'name' => 'Token Commit',
                            'isDefaultComponent' => false,
                            'productRelatedComponent' => new Map<String, Object>{
                                'id' => '0dS000000000003AAA',
                                'quantity' => 1
                            }
                        }
                    }
                }
            }
        };
    }

    private static String mockSuccessBody() {
        return JSON.serialize(new Map<String, Object>{
            'success' => true,
            'transactionContextId' => 'ctx-mock',
            'catalogProducts' => new List<Object>{ sampleCatalog() },
            'messages' => new Map<String, Object>(),
            'errors' => new List<Object>()
        });
    }

    private class ConfigureMock implements HttpCalloutMock {
        Integer statusCode;
        String body;
        ConfigureMock(Integer statusCode, String body) {
            this.statusCode = statusCode;
            this.body = body;
        }
        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(statusCode);
            res.setBody(body);
            return res;
        }
    }

    private class CaptureMock implements HttpCalloutMock {
        Integer statusCode;
        String body;
        List<String> bodies = new List<String>();
        CaptureMock(Integer statusCode, String body) {
            this.statusCode = statusCode;
            this.body = body;
        }
        public HTTPResponse respond(HTTPRequest req) {
            bodies.add(req.getBody());
            HttpResponse res = new HttpResponse();
            res.setStatusCode(statusCode);
            res.setBody(body);
            return res;
        }
    }

    private class RetryMock implements HttpCalloutMock {
        List<String> endpoints = new List<String>();
        List<String> authorizationHeaders = new List<String>();
        public HTTPResponse respond(HTTPRequest req) {
            endpoints.add(req.getEndpoint());
            authorizationHeaders.add(req.getHeader('Authorization'));
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody(mockSuccessBody());
            return res;
        }
    }
}
