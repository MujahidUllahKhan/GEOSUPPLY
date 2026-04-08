// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title  IGOM — Geopolitical Oracle Module Interface
/// @notice Exposes verified force majeure zone data to supply chain
///         smart contracts via 3-of-5 multi-source consensus with
///         tiered authority weighting for conflict resolution.
///
/// @dev    PRIMARY TRIGGER (condition a):
///           confirmCount >= 3 of 5 independent sources
///
///         SECONDARY TRIGGER (condition b — conflict resolution):
///           weightedScore >= 250 AND confirmCount >= 2
///           Handles cases where two high-authority sources confirm
///           before lower-authority sources have reported.
///
///         Source authority weights (scaled x100 for integer arithmetic):
///           LLOYDS_WAR_RISK      : w_s = 90  (legal maritime authority)
///           IMO_SAFETY_NOTICE    : w_s = 85  (intergovernmental body)
///           UN_SECURITY_COUNCIL  : w_s = 85  (international legal instrument)
///           AIS_VESSEL_TRACKING  : w_s = 75  (objective, threshold-dependent)
///           NEWSWIRE_VERIFICATION: w_s = 60  (timely, editorially variable)
///           Maximum weighted score: 90+85+85+75+60 = 395
///           Threshold for condition (b): >= 250 with >= 2 sources
///
///         ELEVATED state: 1-2 sources confirmed, 4-hour window open.
///         Conflict resolution: if unresolved after 4 hours, HITL-DRC notified.
///
///         Data sources (Section 5.1 of GEOSUPPLY paper):
///           1. Lloyd's of London War-Risk Zone designation
///           2. International Maritime Organization Safety Notice
///           3. UN Security Council Resolution or Statement
///           4. AIS Vessel Tracking Divergence (>30% deviation in 100-mile corridor)
///           5. Multi-source newswire verification (Reuters/AP/BBC/Bloomberg)
///
/// @author Mujahid Ullah Khan Afridi, NMSU Industrial Engineering
///         Repository: https://github.com/MujahidUllahKhan/GEOSUPPLY
interface IGOM {

    // =========================================================
    // Enumerations
    // =========================================================

    /// @notice Three-level zone classification.
    ///   NORMAL        — Standard operations; fewer than 1 source confirmed.
    ///   ELEVATED      — 1-2 sources confirmed; 4-hour resolution window open.
    ///   FORCE_MAJEURE — Condition (a) or (b) met; full FM governance active.
    enum ZoneStatus { NORMAL, ELEVATED, FORCE_MAJEURE }

    /// @notice Source identifiers for the 5 GOM sources.
    ///         Enum index corresponds to authority weight:
    ///         LLOYDS=90, IMO=85, UN=85, AIS=75, NEWSWIRE=60
    enum SourceId {
        LLOYDS_WAR_RISK,       // w_s = 90
        IMO_SAFETY_NOTICE,     // w_s = 85
        UN_SECURITY_COUNCIL,   // w_s = 85
        AIS_VESSEL_TRACKING,   // w_s = 75
        NEWSWIRE_VERIFICATION  // w_s = 60
    }

    // =========================================================
    // Events
    // =========================================================

    /// @notice Emitted when a source confirms a geopolitical event.
    event SourceConfirmed(
        bytes32 indexed route,
        SourceId        source,
        uint8           weight,
        uint256         timestamp
    );

    /// @notice Emitted when zone transitions to ELEVATED state.
    ///         windowExpiry = block.timestamp + 4 hours.
    event ElevatedStateEntered(
        bytes32 indexed route,
        uint256         windowExpiry,
        uint8           confirmCount,
        uint256         weightedScore
    );

    /// @notice Emitted when >= 3 sources confirm FM (condition a),
    ///         OR weighted score >= 250 with >= 2 sources (condition b).
    event ForceMajeureEvent(
        bytes32 indexed route,
        uint256         activatedAt,
        bytes32         evidenceHash,
        uint8           sourcesConfirmed,
        uint256         weightedScore
    );

    /// @notice Emitted when GOM records zone resolution (FM lifted).
    event ForceMajeureResolved(
        bytes32 indexed route,
        uint256         resolvedAt,
        bytes32         evidenceHash
    );

    /// @notice Emitted when ELEVATED conflict is unresolved after 4 hours.
    ///         Triggers HITL-DRC manual determination.
    event ConflictEscalatedToDRC(
        bytes32 indexed route,
        uint256         escalatedAt,
        uint8           confirmCount,
        uint256         weightedScore
    );

    // =========================================================
    // Core Oracle Functions
    // =========================================================

    /// @notice Returns the current zone status and on-chain evidence hash
    ///         for a given shipping route at a given timestamp.
    /// @param  route         keccak256 hash of the route identifier
    ///                       e.g. keccak256(abi.encodePacked("HORMUZ-GULF"))
    /// @param  timestamp     Unix timestamp of the query
    /// @return status        Current ZoneStatus classification
    /// @return evidenceHash  keccak256 of the source evidence bundle
    function checkZone(
        bytes32 route,
        uint256 timestamp
    ) external view returns (
        ZoneStatus status,
        bytes32    evidenceHash
    );

    /// @notice Returns the keccak256 hash of the verification evidence
    ///         bundle for a specific zone designation on a given date.
    ///         Enables any counterparty to independently verify FM event.
    /// @param  zone  keccak256 route identifier
    /// @param  date  Unix timestamp of the FM designation (activatedAt)
    /// @return       keccak256 evidence hash; bytes32(0) if none exists
    function getEventHash(
        bytes32 zone,
        uint256 date
    ) external view returns (bytes32);

    /// @notice Returns Unix timestamp when FM status was lifted.
    ///         Returns 0 if zone is still under FM or no FM recorded.
    /// @param  zone  keccak256 route identifier
    function getResolutionDate(bytes32 zone)
        external view returns (uint256);

    // =========================================================
    // Weighted Scoring Functions (Conflict Resolution)
    // =========================================================

    /// @notice Returns the current weighted confirmation score for a route.
    /// @dev    Score = sum of w_s values (x100) for all confirming sources.
    ///         Range: 0 to 395 (all five sources confirmed).
    ///         FORCE_MAJEURE condition (b) threshold: score >= 250
    ///         with confirmCount >= 2.
    ///         Example: Lloyd's (90) + IMO (85) = 175 — ELEVATED only.
    ///         Example: Lloyd's (90) + IMO (85) + AIS (75) = 250 — FORCE_MAJEURE.
    /// @param  zone  keccak256 route identifier
    /// @return       Weighted score (0-395)
    function getWeightedScore(bytes32 zone)
        external view returns (uint256);

    /// @notice Returns the number of sources currently confirming FM.
    /// @param  zone  keccak256 route identifier
    /// @return       Confirm count (0-5)
    function getConfirmCount(bytes32 zone)
        external view returns (uint8);

    /// @notice Returns the authority weight for a given source (x100).
    ///         LLOYDS=90, IMO=85, UN=85, AIS=75, NEWSWIRE=60.
    /// @param  source  SourceId enum value
    /// @return         Weight scaled by 100
    function getSourceWeight(SourceId source)
        external pure returns (uint8);
}
