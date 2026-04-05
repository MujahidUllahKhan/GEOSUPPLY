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
///         Paper: GEOSUPPLY — IEEE Access (under review)
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
