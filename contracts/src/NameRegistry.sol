// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity 0.8.29;

/// @notice Self-set display names, shared across every lobby.
///
/// @dev A game about remembering who promised what, played entirely between addresses, asks people
///      to hold `0x4f2a…a2c1` in their heads and tell it apart from `0x4f1f…0676`. Tribe colour
///      carries some of that load; a name carries the rest.
///
///      Deliberately not part of `SurvivalGame`. A name belongs to a person, not to a lobby, and
///      storing it per game would mean setting it again for every game you join. Nothing on chain
///      reads this — it is display only, and no game logic depends on it, so an unset or duplicate
///      name can never affect a round.
contract NameRegistry {
    /// @notice The longest a name may be, in bytes.
    /// @dev Bounded because it is calldata a stranger will read: a name is a label, not a message,
    ///      and anything longer is someone using the field for something it is not.
    uint256 public constant MAX_LENGTH = 24;

    mapping(address => string) public nameOf;

    event NameSet(address indexed player, string name);

    error NameTooLong(uint256 length, uint256 max);

    /// @notice Sets the caller's display name. An empty string clears it.
    function setName(string calldata name) external {
        if (bytes(name).length > MAX_LENGTH) revert NameTooLong(bytes(name).length, MAX_LENGTH);
        nameOf[msg.sender] = name;
        emit NameSet(msg.sender, name);
    }

    /// @notice Names for several addresses at once.
    /// @dev One call rather than one per player: a roster of a hundred would otherwise be a hundred
    ///      round trips before anything renders.
    function namesOf(address[] calldata players) external view returns (string[] memory names) {
        names = new string[](players.length);
        for (uint256 i = 0; i < players.length; ++i) {
            names[i] = nameOf[players[i]];
        }
    }
}
