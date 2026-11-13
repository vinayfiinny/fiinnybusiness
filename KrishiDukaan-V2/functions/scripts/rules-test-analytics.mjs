// analyticsPurchases rules, with real users.
//   firebase emulators:exec --only firestore --project demo-rules --config firebase.uat.json "node functions/scripts/rules-test-analytics.mjs"
import { initializeApp } from "firebase/app";
import { connectFirestoreEmulator, doc, getDoc, getFirestore, runTransaction, setDoc, updateDoc, deleteDoc, serverTimestamp } from "firebase/firestore";
const [host, port] = process.env.FIRESTORE_EMULATOR_HOST.split(":");
const client = (uid, n) => {
  const db = getFirestore(initializeApp({ projectId: "demo-rules", apiKey: "x" }, n));
  connectFirestoreEmulator(db, host, Number(port), { mockUserToken: { user_id: uid, sub: uid } });
  return db;
};
const a = client("alice", "a"), b = client("bob", "b");
let fail = 0;
const t = async (name, allow, fn) => {
  let ok = true; try { await fn(); } catch (e) { if (e.code !== "permission-denied") console.log("  (", e.code, ")"); ok = false; }
  if (ok !== allow) fail++;
  console.log(`  ${ok === allow ? "PASS" : "FAIL"}  ${name} (${ok ? "allowed" : "denied"})`);
};
const rec = (uid) => ({ uid, platform: "android", orderIds: ["o1", "o2"], at: serverTimestamp() });
// The exact transaction the app runs: read, then create if missing.
const claim = (db, id, uid) => runTransaction(db, async (tx) => {
  const r = doc(db, "analyticsPurchases", id); const s = await tx.get(r);
  if (s.exists()) return false; tx.set(r, rec(uid)); return true;
});
await t("shopper claims a new payment (read-then-create transaction)", true, async () => { if (!(await claim(a, "pay_1", "alice"))) throw new Error("not first"); });
await t("claiming the same payment again finds it and stops", true, async () => { if (await claim(a, "pay_1", "alice")) throw new Error("claimed twice"); });
await t("may NOT create a record in someone else's name", false, () => setDoc(doc(b, "analyticsPurchases", "pay_2"), rec("alice")));
await t("may NOT overwrite an existing record", false, () => setDoc(doc(a, "analyticsPurchases", "pay_1"), rec("alice")));
await t("may NOT edit a record", false, () => updateDoc(doc(a, "analyticsPurchases", "pay_1"), { platform: "ios" }));
await t("may NOT delete a record (to re-send)", false, () => deleteDoc(doc(a, "analyticsPurchases", "pay_1")));
await t("may NOT read another shopper's record", false, () => getDoc(doc(b, "analyticsPurchases", "pay_1")));
await t("may NOT add extra fields (e.g. phone)", false, () => setDoc(doc(a, "analyticsPurchases", "pay_3"), { ...rec("alice"), phone: "+91" }));
console.log(fail ? `${fail} FAILED` : "analytics rules: all passed");
process.exit(fail ? 1 : 0);
