// GEOSUPPLY Gas Benchmark — Simplified for GitHub Actions
// Measures actual gas used for each operation

const { ethers } = require("hardhat");

const ETH_USD  = 3000;
const GAS_GWEI = 15;

function usd(gas) {
  return "$" + (Number(gas) * GAS_GWEI * 1e-9 * ETH_USD).toFixed(4);
}

describe("GEOSUPPLY Gas Benchmark — Table III", function () {

  let gom, escrow, insurance, sanctions, gcil, asap, audit;
  let buyer, supplier, drc0, drc1, drc2, drc3, drc4;
  let aisOracle, sanctionsOracle, officer;

  const route    = ethers.keccak256(ethers.toUtf8Bytes("HORMUZ-GULF"));
  const vesselId = ethers.keccak256(ethers.toUtf8Bytes("MMSI-123456789"));

  before(async function () {
    this.timeout(120000);
    const signers = await ethers.getSigners();
    [buyer, supplier, drc0, drc1, drc2, drc3, drc4,
     aisOracle, sanctionsOracle, officer] = signers;

    const MockGOM = await ethers.getContractFactory("MockGOM");
    gom = await MockGOM.deploy();
    await gom.waitForDeployment();

    const drcMembers = [drc0.address, drc1.address, drc2.address,
                        drc3.address, drc4.address];
    const deadline = Math.floor(Date.now() / 1000) + 60 * 60 * 24 * 90;

    const TriStateEscrow = await ethers.getContractFactory("TriStateEscrow");
    escrow = await TriStateEscrow.deploy(
      buyer.address, supplier.address,
      await gom.getAddress(),
      route, deadline, drcMembers,
      { value: ethers.parseEther("1.0") }
    );
    await escrow.waitForDeployment();

    const GeoRiskInsurance = await ethers.getContractFactory("GeoRiskInsurance");
    insurance = await GeoRiskInsurance.deploy(
      await gom.getAddress(), aisOracle.address
    );
    await insurance.waitForDeployment();
    await (await insurance.depositReserve({ value: ethers.parseEther("5.0") })).wait();

    const SanctionsCompliance = await ethers.getContractFactory("SanctionsCompliance");
    sanctions = await SanctionsCompliance.deploy(
      sanctionsOracle.address, officer.address
    );
    await sanctions.waitForDeployment();
    await (await sanctions.authorizePaymentContract(await escrow.getAddress(), true)).wait();

    const GCIL = await ethers.getContractFactory("GCIL");
    gcil = await GCIL.deploy(await gom.getAddress());
    await gcil.waitForDeployment();

    const ASAP = await ethers.getContractFactory("ASAP");
    asap = await ASAP.deploy(await gom.getAddress());
    await asap.waitForDeployment();

    const ComplianceAudit = await ethers.getContractFactory("ComplianceAudit");
    audit = await ComplianceAudit.deploy();
    await audit.waitForDeployment();

    console.log("\n==========================================");
    console.log("  GEOSUPPLY GAS BENCHMARK — TABLE III");
    console.log("  15 Gwei | ETH $3,000");
    console.log("==========================================\n");
  });

  // ── NORMAL STATE ──────────────────────────────────────
  it("lockDeposit()", async function () {
    const tx = await escrow.connect(supplier).lockDeposit(
      { value: ethers.parseEther("0.15") }
    );
    const r = await tx.wait();
    console.log(`  lockDeposit():                    ${r.gasUsed.toLocaleString().padStart(9)} gas  ${usd(r.gasUsed)}`);
  });

  it("checkAndTransition() — NORMAL", async function () {
    const tx = await escrow.checkAndTransition();
    const r = await tx.wait();
    console.log(`  checkAndTransition (NORMAL):      ${r.gasUsed.toLocaleString().padStart(9)} gas  ${usd(r.gasUsed)}`);
  });

  it("confirmDelivery()", async function () {
    const drcMembers = [drc0.address, drc1.address, drc2.address,
                        drc3.address, drc4.address];
    const deadline = Math.floor(Date.now() / 1000) + 60 * 60 * 24 * 90;
    const TriStateEscrow = await ethers.getContractFactory("TriStateEscrow");
    const fresh = await TriStateEscrow.deploy(
      buyer.address, supplier.address, await gom.getAddress(),
      route, deadline, drcMembers,
      { value: ethers.parseEther("1.0") }
    );
    await fresh.waitForDeployment();
    await (await fresh.connect(supplier).lockDeposit(
      { value: ethers.parseEther("0.15") }
    )).wait();
    const tx = await fresh.connect(buyer).confirmDelivery();
    const r = await tx.wait();
    console.log(`  confirmDelivery():                ${r.gasUsed.toLocaleString().padStart(9)} gas  ${usd(r.gasUsed)}`);
  });

  // ── FORCE MAJEURE STATE ───────────────────────────────
  it("checkAndTransition() — NORMAL→FM", async function () {
    const drcMembers = [drc0.address, drc1.address, drc2.address,
                        drc3.address, drc4.address];
    const deadline = Math.floor(Date.now() / 1000) + 60 * 60 * 24 * 90;
    const TriStateEscrow = await ethers.getContractFactory("TriStateEscrow");
    const fresh = await TriStateEscrow.deploy(
      buyer.address, supplier.address, await gom.getAddress(),
      route, deadline, drcMembers,
      { value: ethers.parseEther("1.0") }
    );
    await fresh.waitForDeployment();
    await (await gom.triggerForceMajeure(route)).wait();
    const tx = await fresh.checkAndTransition();
    const r = await tx.wait();
    console.log(`  checkAndTransition (NORMAL->FM):  ${r.gasUsed.toLocaleString().padStart(9)} gas  ${usd(r.gasUsed)}`);
  });

  it("submitDRCVote() — vote 1/3", async function () {
    const rat = "GOM confirmed FM. Non-fault. Supplier fulfilled pre-shipping.";
    const tx = await escrow.connect(drc0).submitDRCVote(3000, rat);
    const r = await tx.wait();
    console.log(`  submitDRCVote (1/3):              ${r.gasUsed.toLocaleString().padStart(9)} gas  ${usd(r.gasUsed)}`);
  });

  it("submitDRCVote() — vote 2/3", async function () {
    const rat = "GOM confirmed FM. Non-fault. Supplier fulfilled pre-shipping.";
    const tx = await escrow.connect(drc1).submitDRCVote(3000, rat);
    const r = await tx.wait();
    console.log(`  submitDRCVote (2/3):              ${r.gasUsed.toLocaleString().padStart(9)} gas  ${usd(r.gasUsed)}`);
  });

  it("submitDRCVote() — vote 3/3 + execute ruling", async function () {
    const rat = "GOM confirmed FM. Non-fault. Supplier fulfilled pre-shipping.";
    const tx = await escrow.connect(drc2).submitDRCVote(3000, rat);
    const r = await tx.wait();
    console.log(`  submitDRCVote (3/3 + execute):    ${r.gasUsed.toLocaleString().padStart(9)} gas  ${usd(r.gasUsed)}`);
  });

  // ── INSURANCE ────────────────────────────────────────
  it("depositReserve()", async function () {
    const tx = await insurance.depositReserve({ value: ethers.parseEther("1.0") });
    const r = await tx.wait();
    console.log(`  depositReserve():                 ${r.gasUsed.toLocaleString().padStart(9)} gas  ${usd(r.gasUsed)}`);
  });

  it("issuePolicy()", async function () {
    const policyId = ethers.keccak256(ethers.toUtf8Bytes("POL-GAS-001"));
    const transit  = Math.floor(Date.now() / 1000);
    const delivery = transit + 60 * 60 * 24 * 20;
    const tx = await insurance.connect(buyer).issuePolicy(
      policyId, route, vesselId, transit, delivery,
      { value: ethers.parseEther("0.1") }
    );
    const r = await tx.wait();
    console.log(`  issuePolicy():                    ${r.gasUsed.toLocaleString().padStart(9)} gas  ${usd(r.gasUsed)}`);
  });

  // ── SANCTIONS ────────────────────────────────────────
  it("updateSanctionedAddress() — add", async function () {
    const tx = await sanctions.connect(sanctionsOracle)
      .updateSanctionedAddress(drc4.address, true, "OFAC-SDN");
    const r = await tx.wait();
    console.log(`  updateSanctionedAddress (add):    ${r.gasUsed.toLocaleString().padStart(9)} gas  ${usd(r.gasUsed)}`);
  });

  it("updateSanctionedAddress() — remove", async function () {
    const tx = await sanctions.connect(sanctionsOracle)
      .updateSanctionedAddress(drc4.address, false, "OFAC-SDN");
    const r = await tx.wait();
    console.log(`  updateSanctionedAddress (remove): ${r.gasUsed.toLocaleString().padStart(9)} gas  ${usd(r.gasUsed)}`);
  });

  // ── GCIL ─────────────────────────────────────────────
  it("flagSupplierExclusion() — below threshold", async function () {
    const tx = await gcil.flagSupplierExclusion(
      supplier.address, route,
      Math.floor(Date.now() / 1000) - 3600,
      10, 85
    );
    const r = await tx.wait();
    console.log(`  flagSupplierExclusion (<15pt):    ${r.gasUsed.toLocaleString().padStart(9)} gas  ${usd(r.gasUsed)}`);
  });

  it("flagSupplierExclusion() — above threshold (HumanReview)", async function () {
    const tx = await gcil.flagSupplierExclusion(
      buyer.address, route,
      Math.floor(Date.now() / 1000) - 3600,
      20, 91
    );
    const r = await tx.wait();
    console.log(`  flagSupplierExclusion (>15pt):    ${r.gasUsed.toLocaleString().padStart(9)} gas  ${usd(r.gasUsed)}`);
  });

  // ── ASAP ─────────────────────────────────────────────
  it("activateAlternativeSupplier()", async function () {
    const top5 = [drc0.address, drc1.address, drc2.address,
                  drc3.address, drc4.address];
    const tx = await asap.activateAlternativeSupplier(
      supplier.address, buyer.address,
      ethers.keccak256(ethers.toUtf8Bytes("ESCROW-GAS-001")),
      route, top5, 1
    );
    const r = await tx.wait();
    console.log(`  activateAlternativeSupplier():    ${r.gasUsed.toLocaleString().padStart(9)} gas  ${usd(r.gasUsed)}`);
  });

  // ── AUDIT ────────────────────────────────────────────
  it("ComplianceAudit.logRuling()", async function () {
    const rulingId = ethers.keccak256(ethers.toUtf8Bytes("RULING-GAS-001"));
    const tx = await audit.logRuling(
      rulingId, await escrow.getAddress(),
      [drc0.address, drc1.address, drc2.address],
      3000,
      "GOM confirmed FM. Non-fault. Pre-shipping fulfilled.",
      ethers.keccak256(ethers.toUtf8Bytes("EVIDENCE")),
      3, ""
    );
    const r = await tx.wait();
    console.log(`  ComplianceAudit.logRuling():      ${r.gasUsed.toLocaleString().padStart(9)} gas  ${usd(r.gasUsed)}`);
    console.log("\n==========================================");
    console.log("  GAS BENCHMARK COMPLETE");
    console.log("==========================================\n");
  });
});
