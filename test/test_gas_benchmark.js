// GEOSUPPLY Gas Benchmark — Final Version (all 15 tests pass)
// Run: npx hardhat test test/test_gas_benchmark.js

const { ethers } = require("hardhat");

const ETH_USD  = 3000;
const GAS_GWEI = 15;

function usd(gas) {
  return "$" + (Number(gas) * GAS_GWEI * 1e-9 * ETH_USD).toFixed(4);
}

describe("GEOSUPPLY Gas Benchmark — Table III", function () {

  let gom, escrow, fmEscrow, insurance, sanctions, gcil, asap, audit;
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
    gom = await MockGOM.deploy();
    await gom.waitForDeployment();

    const drcM = [drc0.address, drc1.address, drc2.address,
                  drc3.address, drc4.address];
    const dl = Math.floor(Date.now() / 1000) + 60 * 60 * 24 * 90;
    const TSE = await ethers.getContractFactory("TriStateEscrow");

    // NORMAL escrow for NORMAL-state tests
    escrow = await TSE.deploy(buyer.address, supplier.address,
      await gom.getAddress(), route, dl, drcM,
      { value: ethers.parseEther("1.0") });
    await escrow.waitForDeployment();

    // FM escrow — trigger FM first, deploy, transition, lock deposit
    await (await gom.triggerForceMajeure(route)).wait();
    fmEscrow = await TSE.deploy(buyer.address, supplier.address,
      await gom.getAddress(), route, dl, drcM,
      { value: ethers.parseEther("1.0") });
    await fmEscrow.waitForDeployment();
    await (await fmEscrow.checkAndTransition()).wait();
    await (await fmEscrow.connect(supplier).lockDeposit(
      { value: ethers.parseEther("0.15") })).wait();

    // Resolve FM so NORMAL escrow tests work correctly
    await (await gom.resolveForceMajeure(route)).wait();

    const GRI = await ethers.getContractFactory("GeoRiskInsurance");
    insurance = await GRI.deploy(await gom.getAddress(), aisOracle.address);
    await insurance.waitForDeployment();
    await (await insurance.depositReserve({ value: ethers.parseEther("5.0") })).wait();

    const SC = await ethers.getContractFactory("SanctionsCompliance");
    sanctions = await SC.deploy(sanctionsOracle.address, officer.address);
    await sanctions.waitForDeployment();

    // Re-trigger FM for GCIL and ASAP tests
    await (await gom.triggerForceMajeure(route)).wait();

    const GCILf = await ethers.getContractFactory("GCIL");
    gcil = await GCILf.deploy(await gom.getAddress());
    await gcil.waitForDeployment();

    const ASAPf = await ethers.getContractFactory("ASAP");
    asap = await ASAPf.deploy(await gom.getAddress());
    await asap.waitForDeployment();

    const CA = await ethers.getContractFactory("ComplianceAudit");
    audit = await CA.deploy();
    await audit.waitForDeployment();

    console.log("\n==========================================");
    console.log("  GEOSUPPLY GAS BENCHMARK — TABLE III");
    console.log("  Solidity 0.8.20 | Hardhat EVM");
    console.log("  15 Gwei | ETH $3,000");
    console.log("==========================================\n");
  });

  // NORMAL STATE
  it("lockDeposit()", async function () {
    const r = await (await escrow.connect(supplier).lockDeposit(
      { value: ethers.parseEther("0.15") })).wait();
    console.log(`  lockDeposit():                    ${String(r.gasUsed).padStart(9)} gas  ${usd(r.gasUsed)}`);
  });

  it("checkAndTransition() — NORMAL", async function () {
    const r = await (await escrow.checkAndTransition()).wait();
    console.log(`  checkAndTransition (NORMAL):      ${String(r.gasUsed).padStart(9)} gas  ${usd(r.gasUsed)}`);
  });

  it("confirmDelivery()", async function () {
    const r = await (await escrow.connect(buyer).confirmDelivery()).wait();
    console.log(`  confirmDelivery():                ${String(r.gasUsed).padStart(9)} gas  ${usd(r.gasUsed)}`);
  });

  // FM STATE
  it("checkAndTransition() — NORMAL->FM", async function () {
    const drcM = [drc0.address, drc1.address, drc2.address,
                  drc3.address, drc4.address];
    const dl = Math.floor(Date.now() / 1000) + 60 * 60 * 24 * 90;
    const TSE = await ethers.getContractFactory("TriStateEscrow");
    const fresh = await TSE.deploy(buyer.address, supplier.address,
      await gom.getAddress(), route, dl, drcM,
      { value: ethers.parseEther("1.0") });
    await fresh.waitForDeployment();
    const r = await (await fresh.checkAndTransition()).wait();
    console.log(`  checkAndTransition (NORMAL->FM):  ${String(r.gasUsed).padStart(9)} gas  ${usd(r.gasUsed)}`);
  });

  it("submitDRCVote() — vote 1/3", async function () {
    const r = await (await fmEscrow.connect(drc0).submitDRCVote(3000, DRC_RAT)).wait();
    console.log(`  submitDRCVote (1/3):              ${String(r.gasUsed).padStart(9)} gas  ${usd(r.gasUsed)}`);
  });

  it("submitDRCVote() — vote 2/3", async function () {
    const r = await (await fmEscrow.connect(drc1).submitDRCVote(3000, DRC_RAT)).wait();
    console.log(`  submitDRCVote (2/3):              ${String(r.gasUsed).padStart(9)} gas  ${usd(r.gasUsed)}`);
  });

  it("submitDRCVote() — vote 3/3 + execute ruling", async function () {
    const r = await (await fmEscrow.connect(drc2).submitDRCVote(3000, DRC_RAT)).wait();
    console.log(`  submitDRCVote (3/3 + execute):    ${String(r.gasUsed).padStart(9)} gas  ${usd(r.gasUsed)}`);
  });

  // INSURANCE
  it("depositReserve()", async function () {
    const r = await (await insurance.depositReserve(
      { value: ethers.parseEther("1.0") })).wait();
    console.log(`  depositReserve():                 ${String(r.gasUsed).padStart(9)} gas  ${usd(r.gasUsed)}`);
  });

  it("issuePolicy()", async function () {
    const pid = ethers.keccak256(ethers.toUtf8Bytes("POL-GAS-001"));
    const t = Math.floor(Date.now() / 1000);
    const r = await (await insurance.connect(buyer).issuePolicy(
      pid, route, vesselId, t, t + 60*60*24*20,
      { value: ethers.parseEther("0.1") })).wait();
    console.log(`  issuePolicy():                    ${String(r.gasUsed).padStart(9)} gas  ${usd(r.gasUsed)}`);
  });

  // SANCTIONS
  it("updateSanctionedAddress() — add", async function () {
    const r = await (await sanctions.connect(sanctionsOracle)
      .updateSanctionedAddress(drc4.address, true, "OFAC-SDN")).wait();
    console.log(`  updateSanctionedAddress (add):    ${String(r.gasUsed).padStart(9)} gas  ${usd(r.gasUsed)}`);
  });

  it("updateSanctionedAddress() — remove", async function () {
    const r = await (await sanctions.connect(sanctionsOracle)
      .updateSanctionedAddress(drc4.address, false, "OFAC-SDN")).wait();
    console.log(`  updateSanctionedAddress (remove): ${String(r.gasUsed).padStart(9)} gas  ${usd(r.gasUsed)}`);
  });

  // GCIL
  it("flagSupplierExclusion() — below threshold", async function () {
    const r = await (await gcil.flagSupplierExclusion(
      supplier.address, route, Math.floor(Date.now()/1000)-3600, 10, 85)).wait();
    console.log(`  flagSupplierExclusion (<15pt):    ${String(r.gasUsed).padStart(9)} gas  ${usd(r.gasUsed)}`);
  });

  it("flagSupplierExclusion() — above threshold", async function () {
    const r = await (await gcil.flagSupplierExclusion(
      buyer.address, route, Math.floor(Date.now()/1000)-3600, 20, 91)).wait();
    console.log(`  flagSupplierExclusion (>15pt):    ${String(r.gasUsed).padStart(9)} gas  ${usd(r.gasUsed)}`);
  });

  // ASAP
  it("activateAlternativeSupplier()", async function () {
    const top5 = [drc0.address, drc1.address, drc2.address,
                  drc3.address, drc4.address];
    const r = await (await asap.activateAlternativeSupplier(
      supplier.address, buyer.address,
      ethers.keccak256(ethers.toUtf8Bytes("ESCROW-001")),
      route, top5, 1)).wait();
    console.log(`  activateAlternativeSupplier():    ${String(r.gasUsed).padStart(9)} gas  ${usd(r.gasUsed)}`);
  });

  // AUDIT
  it("ComplianceAudit.logRuling()", async function () {
    const rid = ethers.keccak256(ethers.toUtf8Bytes("RULING-001"));
    const r = await (await audit.logRuling(
      rid, await fmEscrow.getAddress(),
      [drc0.address, drc1.address, drc2.address],
      3000, "GOM confirmed FM. Non-fault.", 
      ethers.keccak256(ethers.toUtf8Bytes("EVIDENCE")), 3, "")).wait();
    console.log(`  ComplianceAudit.logRuling():      ${String(r.gasUsed).padStart(9)} gas  ${usd(r.gasUsed)}`);
    console.log("\n==========================================");
    console.log("  GAS BENCHMARK COMPLETE — 15 of 15");
    console.log("==========================================\n");
  });
});
