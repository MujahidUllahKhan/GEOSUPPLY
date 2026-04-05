// GEOSUPPLY — Comprehensive Test Suite
// Tests all contracts and validates paper claims
// Run: npx hardhat test

const { expect } = require("chai");
const { ethers }  = require("hardhat");

describe("GEOSUPPLY — Full Contract Test Suite", function () {

  // Contracts
  let gom, escrow, insurance, sanctions, audit, gcil, asap;

  // Signers
  let buyer, supplier;
  let drcMember0, drcMember1, drcMember2, drcMember3, drcMember4;
  let aisOracle, sanctionsOracle, officer;
  let outsider;

  // Constants
  const route    = ethers.keccak256(ethers.toUtf8Bytes("HORMUZ-GULF"));
  const vesselId = ethers.keccak256(ethers.toUtf8Bytes("MMSI-123456789"));
  const DEFAULT_EVIDENCE = ethers.keccak256(ethers.toUtf8Bytes("MOCK-GEOSUPPLY-EVIDENCE-2026"));

  before(async function () {
    const signers = await ethers.getSigners();
    [
      buyer, supplier,
      drcMember0, drcMember1, drcMember2, drcMember3, drcMember4,
      aisOracle, sanctionsOracle, officer, outsider
    ] = signers;

    // Deploy MockGOM
    const MockGOM = await ethers.getContractFactory("MockGOM");
    gom = await MockGOM.deploy();

    // Deploy ComplianceAudit
    const ComplianceAudit = await ethers.getContractFactory("ComplianceAudit");
    audit = await ComplianceAudit.deploy();

    // Deploy TriStateEscrow with 5 DRC members
    const deadline = Math.floor(Date.now() / 1000) + 60 * 60 * 24 * 90;
    const drcMembers = [
      drcMember0.address,
      drcMember1.address,
      drcMember2.address,
      drcMember3.address,
      drcMember4.address
    ];
    const TriStateEscrow = await ethers.getContractFactory("TriStateEscrow");
    escrow = await TriStateEscrow.deploy(
      buyer.address, supplier.address,
      await gom.getAddress(),
      route, deadline, drcMembers,
      { value: ethers.parseEther("1.0") }
    );

    // Deploy GeoRiskInsurance
    const GeoRiskInsurance = await ethers.getContractFactory("GeoRiskInsurance");
    insurance = await GeoRiskInsurance.deploy(
      await gom.getAddress(), aisOracle.address
    );
    // Fund reserve: 5 ETH
    await insurance.depositReserve({ value: ethers.parseEther("5.0") });

    // Deploy SanctionsCompliance
    const SanctionsCompliance = await ethers.getContractFactory("SanctionsCompliance");
    sanctions = await SanctionsCompliance.deploy(
      sanctionsOracle.address, officer.address
    );
    // Authorize TriStateEscrow
    await sanctions.authorizePaymentContract(await escrow.getAddress(), true);

    // Deploy GCIL
    const GCIL = await ethers.getContractFactory("GCIL");
    gcil = await GCIL.deploy(await gom.getAddress());

    // Deploy ASAP
    const ASAP = await ethers.getContractFactory("ASAP");
    asap = await ASAP.deploy(await gom.getAddress());
  });

  // ===========================================================
  // IGOM Interface
  // ===========================================================
  describe("IGOM / MockGOM — Layer 1", function () {

    it("checkZone() returns NORMAL by default", async function () {
      const [status] = await gom.checkZone(route, Math.floor(Date.now() / 1000));
      expect(status).to.equal(0); // NORMAL = 0
      const receipt = await (await gom.checkZone.staticCall(route, 0)).toString();
    });

    it("triggerForceMajeure() transitions route to FORCE_MAJEURE", async function () {
      await gom.triggerForceMajeure(route);
      const [status, evHash] = await gom.checkZone(route, Math.floor(Date.now() / 1000));
      expect(status).to.equal(2); // FORCE_MAJEURE = 2
      expect(evHash).to.not.equal(ethers.ZeroHash);
    });

    it("getEventHash() returns evidence hash", async function () {
      const hash = await gom.getEventHash(route, Math.floor(Date.now() / 1000));
      expect(hash).to.not.equal(ethers.ZeroHash);
    });

    it("resolveForceMajeure() transitions back to NORMAL", async function () {
      await gom.resolveForceMajeure(route);
      const [status] = await gom.checkZone(route, Math.floor(Date.now() / 1000));
      expect(status).to.equal(0); // NORMAL = 0
    });

    it("getResolutionDate() returns non-zero after resolution", async function () {
      const resDate = await gom.getResolutionDate(route);
      expect(resDate).to.be.gt(0);
    });
  });

  // ===========================================================
  // TriStateEscrow — Normal State
  // ===========================================================
  describe("TriStateEscrow — NORMAL State", function () {

    before(async function () {
      // Ensure NORMAL state for these tests
      await gom.resolveForceMajeure(route);
    });

    it("checkAndTransition() — gas measurement (NORMAL)", async function () {
      const tx = await escrow.checkAndTransition();
      const receipt = await tx.wait();
      console.log("    checkAndTransition (NORMAL):", receipt.gasUsed.toString(), "gas");
      expect(receipt.gasUsed).to.be.gt(0);
    });

    it("lockDeposit() — supplier locks 0.15 ETH security deposit", async function () {
      const tx = await escrow.connect(supplier).lockDeposit(
        { value: ethers.parseEther("0.15") }
      );
      const receipt = await tx.wait();
      console.log("    lockDeposit:", receipt.gasUsed.toString(), "gas");
      expect(await escrow.securityDeposit()).to.equal(ethers.parseEther("0.15"));
    });

    it("activeDeadline() returns original deadline before FM", async function () {
      const deadline = await escrow.activeDeadline();
      expect(deadline).to.be.gt(Math.floor(Date.now() / 1000));
    });

    it("confirmDelivery() — releases full payment to supplier", async function () {
      const supplierBefore = await ethers.provider.getBalance(supplier.address);
      const tx = await escrow.connect(buyer).confirmDelivery();
      const receipt = await tx.wait();
      console.log("    confirmDelivery:", receipt.gasUsed.toString(), "gas");
      const supplierAfter = await ethers.provider.getBalance(supplier.address);
      expect(supplierAfter).to.be.gt(supplierBefore);
    });
  });

  // ===========================================================
  // TriStateEscrow — Force Majeure State
  // ===========================================================
  describe("TriStateEscrow — FORCE_MAJEURE State and DRC", function () {
    let escrow2;

    before(async function () {
      // Deploy a fresh escrow for FM tests
      const deadline = Math.floor(Date.now() / 1000) + 60 * 60 * 24 * 90;
      const drcMembers = [
        drcMember0.address, drcMember1.address, drcMember2.address,
        drcMember3.address, drcMember4.address
      ];
      const TriStateEscrow = await ethers.getContractFactory("TriStateEscrow");
      escrow2 = await TriStateEscrow.deploy(
        buyer.address, supplier.address,
        await gom.getAddress(),
        route, deadline, drcMembers,
        { value: ethers.parseEther("1.0") }
      );

      // Lock deposit
      await escrow2.connect(supplier).lockDeposit({ value: ethers.parseEther("0.15") });

      // Set route to FORCE_MAJEURE
      await gom.triggerForceMajeure(route);
      await escrow2.checkAndTransition();
    });

    it("State transitions to FORCE_MAJEURE after GOM trigger", async function () {
      expect(await escrow2.currentState()).to.equal(1); // FORCE_MAJEURE = 1
    });

    it("applyPenalty() reverts in FORCE_MAJEURE — core GEOSUPPLY protection", async function () {
      await expect(
        escrow2.connect(buyer).applyPenalty()
      ).to.be.revertedWith("TriStateEscrow: wrong state");
    });

    it("submitDRCVote() — first vote (1-of-3)", async function () {
      const rationale = "GOM confirmed FM; supplier fulfilled pre-shipping obligations; non-fault";
      const tx = await escrow2.connect(drcMember0).submitDRCVote(3000, rationale);
      const receipt = await tx.wait();
      console.log("    submitDRCVote (vote 1):", receipt.gasUsed.toString(), "gas");
      const [count] = await escrow2.getDRCVoteCount(3000, rationale);
      expect(count).to.equal(1);
    });

    it("submitDRCVote() — second vote (2-of-3)", async function () {
      const rationale = "GOM confirmed FM; supplier fulfilled pre-shipping obligations; non-fault";
      const tx = await escrow2.connect(drcMember1).submitDRCVote(3000, rationale);
      const receipt = await tx.wait();
      console.log("    submitDRCVote (vote 2):", receipt.gasUsed.toString(), "gas");
      const [count] = await escrow2.getDRCVoteCount(3000, rationale);
      expect(count).to.equal(2);
    });

    it("submitDRCVote() — third vote executes ruling (3-of-3)", async function () {
      const rationale = "GOM confirmed FM; supplier fulfilled pre-shipping obligations; non-fault";
      const supplierBefore = await ethers.provider.getBalance(supplier.address);
      const tx = await escrow2.connect(drcMember2).submitDRCVote(3000, rationale);
      const receipt = await tx.wait();
      console.log("    submitDRCVote (vote 3 — executes):", receipt.gasUsed.toString(), "gas");

      // State should now be PARTIAL
      expect(await escrow2.currentState()).to.equal(2); // PARTIAL = 2

      // Supplier received 30% of 1 ETH
      const supplierAfter = await ethers.provider.getBalance(supplier.address);
      expect(supplierAfter).to.be.gt(supplierBefore);
    });

    it("outsider cannot vote — not a DRC member", async function () {
      const TriStateEscrow = await ethers.getContractFactory("TriStateEscrow");
      const escrow3 = await TriStateEscrow.deploy(
        buyer.address, supplier.address, await gom.getAddress(),
        route, Math.floor(Date.now() / 1000) + 86400,
        [drcMember0.address, drcMember1.address, drcMember2.address,
         drcMember3.address, drcMember4.address],
        { value: ethers.parseEther("1.0") }
      );
      await escrow3.checkAndTransition(); // Should be FM since GOM is still FM
      await expect(
        escrow3.connect(outsider).submitDRCVote(5000, "outsider rationale")
      ).to.be.revertedWith("TriStateEscrow: not a DRC member");
    });

    it("duplicate DRC vote reverts", async function () {
      // drcMember0 already voted on the executed ruling
      // Need new escrow for this test
      const TriStateEscrow = await ethers.getContractFactory("TriStateEscrow");
      const escrow4 = await TriStateEscrow.deploy(
        buyer.address, supplier.address, await gom.getAddress(),
        route, Math.floor(Date.now() / 1000) + 86400,
        [drcMember0.address, drcMember1.address, drcMember2.address,
         drcMember3.address, drcMember4.address],
        { value: ethers.parseEther("1.0") }
      );
      await escrow4.checkAndTransition();
      await escrow4.connect(drcMember0).submitDRCVote(5000, "unique rationale ABC");
      await expect(
        escrow4.connect(drcMember0).submitDRCVote(5000, "unique rationale ABC")
      ).to.be.revertedWith("TriStateEscrow: member already voted on this proposal");
    });
  });

  // ===========================================================
  // GeoRiskInsurance — Layer 6
  // ===========================================================
  describe("GeoRiskInsurance — Layer 6", function () {

    it("depositReserve() — gas measurement", async function () {
      const tx = await insurance.depositReserve({ value: ethers.parseEther("1.0") });
      const receipt = await tx.wait();
      console.log("    depositReserve:", receipt.gasUsed.toString(), "gas");
    });

    it("issuePolicy() — policyholder buys war-risk coverage", async function () {
      const policyId = ethers.keccak256(ethers.toUtf8Bytes("POL-001"));
      const transit  = Math.floor(Date.now() / 1000);
      const delivery = transit + 60 * 60 * 24 * 20;

      const reserveBefore = await insurance.reserveBalance();
      const tx = await insurance.connect(buyer).issuePolicy(
        policyId, route, vesselId, transit, delivery,
        { value: ethers.parseEther("0.1") }
      );
      const receipt = await tx.wait();
      console.log("    issuePolicy:", receipt.gasUsed.toString(), "gas");

      // Reserve: committed 0.1*10=1 ETH, added 0.1 ETH premium
      // Net change = -1 + 0.1 = -0.9 ETH
      const reserveAfter = await insurance.reserveBalance();
      const diff = reserveBefore - reserveAfter;
      expect(diff).to.equal(ethers.parseEther("0.9"));
    });

    it("issuePolicy() fails with insufficient reserve", async function () {
      // Try to issue a policy when reserve < insuredValue
      // reserveBalance is ~5.1 ETH; insuredValue for 1 ETH premium = 10 ETH
      const policyId = ethers.keccak256(ethers.toUtf8Bytes("POL-TOOBIG"));
      const transit  = Math.floor(Date.now() / 1000);
      const delivery = transit + 86400;
      await expect(
        insurance.connect(buyer).issuePolicy(
          policyId, route, vesselId, transit, delivery,
          { value: ethers.parseEther("1.0") }  // insuredValue=10 ETH, reserve<10
        )
      ).to.be.revertedWith("GeoRiskInsurance: insufficient reserve");
    });
  });

  // ===========================================================
  // SanctionsCompliance — Layer 7
  // ===========================================================
  describe("SanctionsCompliance — Layer 7", function () {

    it("updateSanctionedAddress() — oracle updates list", async function () {
      const tx = await sanctions.connect(sanctionsOracle)
        .updateSanctionedAddress(outsider.address, true, "OFAC-SDN");
      const receipt = await tx.wait();
      console.log("    updateSanctionedAddress:", receipt.gasUsed.toString(), "gas");
      expect(await sanctions.isAddressSanctioned(outsider.address)).to.be.true;
    });

    it("isAddressSanctioned() returns false for clean address", async function () {
      expect(await sanctions.isAddressSanctioned(buyer.address)).to.be.false;
    });

    it("unauthorizedContract cannot call screenAndPay()", async function () {
      await expect(
        sanctions.connect(outsider).screenAndPay(
          buyer.address, buyer.address,
          { value: ethers.parseEther("0.1") }
        )
      ).to.be.revertedWith("SanctionsCompliance: caller not authorized payment contract");
    });

    it("updateSanctionedAddress() clears address from list", async function () {
      await sanctions.connect(sanctionsOracle)
        .updateSanctionedAddress(outsider.address, false, "OFAC-SDN");
      expect(await sanctions.isAddressSanctioned(outsider.address)).to.be.false;
    });
  });

  // ===========================================================
  // ComplianceAudit
  // ===========================================================
  describe("ComplianceAudit — DRC Ruling Log", function () {

    it("logRuling() — records DRC ruling on-chain", async function () {
      const rulingId = ethers.keccak256(ethers.toUtf8Bytes("RULING-001"));
      const voters   = [drcMember0.address, drcMember1.address, drcMember2.address];

      const tx = await audit.logRuling(
        rulingId,
        await escrow.getAddress(),
        voters,
        3000,   // 30% to supplier
        "GOM confirmed FM. Supplier fulfilled pre-shipping. Non-fault ruling.",
        DEFAULT_EVIDENCE,
        3,      // 3-of-5 votes
        ""      // No dissenting opinion
      );
      const receipt = await tx.wait();
      console.log("    logRuling:", receipt.gasUsed.toString(), "gas");

      const record = await audit.getAuditRecord(rulingId);
      expect(record.supplierBasisPoints).to.equal(3000);
      expect(record.votesApproved).to.equal(3);
      expect(record.recordedAt).to.be.gt(0);
    });

    it("logRuling() reverts for duplicate rulingId", async function () {
      const rulingId = ethers.keccak256(ethers.toUtf8Bytes("RULING-001"));
      const voters   = [drcMember0.address, drcMember1.address, drcMember2.address];
      await expect(
        audit.logRuling(rulingId, await escrow.getAddress(), voters, 3000,
                        "duplicate", DEFAULT_EVIDENCE, 3, "")
      ).to.be.revertedWith("ComplianceAudit: ruling already recorded");
    });
  });

  // ===========================================================
  // GCIL — Layer 3
  // ===========================================================
  describe("GCIL — Layer 3 (ML Context Injection)", function () {

    before(async function () {
      // Ensure FM is active for GCIL tests
      await gom.triggerForceMajeure(route);
    });

    it("flagSupplierExclusion() — emits PerformanceExclusionEvent", async function () {
      const tx = await gcil.flagSupplierExclusion(
        supplier.address,
        route,
        Math.floor(Date.now() / 1000) - 3600, // FM started 1 hour ago
        10,   // 10 percentile point demotion (below 15pt threshold)
        85    // Current rank: 85th percentile
      );
      const receipt = await tx.wait();
      console.log("    flagSupplierExclusion:", receipt.gasUsed.toString(), "gas");

      // Check PerformanceExclusionEvent was emitted
      const events = await gcil.queryFilter(gcil.filters.PerformanceExclusionEvent());
      expect(events.length).to.be.gt(0);
    });

    it("flagSupplierExclusion() emits HumanReviewRequired when demotion > 15pt", async function () {
      const tx = await gcil.flagSupplierExclusion(
        supplier.address,
        route,
        Math.floor(Date.now() / 1000) - 3600,
        20,   // 20 percentile point demotion — exceeds 15pt threshold
        91    // Current rank: 91st percentile
      );
      const receipt = await tx.wait();

      const events = await gcil.queryFilter(gcil.filters.HumanReviewRequired());
      expect(events.length).to.be.gt(0);
      const ev = events[events.length - 1];
      expect(ev.args.proposedDemotionPct).to.equal(20);
    });

    it("flagSupplierExclusion() reverts when route not under FM", async function () {
      await gom.resolveForceMajeure(route);
      await expect(
        gcil.flagSupplierExclusion(supplier.address, route,
          Math.floor(Date.now() / 1000), 5, 80)
      ).to.be.revertedWith("GCIL: route not under FORCE_MAJEURE");
    });
  });

  // ===========================================================
  // ASAP — Layer 5
  // ===========================================================
  describe("ASAP — Layer 5 (Alternative Supplier Activation)", function () {
    let activationId;

    before(async function () {
      // Set FM active for ASAP tests
      await gom.triggerForceMajeure(route);
    });

    it("activateAlternativeSupplier() — emits AlternativeActivationEvent", async function () {
      // Authorize the deployer as an officer
      const ASAP = await ethers.getContractFactory("ASAP");

      const top5 = [
        drcMember0.address, drcMember1.address, drcMember2.address,
        drcMember3.address, drcMember4.address
      ];

      const tx = await asap.activateAlternativeSupplier(
        supplier.address,         // primary (suspended)
        buyer.address,            // alternative (approved)
        ethers.keccak256(ethers.toUtf8Bytes("ESCROW-001")),
        route,
        top5,
        1                         // top-ranked alternative
      );
      const receipt = await tx.wait();
      console.log("    activateAlternativeSupplier:", receipt.gasUsed.toString(), "gas");

      const events = await asap.queryFilter(asap.filters.AlternativeActivationEvent());
      expect(events.length).to.be.gt(0);
      activationId = events[events.length - 1].args.activationId;
    });

    it("getActivation() returns correct data", async function () {
      if (!activationId) this.skip();
      const a = await asap.getActivation(activationId);
      expect(a.primaryReinstateable).to.be.true;
      expect(a.primaryReinstatedAt).to.equal(0);
    });

    it("reinstatePrimarySupplier() — records reinstatement", async function () {
      if (!activationId) this.skip();
      const tx = await asap.reinstatePrimarySupplier(activationId);
      const receipt = await tx.wait();
      console.log("    reinstatePrimarySupplier:", receipt.gasUsed.toString(), "gas");

      const a = await asap.getActivation(activationId);
      expect(a.primaryReinstatedAt).to.be.gt(0);
    });

    it("activateAlternativeSupplier() reverts when not FM", async function () {
      await gom.resolveForceMajeure(route);
      const top5 = [
        drcMember0.address, drcMember1.address, drcMember2.address,
        drcMember3.address, drcMember4.address
      ];
      await expect(
        asap.activateAlternativeSupplier(
          supplier.address, buyer.address,
          ethers.keccak256(ethers.toUtf8Bytes("ESCROW-002")),
          route, top5, 1
        )
      ).to.be.revertedWith("ASAP: route not under FORCE_MAJEURE");
    });
  });
});
