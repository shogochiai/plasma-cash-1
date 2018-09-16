pragma solidity ^0.4.24;

import "./PlasmaChallenges.sol";

contract PlasmaFinalizeExits is PlasmaChallenges {
    /**
     * Event for exit finalization logging
     * @param slot The slot of the coin whose exit has been finalized
     * @param owner The owner of the coin whose exit has been finalized
     */
    event FinalizedExit(uint64 indexed slot, address owner);

    /**
     * Event to log the freeing of a bond
     * @param from The address of the user whose bonds have been freed
     * @param amount The bond amount which can now be withdrawn
     */
    event FreedBond(address indexed from, uint256 amount);

    // An exit can be finalized after it has matured,
    // after T2 = T0 + MATURITY_PERIOD
    // An exit can be challenged in the first window
    // between T0 and T1 ( T1 = T0 + CHALLENGE_WINDOW)
    // A challenge can be responded to in the second window
    // between T1 and T2
    uint256 constant MATURITY_PERIOD = 7 days;
    uint256 constant CHALLENGE_WINDOW = 3 days + 12 hours;

    /// @dev Finalizes an exit, i.e. puts the exiting coin into the EXITED
    ///      state which will allow it to be withdrawn, provided the exit has
    ///      matured and has not been successfully challenged
    function finalizeExit(uint64 slot) public {
        Coin storage coin = coins[slot];

        // If a coin is not under exit/challenge, then ignore it
        if (coin.state != State.EXITING)
            return;

        // If an exit is not matured, ignore it
        if ((block.timestamp - coin.exit.createdAt) <= MATURITY_PERIOD)
            return;

        // Check if there are any pending challenges for the coin.
        // `checkPendingChallenges` will also penalize
        // for each challenge that has not been responded to
        bool hasChallenges = checkPendingChallenges(slot);

        if (!hasChallenges) {
            // Update coin's owner
            coin.owner = coin.exit.owner;
            coin.state = State.EXITED;

            // Allow the exitor to withdraw their bond
            freeBond(coin.owner);

            emit FinalizedExit(slot, coin.owner);
        } else {
            // Reset coin state since it was challenged
            coin.state = State.DEPOSITED;
        }

        delete coins[slot].exit;
        delete exitSlots[getExitIndex(slot)];
    }

    /// @dev Iterates through all of the initiated exits and finalizes those
    ///      which have matured without being successfully challenged
    function finalizeExits() external {
        uint256 exitSlotsLength = exitSlots.length;
        for (uint256 i = 0; i < exitSlotsLength; i++) {
            finalizeExit(exitSlots[i]);
        }
    }

    function checkPendingChallenges(uint64 slot) private returns (bool hasChallenges) {
        uint256 length = challenges[slot].length;
        bool slashed;
        for (uint i = 0; i < length; i++) {
            if (challenges[slot][i].txHash != 0x0) {
                // Penalize the exitor and reward the first valid challenger. 
                if (!slashed) {
                    slashBond(coins[slot].exit.owner, challenges[slot][i].challenger);
                    slashed = true;
                }
                // Also free the bond of the challenger.
                freeBond(challenges[slot][i].challenger);

                // Challenge resolved, delete it
                delete challenges[slot][i];
                hasChallenges = true;
            }
        }
    }


    function freeBond(address from) private {
        balances[from].bonded = balances[from].bonded.sub(BOND_AMOUNT);
        balances[from].withdrawable = balances[from].withdrawable.add(BOND_AMOUNT);
        emit FreedBond(from, BOND_AMOUNT);
    }




}
