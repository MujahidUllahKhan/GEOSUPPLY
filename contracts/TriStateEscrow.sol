// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IGOM.sol";

/// @title  TriStateEscrow — Three-State Payment Escrow Contract
/// @notice Implements GEOSUPPLY Layer 2: tri-state payment governance
///         with NORMAL, FORCE_MAJEURE, and PARTIAL states.
/// @dev    Addresses Structural Failure 1 ("Code is Law" automatic execution
///         of wrong outcomes) and Structural Failure 3 (binary escrow —
///         no force majeure state) identified in the GEOSUPPLY paper.
///         DRC rulings require genuine 3-of-5 multi-signature approval.
///         All state transitions are immutably recorded on-chain.
/// @author Mujahid Ullah Khan Afridi, NMSU Industrial Engineering
///         Repository: https://github.com/MujahidUllahKhan/GEOSUPPLY
contract TriStateEscrow {

    // =========================================================
    // Escrow State — Equation (1) in GEOSUPPLY paper
    // =========================================================

    /// @notice Three states per Section IV.B:
    ///   NORMAL        — Deadline enforced; penalties apply on miss
    ///   FORCE_MAJEURE — All enforcement suspended; funds in neutral escrow
    ///   PARTIAL       — DRC ruling applied; proportional payment executed
    enum EscrowState { NORMAL, FORCE_MAJEURE, PARTIAL }

    EscrowState public currentState;

    // =========================================================
    // Contract Parties and Parameters
    // =========================================================

    IGOM            public immutable gom;
    address payable public immutable buyer;
    address payable public immutable supplier;
    bytes32         public immutable shippingRoute;

    uint256 public contractValue;
    uint256 public securityDeposit;
    uint256 public originalDeadline;
    uint256 public extendedDeadline;
    uint256 public fmActivatedAt;

    uint256 public constant RESTORATION_BUFFER = 30 days;

    // =========================================================
    // HITL-DRC: 3-of-5 Multi-Signature (Section IV.D)
    // =========================================================

    /// @notice Five DRC adjudicators set at deployment:
    ///   [0] Buyer representative
    ///   [1] Seller / supplier representative
    ///   [2] Neutral trade expert (e.g. ICC arbitrator)
    ///   [3] Technical blockchain auditor
    ///   [4] Legal expert in force majeure / international trade law
    address[5] public drcMembers;

    struct RulingProposal {
        uint256 supplierBasisPoints;
        string  rationale;
        uint8   voteCount;
        bool    executed;
    }

    /// @dev rulingId => RulingProposal
    mapping(bytes32 => RulingProposal) public rulingProposals;

    /// @dev rulingId => member address => has voted
    mapping(bytes32 => mapping(address => bool)) public drcVoted;

    // =========================================================
    // Events
    // =========================================================

    event StateTransition(
        EscrowState indexed prevState,
        EscrowState indexed newState,
        uint256             timestamp,
        bytes32             gomEvidenceHash,
        address             authorizedBy
    );

    event DeliveryConfirmed(
        address indexed confirmedBy,
        uint256         amount,
        uint256         timestamp
    );

    event DepositReturned(
        address indexed supplier,
        uint256         amount,
        string          reason
    );

    event PenaltyApplied(
        address indexed supplier,
        uint256         amount,
        string          reason
    );

    event DRCVoteSubmitted(
        bytes32 indexed rulingId,
        address indexed member,
        uint256         supplierBasisPoints,
        uint8           totalVotesSoFar
    );

    event DRCRulingExecuted(
        bytes32 indexed rulingId,
        uint256         supplierAmount,
        uint256         buyerRefund,
        uint256         supplierBasisPoints,
        string          rationale,
        uint8           finalVoteCount
    );

    event PartialPaymentApplied(
        uint256 supplierAmount,
        uint256 buyerRefund,
        uint256 supplierBasisPoints,
        string  drcRationale
    );

    // =========================================================
    // Modifiers
    // =========================================================

    modifier onlyBuyer() {
        require(msg.sender == buyer, "TriStateEscrow: not buyer");
        _;
    }

    modifier onlyDRCMember() {
        bool isMember = false;
        for (uint256 i = 0; i < 5; i++) {
            if (drcMembers[i] == msg.sender) { isMember = true; break; }
        }
        require(isMember, "TriStateEscrow: not a DRC member");
        _;
    }

    modifier inState(EscrowState expected) {
        require(currentState == expected, "TriStateEscrow: wrong state");
        _;
    }

    // =========================================================
    // Constructor
    // =========================================================

    /// @param _buyer       Buyer's wallet address
    /// @param _supplier    Supplier's wallet address
    /// @param _gom         Deployed GOM oracle address
    /// @param _route       keccak256(abi.encodePacked("HORMUZ-GULF"))
    /// @param _deadline    Unix timestamp of original delivery deadline
    /// @param _drcMembers  Five DRC adjudicator addresses (Section IV.D)
    constructor(
        address payable   _buyer,
        address payable   _supplier,
        address           _gom,
        bytes32           _route,
        uint256           _deadline,
        address[5] memory _drcMembers
    ) payable {
        require(msg.value > 0,                  "TriStateEscrow: value required");
        require(_deadline > block.timestamp,    "TriStateEscrow: deadline in past");

        for (uint256 i = 0; i < 5; i++) {
            require(_drcMembers[i] != address(0), "TriStateEscrow: zero DRC address");
            for (uint256 j = i + 1; j < 5; j++) {
                require(_drcMembers[i] != _drcMembers[j],
                        "TriStateEscrow: duplicate DRC member");
            }
        }

        buyer            = _buyer;
        supplier         = _supplier;
        gom              = IGOM(_gom);
        shippingRoute    = _route;
        originalDeadline = _deadline;
        contractValue    = msg.value;
        currentState     = EscrowState.NORMAL;
        drcMembers       = _drcMembers;
    }

    // =========================================================
    // Core: GOM-Triggered State Transition
    // =========================================================

    /// @notice Syncs escrow state with GOM zone. Callable by anyone.
    ///         Implements Equation (1) state transitions.
    function checkAndTransition() external {
        (IGOM.ZoneStatus status, bytes32 evHash) =
            gom.checkZone(shippingRoute, block.timestamp);

        EscrowState prev = currentState;

        if (status == IGOM.ZoneStatus.FORCE_MAJEURE
                && currentState == EscrowState.NORMAL) {
            currentState  = EscrowState.FORCE_MAJEURE;
            fmActivatedAt = block.timestamp;

        } else if (currentState == EscrowState.FORCE_MAJEURE
                && status == IGOM.ZoneStatus.NORMAL) {
            uint256 resolvedAt = gom.getResolutionDate(shippingRoute);
            extendedDeadline   = resolvedAt + RESTORATION_BUFFER;
            currentState       = EscrowState.NORMAL;
        }

        if (currentState != prev) {
            emit StateTransition(prev, currentState, block.timestamp, evHash, msg.sender);
        }
    }

    // =========================================================
    // NORMAL State Actions
    // =========================================================

    function confirmDelivery()
        external onlyBuyer inState(EscrowState.NORMAL)
    {
        uint256 deadline = extendedDeadline > 0 ? extendedDeadline : originalDeadline;
        require(block.timestamp <= deadline, "TriStateEscrow: deadline exceeded");

        uint256 amount = contractValue;
        contractValue  = 0;
        supplier.transfer(amount);
        _returnDeposit("Delivery confirmed by buyer");
        emit DeliveryConfirmed(buyer, amount, block.timestamp);
    }

    /// @notice Applies penalty if deadline exceeded in NORMAL state.
    ///         Cannot execute in FORCE_MAJEURE state — core GEOSUPPLY protection.
    function applyPenalty()
        external onlyBuyer inState(EscrowState.NORMAL)
    {
        uint256 deadline = extendedDeadline > 0 ? extendedDeadline : originalDeadline;
        require(block.timestamp > deadline,     "TriStateEscrow: deadline not exceeded");
        require(securityDeposit > 0,            "TriStateEscrow: no deposit");

        uint256 penalty = securityDeposit;
        securityDeposit = 0;
        buyer.transfer(penalty);
        emit PenaltyApplied(supplier, penalty, "Deadline exceeded in NORMAL state");
    }

    // =========================================================
    // FORCE_MAJEURE State Actions
    // =========================================================

    /// @notice Supplier delivered despite FM event — full payment released.
    function confirmFMDelivery()
        external onlyBuyer inState(EscrowState.FORCE_MAJEURE)
    {
        uint256 amount = contractValue;
        contractValue  = 0;
        supplier.transfer(amount);
        _returnDeposit("Supplier delivered despite FM event");
        emit DeliveryConfirmed(buyer, amount, block.timestamp);
    }

    // =========================================================
    // HITL-DRC: 3-of-5 Multi-Signature Ruling (Section IV.D)
    // =========================================================

    /// @notice DRC member submits or adds vote to a ruling proposal.
    ///         Ruling auto-executes when 3rd vote is cast.
    ///         Ruling identified by keccak256(supplierBasisPoints, rationale).
    ///
    /// @param supplierBasisPoints  Supplier's share in basis points (0–10000):
    ///   0     = full refund to buyer
    ///   3000  = 30%  (goods prepared, not shipped — Section V.B Scenario B)
    ///   7000  = 70%  (goods shipped, diverted en route)
    ///   10000 = 100% (goods delivered to alternate port)
    /// @param rationale  On-chain DRC rationale (permanently stored).
    ///   Should reference GOM evidence hash and six non-fault criteria
    ///   per Section IV.D of the GEOSUPPLY paper.
    function submitDRCVote(
        uint256         supplierBasisPoints,
        string calldata rationale
    )
        external
        onlyDRCMember
        inState(EscrowState.FORCE_MAJEURE)
    {
        require(supplierBasisPoints <= 10000,   "TriStateEscrow: basis points > 10000");
        require(bytes(rationale).length > 0,    "TriStateEscrow: empty rationale");

        bytes32 rulingId = keccak256(abi.encodePacked(supplierBasisPoints, rationale));

        require(!drcVoted[rulingId][msg.sender],
                "TriStateEscrow: member already voted on this proposal");
        require(!rulingProposals[rulingId].executed,
                "TriStateEscrow: ruling already executed");

        drcVoted[rulingId][msg.sender]               = true;
        rulingProposals[rulingId].voteCount         += 1;
        rulingProposals[rulingId].supplierBasisPoints = supplierBasisPoints;
        rulingProposals[rulingId].rationale           = rationale;

        uint8 total = rulingProposals[rulingId].voteCount;
        emit DRCVoteSubmitted(rulingId, msg.sender, supplierBasisPoints, total);

        if (total >= 3) {
            rulingProposals[rulingId].executed = true;
            _executeDRCRuling(rulingId, supplierBasisPoints, rationale, total);
        }
    }

    /// @notice Returns vote count and execution status for a ruling proposal.
    function getDRCVoteCount(
        uint256         supplierBasisPoints,
        string calldata rationale
    ) external view returns (uint8 voteCount, bool executed) {
        bytes32 rulingId = keccak256(abi.encodePacked(supplierBasisPoints, rationale));
        return (rulingProposals[rulingId].voteCount, rulingProposals[rulingId].executed);
    }

    /// @notice Returns whether a DRC member has voted on a specific proposal.
    function hasDRCMemberVoted(
        address         member,
        uint256         supplierBasisPoints,
        string calldata rationale
    ) external view returns (bool) {
        bytes32 rulingId = keccak256(abi.encodePacked(supplierBasisPoints, rationale));
        return drcVoted[rulingId][member];
    }

    // =========================================================
    // Deposit Management
    // =========================================================

    /// @notice Supplier locks security deposit. Protected in FM state.
    function lockDeposit() external payable {
        require(msg.sender == supplier, "TriStateEscrow: only supplier");
        require(msg.value > 0,          "TriStateEscrow: deposit required");
        securityDeposit += msg.value;
    }

    // =========================================================
    // View Helpers
    // =========================================================

    function activeDeadline() external view returns (uint256) {
        return extendedDeadline > 0 ? extendedDeadline : originalDeadline;
    }

    function balance() external view returns (uint256) {
        return address(this).balance;
    }

    // =========================================================
    // Internal
    // =========================================================

    function _executeDRCRuling(
        bytes32        rulingId,
        uint256        supplierBasisPoints,
        string  memory rationale,
        uint8          finalVoteCount
    ) internal {
        (, bytes32 evHash) = gom.checkZone(shippingRoute, block.timestamp);

        emit StateTransition(
            EscrowState.FORCE_MAJEURE, EscrowState.PARTIAL,
            block.timestamp, evHash, msg.sender
        );
        currentState = EscrowState.PARTIAL;

        uint256 supplierAmt = (contractValue * supplierBasisPoints) / 10000;
        uint256 buyerRefund = contractValue - supplierAmt;
        contractValue       = 0;

        if (supplierAmt > 0) supplier.transfer(supplierAmt);
        if (buyerRefund > 0) buyer.transfer(buyerRefund);

        _returnDeposit("Non-fault FM ruling by HITL-DRC (3-of-5 approved)");

        emit DRCRulingExecuted(
            rulingId, supplierAmt, buyerRefund,
            supplierBasisPoints, rationale, finalVoteCount
        );
        emit PartialPaymentApplied(supplierAmt, buyerRefund, supplierBasisPoints, rationale);
    }

    function _returnDeposit(string memory reason) internal {
        if (securityDeposit > 0) {
            uint256 amt     = securityDeposit;
            securityDeposit = 0;
            supplier.transfer(amt);
            emit DepositReturned(supplier, amt, reason);
        }
    }

    receive() external payable {}
}
