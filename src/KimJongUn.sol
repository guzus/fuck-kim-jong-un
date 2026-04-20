// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract KimJongUn {
    enum Action {
        Pig,
        Fuck
    }

    mapping(address => bool) public isRegardedAsNotNorthKoreanHackerActor;
    mapping(address => uint256) public pigCalls;
    mapping(address => uint256) public fuckCalls;

    uint256 public totalVerifiedAddresses;
    uint256 public totalPigCalls;
    uint256 public totalFuckCalls;

    event CallerRegardedAsNotNorthKoreanHackerActor(
        address indexed caller, Action indexed action, bool firstVerification
    );

    function hasPiggedKimJongUn(address account) public view returns (bool) {
        return pigCalls[account] > 0;
    }

    function hasFuckedKimJongUn(address account) public view returns (bool) {
        return fuckCalls[account] > 0;
    }

    function hasPiggedOrFuckedKimJongUn(address account) public view returns (bool) {
        return isRegardedAsNotNorthKoreanHackerActor[account];
    }

    function hasPiggedAndFuckedKimJongUn(address account) public view returns (bool) {
        return hasPiggedKimJongUn(account) && hasFuckedKimJongUn(account);
    }

    function pig() external {
        pigCalls[msg.sender] += 1;
        totalPigCalls += 1;
        _verifyCaller(Action.Pig);
    }

    function fuck() external {
        fuckCalls[msg.sender] += 1;
        totalFuckCalls += 1;
        _verifyCaller(Action.Fuck);
    }

    function _verifyCaller(Action action) internal {
        bool firstVerification = !isRegardedAsNotNorthKoreanHackerActor[msg.sender];

        if (firstVerification) {
            isRegardedAsNotNorthKoreanHackerActor[msg.sender] = true;
            totalVerifiedAddresses += 1;
        }

        emit CallerRegardedAsNotNorthKoreanHackerActor(msg.sender, action, firstVerification);
    }
}
