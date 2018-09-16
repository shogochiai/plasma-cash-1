pragma solidity ^0.4.24;

import "./PlasmaDeposits.sol";

contract PlasmaExits is PlasmaDeposits {
    /**
     * Event for block submission logging
     * @notice The event indicates the addition of a new Plasma block
     * @param blockNumber The block number of the submitted block
     * @param root The root hash of the Merkle tree containing all of a block's
     *             transactions.
     * @param timestamp The time when a block was added to the Plasma chain
     */
    event SubmittedBlock(uint256 blockNumber, bytes32 root, uint256 timestamp);

    /**
     * Event for logging exit starts
     * @param slot The slot of the coin being exited
     * @param owner The user who claims to own the coin being exited
     */
    event StartedExit(uint64 indexed slot, address indexed owner);


    struct Balance {
        uint256 bonded;
        uint256 withdrawable;
    }
    mapping (address => Balance) public balances;

    uint256 constant BOND_AMOUNT = 0.1 ether;
    uint64[] public exitSlots;

    modifier isState(uint64 slot, State state) {
        require(coins[slot].state == state, "Wrong state");
        _;
    }

    modifier isBonded() {
        require(msg.value == BOND_AMOUNT);
        // Save challenger's bond
        balances[msg.sender].bonded = balances[msg.sender].bonded.add(msg.value);
        _;
    }

    // Exits a coin directly after depositing it
    // The only challenge that applies here is challengeAfter
    // No need for challenges for this optimistic exit
    function startDepositExit(uint64 slot) 
        external
        payable isBonded
        isState(slot, State.DEPOSITED)
    {
        require(coins[slot].owner == msg.sender, "Invalid sender");
        _startExit(slot, msg.sender, [0, coins[slot].depositBlock]);
    }

    function startExit(
        uint64 slot,
        address parentOwner,
        uint256[2] blocks)
        external
        payable isBonded
        isState(slot, State.DEPOSITED)
    {
        _startExit(slot, parentOwner, blocks);
    }

    function _startExit(uint64 slot, address parentOwner, uint256[2] blocks) private {
        // Create exit
        Coin storage c = coins[slot];
        c.exit = Exit({
            parentOwner: parentOwner,
            owner: msg.sender,
            createdAt: block.timestamp,
            bond: msg.value,
            parentBlock: blocks[0],
            exitBlock: blocks[1]
        });

        // Update coin state
        c.state = State.EXITING;

        // Push exit to list
        exitSlots.push(slot);

        emit StartedExit(slot, msg.sender);
    }

    function getExit(uint64 slot) external view returns(address, uint256, uint256, State) {
        Exit memory e = coins[slot].exit;
        return (e.owner, e.parentBlock, e.exitBlock, coins[slot].state);
    }
}
