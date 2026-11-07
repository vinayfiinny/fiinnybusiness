/**
 * UAT only. Creates 6 courier demo orders that STAY, so the team can open them:
 * not accepted yet, booked, on the way, delivered, reassigned, seller delivers.
 * Needs _serverConfig/shipping enabled + simulate (scripts/set-shipping-config.ts --enable).
 * Customer Sai Surve +911231231234, sellers Mankar +918899556633 and Kunal Deore
 * +918767263557 (UAT test logins). Fake payment, simulated bookings.
 *
 *   cd functions && node scripts/demo-delivery-orders.js
 *
 * Re-running replaces them. Remove: delete orders whose id starts with "demo-delivery-".
 */
const admin=require("firebase-admin");
admin.initializeApp({projectId:"karan-arjun-uat"});const db=admin.firestore();
const uids={};
const CUST="+911231231234", SELLER="+918899556633", SELLER2="+918767263557";
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
const ref=id=>db.collection("orders").doc(id);
async function until(id,fn,ms=45000){const e=Date.now()+ms;let o;while(Date.now()<e){o=(await ref(id).get()).data()||{};if(fn(o))return o;await sleep(1200)}return o}
const ask=(id,action,event)=>ref(id).update({shipmentRequest:{id:Math.random().toString(36).slice(2),action,...(event?{event}:{})}});
const booked=o=>o.shipment&&o.shipment.stage&&o.shipment.stage!=="booking";
async function make(id,label,over={}){
  await ref(id).delete().catch(()=>{});
  await ref(id).set({
    isDemo:true, demoNote:"UAT courier demo. Not a real order. Safe to delete.",
    customerId:uids[CUST], customerName:"Sai Surve (DEMO "+label+")", customerPhone:CUST,
    customerAddress:{name:"Sai Surve",address:"DEMO, 12 Test Road, Shivajinagar",city:"Pune",district:"Pune",state:"Maharashtra",pincode:"411005"},
    customerDeliveryState:"Maharashtra",
    sellerPhone:SELLER, sellerId:uids[SELLER], sellerName:"Mankar manufractuere", sellerType:"manufacturer",
    items:[{productId:"demo-delivery-product",name:"DEMO Test Fertilizer",qty:2,quantity:2,variantUnit:"1kg",price:400,lineTotal:800}],
    subtotal:800, deliveryCharge:40, totalGst:0, grandTotal:840, total:840,
    payment:{status:"paid",amount:840,method:"demo (no Razorpay)",paidAt:new Date().toISOString()},
    status:"placed", statusHistory:[{status:"placed",at:new Date().toISOString()}],
    createdAt:admin.firestore.FieldValue.serverTimestamp(), updatedAt:new Date().toISOString(), ...over});
  return id;
}
(async()=>{
  for(const p of ["+911231231234","+918899556633","+918767263557"]) uids[p]=(await admin.auth().getUserByPhoneNumber(p)).uid;
  const c=(await db.collection("_serverConfig").doc("shipping").get()).data()||{};
  if(c.enabled!==true||c.mode!=="simulate") throw new Error("shipping must be enabled + simulate");
  const out=[];
  const show=async(id,what)=>{const o=(await ref(id).get()).data();const s=o.shipment||{};out.push([id,what,o.status,s.mode?(s.mode==="self"?"seller delivers: "+s.reasonText:`${s.carrier}/${s.service} ₹${s.cost} AWB ${s.awb} [${s.stage}]`):"(not accepted yet)"]);};

  await make("demo-delivery-1-placed","1 - accept me"); await show("demo-delivery-1-placed","Waiting for the seller to accept");

  const a=await make("demo-delivery-2-booked","2 - booked"); await ref(a).update({status:"accepted"}); await until(a,booked); await show(a,"Booked, try Ready for pickup + test buttons");

  const b=await make("demo-delivery-3-on-the-way","3 - on the way"); await ref(b).update({status:"accepted"}); await until(b,booked);
  await ask(b,"pickup"); await until(b,o=>o.shipment.stage==="pickup_requested");
  await ask(b,"simulate","picked_up"); await until(b,o=>o.status==="dispatched");
  await ask(b,"simulate","out_for_delivery"); await until(b,o=>o.status==="out_for_delivery"); await show(b,"Picked up, out for delivery");

  const d=await make("demo-delivery-4-delivered","4 - delivered"); await ref(d).update({status:"accepted"}); await until(d,booked);
  await ask(d,"pickup"); await until(d,o=>o.shipment.stage==="pickup_requested");
  for(const e of ["picked_up","in_transit","out_for_delivery","delivered"]){await ask(d,"simulate",e);await sleep(3500);}
  await until(d,o=>o.status==="delivered"); await show(d,"Delivered by the courier");

  const r=await make("demo-delivery-5-reassigned","5 - reassigned"); await ref(r).update({status:"accepted"}); await until(r,booked);
  const offer=db.collection("sellerOffers").doc(SELLER2.slice(-10)).collection("offers").doc(r);
  await offer.set({orderId:r,status:"open",sellerPhone:SELLER2,sellerPhones:[SELLER2,SELLER2.slice(3)],itemSummary:"DEMO Test Fertilizer",orderValue:840,deliveryCity:"Pune",deliveryPincode:"411005",expiresAt:admin.firestore.Timestamp.fromMillis(Date.now()+864e5),createdAt:new Date().toISOString()});
  await ref(r).update({status:"reassigning",rejectionReason:"DEMO: out of stock",statusHistory:admin.firestore.FieldValue.arrayUnion({status:"reassigning",at:new Date().toISOString()}),
    reassignment:{round:1,status:"open",fromSellerPhone:SELLER,fromSellerName:"Mankar manufractuere",rejectionReason:"DEMO: out of stock",candidatePhones:[SELLER2],expiresAt:admin.firestore.Timestamp.fromMillis(Date.now()+864e5)}});
  await until(r,o=>!o.shipment&&(o.shipmentHistory||[]).length===1); await sleep(6000);
  await offer.update({status:"accepted"});
  await ref(r).update({status:"accepted",sellerPhone:SELLER2,sellerId:uids[SELLER2],sellerName:"Kunal Deore Agro Agency","reassignment.status":"accepted","reassignment.acceptedBy":SELLER2,statusHistory:admin.firestore.FieldValue.arrayUnion({status:"accepted",at:new Date().toISOString(),reassigned:true})});
  await until(r,booked); const ro=(await ref(r).get()).data(); await show(r,`Mankar rejected → Kunal took it (old AWB ${ro.shipmentHistory[0].awb} cancelled)`);

  const s=await make("demo-delivery-6-seller-delivers","6 - no courier",{customerAddress:{name:"Sai Surve",address:"DEMO, remote village",city:"Nowhere",state:"Maharashtra",pincode:"999999"}});
  await ref(s).update({status:"accepted"}); await until(s,booked); await show(s,"No courier serves 999999 → seller delivers");

  for(const [id,what,status,ship] of out) console.log(`${id.padEnd(34)} | ${String(status).padEnd(16)} | ${what}\n${" ".repeat(37)}${ship}`);
  process.exit(0);
})().catch(e=>{console.error("STOPPED:",e.message);process.exit(1)});
