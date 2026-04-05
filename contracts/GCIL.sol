// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IGOM.sol";

/// @title  GCIL — Geopolitical Context Injection Layer
/// @notice Implements GEOSUPPLY Layer 3: on-chain anchoring for ML supplier
///         ranking exclusion during geopolitical force majeure periods.
/// @dev    Addresses Structural Failure 2 (ML supplier ranking contamination)
///         identified in the GEOSUPPLY paper Section III.B.
///
///         "When GOM records a force majeure event for a given shipping corridor,
///          GCIL automatically flags all performance records for suppliers whose
///          primary shipping routes pass through the affected zone. The flag is
///          stored on-chain as a PerformanceExclusionEvent." — Section IV.C.
///
///         The off-chain ML system reads PerformanceExclusionEvent logs and
///         applies Equation (2) from the paper to compute adjusted scores.
///         On-chain, GCIL records: which suppliers are excluded, for which
///         routes, during which FM periods, and whether human review is required.
///
///         Human Review Threshold: any ML ranking demotion exceeding 15
///         percentile points triggers a HumanReviewRequired event.
///
/// @author Mujahid Ullah Khan Afridi, NMSU Industrial Engineering
///         Repository: https://github.com/MujahidUllahKhan/GEOSUPPLY
contract GCIL {

    // =========================================================
    // Constants
    // =========================================================

    /// @notice Demotion threshold above which human review is required.
    ///         Per GEOSUPPLY Section IV.C: "Any ML ranking demotion exceeding
    ///         15 percentile points... requires Human-in-the-Loop review."
    uint8 public constant HUMAN_REVIEW_THRESHOLD = 15;

    // =========================================================
    // Storage
    // =========================================================

    IGOM    public immutable gom;
    address public           owner;

    /// @notice Authorized ML operators who can submit exclusion records.
    mapping(address => bool) public authorizedOperators;

    /// @dev supplier => route => FM period start => excluded?
    mapping(address => mapping(bytes32 => mapping(uint256 => bool)))
        public isExcluded;

    // =========================================================
    // Events
    // =========================================================

    /// @notice Core event: performance record flagged with GOM_EXCLUDED.
    ///         Off-chain ML reads this to apply Equation (2) score adjustment.
    event PerformanceExclusionEvent(
        address indexed supplier,
        bytes32 indexed route,
        uint256         fmPeriodStart,
        uint256         fmPeriodEnd,         // 0 if still active
        bytes32         gomEvidenceHash,
        uint256         recordedAt
    );

    /// @notice Emitted when proposed demotion exceeds 15 percentile points.
    ///         Procurement officer must approve before demotion is enacted.
    event HumanReviewRequired(
        address indexed supplier,
        bytes32 indexed route,
        uint8           proposedDemotionPct,  // In percentile points
        uint256         currentRankPct,        // Current ML percentile (0–100)
        uint256         proposedRankPct,       // After proposed demotion
        uint256         timestamp
    );

    /// @notice Emitted when a human reviewer approves or overrides an exclusion.
    event ExclusionReviewCompleted(
        address indexed supplier,
        bytes32 indexed route,
        address indexed reviewer,
        bool            exclusionApproved,
        string          reviewerNotes,
        uint256         timestamp
    );

    event OperatorAuthorized(address indexed operator, bool authorized);

    // =========================================================
    // Modifiers
    // =========================================================

    modifier onlyOwner()    { require(msg.sender == owner, "GCIL: not owner"); _; }
    modifier onlyOperator() {
        require(authorizedOperators[msg.sender], "GCIL: not authorized operator");
        _;
    }

    // =========================================================
    // Constructor
    // =========================================================

    constructor(address _gom) {
        gom   = IGOM(_gom);
        owner = msg.sender;
        authorizedOperators[msg.sender] = true;
    }

    // =========================================================
    // Authorization
    // =========================================================

    function authorizeOperator(address operator, bool authorized) external onlyOwner {
        authorizedOperators[operator] = authorized;
        emit OperatorAuthorized(operator, authorized);
    }

    // =========================================================
    // Core: Flag Supplier Performance Records
    // =========================================================

    /// @notice Records a GOM_EXCLUDED flag for a supplier's performance
    ///         records during a confirmed FM period. Called by the ML
    ///         operator after verifying GOM status for the supplier's route.
    ///
    ///         The FM period is verified on-chain against GOM — this function
    ///         will revert if the route is not currently FORCE_MAJEURE.
    ///
    /// @param supplier       Supplier address to flag
    /// @param route          keccak256 of the affected shipping route
    /// @param fmPeriodStart  Unix timestamp when FM began for this supplier
    /// @param proposedDemotionPct  Proposed ML percentile demotion (0–100)
    /// @param currentRankPct       Current supplier ML percentile (0–100)
    function flagSupplierExclusion(
        address supplier,
        bytes32 route,
        uint256 fmPeriodStart,
        uint8   proposedDemotionPct,
        uint8   currentRankPct
    ) external onlyOperator {
        require(supplier != address(0), "GCIL: zero supplier address");
        require(proposedDemotionPct <= 100, "GCIL: demotion > 100 percentile");
        require(currentRankPct <= 100,      "GCIL: rank > 100 percentile");

        // Verify FM is confirmed by GOM for this route
        (IGOM.ZoneStatus status, bytes32 evHash) =
            gom.checkZone(route, block.timestamp);
        require(status == IGOM.ZoneStatus.FORCE_MAJEURE,
                "GCIL: route not under FORCE_MAJEURE — cannot flag exclusion");

        uint256 fmPeriodEnd = gom.getResolutionDate(route);

        // Record exclusion on-chain
        isExcluded[supplier][route][fmPeriodStart] = true;

        emit PerformanceExclusionEvent(
            supplier, route, fmPeriodStart, fmPeriodEnd, evHash, block.timestamp
        );

        // Check human review threshold (Section IV.C)
        if (proposedDemotionPct > HUMAN_REVIEW_THRESHOLD) {
            uint256 proposedRank = proposedDemotionPct >= currentRankPct
                                 ? 0
                                 : currentRankPct - proposedDemotionPct;
            emit HumanReviewRequired(
                supplier, route, proposedDemotionPct,
                currentRankPct, proposedRank, block.timestamp
            );
        }
    }

    /// @notice Human reviewer approves or overrides an exclusion decision.
    ///         Called by an authorized operator after human review.
    /// @param supplier           Supplier address reviewed
    /// @param route              Route the exclusion applies to
    /// @param exclusionApproved  True = maintain exclusion; False = override
    /// @param reviewerNotes      Reviewer's documented rationale
    function completeExclusionReview(
        address         supplier,
        bytes32         route,
        bool            exclusionApproved,
        string calldata reviewerNotes
    ) external onlyOperator {
        emit ExclusionReviewCompleted(
            supplier, route, msg.sender,
            exclusionApproved, reviewerNotes, block.timestamp
        );
    }
}
