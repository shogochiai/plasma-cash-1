pragma solidity ^0.4.24;

import "./PlasmaExits.sol";
import "./../../Helpers/SparseMerkleTree.sol";
import "./../../Libraries/ChallengeLib.sol";
import "./../../Libraries/ECVerify.sol";

contract PlasmaChallenges is PlasmaExits, SparseMerkleTree {
    /**
     * Event for exit challenge logging
     * @notice This event only fires if `challengeBefore` is called. Other
     *         types of challenges cannot be responded to and thus do not
     *         require an event.
     * @param slot The slot of the coin whose exit was challenged
     * @param txHash The hash of the tx used for the challenge
     */
    event ChallengedExit(uint64 indexed slot, bytes32 txHash);

    /**
     * Event for exit response logging
     * @notice This only logs responses to `challengeBefore`, other challenges
     *         do not require responses.
     * @param slot The slot of the coin whose challenge was responded to
     */
    event RespondedExitChallenge(uint64 indexed slot);

    /**
     * Event to log the slashing of a bond
     * @param from The address of the user whose bonds have been slashed
     * @param to The recipient of the slashed bonds
     * @param amount The bound amount which has been forfeited
     */
    event SlashedBond(address indexed from, address indexed to, uint256 amount);

    uint256 constant BOND_AMOUNT = 0.1 ether;
    // An exit can be finalized after it has matured,
    // after T2 = T0 + MATURITY_PERIOD
    // An exit can be challenged in the first window
    // between T0 and T1 ( T1 = T0 + CHALLENGE_WINDOW)
    // A challenge can be responded to in the second window
    // between T1 and T2
    uint256 constant MATURITY_PERIOD = 7 days;
    uint256 constant CHALLENGE_WINDOW = 3 days + 12 hours;

    using Transaction for bytes;
    using ChallengeLib for ChallengeLib.Challenge[];
    using ECVerify for bytes32;

    SparseMerkleTree smt;

    // Track owners of txs that are pending a response
    struct Challenge {
        address owner;
        uint256 blockNumber;
    }
    mapping (uint64 => ChallengeLib.Challenge[]) challenges;

    modifier cleanupExit(uint64 slot) {
        _;
        delete coins[slot].exit;
        delete exitSlots[getExitIndex(slot)];
    }

    /******************** CHALLENGES ********************/

    function challengeOptimisticExit(uint64 slot, uint256 blockNumber, bytes txBytes, bytes proof, bool parent) external
        isState(slot, State.EXITING)
        cleanupExit(slot)
    {
        Transaction.TX memory txData = txBytes.decodeTx();
        require(txData.slot == slot, "Tx is referencing another slot");


        if (parent) { // check parent tx
            require(blockNumber == coins[slot].exit.parentBlock, "Not challenging the parent block");
            require(txData.owner != coins[slot].exit.parentOwner);
        } else {
            require(blockNumber == coins[slot].exit.exitBlock, "Not challenging the exiting block");
            require(txData.owner != coins[slot].exit.owner ||  // different owner
                    txData.parentBlock != coins[slot].exit.parentBlock); // or different parentblock
        }

        // Check the inclusion
        checkTxIncluded(slot, txData.hash, blockNumber, proof);
        applyPenalties(slot);
    }


    /// @dev Submits proof of a transaction before parentTx as an exit challenge
    /// @notice Exitor has to call respondChallengeBefore and submit a
    ///         transaction before parentTx or parentTx itself.
    /// @param slot The slot corresponding to the coin whose exit is being challenged
    /// @param parentTxBytes The RLP-encoded transaction involving a particular
    ///        coin which took place directly before exitingTxBytes
    /// @param txBytes The RLP-encoded transaction involving a particular
    ///        coin which an exiting owner of the coin claims to be the latest
    /// @param parentTxInclusionProof An inclusion proof of parentTx
    /// @param txInclusionProof An inclusion proof of exitingTx
    /// @param signature The signature of the txBytes by the coin
    ///        owner indicated in parentTx
    /// @param blocks An array of two block numbers, at index 0, the block
    ///        containing the parentTx and at index 1, the block containing
    ///        the exitingTx
    function challengeBefore(
        uint64 slot,
        bytes parentTxBytes, bytes txBytes,
        bytes parentTxInclusionProof, bytes txInclusionProof,
        bytes signature,
        uint256[2] blocks)
        external
        payable isBonded
        isState(slot, State.EXITING)
    {
        doInclusionChecks(
            parentTxBytes, txBytes,
            parentTxInclusionProof, txInclusionProof,
            signature,
            blocks
        );
        setChallenged(slot, txBytes.owner(), blocks[1], txBytes.hash());
    }

    // stack too deep helper
    function doInclusionChecks(
        bytes parentTxBytes, bytes exitingTxBytes,
        bytes parentTxInclusionProof, bytes exitingTxInclusionProof,
        bytes signature,
        uint256[2] blocks)
        private
        view
    {
        require(blocks[0] < blocks[1]);

        Transaction.TX memory exitingTxData = exitingTxBytes.decodeTx();
        Transaction.TX memory parentTxData = parentTxBytes.decodeTx();

        // Both transactions need to be referring to the same slot
        require(exitingTxData.slot == parentTxData.slot);

        // The exiting transaction must be signed by the parent transaction's owner
        require(exitingTxData.hash.ecverify(signature, parentTxData.owner), "Invalid signature");

        // Both transactions must be included in their respective blocks
        checkTxIncluded(parentTxData.slot, parentTxData.hash, blocks[0], parentTxInclusionProof);
        checkTxIncluded(exitingTxData.slot, exitingTxData.hash, blocks[1], exitingTxInclusionProof);
    }


    // Challenge invalid history with a deposit transaction
    function challengeBeforeDeposit(
        uint64 slot)
        external
        payable isBonded
        isState(slot, State.EXITING)
    {
        // Create the tx that we're challenging
        bytes memory rlpTx = Transaction.encode(slot, 0, coins[slot].owner);
        bytes32 txHash = rlpTx.hash();
        setChallenged(slot, coins[slot].owner, coins[slot].depositBlock, txHash);
    }


    /// @dev Submits proof of a later transaction that corresponds to a challenge
    /// @notice Can only be called in the second window of the exit period.
    /// @param slot The slot corresponding to the coin whose exit is being challenged
    /// @param challengingTxHash The hash of the transaction
    ///        corresponding to the challenge we're responding to
    /// @param respondingBlockNumber The block number which included the transaction
    ///        we are responding with
    /// @param respondingTransaction The RLP-encoded transaction involving a particular
    ///        coin which took place directly after challengingTransaction
    /// @param proof An inclusion proof of respondingTransaction
    /// @param signature The signature which proves a direct spend from the challenger
    function respondChallengeBefore(
        uint64 slot,
        bytes32 challengingTxHash,
        uint256 respondingBlockNumber,
        bytes respondingTransaction,
        bytes proof,
        bytes signature)
        external
    {
        // Check that the transaction being challenged exists
        require(challenges[slot].contains(challengingTxHash), "Responding to non existing challenge");

        // Get index of challenge in the challenges array
        uint256 index = uint256(challenges[slot].indexOf(challengingTxHash));

        checkResponse(slot, index, respondingBlockNumber, respondingTransaction, signature, proof);

        // If the exit was actually challenged and responded, penalize the challenger and award the responder
        slashBond(challenges[slot][index].challenger, msg.sender);

        // Put coin back to the exiting state
        coins[slot].state = State.EXITING;

        challenges[slot].remove(challengingTxHash);
        emit RespondedExitChallenge(slot);
    }
    function challengeBetween(
        uint64 slot,
        uint256 challengingBlockNumber,
        bytes challengingTransaction,
        bytes proof,
        bytes signature)
        external isState(slot, State.EXITING) cleanupExit(slot)
    {
        checkBetween(slot, challengingTransaction, challengingBlockNumber, signature, proof);
        applyPenalties(slot);
    }

    function challengeAfter(
        uint64 slot,
        uint256 challengingBlockNumber,
        bytes challengingTransaction,
        bytes proof,
        bytes signature)
        external
        isState(slot, State.EXITING)
        cleanupExit(slot)
    {
        checkAfter(slot, challengingTransaction, challengingBlockNumber, signature, proof);
        applyPenalties(slot);
    }

    // Check that the challenging transaction has been signed
    // by the attested parentious owner of the coin in the exit
    function checkBetween(
        uint64 slot,
        bytes txBytes,
        uint blockNumber, 
        bytes signature, 
        bytes proof
    ) 
        private 
        view 
    {
        require(
            coins[slot].exit.exitBlock > blockNumber &&
            coins[slot].exit.parentBlock < blockNumber,
            "Tx should be between the exit's blocks"
        );

        Transaction.TX memory txData = txBytes.decodeTx();
        require(txData.hash.ecverify(signature, coins[slot].exit.parentOwner), "Invalid signature");
        require(txData.slot == slot, "Tx is referencing another slot");
        checkTxIncluded(slot, txData.hash, blockNumber, proof);
    }

    function checkAfter(uint64 slot, bytes txBytes, uint blockNumber, bytes signature, bytes proof) private view {
        Transaction.TX memory txData = txBytes.decodeTx();
        require(txData.hash.ecverify(signature, coins[slot].exit.owner), "Invalid signature");
        require(txData.slot == slot, "Tx is referencing another slot");
        require(txData.parentBlock == coins[slot].exit.exitBlock, "Not a direct spend");
        checkTxIncluded(slot, txData.hash, blockNumber, proof);
    }

    // stack too deep helper
    function checkResponse(
        uint64 slot,
        uint256 index,
        uint256 blockNumber,
        bytes txBytes,
        bytes signature,
        bytes proof
    )
        private
        view
    {
        Transaction.TX memory txData = txBytes.decodeTx();
        require(txData.hash.ecverify(signature, challenges[slot][index].owner), "Invalid signature");
        require(txData.slot == slot, "Tx is referencing another slot");
        require(blockNumber > challenges[slot][index].challengingBlockNumber);
        checkTxIncluded(txData.slot, txData.hash, blockNumber, proof);
    }


    function applyPenalties(uint64 slot) private {
        // Apply penalties and change state
        slashBond(coins[slot].exit.owner, msg.sender);
        coins[slot].state = State.DEPOSITED;
    }

    /// @param slot The slot of the coin being challenged
    /// @param owner The user claimed to be the true ower of the coin
    function setChallenged(uint64 slot, address owner, uint256 challengingBlockNumber, bytes32 txHash) private {
        // Require that the challenge is in the first half of the challenge window
        require(block.timestamp <= coins[slot].exit.createdAt + CHALLENGE_WINDOW);

        require(!challenges[slot].contains(txHash),
                "Transaction used for challenge already");

        // Need to save the exiting transaction's owner, to verify
        // that the response is valid
        challenges[slot].push(
            ChallengeLib.Challenge({
                owner: owner,
                challenger: msg.sender,
                txHash: txHash,
                challengingBlockNumber: challengingBlockNumber
            })
        );

        emit ChallengedExit(slot, txHash);
    }

    function checkTxIncluded(
        uint64 slot, 
        bytes32 txHash, 
        uint256 blockNumber,
        bytes proof
    ) 
        private 
        view 
    {
        bytes32 root = childChain[blockNumber].root;
        require(checkMembership(
                    txHash,
                    root,
                    slot,
                    proof
                ),
            "Tx not included in claimed block"
        );
    }

    function slashBond(address from, address to) internal {
        balances[from].bonded = balances[from].bonded.sub(BOND_AMOUNT);
        balances[to].withdrawable = balances[to].withdrawable.add(BOND_AMOUNT);
        emit SlashedBond(from, to, BOND_AMOUNT);
    }

    /// @notice If the slot's exit is not found, a large number is returned to
    ///         ensure the exit array access fails
    /// @param slot The slot being exited
    /// @return The index of the slot's exit in the exitSlots array
    function getExitIndex(uint64 slot) internal view returns (uint256) {
        uint256 len = exitSlots.length;
        for (uint256 i = 0; i < len; i++) {
            if (exitSlots[i] == slot)
                return i;
        }
        // a default value to return larger than the possible number of coins
        return 2**65;
    }
}
