// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IGOM.sol";

/// @title  ASAP — Alternative Supplier Activation Protocol
/// @notice Implements GEOSUPPLY Layer 5: on-chain activation record for
///         alternative suppliers when primary supplier routes are under
///         geopolitical force majeure (Section IV.E).
/// @dev    Addresses Structural Failure 5 (no alternative supplier activation
///         protocol) identified in the GEOSUPPLY paper Section III.E.
///
///         Protocol per Section IV.E:
///         1. ASAP queries the ML ranking system (off-chain) for top-5
///            alternatives outside the FM zone
///         2. Contract compatibility is checked (pre-qualified suppliers)
///         3. Procurement officer approves one alternative via digital signature
///         4. AlternativeActivationEvent is recorded on-chain with full audit trail
///         5. Primary supplier receives notification of contract suspension
///            (not termination) with first-priority reinstatement rights
///
/// @author Mujahid Ullah Khan Afridi, NMSU Industrial Engineering
///         Repository: https://github.com/MujahidUllahKhan/GEOSUPPLY
contract ASAP {

    // =========================================================
    // Data Structures
    // =========================================================

    struct AlternativeActivation {
        address primarySupplier;        // Original supplier suspended
        address alternativeSupplier;    // Approved replacement
        bytes32 escrowContract;         // Associated TriStateEscrow (as bytes32)
        bytes32 shippingRoute;          // FM-affected route
        bytes32 gomEvidenceHash;        // GOM 3-of-5 evidence at activation
        address procurementOfficer;     // Officer who approved (digital sig)
        uint8   alternativeRankInML;    // ML ranking position (1=top)
        address[5] top5Alternatives;   // Full ML top-5 list at time of query
        uint256 activatedAt;
        bool    primaryReinstateable;  // Always true per protocol
        uint256 primaryReinstatedAt;  // 0 until reinstated
    }

    // =========================================================
    // Storage
    // =========================================================

    IGOM    public immutable gom;
    address public           owner;

    mapping(address => bool) public authorizedOfficers;

    /// @dev activationId => AlternativeActivation
    mapping(bytes32 => AlternativeActivation) public activations;

    bytes32[] public allActivationIds;
    uint256   public totalActivations;

    // =========================================================
    // Events
    // =========================================================

    /// @notice Core event: alternative supplier activated on-chain.
    ///         Per GEOSUPPLY Section IV.E: "The alternative supplier
    ///         activation — including the officer's signature, the ML ranking,
    ///         the GOM evidence, and the activation timestamp — is recorded
    ///         on-chain in an AlternativeActivationEvent."
    event AlternativeActivationEvent(
        bytes32 indexed activationId,
        address indexed primarySupplier,
        address indexed alternativeSupplier,
        bytes32         shippingRoute,
        uint8           alternativeRankInML,
        address         procurementOfficer,
        bytes32         gomEvidenceHash,
        uint256         activatedAt
    );

    /// @notice Emitted when primary supplier is reinstated after FM resolves.
    event PrimarySupplierReinstated(
        bytes32 indexed activationId,
        address indexed primarySupplier,
        address         reinstatedBy,
        uint256         reinstatedAt
    );

    event OfficerAuthorized(address indexed officer, bool authorized);

    // =========================================================
    // Modifiers
    // =========================================================

    modifier onlyOwner()   { require(msg.sender == owner, "ASAP: not owner"); _; }
    modifier onlyOfficer() {
        require(authorizedOfficers[msg.sender], "ASAP: not authorized officer");
        _;
    }

    // =========================================================
    // Constructor
    // =========================================================

    constructor(address _gom) {
        gom   = IGOM(_gom);
        owner = msg.sender;
        authorizedOfficers[msg.sender] = true;
    }

    // =========================================================
    // Authorization
    // =========================================================

    function authorizeOfficer(address officer, bool authorized) external onlyOwner {
        authorizedOfficers[officer] = authorized;
        emit OfficerAuthorized(officer, authorized);
    }

    // =========================================================
    // Core: Activate Alternative Supplier
    // =========================================================

    /// @notice Procurement officer activates an alternative supplier after
    ///         reviewing the ML-ranked list. Verifies FM is active via GOM.
    ///         Records the full decision on-chain per Section IV.E.
    ///
    /// @param primarySupplier       Original suspended supplier address
    /// @param alternativeSupplier   Officer-approved replacement
    /// @param escrowContract        TriStateEscrow contract address (as bytes32)
    /// @param shippingRoute         FM-affected route identifier
    /// @param top5Alternatives      ML top-5 ranked alternatives at query time
    /// @param alternativeRankInML   Rank of chosen alternative (1–5)
    function activateAlternativeSupplier(
        address            primarySupplier,
        address            alternativeSupplier,
        bytes32            escrowContract,
        bytes32            shippingRoute,
        address[5] calldata top5Alternatives,
        uint8              alternativeRankInML
    ) external onlyOfficer returns (bytes32 activationId) {
        require(primarySupplier     != address(0), "ASAP: zero primary supplier");
        require(alternativeSupplier != address(0), "ASAP: zero alternative supplier");
        require(primarySupplier     != alternativeSupplier, "ASAP: same supplier");
        require(alternativeRankInML >= 1 && alternativeRankInML <= 5,
                "ASAP: rank must be 1–5");

        // Verify route is under FM (GOM confirmation required per protocol)
        (IGOM.ZoneStatus status, bytes32 evHash) =
            gom.checkZone(shippingRoute, block.timestamp);
        require(status == IGOM.ZoneStatus.FORCE_MAJEURE,
                "ASAP: route not under FORCE_MAJEURE");

        activationId = keccak256(
            abi.encodePacked(
                primarySupplier, alternativeSupplier,
                shippingRoute, block.timestamp
            )
        );

        activations[activationId] = AlternativeActivation({
            primarySupplier:      primarySupplier,
            alternativeSupplier:  alternativeSupplier,
            escrowContract:       escrowContract,
            shippingRoute:        shippingRoute,
            gomEvidenceHash:      evHash,
            procurementOfficer:   msg.sender,
            alternativeRankInML:  alternativeRankInML,
            top5Alternatives:     top5Alternatives,
            activatedAt:          block.timestamp,
            primaryReinstateable: true,    // Always true per Section IV.E
            primaryReinstatedAt:  0
        });

        allActivationIds.push(activationId);
        totalActivations++;

        emit AlternativeActivationEvent(
            activationId, primarySupplier, alternativeSupplier,
            shippingRoute, alternativeRankInML, msg.sender,
            evHash, block.timestamp
        );
    }

    // =========================================================
    // Primary Supplier Reinstatement
    // =========================================================

    /// @notice Officer reinstates the primary supplier after FM resolves.
    ///         Per Section IV.E: "primary supplier retains first-priority
    ///         reinstatement when the force majeure resolves."
    function reinstatePrimarySupplier(bytes32 activationId)
        external onlyOfficer
    {
        AlternativeActivation storage a = activations[activationId];
        require(a.activatedAt > 0,             "ASAP: activation not found");
        require(a.primaryReinstatedAt == 0,    "ASAP: already reinstated");

        a.primaryReinstatedAt = block.timestamp;

        emit PrimarySupplierReinstated(
            activationId, a.primarySupplier, msg.sender, block.timestamp
        );
    }

    // =========================================================
    // View Helpers
    // =========================================================

    function getActivation(bytes32 activationId)
        external view returns (AlternativeActivation memory)
    {
        return activations[activationId];
    }

    function getAllActivationIds() external view returns (bytes32[] memory) {
        return allActivationIds;
    }
}
