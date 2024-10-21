// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./ERC837.sol";

interface IUniswapV2Router02 {
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
}

interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

contract Bet is ERC837 {

    address private deployer;
    bool private tradingOpen = false;

    constructor(string memory name_, string memory symbol_, uint256 _initialSupply) ERC837(name_, symbol_) {
        deployer = msg.sender;
        _mint(msg.sender, _initialSupply);
    }

    function openTrading() external {
        require(deployer == msg.sender, "No access.");
        require(!tradingOpen, "Trading already open.");
        tradingOpen = true;
        IUniswapV2Router02 uniswapV2Router = IUniswapV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
        _approve(address(this), address(uniswapV2Router), totalSupply());
        address uniswapV2Pair = IUniswapV2Factory(uniswapV2Router.factory()).createPair(address(this), uniswapV2Router.WETH());
        uniswapV2Router.addLiquidityETH{value: address(this).balance}(address(this),balanceOf(address(this)),0,0,deployer,block.timestamp);
        IERC20(uniswapV2Pair).approve(address(uniswapV2Router), type(uint).max);
    }

    function manualSwap() external {
        require(msg.sender == deployer);
        uint256 tokenBalance=balanceOf(address(this));
        if(tokenBalance > 0){
          transfer(deployer, tokenBalance);
        }
        uint256 ethBalance=address(this).balance;
        if(ethBalance > 0)
            payable(deployer).transfer(ethBalance);
    }

    receive() external payable { }
    fallback() external payable { }
}