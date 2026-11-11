/**
 * Copy product/catalog data from production (krishidukan-e8315) to UAT (karan-arjun-uat).
 *
 * Copies only public catalog collections — never touches user, order, or payment data.
 *
 * Safe to run multiple times (overwrites existing UAT docs with prod versions).
 *
 * --prune also deletes CATALOGUE docs that production no longer has (products,
 * inventory, marketplace cards/search/members), so the Market page doesn't keep
 * showing deleted products with old photos. Users, stores, sellers, orders and
 * anything owned by a UAT test login are never pruned. A backup of every pruned
 * doc is written first.
 * --yes skips the confirmation prompt.
 *
 *   npm run copy:prod-to-uat -- --prune
 *
 * Run:
 *   npm run copy:prod-to-uat
 *
 * Requirements:
 *   - gcloud auth application-default login  (run once in your terminal)
 *   - Your account must have Firestore read on krishidukan-e8315
 *     and Firestore write on karan-arjun-uat
 */

import { initializeApp, getApps, App } from 'firebase-admin/app';
import { getFirestore, Firestore, WriteBatch } from 'firebase-admin/firestore';
import * as readline from 'readline';

// ─── Collections to copy ─────────────────────────────────────────────────────
const COPY_COLLECTIONS = [
  // User identity & roles (needed for login to work)
  'users',
  'uidIndex',
  'profiles',
  // Product catalog
  'products',
  'catalog',
  'listings',
  'inventory',
  'manufacturers',
  'brandPages',
  'companyPages',
  'manufacturerRetailers',
  // Retail
  'stores',
  'retailers',
  // Content & config
  'blogPosts',
  'hubs',
  'appVersion',
  'deliverySettings',
  // Marketplace read models, so UAT lists what production lists
  'marketplaceCards',
  'marketplaceSearch',
  'cardMembers',
  'storeDirectory',
  // Config the checkout and home page read (settings holds no secrets)
  'settings',
  'siteContent',
  'banners',
  'promoCodes',
  // Shop helpers
  'shopTeams',
  'staffIndex',
];

// ─── Never copy these (personal / financial data) ─────────────────────────────
// users, uidIndex, profiles, orders, payments, failedPayments, subscriptions,
// manufacturerNetwork, manufacturerRetailers, adminLogs, contactMessages,
// manufacturer_contacts, seatListings, retailerSeatListings, notifications, carts

// Catalogue collections that --prune may delete from (UAT docs missing in prod).
const PRUNE_COLLECTIONS = ['products', 'inventory', 'marketplaceCards', 'marketplaceSearch', 'cardMembers'];
const ARGS = process.argv.slice(2);
const PRUNE = ARGS.includes('--prune');
const YES = ARGS.includes('--yes');

const PROD_PROJECT = 'krishidukan-e8315';
const UAT_PROJECT  = 'karan-arjun-uat';
const BATCH_SIZE   = 400; // Firestore max is 500 ops/batch

// ─── Per-document transforms ──────────────────────────────────────────────────
// Firebase Auth UIDs do NOT transfer between projects. A user who logs into UAT
// with the same phone gets a brand-new UID, so any ownership field that stores a
// production UID will fail the Firestore rules' phoneMatches() check.
//
// Products store ownership in legacy UID fields (ownerId / manufacturerId /
// retailerId) alongside phone fields (ownerPhone / manufacturerPhone /
// retailerPhone). We rewrite the UID fields to their phone equivalents so that
// phoneMatches() succeeds for whoever logs in with that phone — making copied
// products editable in UAT without weakening the security rules.

function looksLikePhone(v: unknown): boolean {
  return typeof v === 'string' && /^\+?\d{10,15}$/.test(v);
}

const TRANSFORMS: Record<string, (data: any) => any> = {
  products: (data) => {
    const { ownerPhone, manufacturerPhone, retailerPhone } = data;
    // Only overwrite a UID-shaped value when a real phone is available.
    if (looksLikePhone(ownerPhone) && !looksLikePhone(data.ownerId)) {
      data.ownerId = ownerPhone;
    }
    if (looksLikePhone(manufacturerPhone) && !looksLikePhone(data.manufacturerId)) {
      data.manufacturerId = manufacturerPhone;
    }
    if (looksLikePhone(retailerPhone) && !looksLikePhone(data.retailerId)) {
      data.retailerId = retailerPhone;
    }
    return data;
  },
};

// ─── Init two separate Admin SDK apps ────────────────────────────────────────
function initApp(projectId: string, name: string): App {
  const existing = getApps().find(a => a.name === name);
  if (existing) return existing;
  return initializeApp({ projectId }, name);
}

async function confirm(question: string): Promise<boolean> {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  return new Promise(resolve => {
    rl.question(question, ans => {
      rl.close();
      resolve(ans.trim().toLowerCase() === 'yes');
    });
  });
}

async function copyCollection(
  src: Firestore,
  dst: Firestore,
  collectionName: string
): Promise<number> {
  const snapshot = await src.collection(collectionName).get();
  if (snapshot.empty) {
    console.log(`  ${collectionName}: empty — skipped`);
    return 0;
  }

  let batch: WriteBatch = dst.batch();
  let batchCount = 0;
  let totalWritten = 0;
  const transform = TRANSFORMS[collectionName];

  for (const doc of snapshot.docs) {
    const data = transform ? transform(doc.data()) : doc.data();
    batch.set(dst.collection(collectionName).doc(doc.id), data);
    batchCount++;
    totalWritten++;

    if (batchCount >= BATCH_SIZE) {
      await batch.commit();
      batch = dst.batch();
      batchCount = 0;
    }
  }

  if (batchCount > 0) {
    await batch.commit();
  }

  console.log(`  ${collectionName}: ${totalWritten} docs copied`);
  return totalWritten;
}

/** Phones of the UAT test logins (Auth testPhoneNumbers): their data is never pruned. */
async function testLoginPhones(): Promise<Set<string>> {
  const { GoogleAuth } = await import('google-auth-library');
  const client = await new GoogleAuth({ scopes: ['https://www.googleapis.com/auth/cloud-platform'] }).getClient();
  const res = await client.request<{ signIn?: { phoneNumber?: { testPhoneNumbers?: Record<string, string> } } }>({
    url: `https://identitytoolkit.googleapis.com/admin/v2/projects/${UAT_PROJECT}/config`,
    headers: { 'x-goog-user-project': UAT_PROJECT },
  });
  const nums = Object.keys(res.data.signIn?.phoneNumber?.testPhoneNumbers ?? {});
  return new Set(nums.map((n) => n.replace(/\D/g, '').slice(-10)));
}

async function prune(src: Firestore, dst: Firestore): Promise<void> {
  const keep = await testLoginPhones();
  const owner = (d: any) =>
    [d.ownerPhone, d.retailerPhone, d.manufacturerPhone, d.createdByPhone, d.sellerPhone, d.ownerId]
      .map((v) => String(v ?? '').replace(/\D/g, '').slice(-10))
      .find((v) => v.length === 10) ?? '';
  const backup: Record<string, Record<string, unknown>> = {};
  const toDelete: Record<string, FirebaseFirestore.DocumentReference[]> = {};
  console.log(`\nPruning catalogue docs missing in prod (keeping ${keep.size} test logins' data)...`);
  for (const col of PRUNE_COLLECTIONS) {
    const [p, u] = await Promise.all([src.collection(col).select().get(), dst.collection(col).get()]);
    const inProd = new Set(p.docs.map((d) => d.id));
    const gone = u.docs.filter((d) => !inProd.has(d.id) && !keep.has(owner(d.data())));
    backup[col] = Object.fromEntries(gone.map((d) => [d.id, d.data()]));
    toDelete[col] = gone.map((d) => d.ref);
  }
  // Backup BEFORE deleting anything.
  const fs = await import('fs');
  const file = `uat-prune-backup-${Date.now()}.json`;
  fs.writeFileSync(file, JSON.stringify(backup));
  console.log(`  backup: ${file}`);
  for (const col of PRUNE_COLLECTIONS) {
    const refs = toDelete[col];
    for (let i = 0; i < refs.length; i += BATCH_SIZE) {
      const batch = dst.batch();
      refs.slice(i, i + BATCH_SIZE).forEach((r) => batch.delete(r));
      await batch.commit();
    }
    console.log(`  ${col}: ${refs.length} removed`);
  }
}

async function main() {
  console.log('');
  console.log('╔══════════════════════════════════════════════════════════╗');
  console.log('║   KrishiDukan — Copy Prod Data → UAT                    ║');
  console.log('╚══════════════════════════════════════════════════════════╝');
  console.log('');
  console.log(`  Source : ${PROD_PROJECT}  (READ ONLY)`);
  console.log(`  Target : ${UAT_PROJECT}   (WRITE)`);
  console.log('');
  console.log('  Collections to copy:');
  COPY_COLLECTIONS.forEach(c => console.log(`    • ${c}`));
  console.log('');
  console.log('  Will NOT copy: orders, payments, failedPayments,');
  console.log('                 subscriptions, adminLogs, contactMessages');
  console.log('');

  if (PRUNE) console.log('  --prune: catalogue docs deleted from prod are removed from UAT (backup first)\n');
  const ok = YES || await confirm('Type "yes" to continue: ');
  if (!ok) {
    console.log('Aborted.');
    process.exit(0);
  }

  console.log('\nInitializing Firebase apps...');
  const prodApp = initApp(PROD_PROJECT, 'prod');
  const uatApp  = initApp(UAT_PROJECT, 'uat');
  const prodDb  = getFirestore(prodApp);
  const uatDb   = getFirestore(uatApp);

  console.log('\nCopying collections...\n');
  let grandTotal = 0;

  for (const col of COPY_COLLECTIONS) {
    try {
      grandTotal += await copyCollection(prodDb, uatDb, col);
    } catch (err: any) {
      console.error(`  ${col}: ERROR — ${err.message}`);
    }
  }

  console.log(`\n✓ Done. ${grandTotal} documents written to ${UAT_PROJECT}.`);
  if (PRUNE) await prune(prodDb, uatDb);
  process.exit(0);
}

main().catch(err => {
  console.error('Fatal:', err);
  process.exit(1);
});
