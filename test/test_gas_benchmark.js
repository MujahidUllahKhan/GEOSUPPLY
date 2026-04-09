// GEOSUPPLY Gas Benchmark — FIXED Version (all 15 tests pass)
// Fix: uses two separate MockGOM instances so the NORMAL-state escrow
// is never affected by FM triggers needed for fmEscrow / GCIL / ASAP tests.
//
// Root cause of original bug:
//   The before() hook triggers FM a second time (line: "Re-trigger FM for
//   GCIL and ASAP tests") after gom.resolveForceMajeure(). Because `escrow`
//   shares the same GOM instance, when the "checkAndTransition NORMAL" test
//   runs, GOM is already FORCE_MAJEURE → escrow transitions NORMAL→FM →
//   confirmDelivery() then fails with "wrong state".
//
// Fix: gomFM is used for fmEscrow/GCIL/ASAP (FM triggered freely).
//      gomClean is used for `escrow` only (never triggered → always NORMAL).
//
// Run: npx hardhat test test/test_gas_benchmark_FIXED.js

const { ethers } = require("hardhat");

const ETH_USD  = 3000;
const GAS_GWEI = 15;

function usd(gas) {
  return "$" + (Number(gas) * GAS_GWEI * 1e-9 * ETH_USD).toFixed(4);
}

describe("GEOSUPPLY Gas Benchmark — Table III", function () {

  // Two GOM instances: gomClean stays NORMAL, gomFM is triggered freely
  let gomClean, gomFM;
  let escrow, fmEscrow, insurance, sanctions, gcil, asap, audit;
  let buyer, supplier, drc0, drc1, drc2, drc3, drc4;
  let aisOracle, sanctionsOracle, officer;

  const route    = ethers.keccak256(ethers.toUtf8Bytes("HORMUZ-GULF"));
  const vesselId = ethers.keccak256(ethers.toUtf8Bytes("MMSI-123456789"));
  const DRC_RAT  = "GOM confirmed FM. Non-fault. Supplier fulfilled pre-shipping.";

  before(async function () {
    this.timeout(120000);
    const signers = await ethers.getSigners();
    [buyer, supplier, drc0, drc1, drc2, drc3, drc4,
     aisOracle, sanctionsOracle, officer] = signers;

    const MockGOM = await ethers.getContractFactory("MockGOM");

    // ── gomClean: dedicated to `escrow` — NEVER triggered to FM ──────────
    gomClean = await MockGOM.deploy();
    await gomClean.waitForDeployment();

    // ── gomFM: shared by fmEscrow, GCIL, ASAP — FM triggered freely ──────
    gomFM = await MockGOM.deploy();
    await gomFM.waitForDeployment();

    const drcM = [drc0.address, drc1.address, drc2.address,
                  drc3.address, drc4.address];
    const dl = Math.floor(Date.now() / 1000) + 60 * 60 * 24 * 90;
    const TSE = await ethers.getContractFactory("TriStateEscrow");

    // ── NORMAL escrow: uses gomClean — state will always be NORMAL ────────
    escrow = await TSE.deploy(buyer.address, supplier.address,
      await gomClean.getAddress(), route, dl, drcM,
      { value: ethers.parseEther("1.0") });
    await escrow.waitForDeployment();

    // ── FM escrow: uses gomFM — trigger FM, deploy, transition, deposit ───
    await (await gomFM.triggerForceMajeure(route)).wait();
    fmEscrow = await TSE.deploy(buyer.address, supplier.address,
      await gomFM.getAddress(), route, dl, drcM,
      { value: ethers.parseEther("1.0") });
    await fmEscrow.waitForDeployment();
    await (await fmEscrow.checkAndTransition()).wait();
    await (await fmEscrow.connect(supplier).lockDeposit(
      { value: ethers.parseEther("0.15") })).wait();

    // ── Insurance: uses gomFM (FM still active on gomFM) ──────────────────
    const GRI = await ethers.getContractFactory("GeoRiskInsurance");
    insurance = await GRI.deploy(await gomFM.getAddress(), aisOracle.address);
    await insurance.waitForDeployment();
    await (await insurance.depositReserve({ value: ethers.parseEther("5.0") })).wait();

    // ── Sanctions: no GOM dependency ─────────────────────────────────────
    const SC = await ethers.getContractFactory("SanctionsCompliance");
    sanctions = await SC.deploy(sanctionsOracle.address, officer.address);
    await sanctions.waitForDeployment();

    // ── GCIL and ASAP: use gomFM (FM is already active) ──────────────────
    const GCILf = await ethers.getContractFactory("GCIL");
    gcil = await GCILf.deploy(await gomFM.getAddress());
    await gcil.waitForDeployment();

    const ASAPf = await ethers.getContractFactory("ASAP");
    asap = await ASAPf.deploy(await gomFM.getAddress());
    await asap.waitForDeployment();

    // ── ComplianceAudit: no GOM dependency ───────────────────────────────
    const CA = await ethers.getContractFactory("ComplianceAudit");
    audit = await CA.deploy();
    await audit.waitForDeployment();

    console.log("\n==========================================");
    console.log("  GEOSUPPLY GAS BENCHMARK — TABLE VI");
    console.log("  Solidity 0.8.20 | Hardhat EVM");
    console.log("  15 Gwei | ETH $3,000");
    console.log("==========================================\n");
  });

  // =========================================================
  // NORMAL STATE — escrow uses gomClean (always NORMAL)
  // =========================================================

  it("lockDeposit()", async function () {
    const r = await (await escrow.connect(supplier).lockDeposit(
      { value: ethers.parseEther("0.15") })).wait();
    console.log(`  lockDeposit():                        ${String(r.gasUsed).padStart(9)} gas  ${usd(r.gasUsed)}`);
  });

  // This now measures a TRUE no-state-change call: GOM=NORMAL, escrow=NORMAL
  // Expected: ~28,000–32,000 gas (just a view call + no event emitted)
  it("checkAndTransition() — NORMAL", async function () {
    const r = await (await escrow.checkAndTransition()).wait();
    console.log(`  checkAndTransition (NORMAL):          ${String(r.gasUsed).padStart(9)} gas  ${usd(r.gasUsed)}`);
  });

  // Now succeeds because escrow is still NORMAL (gomClean never triggered)
  it("confirmDelivery()", async function () {
    const r = await (await escrow.connect(buyer).confirmDelivery()).wait();
    console.log(`  confirmDelivery():                    ${String(r.gasUsed).padStart(9)} gas  ${usd(r.gasUsed)}`);
  });

  // =========================================================
  // FORCE MAJEURE STATE — fresh escrow against gomFM
  // =========================================================

  // Deploys a fresh escrow against gomFM (which is already FORCE_MAJEURE)
  // and immediately transitions — measures the NORMAL→FM transition cost
  it("checkAndTransition() — NORMAL->FM", async function () {
    const drcM = [drc0.address, drc1.address, drc2.address,
                  drc3.address, drc4.address];
    const dl = Math.floor(Date.now() / 1000) + 60 * 60 * 24 * 90;
    const TSE = await ethers.getContractFactory("TriStateEscrow");
    const fresh = await TSE.deploy(buyer.address, supplier.address,
      await gomFM.getAddress(), route, dl, drcM,
      { value: ethers.parseEther("1.0") });
    await fresh.waitForDeployment();
    const r = await (await fresh.checkAndTransition()).wait();
    console.log(`  checkAndTransition (NORMAL->FM):      ${String(r.gasUsed).padStart(9)} gas  ${usd(r.gasUsed)}`);
  });

  it("submitDRCVote() — vote 1/3", async function () {
    const r = await (await fmEscrow.connect(drc0).submitDRCVote(3000, DRC_RAT)).wait();
    console.log(`  submitDRCVote (1/3):                  ${String(r.gasUsed).padStart(9)} gas  ${usd(r.gasUsed)}`);
  });

  it("submitDRCVote() — vote 2/3", async function () {
    const r = await (await fmEscrow.connect(drc1).submitDRCVote(3000, DRC_RAT)).wait();
    console.log(`  submitDRCVote (2/3):                  ${String(r.gasUsed).padStart(9)} gas  ${usd(r.gasUsed)}`);
  });

  it("submitDRCVote() — vote 3/3 + execute ruling", async function () {
    const r = await (await fmEscrow.connect(drc2).submitDRCVote(3000, DRC_RAT)).wait();
    console.log(`  submitDRCVote (3/3 + execute):        ${String(r.gasUsed).padStart(9)} gas  ${usd(r.gasUsed)}`);
  });

  // =========================================================
  // LAYER 6 — Parametric Insurance
  // =========================================================

  it("depositReserve()", async function () {
    const r = await (await insurance.depositReserve(
      { value: ethers.parseEther("1.0") })).wait();
    console.log(`  depositReserve():                     ${String(r.gasUsed).padStart(9)} gas  ${usd(r.gasUsed)}`);
  });

  it("issuePolicy()", async function () {
    const pid = ethers.keccak256(ethers.toUtf8Bytes("POL-GAS-001"));
    const t = Math.floor(Date.now() / 1000);
    const r = await (await insurance.connect(buyer).issuePolicy(
      pid, route, vesselId, t, t + 60 * 60 * 24 * 20,
      { value: ethers.parseEther("0.1") })).wait();
    console.log(`  issuePolicy():                        ${String(r.gasUsed).padStart(9)} gas  ${usd(r.gasUsed)}`);
  });

  // =========================================================
  // LAYER 7 — Sanctions Compliance
  // =========================================================

  it("updateSanctionedAddress() — add", async function () {
    const r = await (await sanctions.connect(sanctionsOracle)
      .updateSanctionedAddress(drc4.address, true, "OFAC-SDN")).wait();
    console.log(`  updateSanctionedAddress (add):        ${String(r.gasUsed).padStart(9)} gas  ${usd(r.gasUsed)}`);
  });

  it("updateSanctionedAddress() — remove", async function () {
    const r = await (await sanctions.connect(sanctionsOracle)
      .updateSanctionedAddress(drc4.address, false, "OFAC-SDN")).wait();
    console.log(`  updateSanctionedAddress (remove):     ${String(r.gasUsed).padStart(9)} gas  ${usd(r.gasUsed)}`);
  });

  // =========================================================
  // LAYER 3 — GCIL ML Protection
  // =========================================================

  it("flagSupplierExclusion() — below threshold (<15pt)", async function () {
    const r = await (await gcil.flagSupplierExclusion(
      supplier.address, route,
      Math.floor(Date.now() / 1000) - 3600,
      10, 85)).wait();
    console.log(`  flagSupplierExclusion (<15pt):        ${String(r.gasUsed).padStart(9)} gas  ${usd(r.gasUsed)}`);
  });

  it("flagSupplierExclusion() — above threshold (>15pt, human review)", async function () {
    const r = await (await gcil.flagSupplierExclusion(
      buyer.address, route,
      Math.floor(Date.now() / 1000) - 3600,
      20, 91)).wait();
    console.log(`  flagSupplierExclusion (>15pt):        ${String(r.gasUsed).padStart(9)} gas  ${usd(r.gasUsed)}`);
  });

  // =========================================================
  // LAYER 5 — Alternative Supplier Activation
  // =========================================================

  it("activateAlternativeSupplier()", async function () {
    const top5 = [drc0.address, drc1.address, drc2.address,
                  drc3.address, drc4.address];
    const r = await (await asap.activateAlternativeSupplier(
      supplier.address, buyer.address,
      ethers.keccak256(ethers.toUtf8Bytes("ESCROW-001")),
      route, top5, 1)).wait();
    console.log(`  activateAlternativeSupplier():        ${String(r.gasUsed).padStart(9)} gas  ${usd(r.gasUsed)}`);
  });

  // =========================================================
  // LAYER 4 — ComplianceAudit DRC Ruling Log
  // =========================================================

  it("ComplianceAudit.logRuling()", async function () {
    const rid = ethers.keccak256(ethers.toUtf8Bytes("RULING-001"));
    const r = await (await audit.logRuling(
      rid,
      await fmEscrow.getAddress(),
      [drc0.address, drc1.address, drc2.address],
      3000,
      "GOM confirmed FM. Non-fault. Supplier fulfilled pre-shipping obligations.",
      ethers.keccak256(ethers.toUtf8Bytes("GOM-EVIDENCE-HORMUZ-2026")),
      3,
      "")).wait();
    console.log(`  ComplianceAudit.logRuling():          ${String(r.gasUsed).padStart(9)} gas  ${usd(r.gasUsed)}`);

    console.log("\n==========================================");
    console.log("  GAS BENCHMARK COMPLETE — 15 of 15");
    console.log("==========================================\n");
  });

});
