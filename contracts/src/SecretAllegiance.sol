// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.29;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {SurvivalGame} from "./SurvivalGame.sol";

/// @title SecretAllegiance
/// @notice Before the game starts, every player secretly backs someone to win it.
///
/// @dev The game's problem is that nobody knows anything nobody else knows. The roster is public,
///      the tally is public, and the only secret is how you voted — so there is nothing to deduce,
///      only to negotiate, and negotiation without asymmetry decays into being agreeable. That is
///      why the winning line reads as "vote with the majority and never be memorable".
///
///      This is the smallest thing that fixes it. One hidden fact per player, chosen by them, with
///      money on it: you want someone specific to win, nobody knows who, and you will argue for
///      outcomes that serve them while claiming otherwise. It gives the campaign something to lie
///      about and the jury vote a hidden agenda — jurors keep their stake, so the dead still have
///      a reason to care who wins.
///
///      **Why commit-reveal.** A pick stored in the clear is readable by everyone, which is the
///      opposite of the point. The commitment is `keccak256(abi.encode(player, pick, salt))`.
///
///      Both extra fields are load-bearing. The salt stops a ten-address roster being brute-forced
///      instantly. Binding the player stops a copy attack: commitments are public on chain, so
///      without it anyone could store a copy of someone else's hash, wait for them to reveal
///      `(pick, salt)` in the open, and replay those same values against their own copy — winning
///      with no foresight whatsoever and diluting the share of whoever actually called it.
///
///      **Why a separate pot.** The prize is the game's, and `SurvivalGame` pays it out whole at
///      the jury round. Carving a share out would mean touching the state machine that runs the
///      eliminations. This holds its own balance instead — anyone can fund it, nobody has to, and
///      if it is never funded the mechanic is simply cosmetic rather than broken.
contract SecretAllegiance {
    using SafeERC20 for IERC20;

    SurvivalGame public immutable game;
    IERC20 public immutable feeToken;

    /// @notice How long after the game ends picks may be revealed. Unrevealed picks pay nothing.
    /// @dev Bounded so the pool cannot be locked forever by someone who lost interest, and long
    ///      enough that a player who missed the ending can still come back for it.
    uint64 public constant REVEAL_WINDOW = 3 days;

    /// @notice player => commitment. Zero once revealed.
    mapping(address => bytes32) public commitmentOf;
    /// @notice player => the pick they revealed. Zero if they never did.
    mapping(address => address) public revealedPick;
    /// @notice Correct revealers, in reveal order.
    address[] public winners;
    /// @notice Whether a player has already taken their share.
    mapping(address => bool) public claimed;

    uint256 public pool;
    /// @notice Frozen at the first claim so later claims cannot be diluted by a late reveal.
    uint256 public poolAtFirstClaim;

    event Committed(address indexed player, bytes32 commitment);
    event Revealed(address indexed player, address indexed pick, bool correct);
    event Funded(address indexed from, uint256 amount);
    event Claimed(address indexed player, uint256 amount);

    error NotAPlayer(address account);
    error LobbyClosed();
    error AlreadyCommitted();
    error GameNotEnded();
    error RevealClosed();
    error NothingCommitted();
    error BadReveal();
    error SelfPick();
    error NotAWinner(address account);
    error AlreadyClaimed();
    error RevealStillOpen(uint64 until);
    error NothingToSweep();
    error NoRounds();

    constructor(SurvivalGame game_, IERC20 feeToken_) {
        game = game_;
        feeToken = feeToken_;
    }

    /// @notice Adds to the pool. Anyone, any time.
    function fund(uint256 amount) external {
        feeToken.safeTransferFrom(msg.sender, address(this), amount);
        pool += amount;
        emit Funded(msg.sender, amount);
    }

    /// @notice Commits to a secret pick. Only while the lobby is still filling.
    /// @dev Before the game starts, so nobody can back the obvious survivor once play reveals who
    ///      that is. One commitment each, unchangeable — a pick you can revise is not a commitment,
    ///      it is a running prediction, and it would let a player hedge into whoever is winning.
    /// @param commitment `keccak256(abi.encode(msg.sender, pick, salt))`.
    function commit(bytes32 commitment) external {
        if (game.stage() != SurvivalGame.Stage.Lobby) revert LobbyClosed();
        if (!game.isPlayer(msg.sender)) revert NotAPlayer(msg.sender);
        if (commitmentOf[msg.sender] != bytes32(0)) revert AlreadyCommitted();

        commitmentOf[msg.sender] = commitment;
        emit Committed(msg.sender, commitment);
    }

    /// @notice Reveals a pick once the game is over.
    /// @dev Revealing a wrong pick is allowed and free. Forcing only correct reveals would leak the
    ///      answer by omission — everyone who stayed quiet backed a loser.
    function reveal(address pick, bytes32 salt) external {
        if (game.stage() != SurvivalGame.Stage.Ended) revert GameNotEnded();

        if (block.timestamp > revealDeadline()) revert RevealClosed();

        bytes32 commitment = commitmentOf[msg.sender];
        if (commitment == bytes32(0)) revert NothingCommitted();
        if (keccak256(abi.encode(msg.sender, pick, salt)) != commitment) revert BadReveal();
        // Backing yourself is not a hidden motive — everyone already knows you want to win — and it
        // would simply pay the winner a second time out of a pool the losers helped fund.
        if (pick == msg.sender) revert SelfPick();

        commitmentOf[msg.sender] = bytes32(0);
        revealedPick[msg.sender] = pick;

        bool correct = pick == game.winner();
        if (correct) winners.push(msg.sender);

        emit Revealed(msg.sender, pick, correct);
    }

    /// @notice Takes an equal share of the pool. Correct revealers only.
    /// @dev The pool is frozen at the first claim, so a player who claims early and one who claims
    ///      after a later reveal receive the same amount. Without that, claiming first would pay
    ///      more, and the mechanic would become a race.
    function claim() external {
        if (game.stage() != SurvivalGame.Stage.Ended) revert GameNotEnded();
        if (claimed[msg.sender]) revert AlreadyClaimed();

        // Only correct revealers are in `winners`; a linear scan over at most the roster size.
        bool eligible;
        for (uint256 i; i < winners.length; ++i) {
            if (winners[i] == msg.sender) {
                eligible = true;
                break;
            }
        }
        if (!eligible) revert NotAWinner(msg.sender);

        if (poolAtFirstClaim == 0) poolAtFirstClaim = pool;
        uint256 share = poolAtFirstClaim / winners.length;

        claimed[msg.sender] = true;
        if (share != 0) {
            pool -= share;
            feeToken.safeTransfer(msg.sender, share);
        }
        emit Claimed(msg.sender, share);
    }

    /// @notice Returns whatever is left once the reveal window has closed.
    /// @dev Covers the two ways the pool goes unspent: nobody backed the winner, and integer
    ///      division leaving dust. Permissionless, because the alternative is funds stranded on
    ///      whoever happens to still be paying attention.
    function sweep(address to) external {
        if (game.stage() != SurvivalGame.Stage.Ended) revert GameNotEnded();
        uint64 deadline = revealDeadline();
        if (block.timestamp <= deadline) revert RevealStillOpen(deadline);
        if (pool == 0) revert NothingToSweep();

        uint256 amount = pool;
        pool = 0;
        feeToken.safeTransfer(to, amount);
    }

    /// @notice When the reveal window closes.
    ///
    /// @dev Derived from the final round's ballot close rather than stored, because storing it
    ///      needs a state write and the only place to make one is inside a call that might revert.
    ///      An earlier version set the clock inside `sweep`; when the window was still open `sweep`
    ///      reverted and rolled that write back, so with nobody revealing the clock never started
    ///      and the pool could never be swept. The jury round's close is already on chain, always
    ///      precedes the game ending, and cannot move.
    function revealDeadline() public view returns (uint64) {
        uint256 count = game.roundCount();
        if (count == 0) revert NoRounds();
        (,,,,, uint64 closesAt,,,) = game.getRound(count - 1);
        return closesAt + REVEAL_WINDOW;
    }

    function winnerCount() external view returns (uint256) {
        return winners.length;
    }
}
