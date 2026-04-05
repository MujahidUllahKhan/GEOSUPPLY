// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title  ComplianceAudit — HITL-DRC Ruling Audit Log
/// @notice Implements the on-chain audit trail for Human-in-the-Loop
///         Dispute Resolution Committee rulings as described in
///         GEOSUPPLY Section IV.D.
/// @dev    "All rulings are recorded on-chain in ComplianceAudit.sol
///          with the full rationale, evidence references, and dissenting
///          opinions (if any)." — GEOSUPPLY paper Section IV.D.
///
///         DRC members call logRuling() after a TriStateEscrow ruling
///         executes to create the permanent audit record. The escrow
///         address and DRC vote details are recorded immutably.
///
/// @author Mujahid Ullah Khan Afridi, NMSU Industrial Engineering
///         Paper: GEOSUPPLY — IEEE Access (under review)
///         Repository: https://github.com/MujahidUllahKhan/GEOSUPPLY
contract ComplianceAudit {

    // =========================================================
    // Audit Record
    // =========================================================

    struct AuditRecord {
        bytes32 rulingId;               // keccak256(basisPoints, rationale)
        address escrowContract;         // TriStateEscrow that executed ruling
        address[] drcVoters;            // Addresses of 3+ approving members
        uint256 supplierBasisPoints;    // Payment split awarded to supplier
        string  rationale;             // Full DRC rationale text
        bytes32 gomEvidenceHash;        // GOM 3-of-5 evidence bundle hash
        uint8   votesApproved;          // Final vote count (always >= 3)
        uint256 recordedAt;             // Block timestamp
        string  dissentingOpinion;      // Empty string if unanimous
    }

    // =========================================================
    // Storage
    // =========================================================

    address public owner;

    /// @notice Authorized loggers: TriStateEscrow contracts or DRC members
    mapping(address => bool) public authorizedLoggers;

    /// @dev rulingId => AuditRecord
    mapping(bytes32 => AuditRecord) public auditRecords;

    /// @dev All ruling IDs in order of recording
    bytes32[] public allRulingIds;

    uint256 public totalRulings;

    // =========================================================
    // Events
    // =========================================================

    /// @notice Emitted when a DRC ruling is permanently recorded.
    event RulingRecorded(
        bytes32 indexed rulingId,
        address indexed escrowContract,
        uint256         supplierBasisPoints,
        uint8           votesApproved,
        bytes32         gomEvidenceHash,
        uint256         recordedAt
    );

    event LoggerAuthorized(address indexed logger, bool authorized);

    // =========================================================
    // Modifiers
    // =========================================================

    modifier onlyOwner() {
        require(msg.sender == owner, "ComplianceAudit: not owner");
        _;
    }

    modifier onlyAuthorizedLogger() {
        require(authorizedLoggers[msg.sender],
                "ComplianceAudit: not an authorized logger");
        _;
    }

    // =========================================================
    // Constructor
    // =========================================================

    constructor() {
        owner = msg.sender;
        authorizedLoggers[msg.sender] = true;
    }

    // =========================================================
    // Authorization
    // =========================================================

    function authorizeLogger(address logger, bool authorized) external onlyOwner {
        authorizedLoggers[logger] = authorized;
        emit LoggerAuthorized(logger, authorized);
    }

    // =========================================================
    // Core: Log DRC Ruling
    // =========================================================

    /// @notice Records a HITL-DRC ruling permanently on-chain.
    ///         Called by DRC members or TriStateEscrow after 3-of-5 approval.
    ///
    /// @param rulingId            keccak256(supplierBasisPoints, rationale)
    ///                            Must match the rulingId from TriStateEscrow
    /// @param escrowContract      Address of the TriStateEscrow that ruled
    /// @param drcVoters           Addresses of DRC members who voted to approve
    /// @param supplierBasisPoints Payment split in basis points (0–10000)
    /// @param rationale           Full ruling rationale text
    /// @param gomEvidenceHash     GOM 3-of-5 evidence hash at time of ruling
    /// @param votesApproved       Final vote count (must be >= 3)
    /// @param dissentingOpinion   Text of dissenting opinion; empty if unanimous
    function logRuling(
        bytes32          rulingId,
        address          escrowContract,
        address[] calldata drcVoters,
        uint256          supplierBasisPoints,
        string  calldata rationale,
        bytes32          gomEvidenceHash,
        uint8            votesApproved,
        string  calldata dissentingOpinion
    ) external onlyAuthorizedLogger {
        require(auditRecords[rulingId].recordedAt == 0,
                "ComplianceAudit: ruling already recorded");
        require(votesApproved >= 3,
                "ComplianceAudit: ruling requires at least 3 votes");
        require(drcVoters.length >= 3,
                "ComplianceAudit: must provide at least 3 voter addresses");
        require(supplierBasisPoints <= 10000,
                "ComplianceAudit: basis points cannot exceed 10000");
        require(bytes(rationale).length > 0,
                "ComplianceAudit: rationale cannot be empty");

        auditRecords[rulingId] = AuditRecord({
            rulingId:            rulingId,
            escrowContract:      escrowContract,
            drcVoters:           drcVoters,
            supplierBasisPoints: supplierBasisPoints,
            rationale:           rationale,
            gomEvidenceHash:     gomEvidenceHash,
            votesApproved:       votesApproved,
            recordedAt:          block.timestamp,
            dissentingOpinion:   dissentingOpinion
        });

        allRulingIds.push(rulingId);
        totalRulings++;

        emit RulingRecorded(
            rulingId, escrowContract, supplierBasisPoints,
            votesApproved, gomEvidenceHash, block.timestamp
        );
    }

    // =========================================================
    // View Helpers
    // =========================================================

    function getAuditRecord(bytes32 rulingId)
        external view returns (AuditRecord memory)
    {
        return auditRecords[rulingId];
    }

    function getAllRulingIds() external view returns (bytes32[] memory) {
        return allRulingIds;
    }

    function rulingExists(bytes32 rulingId) external view returns (bool) {
        return auditRecords[rulingId].recordedAt > 0;
    }
}
