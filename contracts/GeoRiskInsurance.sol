// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IGOM.sol";

/// @title  GeoRiskInsurance — Parametric Geopolitical Insurance Oracle
/// @notice Implements GEOSUPPLY Layer 6: automatic war-risk insurance
///         settlement when three on-chain parametric triggers are verified.
///         Extends the parametric insurance model (AXA Fizzy) to
///         geopolitical shipping disruption (Section IV.F).
/// @dev    Addresses Structural Failure 6 identified in the GEOSUPPLY paper.
///         Three triggers: (1) GOM FM confirmation, (2) AIS deviation > 200nm
///         or idle > 72h, (3) Delivery missed > 5 days.
///
///         RESERVE ACCOUNTING MODEL:
///         - Owner deposits reserve via depositReserve()
///         - At policy issuance: insuredValue is committed (locked) from
///           reserve; premium is added back as income
///         - At claim APPROVAL: committed funds are transferred to policyholder
///         - At claim REJECTION: committed funds are released back to reserve
///         - reserveBalance tracks: deposited + premiums - committed - paid claims
///
/// @author Mujahid Ullah Khan Afridi, NMSU Industrial Engineering
///         Repository: https://github.com/MujahidUllahKhan/GEOSUPPLY
contract GeoRiskInsurance {

    // =========================================================
    // State Definitions
    // =========================================================

    enum ClaimStatus { PENDING, TRIGGERED, REJECTED }

    struct Policy {
        address payable policyholder;
        bytes32         shippingRoute;
        bytes32         vesselId;
        uint256         scheduledTransit;
        uint256         scheduledDelivery;
        uint256         insuredValue;
        ClaimStatus     status;
        bytes32         triggerEvidence;
    }

    // =========================================================
    // Parameters (Section IV.F)
    // =========================================================

    uint256 public constant AIS_DEVIATION_NM = 200;
    uint256 public constant AIS_IDLE_HOURS   = 72;
    uint256 public constant LATE_THRESHOLD   = 5 days;
    uint256 public constant LEVERAGE_RATIO   = 10;

    IGOM    public immutable gom;
    address public           aisOracle;
    address public           owner;

    mapping(bytes32 => Policy) public policies;

    /// @notice Total reserve available to back new policies and pay claims.
    ///         = deposited funds + premiums received
    ///           - insuredValues committed to active policies
    ///           - claim payouts made
    uint256 public reserveBalance;

    // =========================================================
    // Events
    // =========================================================

    event PolicyIssued(
        bytes32 indexed policyId,
        address indexed policyholder,
        bytes32         shippingRoute,
        bytes32         vesselId,
        uint256         insuredValue,
        uint256         premium
    );

    event ClaimTriggered(
        bytes32 indexed policyId,
        address indexed policyholder,
        uint256         paidAmount,
        bytes32         gomEvidenceHash,
        uint256         triggeredAt
    );

    event ClaimRejected(
        bytes32 indexed policyId,
        string          reason,
        uint256         checkedAt
    );

    event ReserveDeposited(address indexed depositor, uint256 amount);

    // =========================================================
    // Modifiers
    // =========================================================

    modifier onlyOwner()     { require(msg.sender == owner,      "GeoRiskInsurance: not owner");      _; }
    modifier onlyAISOracle() { require(msg.sender == aisOracle,  "GeoRiskInsurance: not AIS oracle"); _; }

    // =========================================================
    // Constructor
    // =========================================================

    constructor(address _gom, address _aisOracle) {
        gom       = IGOM(_gom);
        aisOracle = _aisOracle;
        owner     = msg.sender;
    }

    // =========================================================
    // Reserve Management
    // =========================================================

    /// @notice Owner deposits reserve funds to back policies.
    ///         Must be called before policies can be issued.
    function depositReserve() external payable onlyOwner {
        reserveBalance += msg.value;
        emit ReserveDeposited(msg.sender, msg.value);
    }

    function updateAISOracle(address _newOracle) external onlyOwner {
        aisOracle = _newOracle;
    }

    // =========================================================
    // Policy Issuance — FIXED reserve accounting
    // =========================================================

    /// @notice Policyholder purchases war-risk insurance by paying premium.
    ///         Insured value = premium × LEVERAGE_RATIO (10x).
    ///
    ///         ACCOUNTING: insuredValue is committed from reserveBalance at
    ///         issuance (so we can't over-commit). Premium is added back as
    ///         income. Net change = premium - insuredValue (typically negative).
    ///
    /// @param policyId          Unique policy ID (keccak256 of metadata)
    /// @param route             keccak256 of shipping route identifier
    /// @param vesselId          AIS MMSI of insured vessel (as bytes32)
    /// @param scheduledTransit  Unix timestamp when vessel enters route zone
    /// @param scheduledDelivery Unix timestamp of contracted delivery date
    function issuePolicy(
        bytes32 policyId,
        bytes32 route,
        bytes32 vesselId,
        uint256 scheduledTransit,
        uint256 scheduledDelivery
    ) external payable {
        require(msg.value > 0,
                "GeoRiskInsurance: premium required");
        require(policies[policyId].policyholder == address(0),
                "GeoRiskInsurance: policy ID already exists");
        require(scheduledDelivery > scheduledTransit,
                "GeoRiskInsurance: delivery must be after transit");

        uint256 insuredValue = msg.value * LEVERAGE_RATIO;

        // FIX: Check reserveBalance (not address(this).balance which
        //      already includes the premium just sent by the caller)
        require(reserveBalance >= insuredValue,
                "GeoRiskInsurance: insufficient reserve to back this policy");

        // FIX: Commit insuredValue from reserve; add premium as income
        //      Net effect: locks collateral for this policy
        reserveBalance = reserveBalance - insuredValue + msg.value;

        policies[policyId] = Policy({
            policyholder:      payable(msg.sender),
            shippingRoute:     route,
            vesselId:          vesselId,
            scheduledTransit:  scheduledTransit,
            scheduledDelivery: scheduledDelivery,
            insuredValue:      insuredValue,
            status:            ClaimStatus.PENDING,
            triggerEvidence:   bytes32(0)
        });

        emit PolicyIssued(policyId, msg.sender, route, vesselId, insuredValue, msg.value);
    }

    // =========================================================
    // Claim Settlement — Three-Trigger Parametric Logic
    // =========================================================

    /// @notice Attempts automatic claim settlement after delivery deadline.
    ///         Called by the AIS oracle. Verifies all three triggers on-chain.
    ///
    ///         Trigger 1: GOM confirms FORCE_MAJEURE on route at transit time
    ///         Trigger 2: AIS deviation > 200nm OR vessel idle > 72h
    ///         Trigger 3: Delivery missed by more than 5 days
    ///
    ///         If all three met: insuredValue transferred to policyholder.
    ///         If any rejected: insuredValue returned to reserveBalance.
    ///
    /// @param policyId       Policy to evaluate
    /// @param vesselDevNm    AIS-verified vessel deviation in nautical miles
    /// @param vesselIdleHrs  Hours vessel was idle inside affected port
    function settleClaim(
        bytes32 policyId,
        uint256 vesselDevNm,
        uint256 vesselIdleHrs
    ) external onlyAISOracle {
        Policy storage p = policies[policyId];

        require(p.policyholder != address(0), "GeoRiskInsurance: policy not found");
        require(p.status == ClaimStatus.PENDING, "GeoRiskInsurance: already settled");
        require(block.timestamp > p.scheduledDelivery,
                "GeoRiskInsurance: delivery window not expired");

        // --- Trigger 1: GOM zone at transit time -----------------------
        (IGOM.ZoneStatus status, bytes32 evHash) =
            gom.checkZone(p.shippingRoute, p.scheduledTransit);

        if (status != IGOM.ZoneStatus.FORCE_MAJEURE) {
            p.status = ClaimStatus.REJECTED;
            // FIX: Release committed collateral back to free reserve
            reserveBalance += p.insuredValue;
            emit ClaimRejected(policyId,
                "Trigger 1 failed: GOM zone not FORCE_MAJEURE at transit time",
                block.timestamp);
            return;
        }

        // --- Trigger 2: AIS deviation or idle --------------------------
        bool aisConfirmed = (vesselDevNm > AIS_DEVIATION_NM)
                         || (vesselIdleHrs > AIS_IDLE_HOURS);

        if (!aisConfirmed) {
            p.status = ClaimStatus.REJECTED;
            reserveBalance += p.insuredValue;
            emit ClaimRejected(policyId,
                "Trigger 2 failed: AIS deviation and idle hours below thresholds",
                block.timestamp);
            return;
        }

        // --- Trigger 3: Late > 5 days ----------------------------------
        if (block.timestamp <= p.scheduledDelivery + LATE_THRESHOLD) {
            p.status = ClaimStatus.REJECTED;
            reserveBalance += p.insuredValue;
            emit ClaimRejected(policyId,
                "Trigger 3 failed: delivery within 5-day tolerance window",
                block.timestamp);
            return;
        }

        // --- All three triggers met: auto-pay --------------------------
        // NOTE: insuredValue was already committed (deducted) from
        //       reserveBalance at issuance. Do NOT deduct again here.
        p.status          = ClaimStatus.TRIGGERED;
        p.triggerEvidence = evHash;

        p.policyholder.transfer(p.insuredValue);

        emit ClaimTriggered(
            policyId, p.policyholder, p.insuredValue, evHash, block.timestamp
        );
    }

    // =========================================================
    // View Helpers
    // =========================================================

    function getPolicyStatus(bytes32 policyId)
        external view returns (ClaimStatus)
    {
        return policies[policyId].status;
    }

    receive() external payable {
        reserveBalance += msg.value;
    }
}
