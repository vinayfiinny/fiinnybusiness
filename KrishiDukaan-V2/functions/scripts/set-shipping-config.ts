/**
 * Turns courier automation on for UAT, in simulate mode.
 * Live mode is deliberately not an option here: it books real shipments.
 *
 *   npx tsx scripts/set-shipping-config.ts            # show
 *   npx tsx scripts/set-shipping-config.ts --enable   # enabled + simulate
 *   npx tsx scripts/set-shipping-config.ts --disable
 */
import * as admin from "firebase-admin";
import { randomBytes } from "crypto";

admin.initializeApp({ projectId: "karan-arjun-uat" });
const ref = admin.firestore().collection("_serverConfig").doc("shipping");
(async () => {
  const on = process.argv.includes("--enable");
  const off = process.argv.includes("--disable");
  if (on || off) {
    const cur = (await ref.get()).data() ?? {};
    await ref.set({
      enabled: on, mode: "simulate", webhookToken: cur.webhookToken || randomBytes(24).toString("hex"),
      updatedAt: new Date().toISOString(),
    }, { merge: true });
  }
  const d = (await ref.get()).data() ?? {};
  console.log({ ...d, webhookToken: d.webhookToken ? "(set)" : "(none)" });
})();
