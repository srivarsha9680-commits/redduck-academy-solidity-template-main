// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

contract RPSCommitReveal {
    enum Move {
        None,
        Rock,
        Paper,
        Scissors
    }

    address public immutable player1;
    address public immutable player2;

    bytes32 public commit1;
    bytes32 public commit2;

    Move public reveal1;
    Move public reveal2;

    address public winner;
    bool public settled;

    error NotPlayer();
    error AlreadyCommitted();
    error WaitingForCommits();
    error AlreadyRevealed();
    error AlreadySettled();
    error InvalidMove();
    error HashMismatch();
    error InvalidPlayers();

    constructor(address _player1, address _player2) {
        if (_player1 == address(0) || _player2 == address(0) || _player1 == _player2) {
            revert InvalidPlayers();
        }

        player1 = _player1;
        player2 = _player2;
    }

    function commit(bytes32 hash) external {
        if (msg.sender != player1 && msg.sender != player2) {
            revert NotPlayer();
        }

        if (settled) revert AlreadySettled();

        if (hash == bytes32(0)) revert HashMismatch();

        if (msg.sender == player1) {
            if (commit1 != bytes32(0)) revert AlreadyCommitted();
            commit1 = hash;
        } else {
            if (commit2 != bytes32(0)) revert AlreadyCommitted();
            commit2 = hash;
        }
    }

    function reveal(Move move, bytes32 salt) external {
        if (msg.sender != player1 && msg.sender != player2) {
            revert NotPlayer();
        }

        if (settled) revert AlreadySettled();

        if (move != Move.Rock && move != Move.Paper && move != Move.Scissors) {
            revert InvalidMove();
        }

        if (commit1 == bytes32(0) || commit2 == bytes32(0)) {
            revert WaitingForCommits();
        }

        bytes32 expectedHash = keccak256(abi.encode(move, salt, msg.sender));

        if (msg.sender == player1) {
            if (reveal1 != Move.None) revert AlreadyRevealed();
            if (expectedHash != commit1) revert HashMismatch();

            reveal1 = move;
        } else {
            if (reveal2 != Move.None) revert AlreadyRevealed();
            if (expectedHash != commit2) revert HashMismatch();

            reveal2 = move;
        }

        if (reveal1 != Move.None && reveal2 != Move.None) {
            settled = true;

            if (reveal1 == reveal2) {
                winner = address(0);
            } else if (
                (reveal1 == Move.Rock && reveal2 == Move.Scissors) ||
                (reveal1 == Move.Paper && reveal2 == Move.Rock) ||
                (reveal1 == Move.Scissors && reveal2 == Move.Paper)
            ) {
                winner = player1;
            } else {
                winner = player2;
            }
        }
    }
}
