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
}
