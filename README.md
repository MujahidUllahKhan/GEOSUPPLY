# GEOSUPPLY — Smart Contract Repository

**Geopolitical Oracle-Mediated Supply Chain Governance**

> Supporting code for: *"GEOSUPPLY: When 'Code is Law' Breaks Down — A Critical Review of Blockchain-Enabled Supply Chain Smart Contract Failures Under Geopolitical Force Majeure and a Human-in-the-Loop Governance Framework for Resilient Global Trade"*
>
> **Author:** Mujahid Ullah Khan Afridi, Department of Industrial Engineering, New Mexico State University (mujahida@nmsu.edu)
>
>
> **License:** MIT

---

## Overview

GEOSUPPLY addresses **seven structural failures** exposed by the 2026 Strait of Hormuz crisis in existing blockchain supply chain systems. This repository contains the Solidity smart contracts implementing the framework's on-chain governance logic across all seven layers.

The 2026 crisis — triggered by coordinated U.S.–Israel strikes on Iran on 28 February 2026 — demonstrated that "code is law" fails catastrophically when geopolitical reality renders contractual execution physically impossible. Blockchain immutability, intended as a strength, became a source of systematic injustice when innocent suppliers had deposits withheld and reputation scores destroyed automatically by code that could not distinguish force majeure from non-performance.

---

## Contract Architecture — Seven Layers

| Contract | Layer | Paper Section | Purpose |
|---|---|---|---|
| `IGOM.sol` | Layer 1 (Interface) | IV.A | Geopolitical Oracle Module — 3-of-5 source verification |
| `MockGOM.sol` | Layer 1 (Test Mock) | IV.A | Configurable GOM mock for unit tests |
| `TriStateEscrow.sol` | Layer 2 | IV.B | Three-state escrow: NORMAL / FORCE\_MAJEURE / PARTIAL |
| `GCIL.sol` | Layer 3 | IV.C | ML ranking exclusion — PerformanceExclusionEvent on-chain |
| `ComplianceAudit.sol` | Layer 4 (DRC Log) | IV.D | HITL-DRC ruling audit trail with rationale and evidence |
| `ASAP.sol` | Layer 5 | IV.E | Alternative supplier activation — AlternativeActivationEvent |
| `GeoRiskInsurance.sol` | Layer 6 | IV.F | Parametric war-risk insurance — three-trigger auto-settlement |
| `SanctionsCompliance.sol` | Layer 7 | IV.G | Real-time OFAC/EU/UN/HMT sanctions screening |

---

## Structural Failures Addressed

| Failure | Contract | Description |
|---|---|---|
| F1: Code-is-Law catastrophe | `TriStateEscrow.sol` | Automatic execution suspended in FM state |
| F2: ML ranking contamination | `GCIL.sol` | GOM\_EXCLUDED marker prevents FM data from corrupting ML |
| F3: Binary escrow logic | `TriStateEscrow.sol` | Tri-state: NORMAL / FORCE\_MAJEURE / PARTIAL |
| F4: Reputation destruction | `TriStateEscrow.sol` | Non-fault DRC ruling clears reputation records |
| F5: No alternative supplier | `ASAP.sol` | On-chain AlternativeActivationEvent with officer approval |
| F6: Insurance cannot verify FM | `GeoRiskInsurance.sol` | Three-trigger parametric settlement via GOM |
| F7: Sanctions screening absent | `SanctionsCompliance.sol` | OFAC/EU/UN/HMT screening before every payment |

---

## Key Design Decisions

### TriStateEscrow — Real 3-of-5 Multi-Signature DRC
The HITL-DRC requires **genuine 3-of-5 approval** from five pre-designated adjudicators:
- `[0]` Buyer representative
- `[1]` Seller / supplier representative
- `[2]` Neutral trade expert (ICC arbitrator)
- `[3]` Technical blockchain auditor
- `[4]` Legal expert in force majeure / international trade law

`submitDRCVote()` auto-executes the ruling when the 3rd vote is cast.

### GeoRiskInsurance — Correct Reserve Accounting
- At policy issuance: `insuredValue` is **committed** from `reserveBalance`; premium added as income
- At claim approval: committed funds transferred to policyholder (no double-deduction)
- At claim rejection: committed funds released back to `reserveBalance`

### SanctionsCompliance — Proper Access Control
- Oracle maintains `sanctionedAddresses` mapping (updated daily)
- Payment contracts call `screenAndPay()` which reads the mapping internally
- Sanctioned status is **not** passed as a parameter (prevents manipulation)
- Owner authorizes which payment contracts may call `screenAndPay()`

---

## Setup

```bash
npm install
npx hardhat compile
npx hardhat test
npx hardhat run scripts/deploy.js --network hardhat
```

### Requirements
- Node.js >= 18
- Hardhat >= 2.22.0

### Expected Test Output
```
GEOSUPPLY — Full Contract Test Suite
  IGOM / MockGOM — Layer 1
    ✓ checkZone() returns NORMAL by default
    ✓ triggerForceMajeure() transitions route to FORCE_MAJEURE
    ✓ getEventHash() returns evidence hash
    ✓ resolveForceMajeure() transitions back to NORMAL
    ✓ getResolutionDate() returns non-zero after resolution
  TriStateEscrow — NORMAL State
    ✓ checkAndTransition() — gas measurement (NORMAL)
    ✓ lockDeposit() — supplier locks 0.15 ETH security deposit
    ✓ activeDeadline() returns original deadline before FM
    ✓ confirmDelivery() — releases full payment to supplier
  TriStateEscrow — FORCE_MAJEURE State and DRC
    ✓ State transitions to FORCE_MAJEURE after GOM trigger
    ✓ applyPenalty() reverts in FORCE_MAJEURE — core GEOSUPPLY protection
    ✓ submitDRCVote() — first vote (1-of-3)
    ✓ submitDRCVote() — second vote (2-of-3)
    ✓ submitDRCVote() — third vote executes ruling (3-of-3)
    ✓ outsider cannot vote — not a DRC member
    ✓ duplicate DRC vote reverts
  ... (and more)
```

---

## Data Availability

All GEOSUPPLY smart contracts (`IGOM.sol`, `MockGOM.sol`, `TriStateEscrow.sol`,
`GCIL.sol`, `ComplianceAudit.sol`, `ASAP.sol`, `GeoRiskInsurance.sol`,
`SanctionsCompliance.sol`) and deployment scripts are openly available at
[https://github.com/MujahidUllahKhan/GEOSUPPLY](https://github.com/MujahidUllahKhan/GEOSUPPLY)
under the **MIT License**.

---

## Citation

If you use this code in your research, please cite:

```
M. U. K. Afridi, "GEOSUPPLY: When 'Code is Law' Breaks Down — A Critical 
Review of Blockchain-Enabled Supply Chain Smart Contract Failures Under 
Geopolitical Force Majeure and a Human-in-the-Loop Governance Framework 
for Resilient Global Trade," under review, 2026.
```

---

## Contact

**Mujahid Ullah Khan Afridi**  
PhD Candidate, Department of Industrial Engineering  
New Mexico State University, Las Cruces, NM 88003, USA  
Email: mujahida@nmsu.edu
