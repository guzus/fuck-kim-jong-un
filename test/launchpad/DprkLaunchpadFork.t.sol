// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {KimJongUn} from "../../src/KimJongUn.sol";
import {DprkPass} from "../../src/launchpad/DprkPass.sol";
import {DprkLaunchpad} from "../../src/launchpad/DprkLaunchpad.sol";
import {DprkToken} from "../../src/launchpad/DprkToken.sol";
import {IDprkLaunchpad} from "../../src/launchpad/interfaces/IDprkLaunchpad.sol";
import {IDprkToken} from "../../src/launchpad/interfaces/IDprkToken.sol";
import {IPancakeV2Factory, IPancakeV2Pair, IWBNB} from "../../src/launchpad/interfaces/IPancakeV2.sol";

interface IPancakeRouter02 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
    function swapExactETHForTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline)
        external
        payable
        returns (uint256[] memory amounts);
    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

contract PlainToken is ERC20 {
    constructor() ERC20("Plain", "PLN") {
        _mint(msg.sender, 1e27);
    }
}

/// @notice Full flow against real PancakeSwap V2 and WBNB on a BSC mainnet fork. Runs only with BSC_RPC_URL set:
///   BSC_RPC_URL=https://bsc-dataseed.bnbchain.org forge test --match-path 'test/launchpad/*Fork*' -vv
contract DprkLaunchpadForkTest is Test {
    address internal constant FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant V0 = 8 ether;
    uint256 internal constant L = 200_000_000e18;

    bool internal forked;
    KimJongUn internal kimJongUn;
    DprkPass internal pass;
    DprkLaunchpad internal launchpad;

    address internal owner = makeAddr("owner");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal mallory = makeAddr("mallory");

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        assertEq(block.chainid, 56, "BSC_RPC_URL must point at BSC mainnet");
        assertEq(IPancakeRouter02(ROUTER).factory(), FACTORY);
        assertEq(IPancakeRouter02(ROUTER).WETH(), WBNB);

        kimJongUn = new KimJongUn();
        pass = new DprkPass(address(kimJongUn), "DPRK.FUN Not-Lazarus Pass", "NOTLAZ");
        launchpad = new DprkLaunchpad(address(pass), FACTORY, WBNB, feeRecipient, owner, V0, 100);
        address[3] memory users = [alice, bob, carol];
        for (uint256 i; i < users.length; ++i) {
            vm.startPrank(users[i]);
            kimJongUn.pig();
            kimJongUn.fuck();
            pass.claim();
            vm.stopPrank();
            vm.deal(users[i], 100 ether);
        }
        vm.deal(mallory, 100 ether);
    }

    modifier onlyFork() {
        if (!forked) vm.skip(true, "BSC_RPC_URL not set");
        _;
    }

    function test_fork_fullFlowAndRouterSwap() public onlyFork {
        console.log("fork block", block.number);
        console.log("factory feeTo", IPancakeV2Factory(FACTORY).feeTo());

        vm.prank(alice);
        (address token, uint256 creatorTokens) =
            launchpad.createToken{value: 1 ether}("Kim Pig", "KPIG", '{"description":"oink"}', 0, block.timestamp);
        assertGt(creatorTokens, 0);

        vm.prank(bob);
        uint256 bobTokens = launchpad.buy{value: 5 ether}(token, 0, block.timestamp);
        vm.startPrank(bob);
        DprkToken(token).approve(address(launchpad), bobTokens);
        uint256 bobBnb = launchpad.sell(token, bobTokens / 2, 0, block.timestamp);
        vm.stopPrank();
        assertGt(bobBnb, 0);

        // Completing buy with a refund graduates inline on the real factory.
        (,, uint256 gross,) = launchpad.quoteBuy(token, type(uint256).max);
        uint256 carolBefore = carol.balance;
        uint256 gasBefore = gasleft();
        vm.prank(carol);
        launchpad.buy{value: gross + 3 ether}(token, 0, block.timestamp);
        console.log("graduating buy gas (incl. real createPair)", gasBefore - gasleft());
        assertEq(carolBefore - carol.balance, gross, "refund");

        IDprkLaunchpad.TokenState memory s = launchpad.getTokenState(token);
        assertTrue(s.graduated);
        address pair = IPancakeV2Factory(FACTORY).getPair(token, WBNB);
        assertEq(s.pair, pair);
        (uint256 rb, uint256 rt) = _reserves(pair, token);
        assertEq(rt, L);
        assertEq(rb, s.realBnbReserve);
        assertGe(rb, launchpad.graduationBnb());
        assertGe(rb * s.virtualTokenReserve, s.virtualBnbReserve * rt, "pool price below curve price");
        assertEq(IPancakeV2Pair(pair).balanceOf(address(0)), 1000);
        assertEq(IPancakeV2Pair(pair).totalSupply(), IPancakeV2Pair(pair).balanceOf(DEAD) + 1000);
        assertEq(address(launchpad).balance, launchpad.accruedFees());
        console.log("graduation BNB", rb);
        console.log("LP burned to 0xdEaD", IPancakeV2Pair(pair).balanceOf(DEAD));

        // Real router swaps by an uncertified wallet: BNB -> token -> BNB.
        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = token;
        vm.prank(mallory);
        uint256[] memory amounts =
            IPancakeRouter02(ROUTER).swapExactETHForTokens{value: 1 ether}(0, path, mallory, block.timestamp);
        assertEq(DprkToken(token).balanceOf(mallory), amounts[1]);
        assertGt(amounts[1], 0);

        path[0] = token;
        path[1] = WBNB;
        uint256 malloryBnb = mallory.balance;
        vm.startPrank(mallory);
        DprkToken(token).approve(ROUTER, amounts[1]);
        IPancakeRouter02(ROUTER).swapExactTokensForETH(amounts[1], 0, path, mallory, block.timestamp);
        vm.stopPrank();
        assertGt(mallory.balance, malloryBnb);
        console.log("router round trip: 1 BNB in, back", mallory.balance - malloryBnb);

        // Fees are claimable.
        uint256 fees = launchpad.claimFees();
        assertEq(feeRecipient.balance, fees);
    }

    /// @notice Premise 2 on real contracts: donate WBNB + sync bricks router.addLiquidityETH, but not our mint.
    function test_fork_donateAndSyncGriefing() public onlyFork {
        // Control: a plain token whose pair was griefed can't be seeded through the router.
        PlainToken plain = new PlainToken();
        address plainPair = IPancakeV2Factory(FACTORY).createPair(address(plain), WBNB);
        _donateAndSync(plainPair, 1 ether);
        plain.approve(ROUTER, L);
        vm.expectRevert(bytes("PancakeLibrary: INSUFFICIENT_LIQUIDITY"));
        IPancakeRouter02(ROUTER).addLiquidityETH{value: 24 ether}(address(plain), L, 0, 0, DEAD, block.timestamp);

        // Same griefing against a DPRK.FUN token: the pair is created and WBNB donated before the token even
        // exists (CREATE addresses are predictable). The real pair's sync() needs token code, so the attacker
        // syncs right after creation, leaving reserves at (0 tokens, 1 WBNB).
        address predicted = vm.computeCreateAddress(address(launchpad), vm.getNonce(address(launchpad)));
        address pair = IPancakeV2Factory(FACTORY).createPair(predicted, WBNB);
        vm.startPrank(mallory);
        IWBNB(WBNB).deposit{value: 1 ether}();
        IWBNB(WBNB).transfer(pair, 1 ether);
        vm.expectRevert(); // sync() before the token has code: balanceOf on a non-contract
        IPancakeV2Pair(pair).sync();
        vm.stopPrank();

        vm.prank(alice);
        (address token,) = launchpad.createToken("Griefed", "GRF", "", 0, block.timestamp);
        assertEq(token, predicted);
        IPancakeV2Pair(pair).sync();
        (uint256 rb0, uint256 rt0) = _reserves(pair, token);
        assertEq(rb0, 1 ether);
        assertEq(rt0, 0);

        // Pre-graduation the pair can't receive tokens, so it can't be seeded or LP'd by anyone.
        vm.prank(bob);
        uint256 bobTokens = launchpad.buy{value: 2 ether}(token, 0, block.timestamp);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IDprkToken.TransferLocked.selector, bob, pair));
        DprkToken(token).transfer(pair, bobTokens);

        (,, uint256 gross,) = launchpad.quoteBuy(token, type(uint256).max);
        vm.prank(carol);
        launchpad.buy{value: gross}(token, 0, block.timestamp);

        IDprkLaunchpad.TokenState memory s = launchpad.getTokenState(token);
        assertTrue(s.graduated);
        assertEq(s.pair, pair);
        (uint256 rb, uint256 rt) = _reserves(pair, token);
        assertEq(rt, L);
        assertEq(rb, s.realBnbReserve + 1 ether); // the donation only raised the listing price
        assertGe(rb * s.virtualTokenReserve, s.virtualBnbReserve * rt);
        assertGt(IPancakeV2Pair(pair).balanceOf(DEAD), 0);
    }

    function _donateAndSync(address pair, uint256 amount) internal {
        vm.startPrank(mallory);
        IWBNB(WBNB).deposit{value: amount}();
        IWBNB(WBNB).transfer(pair, amount);
        IPancakeV2Pair(pair).sync();
        vm.stopPrank();
        (uint112 r0, uint112 r1,) = IPancakeV2Pair(pair).getReserves();
        assertTrue((r0 == 0) != (r1 == 0), "expected one-sided reserves");
    }

    function _reserves(address pair, address token) internal view returns (uint256 rb, uint256 rt) {
        (uint112 r0, uint112 r1,) = IPancakeV2Pair(pair).getReserves();
        (rb, rt) = IPancakeV2Pair(pair).token0() == token ? (uint256(r1), uint256(r0)) : (uint256(r0), uint256(r1));
    }
}
