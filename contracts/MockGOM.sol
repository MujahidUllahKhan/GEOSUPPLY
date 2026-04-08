// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IGOM.sol";

/// @title  MockGOM — Test Mock for Geopolitical Oracle Module
/// @notice Implements IGOM interface with configurable state for unit tests.
///         Allows test scripts to set zone status without real oracle infra.
/// @dev    NEVER deploy to mainnet. For local Hardhat/Ganache testing only.
/// @author Mujahid Ullah Khan Afridi, NMSU Industrial Engineering
///         Repository: https://github.com/MujahidUllahKhan/GEOSUPPLY
contract MockGOM is IGOM {

    mapping(bytes32 => ZoneStatus) private _zoneStatus;
    mapping(bytes32 => bytes32)    private _evidenceHash;
    mapping(bytes32 => uint256)    private _resolutionDate;
    mapping(bytes32 => mapping(uint256 => bytes32)) private _eventHash;

    // New mappings for weighted scoring (conflict resolution)
    mapping(bytes32 => uint256) private _weightedScore;
    mapping(bytes32 => uint8)   private _confirmCount;

    bytes32 public constant DEFAULT_EVIDENCE =
        keccak256(abi.encodePacked("MOCK-GEOSUPPLY-EVIDENCE-2026"));

    // =========================================================
    // Test Control Functions
    // =========================================================

    function setZone(
        bytes32    route,
        ZoneStatus status,
        bytes32    evHash
    ) external {
        _zoneStatus[route]                 = status;
        _evidenceHash[route]               = evHash;
        _eventHash[route][block.timestamp] = evHash;

        if (status == ZoneStatus.FORCE_MAJEURE) {
            _confirmCount[route]  = 3;
            _weightedScore[route] = 260; // Lloyd's(90)+IMO(85)+AIS(75)+margin
            emit ForceMajeureEvent(
                route,
                block.timestamp,
                evHash,
                3,       // sourcesConfirmed
                260      // weightedScore
            );
        } else if (status == ZoneStatus.ELEVATED) {
            _confirmCount[route]  = 2;
            _weightedScore[route] = 175; // Lloyd's(90)+IMO(85)
            emit ElevatedStateEntered(
                route,
                block.timestamp + 4 hours,
                2,    // confirmCount
                175   // weightedScore
            );
        } else {
            _confirmCount[route]  = 0;
            _weightedScore[route] = 0;
        }
    }

    function setResolutionDate(bytes32 route, uint256 date) external {
        _resolutionDate[route] = date;
        if (date > 0) {
            emit ForceMajeureResolved(route, date, _evidenceHash[route]);
        }
    }

    /// @notice One-line helper: set route to FORCE_MAJEURE with default evidence.
    function triggerForceMajeure(bytes32 route) external {
        _zoneStatus[route]                 = ZoneStatus.FORCE_MAJEURE;
        _evidenceHash[route]               = DEFAULT_EVIDENCE;
        _eventHash[route][block.timestamp] = DEFAULT_EVIDENCE;
        _confirmCount[route]               = 3;
        _weightedScore[route]              = 260;

        emit ForceMajeureEvent(
            route,
            block.timestamp,
            DEFAULT_EVIDENCE,
            3,    // sourcesConfirmed
            260   // weightedScore
        );
    }

    /// @notice One-line helper: resolve FM and return route to NORMAL.
    function resolveForceMajeure(bytes32 route) external {
        _zoneStatus[route]     = ZoneStatus.NORMAL;
        _resolutionDate[route] = block.timestamp;
        _confirmCount[route]   = 0;
        _weightedScore[route]  = 0;

        emit ForceMajeureResolved(
            route,
            block.timestamp,
            _evidenceHash[route]
        );
    }

    /// @notice Test helper: emit ElevatedStateEntered for conflict tests.
    function triggerElevated(bytes32 route) external {
        _zoneStatus[route]    = ZoneStatus.ELEVATED;
        _confirmCount[route]  = 2;
        _weightedScore[route] = 175;

        emit ElevatedStateEntered(
            route,
            block.timestamp + 4 hours,
            2,
            175
        );
    }

    /// @notice Test helper: emit ConflictEscalatedToDRC for DRC tests.
    function triggerDRCEscalation(bytes32 route) external {
        emit ConflictEscalatedToDRC(
            route,
            block.timestamp,
            _confirmCount[route],
            _weightedScore[route]
        );
    }

    // =========================================================
    // IGOM Interface Implementation — Core Oracle Functions
    // =========================================================

    function checkZone(
        bytes32 route,
        uint256 /*timestamp*/
    )
        external view override
        returns (ZoneStatus status, bytes32 evidenceHash)
    {
        status       = _zoneStatus[route];
        evidenceHash = _evidenceHash[route] != bytes32(0)
                     ? _evidenceHash[route]
                     : DEFAULT_EVIDENCE;
    }

    function getEventHash(bytes32 zone, uint256 date)
        external view override returns (bytes32)
    {
        bytes32 stored = _eventHash[zone][date];
        return stored != bytes32(0) ? stored : DEFAULT_EVIDENCE;
    }

    function getResolutionDate(bytes32 zone)
        external view override returns (uint256)
    {
        return _resolutionDate[zone];
    }

    // =========================================================
    // IGOM Interface Implementation — Weighted Scoring Functions
    // =========================================================

    /// @notice Returns the stored weighted score for a route.
    ///         In production this would be computed live from oracle feeds.
    ///         In MockGOM it is set by test helpers above.
    function getWeightedScore(bytes32 zone)
        external view override returns (uint256)
    {
        return _weightedScore[zone];
    }

    /// @notice Returns the stored confirm count for a route.
    function getConfirmCount(bytes32 zone)
        external view override returns (uint8)
    {
        return _confirmCount[zone];
    }

    /// @notice Returns the authority weight for a given source (x100).
    ///         Matches the weights defined in IGOM.sol NatSpec.
    function getSourceWeight(SourceId source)
        external pure override returns (uint8)
    {
        if (source == SourceId.LLOYDS_WAR_RISK)      return 90;
        if (source == SourceId.IMO_SAFETY_NOTICE)     return 85;
        if (source == SourceId.UN_SECURITY_COUNCIL)   return 85;
        if (source == SourceId.AIS_VESSEL_TRACKING)   return 75;
        if (source == SourceId.NEWSWIRE_VERIFICATION) return 60;
        return 0;
    }
}
