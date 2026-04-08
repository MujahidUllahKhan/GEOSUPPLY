// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title  IGOM — Geopolitical Oracle Module Interface
/// @notice Exposes verified force majeure zone data to supply chain
///         smart contracts via 3-of-5 multi-source consensus.
/// @dev    Data sources (Section IV.A of GEOSUPPLY paper):
///           1. Lloyd's of London War-Risk Zone designation
///           2. International Maritime Organization Safety Notice
///           3. UN Security Council Resolution or Statement
///           4. AIS Vessel Tracking Divergence (>30% deviation)
///           5. Multi-source newswire verification (Reuters/AP/BBC/Bloomberg)
///         A zone is designated FORCE_MAJEURE only when >= 3 of 5
///         sources independently confirm the event.
/// @author Mujahid Ullah Khan Afridi, NMSU Industrial Engineering
///         Repository: https://github.com/MujahidUllahKhan/GEOSUPPLY
interface IGOM {

    // =========================================================
    // Enumerations
    // =========================================================

    /// @notice Three-level zone classification.
    ///   NORMAL        — Standard operations; no disruption confirmed.
    ///   ELEVATED      — Heightened risk; fewer than 3 sources confirmed.
    ///   FORCE_MAJEURE — >= 3 of 5 independent sources confirmed event.
    enum ZoneStatus { NORMAL, ELEVATED, FORCE_MAJEURE }

    // =========================================================
    // Core Oracle Functions (Section IV.A.3)
    // =========================================================

    /// @notice Returns the current zone status and on-chain evidence hash
    ///         for a given shipping route at a given timestamp.
    /// @param  route         keccak256 hash of the route identifier
    ///                       e.g. keccak256(abi.encodePacked("HORMUZ-GULF"))
    /// @param  timestamp     Unix timestamp of the query
    /// @return status        Current ZoneStatus classification
    /// @return evidenceHash  keccak256 of the 3-of-5 source evidence bundle
    function checkZone(
        bytes32 route,
        uint256 timestamp
    ) external view returns (
        ZoneStatus status,
        bytes32    evidenceHash
    );

    /// @notice Returns the keccak256 hash of the 3-of-5 verification
    ///         evidence bundle for a specific zone designation on a given date.
    ///         Enables any counterparty to independently verify the FM event.
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
    // Events
    // =========================================================

    /// @notice Emitted when >= 3 of 5 sources confirm FM for the zone.
    event ForceMajeureEvent(
        bytes32 indexed zone,
        uint256         activatedAt,
        bytes32         evidenceHash,
        uint8           sourcesConfirmed
    );

    /// @notice Emitted when GOM records zone resolution (FM lifted).
    event ForceMajeureResolved(
        bytes32 indexed zone,
        uint256         resolvedAt,
        bytes32         evidenceHash
    );
}


// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IGOM — Geopolitical Oracle Module Interface
 * @notice Defines the oracle interface for geopolitical force majeure
 *         recognition with tiered source authority weighting.
 *
 * Source authority weights (scaled x100 for integer arithmetic):
 *   Lloyd's War-Risk Zone    : w_s = 90
 *   IMO Safety Notice        : w_s = 85
 *   UN Security Council      : w_s = 85
 *   AIS Vessel Tracking      : w_s = 75
 *   Multi-source news        : w_s = 60
 *
 * Trigger conditions for FORCE_MAJEURE:
 *   (a) confirmCount >= 3  (simple majority), OR
 *   (b) weightedScore >= 250 AND confirmCount >= 2
 *       (two high-authority sources, e.g. Lloyd's + IMO = 175 -- 
 *        but 250 requires at least one more confirmation)
 *
 * ELEVATED state: 1-2 sources confirmed, 4-hour window open.
 * Conflict resolution: if unresolved after 4 hours, HITL-DRC notified.
 */
interface IGOM {

    /// @notice Zone status returned by checkZone()
    enum ZoneStatus { NORMAL, ELEVATED, FORCE_MAJEURE }

    /// @notice Source identifiers for the 5 GOM sources
    enum SourceId {
        LLOYDS_WAR_RISK,      // w_s = 90
        IMO_SAFETY_NOTICE,    // w_s = 85
        UN_SECURITY_COUNCIL,  // w_s = 85
        AIS_VESSEL_TRACKING,  // w_s = 75
        NEWSWIRE_VERIFICATION // w_s = 60
    }

    /// @notice Emitted when a source confirms a geopolitical event
    event SourceConfirmed(
        string indexed route,
        SourceId source,
        uint8 weight,
        uint256 timestamp
    );

    /// @notice Emitted when zone transitions to ELEVATED
    event ElevatedStateEntered(
        string indexed route,
        uint256 windowExpiry,
        uint256 weightedScore
    );

    /// @notice Emitted when FORCE_MAJEURE is confirmed
    event ForceMajeureEvent(
        string indexed route,
        uint256 timestamp,
        bytes32 evidenceHash
    );

    /// @notice Emitted when HITL-DRC is notified of unresolved conflict
    event ConflictEscalatedToDRC(
        string indexed route,
        uint256 timestamp,
        uint8 confirmCount,
        uint256 weightedScore
    );

    /**
     * @notice Check current zone status for a route at a given time.
     * @param route  Shipping corridor identifier (e.g. "HORMUZ", "RED_SEA")
     * @param timestamp  Unix timestamp to evaluate
     * @return ZoneStatus: NORMAL, ELEVATED, or FORCE_MAJEURE
     */
    function checkZone(string memory route, uint256 timestamp)
        external view returns (ZoneStatus);

    /**
     * @notice Get the keccak256 hash of the evidence bundle for an event.
     * @param zone   Zone identifier
     * @param date   Event date (Unix timestamp)
     * @return bytes32 evidence hash stored on-chain
     */
    function getEventHash(string memory zone, uint256 date)
        external view returns (bytes32);

    /**
     * @notice Get the resolution date for an active FM zone.
     * @param zone  Zone identifier
     * @return uint256 Unix timestamp when FM designation was lifted,
     *         or 0 if still active
     */
    function getResolutionDate(string memory zone)
        external view returns (uint256);

    /**
     * @notice Get the current weighted confirmation score for a route.
     * @dev Score = sum of w_s values for all confirming sources (x100).
     *      Threshold for condition (b): score >= 250 with confirmCount >= 2.
     * @param route  Shipping corridor identifier
     * @return uint256 weighted score (0-395 range, 395 = all 5 sources)
     */
    function getWeightedScore(string memory route)
        external view returns (uint256);

    /**
     * @notice Get number of sources currently confirming FM for a route.
     * @param route  Shipping corridor identifier
     * @return uint8 count of confirming sources (0-5)
     */
    function getConfirmCount(string memory route)
        external view returns (uint8);
}
