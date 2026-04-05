// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title  SanctionsCompliance — Real-Time Sanctions Screening Layer
/// @notice Implements GEOSUPPLY Layer 7: intercepts all outbound payments
///         and screens recipient addresses against four international
///         sanctions lists before execution (Section IV.G).
/// @dev    Addresses Structural Failure 7 identified in the GEOSUPPLY paper.
///
///         ARCHITECTURE:
///         - Sanctions oracle maintains the sanctionedAddresses mapping
///           (updated daily from OFAC/EU/UN/HMT official APIs).
///         - Payment contracts (e.g. TriStateEscrow) call screenAndPay()
///           which reads the oracle-maintained mapping to determine
///           sanctioned status — no oracle call needed at payment time.
///         - Owner authorizes which payment contracts may call screenAndPay().
///         - This design prevents gaming (status from stored mapping, not
///           from a parameter that could be passed incorrectly).
///
/// @author Mujahid Ullah Khan Afridi, NMSU Industrial Engineering
///         Paper: GEOSUPPLY — IEEE Access (under review)
///         Repository: https://github.com/MujahidUllahKhan/GEOSUPPLY
contract SanctionsCompliance {

    // =========================================================
    // Sanctions Lists (Section IV.G)
    // =========================================================

    string public constant LIST_OFAC_SDN = "OFAC-SDN";
    string public constant LIST_EU       = "EU-CONSOLIDATED";
    string public constant LIST_UN       = "UN-SECURITY-COUNCIL";
    string public constant LIST_UK_HMT   = "UK-HM-TREASURY";

    // =========================================================
    // Hold Record
    // =========================================================

    struct SanctionsHold {
        address payable recipient;
        uint256         amount;
        uint256         heldAt;
        string          listFlagged;
        bool            resolved;
        bool            released;
        string          officerRationale;
        address         resolvedBy;
        uint256         resolvedAt;
    }

    // =========================================================
    // Storage
    // =========================================================

    address public sanctionsOracle;
    address public complianceOfficer;
    address public owner;

    /// @notice Oracle-maintained map of sanctioned addresses.
    mapping(address => bool)   public sanctionedAddresses;

    /// @notice Tracks which sanctions list flagged each address.
    mapping(address => string) public sanctionedOnList;

    /// @notice Payment contracts authorized to call screenAndPay().
    ///         Set by owner via authorizePaymentContract().
    mapping(address => bool)   public authorizedPaymentContracts;

    mapping(bytes32 => SanctionsHold) public holds;

    uint256 public totalHeld;
    uint256 public holdCount;

    // =========================================================
    // Events
    // =========================================================

    event PaymentCleaned(
        address indexed recipient,
        uint256         amount,
        uint256         timestamp
    );

    /// @notice Emitted when payment is blocked — "SanctionsHoldEvent"
    ///         per GEOSUPPLY paper Section IV.G.
    event SanctionsHoldEvent(
        bytes32 indexed holdId,
        address indexed recipient,
        uint256         amount,
        string          listFlagged,
        uint256         timestamp
    );

    event HoldReleased(
        bytes32 indexed holdId,
        address indexed recipient,
        address indexed officer,
        uint256         amount,
        string          rationale,
        uint256         timestamp
    );

    event HoldReturned(
        bytes32 indexed holdId,
        address indexed returnedTo,
        address indexed officer,
        uint256         amount,
        uint256         timestamp
    );

    event SanctionedAddressUpdated(
        address indexed target,
        bool            isSanctioned,
        string          listName,
        uint256         timestamp
    );

    event PaymentContractAuthorized(
        address indexed contractAddress,
        bool            authorized
    );

    // =========================================================
    // Modifiers
    // =========================================================

    modifier onlyOwner() {
        require(msg.sender == owner,              "SanctionsCompliance: not owner");   _;
    }
    modifier onlyOracle() {
        require(msg.sender == sanctionsOracle,    "SanctionsCompliance: not oracle");  _;
    }
    modifier onlyOfficer() {
        require(msg.sender == complianceOfficer,  "SanctionsCompliance: not officer"); _;
    }
    modifier onlyAuthorizedContract() {
        require(authorizedPaymentContracts[msg.sender],
                "SanctionsCompliance: caller not authorized payment contract");
        _;
    }

    // =========================================================
    // Constructor
    // =========================================================

    constructor(address _oracle, address _officer) {
        sanctionsOracle   = _oracle;
        complianceOfficer = _officer;
        owner             = msg.sender;
    }

    // =========================================================
    // Authorization Management
    // =========================================================

    /// @notice Owner authorizes a payment contract (e.g. TriStateEscrow)
    ///         to call screenAndPay(). Must be called after deploying
    ///         TriStateEscrow and before it attempts any payments.
    function authorizePaymentContract(address contractAddress, bool authorized)
        external onlyOwner
    {
        authorizedPaymentContracts[contractAddress] = authorized;
        emit PaymentContractAuthorized(contractAddress, authorized);
    }

    // =========================================================
    // Core: Screen and Pay — FIXED access control
    // =========================================================

    /// @notice Called by TriStateEscrow (or any authorized payment contract)
    ///         before releasing funds. Checks oracle-maintained sanctions list.
    ///         Sanctioned status is read from the stored mapping — not passed
    ///         as a parameter — preventing any manipulation.
    ///
    ///         Clean payments execute immediately and emit PaymentCleaned.
    ///         Sanctioned recipients are placed in a hold with SanctionsHoldEvent
    ///         emitted on-chain per GEOSUPPLY Section IV.G.
    ///
    /// @param recipient  Wallet address to receive payment
    /// @param initiator  Address to return funds to if hold is rejected
    /// @return holdId    Non-zero bytes32 if payment was blocked; zero if clean
    function screenAndPay(
        address payable recipient,
        address         initiator
    ) external payable onlyAuthorizedContract returns (bytes32 holdId) {

        require(msg.value > 0, "SanctionsCompliance: no payment value");

        bool   isSanctioned = sanctionedAddresses[recipient];
        string memory list  = sanctionedOnList[recipient];

        if (!isSanctioned) {
            recipient.transfer(msg.value);
            emit PaymentCleaned(recipient, msg.value, block.timestamp);
            return bytes32(0);
        }

        // Create hold
        holdId = keccak256(
            abi.encodePacked(recipient, msg.value, block.timestamp, holdCount)
        );
        holdCount++;
        totalHeld += msg.value;

        holds[holdId] = SanctionsHold({
            recipient:        recipient,
            amount:           msg.value,
            heldAt:           block.timestamp,
            listFlagged:      list,
            resolved:         false,
            released:         false,
            officerRationale: "",
            resolvedBy:       address(0),
            resolvedAt:       0
        });

        emit SanctionsHoldEvent(holdId, recipient, msg.value, list, block.timestamp);
    }

    // =========================================================
    // Compliance Officer Actions
    // =========================================================

    /// @notice Officer releases hold after confirming legal basis.
    ///         Rationale stored permanently on-chain (e.g. "OFAC GL-8").
    function releaseHold(bytes32 holdId, string calldata rationale)
        external onlyOfficer
    {
        SanctionsHold storage h = holds[holdId];
        require(!h.resolved, "SanctionsCompliance: already resolved");
        require(h.amount > 0, "SanctionsCompliance: no funds in hold");

        h.resolved         = true;
        h.released         = true;
        h.officerRationale = rationale;
        h.resolvedBy       = msg.sender;
        h.resolvedAt       = block.timestamp;
        totalHeld         -= h.amount;

        h.recipient.transfer(h.amount);
        emit HoldReleased(holdId, h.recipient, msg.sender, h.amount, rationale, block.timestamp);
    }

    /// @notice Officer rejects hold and returns funds to payment initiator.
    function returnHold(
        bytes32         holdId,
        address payable returnTo,
        string calldata rationale
    ) external onlyOfficer {
        SanctionsHold storage h = holds[holdId];
        require(!h.resolved, "SanctionsCompliance: already resolved");

        h.resolved         = true;
        h.released         = false;
        h.officerRationale = rationale;
        h.resolvedBy       = msg.sender;
        h.resolvedAt       = block.timestamp;
        totalHeld         -= h.amount;

        returnTo.transfer(h.amount);
        emit HoldReturned(holdId, returnTo, msg.sender, h.amount, block.timestamp);
    }

    // =========================================================
    // Oracle: Update Sanctions Lists
    // =========================================================

    /// @notice Oracle updates on-chain sanctioned address mapping.
    ///         Called daily or on emergency basis during active conflict.
    function updateSanctionedAddress(
        address target,
        bool    isSanctioned,
        string calldata listName
    ) external onlyOracle {
        sanctionedAddresses[target] = isSanctioned;
        sanctionedOnList[target]    = isSanctioned ? listName : "";
        emit SanctionedAddressUpdated(target, isSanctioned, listName, block.timestamp);
    }

    function batchUpdateSanctionedAddresses(
        address[] calldata targets,
        bool[]    calldata flags,
        string    calldata listName
    ) external onlyOracle {
        require(targets.length == flags.length, "SanctionsCompliance: length mismatch");
        for (uint256 i = 0; i < targets.length; i++) {
            sanctionedAddresses[targets[i]] = flags[i];
            sanctionedOnList[targets[i]]    = flags[i] ? listName : "";
            emit SanctionedAddressUpdated(
                targets[i], flags[i], listName, block.timestamp
            );
        }
    }

    // =========================================================
    // View Helpers
    // =========================================================

    function isAddressSanctioned(address target) external view returns (bool) {
        return sanctionedAddresses[target];
    }

    function getHold(bytes32 holdId) external view returns (SanctionsHold memory) {
        return holds[holdId];
    }

    // =========================================================
    // Admin
    // =========================================================

    function updateOfficer(address _officer) external onlyOwner {
        complianceOfficer = _officer;
    }

    function updateOracle(address _oracle) external onlyOwner {
        sanctionsOracle = _oracle;
    }

    receive() external payable {}
}
