// SPDX-License-Identifier: MIT
// GEOSUPPLY Deployment Script
// Deploys all contracts in dependency order and configures cross-contract
// authorization per GEOSUPPLY paper Section IV.
//
// Deployment order:
//   1. MockGOM        (Layer 1 — use real GOM address in production)
//   2. ComplianceAudit (HITL-DRC audit log)
//   3. TriStateEscrow  (Layer 2 — requires GOM + 5 DRC members)
//   4. GeoRiskInsurance (Layer 6 — requires GOM + AIS oracle)
//   5. SanctionsCompliance (Layer 7 — requires oracle + officer)
//   6. GCIL           (Layer 3 — requires GOM)
//   7. ASAP           (Layer 5 — requires GOM)
//
// Post-deployment:
//   - SanctionsCompliance.authorizePaymentContract(TriStateEscrow)
//   - ComplianceAudit.authorizeLogger(deployer)
//   - GeoRiskInsurance.depositReserve(1 ETH)

const hre = require("hardhat");

async function main() {
  const signers = await hre.ethers.getSigners();
  const [
    deployer,
    buyer,
    supplier,
    drcBuyerRep,      // DRC [0]: buyer representative
    drcSellerRep,     // DRC [1]: seller representative
    drcTradeExpert,   // DRC [2]: neutral trade expert (ICC arbitrator)
    drcBlockchainAuditor, // DRC [3]: technical blockchain auditor
    drcLegalExpert,   // DRC [4]: legal expert in FM / international trade
    aisOracle,        // AIS oracle for GeoRiskInsurance
    sanctionsOracle,  // Sanctions oracle for SanctionsCompliance
    complianceOfficer // Compliance officer for SanctionsCompliance
  ] = signers;

  console.log("=".repeat(60));
  console.log("GEOSUPPLY Contract Deployment");
  console.log("Paper: GEOSUPPLY — IEEE Access (under review)");
  console.log("Author: Mujahid Ullah Khan Afridi, NMSU");
  console.log("=".repeat(60));
  console.log("Deployer:", deployer.address);

  // =========================================================
  // 1. Deploy MockGOM (Layer 1 interface)
  //    In production: replace with actual GOM oracle address
  // =========================================================
  console.log("\n[1/7] Deploying MockGOM (Layer 1)...");
  const MockGOM = await hre.ethers.getContractFactory("MockGOM");
  const gom = await MockGOM.deploy();
  await gom.waitForDeployment();
  const gomAddr = await gom.getAddress();
  console.log("  MockGOM:", gomAddr);

  // =========================================================
  // 2. Deploy ComplianceAudit (HITL-DRC Audit Log)
  // =========================================================
  console.log("\n[2/7] Deploying ComplianceAudit...");
  const ComplianceAudit = await hre.ethers.getContractFactory("ComplianceAudit");
  const audit = await ComplianceAudit.deploy();
  await audit.waitForDeployment();
  const auditAddr = await audit.getAddress();
  console.log("  ComplianceAudit:", auditAddr);

  // =========================================================
  // 3. Deploy TriStateEscrow (Layer 2)
  //    5 DRC members per Section IV.D of GEOSUPPLY paper
  // =========================================================
  console.log("\n[3/7] Deploying TriStateEscrow (Layer 2)...");
  const route    = hre.ethers.keccak256(hre.ethers.toUtf8Bytes("HORMUZ-GULF"));
  const deadline = Math.floor(Date.now() / 1000) + 60 * 60 * 24 * 90; // 90 days
  const value    = hre.ethers.parseEther("1.0");

  // DRC members array: [buyer rep, seller rep, trade expert, blockchain auditor, legal expert]
  const drcMembers = [
    drcBuyerRep.address,
    drcSellerRep.address,
    drcTradeExpert.address,
    drcBlockchainAuditor.address,
    drcLegalExpert.address
  ];

  const TriStateEscrow = await hre.ethers.getContractFactory("TriStateEscrow");
  const escrow = await TriStateEscrow.deploy(
    buyer.address,
    supplier.address,
    gomAddr,
    route,
    deadline,
    drcMembers,
    { value: value }
  );
  await escrow.waitForDeployment();
  const escrowAddr = await escrow.getAddress();
  console.log("  TriStateEscrow:", escrowAddr);
  console.log("  DRC Members:");
  console.log("    [0] Buyer Rep:     ", drcBuyerRep.address);
  console.log("    [1] Seller Rep:    ", drcSellerRep.address);
  console.log("    [2] Trade Expert:  ", drcTradeExpert.address);
  console.log("    [3] Blockchain Aud:", drcBlockchainAuditor.address);
  console.log("    [4] Legal Expert:  ", drcLegalExpert.address);

  // =========================================================
  // 4. Deploy GeoRiskInsurance (Layer 6)
  // =========================================================
  console.log("\n[4/7] Deploying GeoRiskInsurance (Layer 6)...");
  const GeoRiskInsurance = await hre.ethers.getContractFactory("GeoRiskInsurance");
  const insurance = await GeoRiskInsurance.deploy(gomAddr, aisOracle.address);
  await insurance.waitForDeployment();
  const insuranceAddr = await insurance.getAddress();
  console.log("  GeoRiskInsurance:", insuranceAddr);

  // Deposit reserve so policies can be issued
  const reserveTx = await insurance.depositReserve({ value: hre.ethers.parseEther("5.0") });
  await reserveTx.wait();
  console.log("  Reserve funded: 5 ETH");

  // =========================================================
  // 5. Deploy SanctionsCompliance (Layer 7)
  // =========================================================
  console.log("\n[5/7] Deploying SanctionsCompliance (Layer 7)...");
  const SanctionsCompliance = await hre.ethers.getContractFactory("SanctionsCompliance");
  const sanctions = await SanctionsCompliance.deploy(
    sanctionsOracle.address,
    complianceOfficer.address
  );
  await sanctions.waitForDeployment();
  const sanctionsAddr = await sanctions.getAddress();
  console.log("  SanctionsCompliance:", sanctionsAddr);

  // Authorize TriStateEscrow to call screenAndPay()
  const authTx = await sanctions.authorizePaymentContract(escrowAddr, true);
  await authTx.wait();
  console.log("  TriStateEscrow authorized as payment contract");

  // =========================================================
  // 6. Deploy GCIL (Layer 3)
  // =========================================================
  console.log("\n[6/7] Deploying GCIL (Layer 3)...");
  const GCIL = await hre.ethers.getContractFactory("GCIL");
  const gcil = await GCIL.deploy(gomAddr);
  await gcil.waitForDeployment();
  const gcilAddr = await gcil.getAddress();
  console.log("  GCIL:", gcilAddr);

  // =========================================================
  // 7. Deploy ASAP (Layer 5)
  // =========================================================
  console.log("\n[7/7] Deploying ASAP (Layer 5)...");
  const ASAP = await hre.ethers.getContractFactory("ASAP");
  const asap = await ASAP.deploy(gomAddr);
  await asap.waitForDeployment();
  const asapAddr = await asap.getAddress();
  console.log("  ASAP:", asapAddr);

  // =========================================================
  // Summary
  // =========================================================
  console.log("\n" + "=".repeat(60));
  console.log("GEOSUPPLY Deployment Complete");
  console.log("=".repeat(60));
  console.log("Layer 1 (GOM Interface): ", gomAddr);
  console.log("Layer 2 (TriStateEscrow):", escrowAddr);
  console.log("Layer 3 (GCIL):          ", gcilAddr);
  console.log("Layer 5 (ASAP):          ", asapAddr);
  console.log("Layer 6 (GeoRiskIns):    ", insuranceAddr);
  console.log("Layer 7 (SanctionsComp): ", sanctionsAddr);
  console.log("ComplianceAudit:         ", auditAddr);
  console.log("\nRun gas measurements: npx hardhat test");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
