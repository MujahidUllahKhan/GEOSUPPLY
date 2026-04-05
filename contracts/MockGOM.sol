// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IGOM.sol";

/// @title  MockGOM — Test Mock for Geopolitical Oracle Module
/// @notice Implements IGOM interface with configurable state for unit tests.
///         Allows test scripts to set zone status without real oracle infra.
/// @dev    NEVER deploy to mainnet. For local Hardhat/Ganache testing only.
/// @author Mujahid Ullah Khan Afridi, NMSU Industrial Engineering
///         Paper: GEOSUPPLY — IEEE Access (under review)
///         Repository: https://github.com/MujahidUllahKhan/GEOSUPPLY
contract MockGOM is IGOM {

    mapping(bytes32 => ZoneStatus) private _zoneStatus;
    mapping(bytes32 => bytes32)    private _evidenceHash;
    mapping(bytes32 => uint256)    private _resolutionDate;
    mapping(bytes32 => mapping(uint256 => bytes32)) private _eventHash;

    bytes32 public constant DEFAULT_EVIDENCE =
        keccak256(abi.encodePacked("MOCK-GEOSUPPLY-EVIDENCE-2026"));

    // =========================================================
    // Test Control Functions
    // =========================================================

    function setZone(bytes32 route, ZoneStatus status, bytes32 evHash) external {
        _zoneStatus[route]               = status;
        _evidenceHash[route]             = evHash;
        _eventHash[route][block.timestamp] = evHash;
        if (status == ZoneStatus.FORCE_MAJEURE) {
            emit ForceMajeureEvent(route, block.timestamp, evHash, 3);
        }
    }

    function setResolutionDate(bytes32 route, uint256 date) external {
        _resolutionDate[route] = date;
        if (date > 0) emit ForceMajeureResolved(route, date, _evidenceHash[route]);
    }

    /// @notice One-line helper: set route to FORCE_MAJEURE with default evidence.
    function triggerForceMajeure(bytes32 route) external {
        _zoneStatus[route]                 = ZoneStatus.FORCE_MAJEURE;
        _evidenceHash[route]               = DEFAULT_EVIDENCE;
        _eventHash[route][block.timestamp] = DEFAULT_EVIDENCE;
        emit ForceMajeureEvent(route, block.timestamp, DEFAULT_EVIDENCE, 3);
    }

    /// @notice One-line helper: resolve FM and return route to NORMAL.
    function resolveForceMajeure(bytes32 route) external {
        _zoneStatus[route]     = ZoneStatus.NORMAL;
        _resolutionDate[route] = block.timestamp;
        emit ForceMajeureResolved(route, block.timestamp, _evidenceHash[route]);
    }

    // =========================================================
    // IGOM Interface Implementation
    // =========================================================

    function checkZone(bytes32 route, uint256 /*timestamp*/)
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
}
