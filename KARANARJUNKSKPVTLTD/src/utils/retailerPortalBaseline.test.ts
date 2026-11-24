import { describe, expect, it } from 'vitest';
import {
    DEFAULT_FEATURE_PERMISSIONS,
    enforceRetailerPortalFeatures,
    enforceRetailerPortalRole,
} from './featurePermissions';

describe('retailer portal baseline', () => {
    it('a saved matrix with worklist off cannot lock retailers out', () => {
        const saved = { worklist: false, dashboard: false, settings: false };
        expect(enforceRetailerPortalRole(saved).worklist).toBe(true);
        expect(enforceRetailerPortalRole(saved).dashboard).toBe(false); // other screens untouched
        expect(enforceRetailerPortalRole(undefined).worklist).toBe(true);
    });

    it('write features can never be on for a retailer, whatever was saved', () => {
        const saved = {
            ...DEFAULT_FEATURE_PERMISSIONS.retailer,
            'worklist.invoices.delete': true,
            'worklist.partners.create': true,
            'worklist.payments.addPayment': true,
            'worklist.retailerProfile.b2bOrders.deleteOrder': true,
        };
        const out = enforceRetailerPortalFeatures(saved);
        for (const id of Object.keys(out)) {
            if (id.startsWith('worklist.') && !id.endsWith('.view')) expect(out[id], id).toBe(false);
        }
    });

    it('bills and payments are always visible; product sales stays admin-controllable', () => {
        const out = enforceRetailerPortalFeatures({
            'worklist.payments.view': false,
            'worklist.retailerProfile.b2bOrders.view': false,
            'worklist.retailerProfile.payments.view': false,
            'worklist.retailerProfile.productSalesOverview.view': false,
        });
        expect(out['worklist.payments.view']).toBe(true);
        expect(out['worklist.retailerProfile.b2bOrders.view']).toBe(true);
        expect(out['worklist.retailerProfile.payments.view']).toBe(true);
        expect(out['worklist.retailerProfile.productSalesOverview.view']).toBe(false);
    });

    it('non-worklist features are left as saved', () => {
        expect(enforceRetailerPortalFeatures({ 'reports.gst.view': false })['reports.gst.view']).toBe(false);
    });
});
